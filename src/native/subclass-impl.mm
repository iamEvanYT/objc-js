#include "subclass-impl.h"
#include "bridge.h"
#include "debug.h"
#include "method-forwarding.h"
#include "ObjcObject.h"
#include "protocol-storage.h"
#include "type-conversion.h"
#include <Foundation/Foundation.h>
#include <atomic>
#include <chrono>
#include <napi.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sstream>

// MARK: - Global Storage Definition

std::unordered_map<void *, SubclassImplementation> g_subclasses;
std::mutex g_subclasses_mutex;

// MARK: - Forward Declarations for Method Forwarding

static BOOL SubclassRespondsToSelector(id self, SEL _cmd, SEL selector);
static NSMethodSignature *SubclassMethodSignatureForSelector(id self, SEL _cmd,
                                                              SEL selector);
static void SubclassForwardInvocation(id self, SEL _cmd,
                                       NSInvocation *invocation);
static void SubclassDeallocImplementation(id self, SEL _cmd);

// MARK: - Subclass Method Forwarding Implementation

static BOOL SubclassRespondsToSelector(id self, SEL _cmd, SEL selector) {
  Class cls = object_getClass(self);
  void *clsPtr = (__bridge void *)cls;

  {
    std::lock_guard<std::mutex> lock(g_subclasses_mutex);
    auto it = g_subclasses.find(clsPtr);
    if (it != g_subclasses.end()) {
      NSString *selectorString = NSStringFromSelector(selector);
      if (selectorString != nil) {
        std::string selName = [selectorString UTF8String];
        auto methodIt = it->second.methods.find(selName);
        if (methodIt != it->second.methods.end()) {
          return YES;
        }
      }
    }
  }

  // Check superclass
  Class superClass = class_getSuperclass(cls);
  if (superClass != nil) {
    return [superClass instancesRespondToSelector:selector];
  }
  return NO;
}

static NSMethodSignature *SubclassMethodSignatureForSelector(id self, SEL _cmd,
                                                              SEL selector) {
  Class cls = object_getClass(self);
  void *clsPtr = (__bridge void *)cls;

  {
    std::lock_guard<std::mutex> lock(g_subclasses_mutex);
    auto it = g_subclasses.find(clsPtr);
    if (it != g_subclasses.end()) {
      NSString *selectorString = NSStringFromSelector(selector);
      std::string selName = [selectorString UTF8String];
      auto methodIt = it->second.methods.find(selName);
      if (methodIt != it->second.methods.end()) {
        return [NSMethodSignature
            signatureWithObjCTypes:methodIt->second.typeEncoding.c_str()];
      }
    }
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
  if (!invocation) {
    NOBJC_ERROR("SubclassForwardInvocation called with nil invocation");
    return;
  }

  [invocation retainArguments];
  [invocation retain];

  SEL selector = [invocation selector];
  NSString *selectorString = NSStringFromSelector(selector);
  if (!selectorString) {
    NOBJC_ERROR("Failed to convert selector to string");
    [invocation release];
    return;
  }

  std::string selectorName = [selectorString UTF8String];
  
  Class cls = object_getClass(self);
  void *clsPtr = (__bridge void *)cls;

  Napi::ThreadSafeFunction tsfn;
  std::string typeEncoding;
  pthread_t js_thread;
  bool isElectron;
  void *superClassPtr = nullptr;

  {
    std::lock_guard<std::mutex> lock(g_subclasses_mutex);
    auto it = g_subclasses.find(clsPtr);
    if (it == g_subclasses.end()) {
      NOBJC_WARN("Subclass implementation not found for class %p", cls);
      [invocation release];
      return;
    }

    auto methodIt = it->second.methods.find(selectorName);
    if (methodIt == it->second.methods.end()) {
      NOBJC_WARN("Method not found for selector %s", selectorName.c_str());
      [invocation release];
      return;
    }

    tsfn = methodIt->second.callback;
    napi_status acq_status = tsfn.Acquire();
    if (acq_status != napi_ok) {
      NOBJC_WARN("Failed to acquire ThreadSafeFunction for selector %s",
            selectorName.c_str());
      [invocation release];
      return;
    }

    typeEncoding = methodIt->second.typeEncoding;
    js_thread = it->second.js_thread;
    isElectron = it->second.isElectron;
    superClassPtr = it->second.superClass;
  }

  bool is_js_thread = pthread_equal(pthread_self(), js_thread);

  auto data = new InvocationData();
  data->invocation = invocation;
  data->selectorName = selectorName;
  data->typeEncoding = typeEncoding;
  data->instancePtr = (__bridge void *)self;
  data->superClassPtr = superClassPtr;
  data->callbackType = CallbackType::Subclass;  // Set callback type

  napi_status status;

  if (is_js_thread && !isElectron) {
    // Direct call on JS thread (Node/Bun, NOT Electron)
    data->completionMutex = nullptr;
    data->completionCv = nullptr;
    data->isComplete = nullptr;

    tsfn.Release();

    Napi::Function jsFn;
    napi_env stored_env;
    {
      std::lock_guard<std::mutex> lock(g_subclasses_mutex);
      auto it = g_subclasses.find(clsPtr);
      if (it == g_subclasses.end()) {
        NOBJC_WARN("Subclass implementation not found for class %p (JS thread path)", cls);
        [invocation release];
        delete data;
        return;
      }

      auto methodIt = it->second.methods.find(selectorName);
      if (methodIt == it->second.methods.end()) {
        NOBJC_WARN("Method not found for selector %s (JS thread path)", 
                   selectorName.c_str());
        [invocation release];
        delete data;
        return;
      }

      stored_env = it->second.env;
      jsFn = methodIt->second.jsCallback.Value();
    }

    try {
      Napi::Env callEnv(stored_env);
      Napi::HandleScope scope(callEnv);
      CallJSCallback(callEnv, jsFn, data);  // Use unified CallJSCallback
      // CallJSCallback releases invocation and deletes data.
    } catch (const std::exception &e) {
      NOBJC_ERROR("Error calling JS callback directly (likely invalid env in Electron): %s", 
                  e.what());
      NOBJC_LOG("Falling back to ThreadSafeFunction for selector %s", 
                selectorName.c_str());
      
      // Fallback to TSFN if direct call fails
      {
        std::lock_guard<std::mutex> lock(g_subclasses_mutex);
        auto it = g_subclasses.find(clsPtr);
        if (it != g_subclasses.end()) {
          auto methodIt = it->second.methods.find(selectorName);
          if (methodIt != it->second.methods.end()) {
            tsfn = methodIt->second.callback;
            napi_status acq_status = tsfn.Acquire();
            if (acq_status == napi_ok) {
              // Use helper function for fallback
              if (FallbackToTSFN(tsfn, data, selectorName)) {
                return; // Data cleaned up in callback
              }
              NOBJC_ERROR("SubclassForwardInvocation: Fallback failed");
            }
          }
        }
      }
      
      // If fallback also failed, clean up manually
      [invocation release];
      delete data;
    }
  } else {
    // Cross-thread call via TSFN or Electron (always use TSFN)
    std::mutex completionMutex;
    std::condition_variable completionCv;
    bool isComplete = false;

    data->completionMutex = &completionMutex;
    data->completionCv = &completionCv;
    data->isComplete = &isComplete;

    status = tsfn.NonBlockingCall(data, CallJSCallback);  // Use unified CallJSCallback
    tsfn.Release();

    if (status != napi_ok) {
      NOBJC_ERROR("Failed to call ThreadSafeFunction for selector %s (status: %d)",
            selectorName.c_str(), status);
      [invocation release];
      delete data;
      return;
    }

    // Wait for callback via runloop pumping
    CFTimeInterval timeout = 0.001;
    int iterations = 0;
    while (true) {
      {
        std::unique_lock<std::mutex> lock(completionMutex);
        if (isComplete) {
          break;
        }
      }
      iterations++;
      if (iterations % 1000 == 0) {
        NOBJC_LOG("SubclassForwardInvocation: Still waiting... (%d iterations)", iterations);
      }
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout, true);
    }
  }
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

  // Detect Electron or Bun
  bool isElectron = false;
  bool isBun = false;
  try {
    Napi::Object global = env.Global();
    if (global.Has("process")) {
      Napi::Object process = global.Get("process").As<Napi::Object>();
      if (process.Has("versions")) {
        Napi::Object versions = process.Get("versions").As<Napi::Object>();
        isElectron = versions.Has("electron");
        isBun = versions.Has("bun");
      }
    }
  } catch (...) {
  }

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
      .isElectron = isElectron,  // Only Electron needs TSFN always; Bun works with direct calls
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

  // Store in global map
  void *classPtr = (__bridge void *)newClass;
  {
    std::lock_guard<std::mutex> lock(g_subclasses_mutex);
    g_subclasses.emplace(classPtr, std::move(impl));
  }

  // Return the Class object
  return ObjcObject::NewInstance(env, newClass);
}

// MARK: - CallSuper Implementation

Napi::Value CallSuper(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  // Args: self, selector, ...args
  if (info.Length() < 2) {
    throw Napi::TypeError::New(
        env, "CallSuper requires at least 2 arguments: self and selector");
  }

  // Get self
  if (!info[0].IsObject()) {
    throw Napi::TypeError::New(env, "First argument must be an ObjcObject (self)");
  }
  Napi::Object selfObj = info[0].As<Napi::Object>();
  if (!selfObj.InstanceOf(ObjcObject::constructor.Value())) {
    throw Napi::TypeError::New(env, "First argument must be an ObjcObject (self)");
  }
  ObjcObject *selfWrapper = Napi::ObjectWrap<ObjcObject>::Unwrap(selfObj);
  id self = selfWrapper->objcObject;

  // Get selector
  if (!info[1].IsString()) {
    throw Napi::TypeError::New(env, "Second argument must be a selector string");
  }
  std::string selectorName = info[1].As<Napi::String>().Utf8Value();
  SEL selector = sel_registerName(selectorName.c_str());
  
  NOBJC_LOG("CallSuper: selector=%s, self=%p, argCount=%zu", 
            selectorName.c_str(), self, info.Length() - 2);

  // Find the superclass
  Class instanceClass = object_getClass(self);
  Class superClass = nil;
  
  NOBJC_LOG("CallSuper: instanceClass=%s", class_getName(instanceClass));

  {
    std::lock_guard<std::mutex> lock(g_subclasses_mutex);
    // Walk up the class hierarchy to find our subclass implementation
    Class cls = instanceClass;
    while (cls != nil) {
      void *clsPtr = (__bridge void *)cls;
      auto it = g_subclasses.find(clsPtr);
      if (it != g_subclasses.end()) {
        superClass = (__bridge Class)it->second.superClass;
        NOBJC_LOG("CallSuper: Found superclass from registry: %s", 
                  class_getName(superClass));
        break;
      }
      cls = class_getSuperclass(cls);
    }
  }

  if (superClass == nil) {
    // Fall back to direct superclass
    superClass = class_getSuperclass(instanceClass);
    NOBJC_LOG("CallSuper: Using direct superclass: %s", 
              superClass ? class_getName(superClass) : "nil");
  }

  if (superClass == nil) {
    NOBJC_ERROR("CallSuper: Could not determine superclass for super call");
    throw Napi::Error::New(env, "Could not determine superclass for super call");
  }

  // Get method signature from superclass
  NSMethodSignature *methodSig =
      [superClass instanceMethodSignatureForSelector:selector];
  if (methodSig == nil) {
    NOBJC_ERROR("CallSuper: Selector '%s' not found on superclass %s", 
                selectorName.c_str(), class_getName(superClass));
    throw Napi::Error::New(
        env, "Selector '" + selectorName + "' not found on superclass");
  }
  
  NOBJC_LOG("CallSuper: Method signature: %s", [methodSig description].UTF8String);

  // Get the super method's IMP directly
  Method superMethod = class_getInstanceMethod(superClass, selector);
  if (superMethod == nil) {
    NOBJC_ERROR("CallSuper: Could not get method implementation for selector '%s'", 
                selectorName.c_str());
    throw Napi::Error::New(
        env, "Could not get method implementation for selector '" + selectorName +
                 "' from superclass");
  }
  
  NOBJC_LOG("CallSuper: Found method implementation at %p", 
            method_getImplementation(superMethod));

  // Validate argument count
  const size_t expectedArgCount = [methodSig numberOfArguments] - 2;
  const size_t providedArgCount = info.Length() - 2;
  
  NOBJC_LOG("CallSuper: Expected %zu args, provided %zu args", 
            expectedArgCount, providedArgCount);

  if (providedArgCount != expectedArgCount) {
    NOBJC_ERROR("CallSuper: Argument count mismatch for selector '%s'", 
                selectorName.c_str());
    throw Napi::Error::New(
        env, "Selector " + selectorName + " expected " +
                 std::to_string(expectedArgCount) + " argument(s), but got " +
                 std::to_string(providedArgCount));
  }

  // Create invocation but DON'T set it on self - we'll invoke the IMP directly
  NSInvocation *invocation =
      [NSInvocation invocationWithMethodSignature:methodSig];
  [invocation setSelector:selector];
  // Note: We set target to self because the IMP expects self as first arg
  [invocation setTarget:self];

  // Store arguments to keep them alive
  std::vector<ObjcType> storedArgs;
  storedArgs.reserve(providedArgCount);

  for (size_t i = 2; i < info.Length(); i++) {
    const ObjcArgumentContext context = {
        .className = std::string(class_getName(superClass)),
        .selectorName = selectorName,
        .argumentIndex = (int)(i - 2),
    };

    size_t argIndex = i; // Argument index in invocation (0=self, 1=_cmd, 2+=args)
    const char *typeEncoding =
        SimplifyTypeEncoding([methodSig getArgumentTypeAtIndex:argIndex]);
    
    NOBJC_LOG("CallSuper: Processing argument %zu, type encoding: %s", 
              i - 2, typeEncoding);

    // Handle ^@ (pointer to object) specially for out-params
    if (typeEncoding[0] == '^' && typeEncoding[1] == '@') {
      NOBJC_LOG("CallSuper: Argument %zu is pointer-to-object (out-param)", i - 2);
      // For super calls with NSError**, we need to pass the pointer through
      if (info[i].IsObject()) {
        // Pass nullptr - the super call will set it if needed
        id *errorPtr = nullptr;
        [invocation setArgument:&errorPtr atIndex:argIndex];
        NOBJC_LOG("CallSuper: Set out-param to nullptr");
        continue;
      }
    }

    auto arg = AsObjCArgument(info[i], typeEncoding, context);
    if (!arg.has_value()) {
      NOBJC_ERROR("CallSuper: Failed to convert argument %zu", i - 2);
      throw Napi::TypeError::New(
          env, "Unsupported argument type for argument " + std::to_string(i - 2));
    }
    NOBJC_LOG("CallSuper: Successfully converted argument %zu", i - 2);
    storedArgs.push_back(std::move(*arg));
    std::visit(
        [&](auto &&outer) {
          using OuterT = std::decay_t<decltype(outer)>;
          if constexpr (std::is_same_v<OuterT, BaseObjcType>) {
            std::visit(SetObjCArgumentVisitor{invocation, argIndex}, outer);
          } else if constexpr (std::is_same_v<OuterT, BaseObjcType *>) {
            if (outer)
              std::visit(SetObjCArgumentVisitor{invocation, argIndex}, *outer);
          }
        },
        storedArgs.back());
    NOBJC_LOG("CallSuper: Set argument %zu on invocation", i - 2);
  }

  // Invoke the super's IMP directly using the invocation mechanism
  // We need to call the IMP with the invocation's arguments
  // The key is to invoke WITH the super IMP, not through message dispatch

  // Use invokeUsingIMP: if available (private but works), or invoke directly
  // Since invokeUsingIMP: is private, we'll use a different approach:
  // Temporarily replace the method implementation, invoke, then restore

  // Actually, the cleanest approach is to use objc_msgSendSuper
  // Let's build the super struct and call it

  struct objc_super superStruct;
  superStruct.receiver = self;
  superStruct.super_class = superClass;
  
  NOBJC_LOG("CallSuper: Created objc_super struct (receiver=%p, super_class=%s)",
            self, class_getName(superClass));

  // For super calls, we use objc_msgSendSuper / objc_msgSendSuper_stret
  // depending on the return type. However, this is complex on ARM64.
  
  // Simpler approach: Use performSelector on the superclass directly
  // by getting the IMP and calling it

  // Even simpler: Temporarily add the method to the superclass and invoke
  // No wait - we can just call the IMP directly since we have it

  // The easiest way is to use the invocation but call [super's class method]
  // We'll create a helper object approach

  // Actually, let's use NSInvocation's invokeWithTarget: on a temporary proxy
  // that forwards to super. But that's complex.

  // Best approach: Just call the IMP directly with proper arguments
  // For methods with simple types, we can cast the IMP appropriately

  // For now, let's use invokeWithTarget: on an instance of the superclass
  // if we can get one, or use the direct IMP call for simple cases

  // The safest general approach: Use objc_msgSendSuper
  // This is what the compiler generates for [super method]

  const char *returnType = SimplifyTypeEncoding([methodSig methodReturnType]);
  
  NOBJC_LOG("CallSuper: Return type encoding: %s", returnType);
  NOBJC_LOG("CallSuper: About to call objc_msgSendSuper with %zu arguments", 
            providedArgCount);

  // CRITICAL: The issue is that the switch statement below only handles
  // methods WITHOUT arguments. For methods WITH arguments, we need to
  // use NSInvocation to properly forward all arguments.
  
  // If we have arguments, use NSInvocation approach instead of direct msgSend
  if (providedArgCount > 0) {
    NOBJC_LOG("CallSuper: Using NSInvocation approach for method with arguments");
    
    // Invoke using the invocation we already populated
    [invocation invoke];
    
    NOBJC_LOG("CallSuper: NSInvocation completed successfully");
    
    // Extract and return the result
    if (returnType[0] == 'v') {
      return env.Undefined();
    } else if (returnType[0] == '@' || returnType[0] == '#') {
      __unsafe_unretained id result = nil;
      [invocation getReturnValue:&result];
      NOBJC_LOG("CallSuper: Got return value: %p", result);
      if (result == nil) {
        return env.Null();
      }
      return ObjcObject::NewInstance(env, result);
    } else {
      // For other return types, extract appropriately
      switch (returnType[0]) {
        case 'B': {
          BOOL result;
          [invocation getReturnValue:&result];
          return Napi::Boolean::New(env, result);
        }
        case 'c':
        case 'i':
        case 's':
        case 'l': {
          long result;
          [invocation getReturnValue:&result];
          return Napi::Number::New(env, result);
        }
        case 'q': {
          long long result;
          [invocation getReturnValue:&result];
          return Napi::Number::New(env, result);
        }
        case 'Q': {
          unsigned long long result;
          [invocation getReturnValue:&result];
          return Napi::Number::New(env, result);
        }
        case 'f': {
          float result;
          [invocation getReturnValue:&result];
          return Napi::Number::New(env, result);
        }
        case 'd': {
          double result;
          [invocation getReturnValue:&result];
          return Napi::Number::New(env, result);
        }
        default:
          NOBJC_ERROR("CallSuper: Unsupported return type '%c'", returnType[0]);
          throw Napi::Error::New(
              env, "Unsupported return type '" + std::string(1, returnType[0]) +
                       "' for super call");
      }
    }
  }

  // For methods WITHOUT arguments, use direct objc_msgSendSuper
  NOBJC_LOG("CallSuper: Using direct objc_msgSendSuper for method without arguments");

  switch (returnType[0]) {
  case 'v': { // void
    // Call and return undefined
    NOBJC_LOG("CallSuper: Calling void method");
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superStruct,
                                                             selector);
    NOBJC_LOG("CallSuper: Void method completed");
    return env.Undefined();
  }
  case '@':
  case '#': { // id or Class
    NOBJC_LOG("CallSuper: Calling method returning id/Class");
    id result = ((id(*)(struct objc_super *, SEL))objc_msgSendSuper)(
        &superStruct, selector);
    NOBJC_LOG("CallSuper: Method returned %p", result);
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
    // For complex return types or methods with arguments, fall back to
    // NSInvocation but invoke the IMP directly

    // This is a workaround: invoke on the superclass's implementation
    // by creating a temporary object or using method_invoke

    // For methods WITH arguments, we need a different approach
    // Let's use method_invoke which calls the IMP with an invocation

    // Actually, the safest thing is to just use the invocation
    // but make sure we're calling on the right implementation

    // For now, throw for unsupported return types
    throw Napi::Error::New(
        env, "Unsupported return type '" + std::string(1, returnType[0]) +
                 "' for super call. Use simpler return types.");
  }
  }
}
