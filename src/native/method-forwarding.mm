#include "method-forwarding.h"
#include "debug.h"
#include "forwarding-common.h"
#include "memory-utils.h"
#include "ObjcObject.h"
#include "protocol-storage.h"
#include "type-conversion.h"
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <napi.h>
#include <objc/runtime.h>

// MARK: - ThreadSafeFunction Callback Handler

// This function runs on the JavaScript thread
// Handles both protocol implementation and subclass method forwarding
// NOTE: This function takes ownership of data and must clean it up
void CallJSCallback(Napi::Env env, Napi::Function jsCallback,
                    InvocationData *data) {
  // Use RAII to ensure cleanup even if we return early or throw
  // The guard will release the invocation and delete data
  InvocationDataGuard guard(data);
  
  if (!data) {
    NOBJC_ERROR("InvocationData is null in CallJSCallback");
    return;
  }

  NOBJC_LOG("CallJSCallback: Called for selector %s, callbackType=%d", 
            data->selectorName.c_str(), (int)data->callbackType);

  // Check if the callback is valid before proceeding
  if (jsCallback.IsEmpty()) {
    NOBJC_ERROR("jsCallback is null/empty in CallJSCallback for selector %s",
          data->selectorName.c_str());
    SignalInvocationComplete(data);
    return;  // guard cleans up
  }

  NSInvocation *invocation = data->invocation;
  if (!invocation) {
    NOBJC_ERROR("NSInvocation is null in CallJSCallback");
    SignalInvocationComplete(data);
    return;  // guard cleans up
  }

  NOBJC_LOG("CallJSCallback: About to get method signature");

  // Extract arguments using NSInvocation
  NSMethodSignature *sig = [invocation methodSignature];
  if (!sig) {
    NOBJC_ERROR("Failed to get method signature for selector %s",
          data->selectorName.c_str());
    SignalInvocationComplete(data);
    return;  // guard cleans up
  }

  NOBJC_LOG("CallJSCallback: Method signature: %s, numArgs: %lu", 
            [sig description].UTF8String, (unsigned long)[sig numberOfArguments]);

  std::vector<napi_value> jsArgs;

  // For subclass methods, include 'self' as first JavaScript argument
  if (data->callbackType == CallbackType::Subclass) {
    NOBJC_LOG("CallJSCallback: Extracting 'self' argument for subclass method");
    __unsafe_unretained id selfObj;
    [invocation getArgument:&selfObj atIndex:0];
    NOBJC_LOG("CallJSCallback: About to create ObjcObject for self=%p", selfObj);
    Napi::Value selfValue = ObjcObject::NewInstance(env, selfObj);
    NOBJC_LOG("CallJSCallback: Created ObjcObject for self (JS wrapper created)");
    jsArgs.push_back(selfValue);
    NOBJC_LOG("CallJSCallback: Added self to jsArgs");
  }

  // Extract remaining arguments (skip self and _cmd, start at index 2)
  NOBJC_LOG("CallJSCallback: Extracting %lu method arguments", (unsigned long)[sig numberOfArguments] - 2);
  for (NSUInteger i = 2; i < [sig numberOfArguments]; i++) {
    const char *type = [sig getArgumentTypeAtIndex:i];
    SimplifiedTypeEncoding argType(type);
    
    NOBJC_LOG("CallJSCallback: Processing arg %lu, type=%s, simplified=%s", 
              (unsigned long)i, type, argType.c_str());
    
    // Handle out-parameters (e.g., NSError**) by passing null
    // This avoids creating N-API Function objects which triggers Bun crashes
    if (argType[0] == '^' && argType[1] == '@') {
      NOBJC_LOG("CallJSCallback: Arg %lu is out-param (^@), passing null", (unsigned long)i);
      jsArgs.push_back(env.Null());
      continue;
    }
    
    NOBJC_LOG("CallJSCallback: About to extract arg %lu to JS", (unsigned long)i);
    jsArgs.push_back(ExtractInvocationArgumentToJS(env, invocation, i, argType[0]));
    NOBJC_LOG("CallJSCallback: Successfully extracted arg %lu", (unsigned long)i);
  }

  // Call the JavaScript callback
  try {
    NOBJC_LOG("CallJSCallback: About to call JS function with %zu args", jsArgs.size());
    Napi::Value result = jsCallback.Call(jsArgs);
    NOBJC_LOG("CallJSCallback: JS function returned successfully");

    // Handle return value if the method expects one
    const char *returnType = [sig methodReturnType];
    SimplifiedTypeEncoding retType(returnType);

    if (retType[0] != 'v') { // Not void
      SetInvocationReturnFromJS(invocation, result, retType[0],
                                data->selectorName.c_str());
    }
  } catch (const Napi::Error &e) {
    NOBJC_ERROR("Error calling JavaScript callback for %s: %s",
          data->selectorName.c_str(), e.what());
  } catch (const std::exception &e) {
    NOBJC_ERROR("Exception calling JavaScript callback for %s: %s",
          data->selectorName.c_str(), e.what());
  } catch (...) {
    NOBJC_ERROR("Unknown error calling JavaScript callback for %s",
          data->selectorName.c_str());
  }

  // Signal completion to the waiting ForwardInvocation
  NOBJC_LOG("CallJSCallback: About to signal completion for %s", data->selectorName.c_str());
  SignalInvocationComplete(data);
  NOBJC_LOG("CallJSCallback: Signaled completion for %s", data->selectorName.c_str());

  // guard destructor cleans up invocation and data
}

// MARK: - Fallback Helper

// Helper function to fallback to ThreadSafeFunction when direct call fails
// This is used when direct JS callback invocation fails (e.g., in Electron)
bool FallbackToTSFN(Napi::ThreadSafeFunction &tsfn, InvocationData *data,
                    const std::string &selectorName) {
  // Set up synchronization primitives
  std::mutex completionMutex;
  std::condition_variable completionCv;
  bool isComplete = false;

  data->completionMutex = &completionMutex;
  data->completionCv = &completionCv;
  data->isComplete = &isComplete;

  // Call via ThreadSafeFunction
  napi_status status = tsfn.NonBlockingCall(data, CallJSCallback);
  tsfn.Release();

  if (status != napi_ok) {
    NOBJC_ERROR("FallbackToTSFN failed for selector %s (status: %d)",
                selectorName.c_str(), status);
    return false;
  }

  // Wait for callback by pumping CFRunLoop
  CFTimeInterval timeout = 0.001; // 1ms per iteration
  while (true) {
    {
      std::unique_lock<std::mutex> lock(completionMutex);
      if (isComplete) {
        break;
      }
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout, true);
  }
  
  return true;
}

// MARK: - Message Forwarding Implementation

// Override respondsToSelector to return YES for methods we implement
BOOL RespondsToSelector(id self, SEL _cmd, SEL selector) {
  void *ptr = (__bridge void *)self;

  // Check if this is one of our implemented methods
  {
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    auto it = g_implementations.find(ptr);
    if (it != g_implementations.end()) {
      NSString *selectorString = NSStringFromSelector(selector);
      if (selectorString != nil) {
        std::string selName = [selectorString UTF8String];
        auto callbackIt = it->second.callbacks.find(selName);
        if (callbackIt != it->second.callbacks.end()) {
          return YES;
        }
      }
    }
  }

  // For methods we don't implement, check if NSObject responds to them
  // This handles standard NSObject methods like description, isEqual:, etc.
  return [NSObject instancesRespondToSelector:selector];
}

// Provide method signature for message forwarding
NSMethodSignature *MethodSignatureForSelector(id self, SEL _cmd, SEL selector) {
  void *ptr = (__bridge void *)self;

  std::lock_guard<std::mutex> lock(g_implementations_mutex);
  auto it = g_implementations.find(ptr);
  if (it != g_implementations.end()) {
    NSString *selectorString = NSStringFromSelector(selector);
    std::string selName = [selectorString UTF8String];
    auto encIt = it->second.typeEncodings.find(selName);
    if (encIt != it->second.typeEncodings.end()) {
      return [NSMethodSignature signatureWithObjCTypes:encIt->second.c_str()];
    }
  }
  // Fall back to superclass for methods we don't implement
  return [NSObject instanceMethodSignatureForSelector:selector];
}

// Handle forwarded invocations
void ForwardInvocation(id self, SEL _cmd, NSInvocation *invocation) {
  if (!invocation) {
    NOBJC_ERROR("ForwardInvocation called with nil invocation");
    return;
  }

  // Retain the invocation to keep it alive during async call
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
  void *ptr = (__bridge void *)self;

  // Set up callbacks for protocol-specific storage access
  ForwardingCallbacks callbacks;
  callbacks.callbackType = CallbackType::Protocol;

  // Lookup context and acquire TSFN
  callbacks.lookupContext = [](void *lookupKey,
                               const std::string &selName) -> std::optional<ForwardingContext> {
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    auto it = g_implementations.find(lookupKey);
    if (it == g_implementations.end()) {
      NOBJC_WARN("Protocol implementation not found for instance %p", lookupKey);
      return std::nullopt;
    }

    auto callbackIt = it->second.callbacks.find(selName);
    if (callbackIt == it->second.callbacks.end()) {
      NOBJC_WARN("Callback not found for selector %s", selName.c_str());
      return std::nullopt;
    }

    // Acquire the TSFN
    Napi::ThreadSafeFunction tsfn = callbackIt->second;
    napi_status acq_status = tsfn.Acquire();
    if (acq_status != napi_ok) {
      NOBJC_WARN("Failed to acquire ThreadSafeFunction for selector %s", selName.c_str());
      return std::nullopt;
    }

    ForwardingContext ctx;
    ctx.tsfn = tsfn;
    ctx.js_thread = it->second.js_thread;
    ctx.env = it->second.env;
    ctx.skipDirectCallForElectron = it->second.isElectron;
    ctx.instancePtr = nullptr;   // Not used for protocols
    ctx.superClassPtr = nullptr; // Not used for protocols

    // Cache the JS callback reference to avoid mutex re-acquisition
    auto jsCallbackIt = it->second.jsCallbacks.find(selName);
    if (jsCallbackIt != it->second.jsCallbacks.end()) {
      ctx.cachedJsCallback = &jsCallbackIt->second;
    }

    auto encIt = it->second.typeEncodings.find(selName);
    if (encIt != it->second.typeEncodings.end()) {
      ctx.typeEncoding = encIt->second;
    }

    return ctx;
  };

  // Get JS function for direct call path
  callbacks.getJSFunction = [](void *lookupKey, const std::string &selName,
                               Napi::Env env) -> Napi::Function {
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    auto it = g_implementations.find(lookupKey);
    if (it == g_implementations.end()) {
      return Napi::Function();
    }

    auto jsCallbackIt = it->second.jsCallbacks.find(selName);
    if (jsCallbackIt == it->second.jsCallbacks.end()) {
      return Napi::Function();
    }

    return jsCallbackIt->second.Value();
  };

  // Re-acquire TSFN for fallback path
  callbacks.reacquireTSFN = [](void *lookupKey,
                               const std::string &selName) -> std::optional<Napi::ThreadSafeFunction> {
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    auto it = g_implementations.find(lookupKey);
    if (it == g_implementations.end()) {
      return std::nullopt;
    }

    auto callbackIt = it->second.callbacks.find(selName);
    if (callbackIt == it->second.callbacks.end()) {
      return std::nullopt;
    }

    Napi::ThreadSafeFunction tsfn = callbackIt->second;
    napi_status acq_status = tsfn.Acquire();
    if (acq_status != napi_ok) {
      return std::nullopt;
    }

    return tsfn;
  };

  ForwardInvocationCommon(invocation, selectorName, ptr, callbacks);
}

// Deallocation implementation
void DeallocImplementation(id self, SEL _cmd) {
  @autoreleasepool {
    // Remove the implementation from the global map
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    void *ptr = (__bridge void *)self;
    auto it = g_implementations.find(ptr);
    if (it != g_implementations.end()) {
      // Release all ThreadSafeFunctions and JS callbacks
      // Do this carefully to avoid issues during shutdown
      try {
        for (auto &pair : it->second.callbacks) {
          // Release the ThreadSafeFunction
          pair.second.Release();
        }
        it->second.callbacks.clear();
        it->second.jsCallbacks.clear();
        it->second.typeEncodings.clear();
      } catch (...) {
        // Ignore errors during cleanup
        NOBJC_WARN("Exception during callback cleanup for instance %p", self);
      }
      g_implementations.erase(it);
    }
  }

  // Call the superclass dealloc
  // Note: Under ARC, we don't need to manually call [super dealloc]
  // The runtime handles this automatically
}
