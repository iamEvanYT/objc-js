#include "subclass-impl.h"
#include "bridge.h"
#include "constants.h"
#include "debug.h"
#include "ffi-utils.h"
#include "forwarding-common.h"
#include "memory-utils.h"
#include "method-forwarding.h"
#include "ObjcObject.h"
#include "protocol-storage.h"
#include "runtime-detection.h"
#include "subclass-manager.h"
#include "super-call-helpers.h"
#include "type-conversion.h"
#include <Foundation/Foundation.h>
#include <atomic>
#include <chrono>
#include <napi.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sstream>

// MARK: - objc_msgSendSuper declarations

// Declare objc_msgSendSuper2 for super calls
// Note: On ARM64, there is no separate stret variant - it's handled automatically
// objc_msgSendSuper2 isn't in the headers but is exported
extern "C" id objc_msgSendSuper2(struct objc_super *super, SEL op, ...);

using nobjc::SubclassManager;

// MARK: - Forward Declarations for Method Forwarding

static BOOL SubclassRespondsToSelector(id self, SEL _cmd, SEL selector);
static NSMethodSignature *SubclassMethodSignatureForSelector(id self, SEL _cmd,
                                                              SEL selector);
static void SubclassForwardInvocation(id self, SEL _cmd,
                                       NSInvocation *invocation);
static void SubclassDeallocImplementation(id self, SEL _cmd);

// MARK: - Subclass Method Forwarding Implementation

static BOOL SubclassRespondsToSelector(id self, SEL _cmd, SEL selector) {
  @autoreleasepool {
  Class cls = object_getClass(self);
  void *clsPtr = (__bridge void *)cls;

  bool found = SubclassManager::Instance().WithLockConst([clsPtr, selector](const auto& map) {
    auto it = map.find(clsPtr);
    if (it != map.end()) {
      std::string selName(sel_getName(selector));
      auto methodIt = it->second.methods.find(selName);
      if (methodIt != it->second.methods.end()) {
        // Cache type encoding for subsequent SubclassMethodSignatureForSelector call
        GetForwardingCache().store(clsPtr, selector, methodIt->second.typeEncoding.c_str());
        return true;
      }
    }
    return false;
  });

  if (found) {
    return YES;
  }

  // Check superclass
  Class superClass = class_getSuperclass(cls);
  if (superClass != nil) {
    return [superClass instancesRespondToSelector:selector];
  }
  return NO;
  } // @autoreleasepool
}

static NSMethodSignature *SubclassMethodSignatureForSelector(id self, SEL _cmd,
                                                              SEL selector) {
  Class cls = object_getClass(self);
  void *clsPtr = (__bridge void *)cls;

  // Check forwarding pipeline cache first (populated by SubclassRespondsToSelector)
  auto& cache = GetForwardingCache();
  if (cache.matches(clsPtr, selector)) {
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:cache.typeEncoding];
    cache.invalidate();
    if (sig != nil) {
      return sig;
    }
  }

  NSMethodSignature *sig = SubclassManager::Instance().WithLockConst([clsPtr, selector](const auto& map) -> NSMethodSignature* {
    auto it = map.find(clsPtr);
    if (it != map.end()) {
      std::string selName(sel_getName(selector));
      auto methodIt = it->second.methods.find(selName);
      if (methodIt != it->second.methods.end()) {
        return [NSMethodSignature
            signatureWithObjCTypes:methodIt->second.typeEncoding.c_str()];
      }
    }
    return nil;
  });

  if (sig != nil) {
    return sig;
  }

  // Fall back to superclass
  Class superClass = class_getSuperclass(cls);
  if (superClass != nil) {
    return [superClass instanceMethodSignatureForSelector:selector];
  }
  return nil;
}

static void SubclassForwardInvocation(id self, SEL _cmd,
                                       NSInvocation *invocation) {
  @autoreleasepool {
  if (!invocation) {
    NOBJC_ERROR("SubclassForwardInvocation called with nil invocation");
    return;
  }

  [invocation retainArguments];
  [invocation retain];

  SEL selector = [invocation selector];
  std::string selectorName(sel_getName(selector));
  NOBJC_LOG("SubclassForwardInvocation: Called for selector %s", selectorName.c_str());

  Class cls = object_getClass(self);
  void *clsPtr = (__bridge void *)cls;
  void *selfPtr = (__bridge void *)self;

  NOBJC_LOG("SubclassForwardInvocation: Class=%s, clsPtr=%p", class_getName(cls), clsPtr);

  // Set up callbacks for subclass-specific storage access
  ForwardingCallbacks callbacks;
  callbacks.callbackType = CallbackType::Subclass;

  // Capture selfPtr for use in lookupContext
  void *capturedSelfPtr = selfPtr;

  // Lookup context and acquire TSFN
  callbacks.lookupContext = [capturedSelfPtr](void *lookupKey,
                               const std::string &selName) -> std::optional<ForwardingContext> {
    return SubclassManager::Instance().WithLock([lookupKey, &selName, capturedSelfPtr](auto& map) -> std::optional<ForwardingContext> {
      auto it = map.find(lookupKey);
      if (it == map.end()) {
        NOBJC_WARN("Subclass implementation not found for class %p", lookupKey);
        return std::nullopt;
      }

      auto methodIt = it->second.methods.find(selName);
      if (methodIt == it->second.methods.end()) {
        NOBJC_WARN("Method not found for selector %s", selName.c_str());
        return std::nullopt;
      }

      // Acquire the TSFN
      Napi::ThreadSafeFunction tsfn = methodIt->second.callback;
      napi_status acq_status = tsfn.Acquire();
      if (acq_status != napi_ok) {
        NOBJC_WARN("Failed to acquire ThreadSafeFunction for selector %s", selName.c_str());
        return std::nullopt;
      }

      ForwardingContext ctx;
      ctx.tsfn = tsfn;
      ctx.typeEncoding = methodIt->second.typeEncoding;
      ctx.js_thread = it->second.js_thread;
      ctx.env = it->second.env;
      ctx.skipDirectCallForElectron = false; // Subclass always tries direct call
      ctx.instancePtr = capturedSelfPtr;
      ctx.superClassPtr = it->second.superClass;
      
      // Cache the JS callback reference to avoid mutex re-acquisition
      ctx.cachedJsCallback = &methodIt->second.jsCallback;

      return ctx;
    });
  };

  // Get JS function for direct call path
  callbacks.getJSFunction = [](void *lookupKey, const std::string &selName,
                               Napi::Env /*env*/) -> Napi::Function {
    return SubclassManager::Instance().WithLock([lookupKey, &selName](auto& map) -> Napi::Function {
      auto it = map.find(lookupKey);
      if (it == map.end()) {
        return Napi::Function();
      }

      auto methodIt = it->second.methods.find(selName);
      if (methodIt == it->second.methods.end()) {
        return Napi::Function();
      }

      return methodIt->second.jsCallback.Value();
    });
  };

  // Re-acquire TSFN for fallback path
  callbacks.reacquireTSFN = [](void *lookupKey,
                               const std::string &selName) -> std::optional<Napi::ThreadSafeFunction> {
    return SubclassManager::Instance().WithLock([lookupKey, &selName](auto& map) -> std::optional<Napi::ThreadSafeFunction> {
      auto it = map.find(lookupKey);
      if (it == map.end()) {
        return std::nullopt;
      }

      auto methodIt = it->second.methods.find(selName);
      if (methodIt == it->second.methods.end()) {
        return std::nullopt;
      }

      Napi::ThreadSafeFunction tsfn = methodIt->second.callback;
      napi_status acq_status = tsfn.Acquire();
      if (acq_status != napi_ok) {
        return std::nullopt;
      }

      return tsfn;
    });
  };

  ForwardInvocationCommon(invocation, selectorName, clsPtr, callbacks);
  } // @autoreleasepool
}

static void SubclassDeallocImplementation(id self, SEL _cmd) {
  // Nothing special to clean up per-instance for subclasses
  // The class-level storage remains until explicitly disposed

  // Call super dealloc (handled by ARC, but we need to be careful)
  Class cls = object_getClass(self);
  Class superClass = class_getSuperclass(cls);
  if (superClass) {
    // Under ARC, dealloc is handled automatically
    // We don't need to call [super dealloc]
  }
}

// MARK: - Main DefineClass Implementation

Napi::Value DefineClass(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  // Validate arguments
  if (info.Length() < 1 || !info[0].IsObject()) {
    throw Napi::TypeError::New(
        env, "Expected an object argument with class definition");
  }

  Napi::Object definition = info[0].As<Napi::Object>();

  // Extract class name
  if (!definition.Has("name") || !definition.Get("name").IsString()) {
    throw Napi::TypeError::New(env, "Class definition must have 'name' string");
  }
  std::string className = definition.Get("name").As<Napi::String>().Utf8Value();

  // Check if class already exists
  if (NSClassFromString([NSString stringWithUTF8String:className.c_str()]) !=
      nil) {
    throw Napi::Error::New(
        env, "Class '" + className + "' already exists in the Objective-C runtime");
  }

  // Extract superclass
  Class superClass = nil;
  if (!definition.Has("superclass")) {
    throw Napi::TypeError::New(env,
                               "Class definition must have 'superclass'");
  }

  Napi::Value superValue = definition.Get("superclass");
  if (superValue.IsString()) {
    std::string superName = superValue.As<Napi::String>().Utf8Value();
    superClass =
        NSClassFromString([NSString stringWithUTF8String:superName.c_str()]);
    if (superClass == nil) {
      throw Napi::Error::New(env, "Superclass '" + superName + "' not found");
    }
  } else if (superValue.IsObject()) {
    Napi::Object superObj = superValue.As<Napi::Object>();
    if (superObj.InstanceOf(ObjcObject::constructor.Value())) {
      ObjcObject *objcObj = Napi::ObjectWrap<ObjcObject>::Unwrap(superObj);
      superClass = (Class)objcObj->objcObject;
    }
  }

  if (superClass == nil) {
    throw Napi::TypeError::New(
        env, "'superclass' must be a string or ObjcObject representing a Class");
  }

  // Detect Electron runtime
  bool isElectron = IsElectronRuntime(env);

  // Allocate the new class
  Class newClass = objc_allocateClassPair(superClass, className.c_str(), 0);
  if (newClass == nil) {
    throw Napi::Error::New(env,
                           "Failed to allocate class pair for '" + className + "'");
  }

  // Create the subclass implementation storage
  SubclassImplementation impl{
      .className = className,
      .objcClass = (__bridge void *)newClass,
      .superClass = (__bridge void *)superClass,
      .methods = {},
      .env = env,
      .js_thread = pthread_self(),
      .isElectron = isElectron,
  };

  // Add protocol conformance
  if (definition.Has("protocols") && definition.Get("protocols").IsArray()) {
    Napi::Array protocols = definition.Get("protocols").As<Napi::Array>();
    for (uint32_t i = 0; i < protocols.Length(); i++) {
      if (protocols.Get(i).IsString()) {
        std::string protoName =
            protocols.Get(i).As<Napi::String>().Utf8Value();
        Protocol *proto = objc_getProtocol(protoName.c_str());
        if (proto != nullptr) {
          class_addProtocol(newClass, proto);
        } else {
          NOBJC_WARN("Protocol %s not found", protoName.c_str());
        }
      }
    }
  }

  // Process method definitions
  if (definition.Has("methods") && definition.Get("methods").IsObject()) {
    Napi::Object methods = definition.Get("methods").As<Napi::Object>();
    Napi::Array methodNames = methods.GetPropertyNames();

    for (uint32_t i = 0; i < methodNames.Length(); i++) {
      Napi::Value key = methodNames.Get(i);
      if (!key.IsString())
        continue;

      std::string selectorName = key.As<Napi::String>().Utf8Value();
      Napi::Value methodDef = methods.Get(key);

      if (!methodDef.IsObject()) {
        NOBJC_WARN("Method definition for %s is not an object",
              selectorName.c_str());
        continue;
      }

      Napi::Object methodObj = methodDef.As<Napi::Object>();

      // Get type encoding
      if (!methodObj.Has("types") || !methodObj.Get("types").IsString()) {
        NOBJC_WARN("Method %s missing 'types' string", selectorName.c_str());
        continue;
      }
      std::string typeEncoding =
          methodObj.Get("types").As<Napi::String>().Utf8Value();

      // Get implementation function
      if (!methodObj.Has("implementation") ||
          !methodObj.Get("implementation").IsFunction()) {
        NOBJC_WARN("Method %s missing 'implementation' function",
              selectorName.c_str());
        continue;
      }
      Napi::Function jsImpl =
          methodObj.Get("implementation").As<Napi::Function>();

      SEL selector = sel_registerName(selectorName.c_str());

      // Create ThreadSafeFunction
      Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
          env, jsImpl, "SubclassMethod_" + selectorName, 0, 1,
          [](Napi::Env) {});

      // Store method info
      SubclassMethodInfo methodInfo{
          .callback = tsfn,
          .jsCallback = Napi::Persistent(jsImpl),
          .typeEncoding = typeEncoding,
          .selectorName = selectorName,
          .isClassMethod = false,
      };
      impl.methods[selectorName] = std::move(methodInfo);

      // Add the method with _objc_msgForward as IMP (triggers forwarding)
      // This ensures our forwardInvocation: gets called
      class_addMethod(newClass, selector, (IMP)_objc_msgForward,
                      typeEncoding.c_str());
    }
  }

  // Add message forwarding methods
  class_addMethod(newClass, @selector(respondsToSelector:),
                  (IMP)SubclassRespondsToSelector, "B@::");
  class_addMethod(newClass, @selector(methodSignatureForSelector:),
                  (IMP)SubclassMethodSignatureForSelector, "@@::");
  class_addMethod(newClass, @selector(forwardInvocation:),
                  (IMP)SubclassForwardInvocation, "v@:@");
  class_addMethod(newClass, sel_registerName("dealloc"),
                  (IMP)SubclassDeallocImplementation, "v@:");

  // Register the class
  objc_registerClassPair(newClass);

  // Store in manager
  void *classPtr = (__bridge void *)newClass;
  SubclassManager::Instance().Register(classPtr, std::move(impl));

  // Return the Class object
  return ObjcObject::NewInstance(env, newClass);
}

// MARK: - CallSuper Implementation

// FFI-based implementation to avoid infinite recursion
static Napi::Value CallSuperWithFFI(
    Napi::Env env,
    id self,
    Class superClass,
    SEL selector,
    NSMethodSignature* methodSig,
    const Napi::CallbackInfo& info,
    size_t argStartIndex) {
  
  std::string selectorName(sel_getName(selector));
  NOBJC_LOG("CallSuperWithFFI: selector=%s, self=%p, superClass=%s",
            selectorName.c_str(), self, class_getName(superClass));
  
  FFIArgumentContext ctx;
  
  try {
    // 1. Prepare objc_super struct
    struct objc_super superStruct;
    superStruct.receiver = self;
    superStruct.super_class = superClass;
    NOBJC_LOG("CallSuperWithFFI: superStruct at %p, receiver=%p, superclass=%s", 
              &superStruct, self, class_getName(superClass));
    
    // 2. Get return type info
    const char* returnEncoding = [methodSig methodReturnType];
    SimplifiedTypeEncoding simpleReturnEncoding(returnEncoding);
    
    // 3. Prepare FFI argument types
    size_t returnSize = 0;
    ffi_type* returnFFIType = PrepareFFIArgumentTypes(
        methodSig, simpleReturnEncoding.c_str(), &returnSize, ctx);
    
    // 4. Prepare FFI CIF
    ffi_cif cif;
    ffi_status status = ffi_prep_cif(
        &cif,
        FFI_DEFAULT_ABI,
        ctx.argFFITypes.size(),
        returnFFIType,
        ctx.argFFITypes.data()
    );
    
    if (status != FFI_OK) {
      CleanupAllocatedFFITypes(ctx.allocatedTypes);
      NOBJC_ERROR("CallSuperWithFFI: ffi_prep_cif failed with status %d", status);
      throw Napi::Error::New(env, "FFI preparation failed");
    }
    NOBJC_LOG("CallSuperWithFFI: FFI CIF prepared successfully");
    
    // 5. Add fixed arguments (objc_super* and SEL)
    AddFixedFFIArguments(&superStruct, selector, ctx);
    
    // 6. Extract method arguments from JS
    ExtractMethodArguments(env, info, argStartIndex, methodSig, superClass, selectorName, ctx);
    
    // 7. Log setup for debugging
    void* msgSendFn = (void*)objc_msgSendSuper;
    LogFFICallSetup(msgSendFn, ctx.argValues, superStruct, superClass, methodSig);
    
    // 8. Execute FFI call and convert result
    Napi::Value result = ExecuteFFICallAndConvert(
        env, &cif, msgSendFn, ctx, simpleReturnEncoding.c_str(), returnSize);
    
    // 9. Cleanup
    CleanupAllocatedFFITypes(ctx.allocatedTypes);
    return result;
    
  } catch (const std::exception& e) {
    CleanupAllocatedFFITypes(ctx.allocatedTypes);
    NOBJC_ERROR("CallSuperWithFFI: Exception: %s", e.what());
    throw;
  } catch (...) {
    CleanupAllocatedFFITypes(ctx.allocatedTypes);
    NOBJC_ERROR("CallSuperWithFFI: Unknown exception");
    throw;
  }
}

// MARK: - CallSuper Helper Functions

/// Find superclass from the subclass registry or fall back to direct superclass.
static Class FindSuperClass(id self) {
  Class instanceClass = object_getClass(self);
  
  NOBJC_LOG("FindSuperClass: instanceClass=%s", class_getName(instanceClass));
  
  // Walk up the class hierarchy to find our subclass implementation
  Class cls = instanceClass;
  while (cls != nil) {
    void *clsPtr = (__bridge void *)cls;
    
    Class superClass = SubclassManager::Instance().WithLockConst([clsPtr](const auto& map) -> Class {
      auto it = map.find(clsPtr);
      if (it != map.end()) {
        return (__bridge Class)it->second.superClass;
      }
      return nil;
    });
    
    if (superClass != nil) {
      NOBJC_LOG("FindSuperClass: Found superclass from registry: %s", 
                class_getName(superClass));
      return superClass;
    }
    cls = class_getSuperclass(cls);
  }
  
  // Fall back to direct superclass
  Class superClass = class_getSuperclass(instanceClass);
  NOBJC_LOG("FindSuperClass: Using direct superclass: %s", 
            superClass ? class_getName(superClass) : "nil");
  return superClass;
}

/// Direct objc_msgSendSuper call for methods without arguments.
static Napi::Value CallSuperNoArgs(
    Napi::Env env,
    id self,
    Class superClass,
    SEL selector,
    const char* returnType,
    const std::string& selectorName) {
  
  struct objc_super superStruct;
  superStruct.receiver = self;
  superStruct.super_class = superClass;
  
  NOBJC_LOG("CallSuperNoArgs: Using direct objc_msgSendSuper for method without arguments");
  
  switch (returnType[0]) {
  case 'v': { // void
    NOBJC_LOG("CallSuperNoArgs: Calling void method");
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superStruct, selector);
    NOBJC_LOG("CallSuperNoArgs: Void method completed");
    return env.Undefined();
  }
  case '@':
  case '#': { // id or Class
    NOBJC_LOG("CallSuperNoArgs: Calling method returning id/Class");
    id result = ((id(*)(struct objc_super *, SEL))objc_msgSendSuper)(
        &superStruct, selector);
    NOBJC_LOG("CallSuperNoArgs: Method returned %p", result);
    if (result == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, result);
  }
  case 'B': { // BOOL
    BOOL result = ((BOOL(*)(struct objc_super *, SEL))objc_msgSendSuper)(
        &superStruct, selector);
    return Napi::Boolean::New(env, result);
  }
  case 'c':
  case 'i':
  case 's':
  case 'l': { // signed integers
    long result = ((long (*)(struct objc_super *, SEL))objc_msgSendSuper)(
        &superStruct, selector);
    return Napi::Number::New(env, result);
  }
  case 'C':
  case 'I':
  case 'S':
  case 'L': { // unsigned integers
    unsigned long result =
        ((unsigned long (*)(struct objc_super *, SEL))objc_msgSendSuper)(
            &superStruct, selector);
    return Napi::Number::New(env, result);
  }
  case 'q': { // long long / NSInteger
    long long result =
        ((long long (*)(struct objc_super *, SEL))objc_msgSendSuper)(
            &superStruct, selector);
    return Napi::Number::New(env, result);
  }
  case 'Q': { // unsigned long long / NSUInteger
    unsigned long long result =
        ((unsigned long long (*)(struct objc_super *, SEL))objc_msgSendSuper)(
            &superStruct, selector);
    return Napi::Number::New(env, result);
  }
  case 'f': { // float
    float result = ((float (*)(struct objc_super *, SEL))objc_msgSendSuper)(
        &superStruct, selector);
    return Napi::Number::New(env, result);
  }
  case 'd': { // double
    double result = ((double (*)(struct objc_super *, SEL))objc_msgSendSuper)(
        &superStruct, selector);
    return Napi::Number::New(env, result);
  }
  default: {
    throw Napi::Error::New(
        env, "Unsupported return type '" + std::string(1, returnType[0]) +
                 "' for super call to " + selectorName + ". Use simpler return types.");
  }
  }
}

Napi::Value CallSuper(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  // 1. Validate basic arguments
  if (info.Length() < 2) {
    throw Napi::TypeError::New(
        env, "CallSuper requires at least 2 arguments: self and selector");
  }

  // 2. Extract self
  if (!info[0].IsObject()) {
    throw Napi::TypeError::New(env, "First argument must be an ObjcObject (self)");
  }
  Napi::Object selfObj = info[0].As<Napi::Object>();
  if (!selfObj.InstanceOf(ObjcObject::constructor.Value())) {
    throw Napi::TypeError::New(env, "First argument must be an ObjcObject (self)");
  }
  ObjcObject *selfWrapper = Napi::ObjectWrap<ObjcObject>::Unwrap(selfObj);
  id self = selfWrapper->objcObject;

  // 3. Extract selector
  if (!info[1].IsString()) {
    throw Napi::TypeError::New(env, "Second argument must be a selector string");
  }
  std::string selectorName = info[1].As<Napi::String>().Utf8Value();
  SEL selector = sel_registerName(selectorName.c_str());
  
  NOBJC_LOG("CallSuper: selector=%s, self=%p, argCount=%zu", 
            selectorName.c_str(), self, info.Length() - 2);

  // 4. Find superclass
  Class superClass = FindSuperClass(self);
  if (superClass == nil) {
    NOBJC_ERROR("CallSuper: Could not determine superclass for super call");
    throw Napi::Error::New(env, "Could not determine superclass for super call");
  }

  // 5. Validate method and arguments
  const size_t providedArgCount = info.Length() - 2;
  NSMethodSignature *methodSig = ValidateSuperMethod(
      env, superClass, selector, selectorName, providedArgCount);

  // 6. Dispatch to appropriate call path
  if (providedArgCount > 0) {
    // Methods with arguments: use FFI approach
    NOBJC_LOG("CallSuper: Using FFI approach for method with arguments");
    return CallSuperWithFFI(env, self, superClass, selector, methodSig, info, 2);
  }

  // Methods without arguments: use direct objc_msgSendSuper
  const char *returnType = SimplifyTypeEncoding([methodSig methodReturnType]);
  return CallSuperNoArgs(env, self, superClass, selector, returnType, selectorName);
}
