#include "subclass-impl.h"
#include "bridge.h"
#include "debug.h"
#include "ffi-utils.h"
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

// MARK: - objc_msgSendSuper declarations

// Declare objc_msgSendSuper2 for super calls
// Note: On ARM64, there is no separate stret variant - it's handled automatically
// objc_msgSendSuper2 isn't in the headers but is exported
extern "C" id objc_msgSendSuper2(struct objc_super *super, SEL op, ...);

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
  
  NOBJC_LOG("SubclassForwardInvocation: Called for selector %s", selectorName.c_str());
  
  Class cls = object_getClass(self);
  void *clsPtr = (__bridge void *)cls;
  
  NOBJC_LOG("SubclassForwardInvocation: Class=%s, clsPtr=%p", class_getName(cls), clsPtr);

  Napi::ThreadSafeFunction tsfn;
  std::string typeEncoding;
  pthread_t js_thread;
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

  // IMPORTANT: Always try direct call when on JS thread (including Electron)
  // The direct call will catch exceptions and fall back to TSFN if needed
  // Only use TSFN+runloop when on a DIFFERENT thread
  if (is_js_thread) {
    // Direct call on JS thread (Node/Bun/Electron)
    NOBJC_LOG("SubclassForwardInvocation: Using direct call path (JS thread)");
    data->completionMutex = nullptr;
    data->completionCv = nullptr;
    data->isComplete = nullptr;

    tsfn.Release();

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
      // Don't get the function value here - do it inside the HandleScope
    }

    try {
      NOBJC_LOG("SubclassForwardInvocation: About to call JS callback directly");
      Napi::Env callEnv(stored_env);
      Napi::HandleScope scope(callEnv);
      
      // Get the JS function within the HandleScope
      Napi::Function jsFn;
      {
        std::lock_guard<std::mutex> lock(g_subclasses_mutex);
        auto it = g_subclasses.find(clsPtr);
        if (it != g_subclasses.end()) {
          auto methodIt = it->second.methods.find(selectorName);
          if (methodIt != it->second.methods.end()) {
            jsFn = methodIt->second.jsCallback.Value();
          }
        }
      }
      
      CallJSCallback(callEnv, jsFn, data);  // Use unified CallJSCallback
      // CallJSCallback releases invocation and deletes data.
      NOBJC_LOG("SubclassForwardInvocation: Direct call succeeded");
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
    // Cross-thread call via TSFN (NOT on JS thread)
    NOBJC_LOG("SubclassForwardInvocation: Using TSFN+runloop path (different thread)");
    std::mutex completionMutex;
    std::condition_variable completionCv;
    bool isComplete = false;

    data->completionMutex = &completionMutex;
    data->completionCv = &completionCv;
    data->isComplete = &isComplete;

    NOBJC_LOG("SubclassForwardInvocation: About to call NonBlockingCall for selector %s", 
              selectorName.c_str());

    status = tsfn.NonBlockingCall(data, CallJSCallback);  // Use unified CallJSCallback
    tsfn.Release();

    NOBJC_LOG("SubclassForwardInvocation: NonBlockingCall returned status=%d", status);

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

  // Detect Electron (bun is commented out as it's not needed)
  bool isElectron = false;
  // bool isBun = false;
  try {
    Napi::Object global = env.Global();
    if (global.Has("process")) {
      Napi::Object process = global.Get("process").As<Napi::Object>();
      if (process.Has("versions")) {
        Napi::Object versions = process.Get("versions").As<Napi::Object>();
        isElectron = versions.Has("electron");
        // isBun = versions.Has("bun");
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

// New FFI-based implementation to avoid infinite recursion
static Napi::Value CallSuperWithFFI(
    Napi::Env env,
    id self,
    Class superClass,
    SEL selector,
    NSMethodSignature* methodSig,
    const Napi::CallbackInfo& info,
    size_t argStartIndex) {
  
  std::string selectorName = NSStringFromSelector(selector).UTF8String;
  NOBJC_LOG("CallSuperWithFFI: selector=%s, self=%p, superClass=%s",
            selectorName.c_str(), self, class_getName(superClass));
  
  // Vector to track allocated FFI types for cleanup
  std::vector<ffi_type*> allocatedTypes;
  
  try {
    //1. Prepare objc_super struct  
    // Use objc_msgSendSuper (NOT Super2) with the superclass
    // This is the variant that works reliably on all platforms
    struct objc_super superStruct;
    superStruct.receiver = self;
    superStruct.super_class = superClass;
    NOBJC_LOG("CallSuperWithFFI: superStruct is at address %p", &superStruct);
    NOBJC_LOG("CallSuperWithFFI: receiver=%p, calling superclass=%s", 
              self, class_getName(superClass));
    
    // 2. Determine which objc_msgSend variant to use
    // Use objc_msgSendSuper with the superclass (matches the no-args case)
    const char* returnEncoding = [methodSig methodReturnType];
    SimplifiedTypeEncoding simpleReturnEncoding(returnEncoding);
    
    void* msgSendFn = (void*)objc_msgSendSuper;
    
    NOBJC_LOG("CallSuperWithFFI: Using objc_msgSendSuper with superclass");
    
    // 3. Build FFI type arrays for arguments
    size_t totalArgs = [methodSig numberOfArguments];
    std::vector<ffi_type*> argFFITypes;
    
    // First arg: objc_super pointer
    argFFITypes.push_back(&ffi_type_pointer);
    // Second arg: SEL
    argFFITypes.push_back(&ffi_type_pointer);
    
    // Remaining args: method arguments (starting from index 2)
    for (size_t i = 2; i < totalArgs; i++) {
      const char* argEncoding = [methodSig getArgumentTypeAtIndex:i];
      ffi_type* argType = GetFFITypeForEncoding(argEncoding, nullptr, allocatedTypes);
      argFFITypes.push_back(argType);
      NOBJC_LOG("CallSuperWithFFI: Arg %zu type encoding: %s", i - 2, argEncoding);
    }
    
    // 4. Build return FFI type
    size_t returnSize = 0;
    ffi_type* returnFFIType = GetFFITypeForEncoding(simpleReturnEncoding.c_str(), 
                                                     &returnSize, allocatedTypes);
    NOBJC_LOG("CallSuperWithFFI: Return type encoding: %s, size: %zu",
              simpleReturnEncoding.c_str(), returnSize);
    
    // 5. Prepare FFI CIF
    ffi_cif cif;
    ffi_status status = ffi_prep_cif(
        &cif,
        FFI_DEFAULT_ABI,
        argFFITypes.size(),
        returnFFIType,
        argFFITypes.data()
    );
    
    if (status != FFI_OK) {
      CleanupAllocatedFFITypes(allocatedTypes);
      NOBJC_ERROR("CallSuperWithFFI: ffi_prep_cif failed with status %d", status);
      throw Napi::Error::New(env, "FFI preparation failed");
    }
    
    NOBJC_LOG("CallSuperWithFFI: FFI CIF prepared successfully");
    
    // 6. Prepare argument value buffers
    std::vector<void*> argValues;
    std::vector<std::unique_ptr<uint8_t[]>> argBuffers;
    
    NOBJC_LOG("CallSuperWithFFI: Preparing argument buffers...");
    
    // Add objc_super pointer
    // libffi expects argValues[i] to point to the actual argument value
    // Store the pointer in a buffer to ensure it stays valid
    auto superPtrBuffer = std::make_unique<uint8_t[]>(sizeof(objc_super*));
    objc_super* superPtr = &superStruct;
    memcpy(superPtrBuffer.get(), &superPtr, sizeof(objc_super*));
    void* superPtrBufferRawPtr = superPtrBuffer.get();  // Get raw pointer before move
    argBuffers.push_back(std::move(superPtrBuffer));  // Move to keep alive
    argValues.push_back(superPtrBufferRawPtr);  // Add raw pointer to argValues
    NOBJC_LOG("CallSuperWithFFI: Added objc_super* buffer at %p (points to %p)", 
              superPtrBufferRawPtr, superPtr);
    
    // Add selector - also store in buffer
    auto selectorBuffer = std::make_unique<uint8_t[]>(sizeof(SEL));
    memcpy(selectorBuffer.get(), &selector, sizeof(SEL));
    void* selectorBufferRawPtr = selectorBuffer.get();  // Get raw pointer before move
    argBuffers.push_back(std::move(selectorBuffer));  // Move to keep alive
    argValues.push_back(selectorBufferRawPtr);  // Add raw pointer to argValues
    NOBJC_LOG("CallSuperWithFFI: Added SEL buffer at %p (value=%p, name=%s)", 
              selectorBufferRawPtr, selector, sel_getName(selector));
    
    // Add method arguments
    NOBJC_LOG("CallSuperWithFFI: Processing %zu method arguments...", info.Length() - argStartIndex);
    for (size_t i = argStartIndex; i < info.Length(); i++) {
      size_t argIndex = i - argStartIndex + 2; // +2 for self and _cmd
      const char* argEncoding = [methodSig getArgumentTypeAtIndex:argIndex];
      SimplifiedTypeEncoding simpleArgEncoding(argEncoding);
      
      NOBJC_LOG("CallSuperWithFFI: Processing JS arg %zu (method arg %zu), encoding=%s",
                i - argStartIndex, argIndex, argEncoding);
      
      // Handle special case for ^@ (out-params like NSError**)
      if (simpleArgEncoding[0] == '^' && simpleArgEncoding[1] == '@') {
        NOBJC_LOG("CallSuperWithFFI: Arg %zu is out-param (^@)", i - argStartIndex);
        
        // CRITICAL: For pointer-to-pointer types, we need TWO buffers:
        // 1. The actual storage location for the id (initialized to nil)
        // 2. A pointer to that storage (what we pass to the function)
        
        // Buffer 1: Storage for the id* (initialized to nil)
        auto errorStorage = std::make_unique<uint8_t[]>(sizeof(id));
        id nullObj = nil;
        memcpy(errorStorage.get(), &nullObj, sizeof(id));
        void* errorStoragePtr = errorStorage.get();
        
        NOBJC_LOG("CallSuperWithFFI: Allocated error storage at %p", errorStoragePtr);
        NOBJC_LOG("CallSuperWithFFI: Error storage contains: %p", *(id*)errorStoragePtr);
        
        // Buffer 2: Storage for the pointer to errorStorage (this is what argValues needs)
        auto pointerBuffer = std::make_unique<uint8_t[]>(sizeof(void*));
        memcpy(pointerBuffer.get(), &errorStoragePtr, sizeof(void*));
        void* pointerBufferPtr = pointerBuffer.get();
        
        NOBJC_LOG("CallSuperWithFFI: Allocated pointer buffer at %p", pointerBufferPtr);
        NOBJC_LOG("CallSuperWithFFI: Pointer buffer contains: %p (address of error storage)", 
                  *(void**)pointerBufferPtr);
        NOBJC_LOG("CallSuperWithFFI: This address will be passed to the method");
        
        // CRITICAL: argValues must point to pointerBuffer, not errorStorage
        // libffi will dereference this to get the address to pass
        argValues.push_back(pointerBufferPtr);
        argBuffers.push_back(std::move(errorStorage));
        argBuffers.push_back(std::move(pointerBuffer));
        continue;
      }
      
      // Calculate size for this argument
      size_t argSize = GetSizeForTypeEncoding(simpleArgEncoding[0]);
      if (argSize == 0) {
        // For complex types, use NSGetSizeAndAlignment
        NSUInteger size, alignment;
        NSGetSizeAndAlignment(argEncoding, &size, &alignment);
        argSize = size;
        NOBJC_LOG("CallSuperWithFFI: Complex type, size from NSGetSizeAndAlignment: %zu", argSize);
      }
      
      // Allocate buffer
      NOBJC_LOG("CallSuperWithFFI: Allocating buffer of %zu bytes for arg %zu", argSize, i - argStartIndex);
      auto buffer = std::make_unique<uint8_t[]>(argSize);
      memset(buffer.get(), 0, argSize);
      void* bufferPtr = buffer.get();
      NOBJC_LOG("CallSuperWithFFI: Buffer allocated at %p", bufferPtr);
      
      // Extract JS argument to buffer
      ObjcArgumentContext context = {
          .className = std::string(class_getName(superClass)),
          .selectorName = selectorName,
          .argumentIndex = (int)(i - argStartIndex),
      };
      
      try {
        NOBJC_LOG("CallSuperWithFFI: Calling ExtractJSArgumentToBuffer...");
        ExtractJSArgumentToBuffer(env, info[i], argEncoding, bufferPtr, context);
        NOBJC_LOG("CallSuperWithFFI: ExtractJSArgumentToBuffer succeeded");
      } catch (const std::exception& e) {
        CleanupAllocatedFFITypes(allocatedTypes);
        NOBJC_ERROR("CallSuperWithFFI: Failed to extract argument %zu: %s", i - argStartIndex, e.what());
        throw;
      }
      
      NOBJC_LOG("CallSuperWithFFI: Extracted argument %zu (size: %zu)", i - argStartIndex, argSize);
      
      // For object types, log the actual pointer value
      if (simpleArgEncoding[0] == '@') {
        [[maybe_unused]] id* objPtr = (id*)bufferPtr;
        NOBJC_LOG("CallSuperWithFFI: Argument %zu is object: buffer=%p, contains id=%p", 
                  i - argStartIndex, bufferPtr, *objPtr);
      }
      
      NOBJC_LOG("CallSuperWithFFI: Adding buffer %p to argValues (index %zu)", bufferPtr, argValues.size());
      argValues.push_back(bufferPtr);
      argBuffers.push_back(std::move(buffer));
      NOBJC_LOG("CallSuperWithFFI: Buffer moved to argBuffers (now size %zu)", argBuffers.size());
    }
    
    NOBJC_LOG("CallSuperWithFFI: Finished preparing %zu argument buffers", argBuffers.size());
    
    // 7. Prepare return buffer
    std::unique_ptr<uint8_t[]> returnBuffer;
    if (simpleReturnEncoding[0] != 'v') {
      size_t bufferSize = returnSize > 0 ? returnSize : 16; // Minimum 16 bytes
      returnBuffer = std::make_unique<uint8_t[]>(bufferSize);
      memset(returnBuffer.get(), 0, bufferSize);
      NOBJC_LOG("CallSuperWithFFI: Allocated return buffer of %zu bytes at %p", 
                bufferSize, returnBuffer.get());
    } else {
      NOBJC_LOG("CallSuperWithFFI: No return buffer needed (void return)");
    }
    
    // 8. Make the FFI call
    NOBJC_LOG("CallSuperWithFFI: ========== FFI CALL SETUP ==========");
    NOBJC_LOG("CallSuperWithFFI: Function to call: objc_msgSendSuper at %p", msgSendFn);
    NOBJC_LOG("CallSuperWithFFI: Number of arguments: %zu", argValues.size());
    NOBJC_LOG("CallSuperWithFFI: Arg 0 (objc_super*): argValues[0]=%p",
              argValues[0]);
    // Log what's actually stored in the buffer
    [[maybe_unused]] objc_super** superPtrPtr = (objc_super**)argValues[0];
    NOBJC_LOG("CallSuperWithFFI:   Buffer contains pointer: %p", *superPtrPtr);
    NOBJC_LOG("CallSuperWithFFI:   objc_super.receiver=%p", superStruct.receiver);
    NOBJC_LOG("CallSuperWithFFI:   objc_super.super_class=%p (%s)", 
              superStruct.super_class, class_getName(superClass));
    NOBJC_LOG("CallSuperWithFFI: Arg 1 (SEL*): argValues[1]=%p",
              argValues[1]);
    [[maybe_unused]] SEL* selPtr = (SEL*)argValues[1];
    NOBJC_LOG("CallSuperWithFFI:   Buffer contains SEL: %p (%s)", 
              *selPtr, sel_getName(*selPtr));
    
    for (size_t i = 2; i < argValues.size(); i++) {
      const char* argEncoding = [methodSig getArgumentTypeAtIndex:i];
      SimplifiedTypeEncoding simpleArgEncoding(argEncoding);
      NOBJC_LOG("CallSuperWithFFI: Arg %zu: argValues[%zu]=%p, encoding=%s",
                i, i, argValues[i], simpleArgEncoding.c_str());
      if (simpleArgEncoding[0] == '@') {
        [[maybe_unused]] id* objPtrLocation = (id*)argValues[i];
        NOBJC_LOG("CallSuperWithFFI:   Object pointer at %p points to id=%p",
                  objPtrLocation, *objPtrLocation);
      } else if (simpleArgEncoding[0] == '^') {
        [[maybe_unused]] void** ptrLocation = (void**)argValues[i];
        NOBJC_LOG("CallSuperWithFFI:   Pointer at %p contains: %p",
                  ptrLocation, *ptrLocation);
      }
    }
    
    NOBJC_LOG("CallSuperWithFFI: About to call ffi_call...");
    ffi_call(&cif, FFI_FN(msgSendFn), 
             returnBuffer ? returnBuffer.get() : nullptr, 
             argValues.data());
    NOBJC_LOG("CallSuperWithFFI: ffi_call completed successfully!");
    
    // 9. Convert return value
    Napi::Value result;
    if (simpleReturnEncoding[0] == 'v') {
      result = env.Undefined();
    } else {
      result = ConvertFFIReturnToJS(env, returnBuffer.get(), simpleReturnEncoding.c_str());
    }
    
    // 10. Cleanup
    CleanupAllocatedFFITypes(allocatedTypes);
    
    NOBJC_LOG("CallSuperWithFFI: Returning result");
    return result;
    
  } catch (const std::exception& e) {
    CleanupAllocatedFFITypes(allocatedTypes);
    NOBJC_ERROR("CallSuperWithFFI: Exception: %s", e.what());
    throw;
  } catch (...) {
    CleanupAllocatedFFITypes(allocatedTypes);
    NOBJC_ERROR("CallSuperWithFFI: Unknown exception");
    throw;
  }
}

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

  // CRITICAL: Use FFI approach to avoid infinite recursion
  // The NSInvocation approach below causes infinite recursion because
  // [invocation invoke] dispatches to self's implementation, not super's.
  
  // If we have arguments, use FFI approach
  if (providedArgCount > 0) {
    NOBJC_LOG("CallSuper: Using FFI approach for method with arguments");
    
    try {
      return CallSuperWithFFI(env, self, superClass, selector, methodSig, info, 2);
    } catch (const std::exception& e) {
      NOBJC_ERROR("CallSuper: FFI approach failed: %s", e.what());
      // Re-throw - don't fall back to broken NSInvocation
      throw;
    }
  }

  // For methods WITHOUT arguments, use direct objc_msgSendSuper
  const char *returnType = SimplifyTypeEncoding([methodSig methodReturnType]);
  struct objc_super superStruct;
  superStruct.receiver = self;
  superStruct.super_class = superClass;

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
