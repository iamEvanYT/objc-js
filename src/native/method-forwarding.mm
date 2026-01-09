#include "method-forwarding.h"
#include "debug.h"
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
  // retainArguments only retains the arguments, not the invocation itself
  [invocation retainArguments];
  [invocation retain]; // Keep invocation alive until callback completes

  SEL selector = [invocation selector];
  NSString *selectorString = NSStringFromSelector(selector);
  if (!selectorString) {
    NOBJC_ERROR("Failed to convert selector to string");
    [invocation release];
    return;
  }

  std::string selectorName = [selectorString UTF8String];

  // Store self pointer for later lookups
  void *ptr = (__bridge void *)self;

  // Get thread-safe data (TSFN, typeEncoding, js_thread)
  // DO NOT access any N-API values here - we may not be on the JS thread!
  Napi::ThreadSafeFunction tsfn;
  std::string typeEncoding;
  pthread_t js_thread;
  bool isElectron;
  {
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    auto it = g_implementations.find(ptr);
    if (it == g_implementations.end()) {
      NOBJC_WARN("Protocol implementation not found for instance %p", self);
      [invocation release];
      return;
    }

    auto callbackIt = it->second.callbacks.find(selectorName);
    if (callbackIt == it->second.callbacks.end()) {
      NOBJC_WARN("Callback not found for selector %s", selectorName.c_str());
      [invocation release];
      return;
    }

    // Get the ThreadSafeFunction - this is thread-safe by design
    // IMPORTANT: We must Acquire() to increment the ref count, because copying
    // a ThreadSafeFunction does NOT increment it. If DeallocImplementation
    // runs and calls Release() on the original, our copy would become invalid.
    tsfn = callbackIt->second;
    napi_status acq_status = tsfn.Acquire();
    if (acq_status != napi_ok) {
      NOBJC_WARN("Failed to acquire ThreadSafeFunction for selector %s",
            selectorName.c_str());
      [invocation release];
      return;
    }

    // Get the type encoding for return value handling
    auto encIt = it->second.typeEncodings.find(selectorName);
    if (encIt != it->second.typeEncodings.end()) {
      typeEncoding = encIt->second;
    }

    // Get the JS thread ID to check if we're on the same thread
    js_thread = it->second.js_thread;
    isElectron = it->second.isElectron;
  }

  // Check if we're on the JS thread
  bool is_js_thread = pthread_equal(pthread_self(), js_thread);

  // IMPORTANT: We call directly on the JS thread so return values are set
  // synchronously; otherwise we use a ThreadSafeFunction to marshal work.
  // EXCEPTION: In Electron, we ALWAYS use TSFN even on the JS thread because
  // Electron's V8 context isn't properly set up for direct handle creation.

  // Create invocation data with RAII guard
  // The guard will clean up if we don't transfer ownership
  auto data = new InvocationData();
  data->invocation = invocation;
  data->selectorName = selectorName;
  data->typeEncoding = typeEncoding;
  data->callbackType = CallbackType::Protocol;
  
  // Use RAII to ensure cleanup on error paths
  InvocationDataGuard dataGuard(data);

  napi_status status;

  if (is_js_thread && !isElectron) {
    // We're on the JS thread in Node/Bun (NOT Electron)
    // Call directly to ensure return values are set synchronously.
    data->completionMutex = nullptr;
    data->completionCv = nullptr;
    data->isComplete = nullptr;

    tsfn.Release();

    Napi::Function jsFn;
    napi_env stored_env;
    {
      std::lock_guard<std::mutex> lock(g_implementations_mutex);
      auto it = g_implementations.find(ptr);
      if (it == g_implementations.end()) {
        NOBJC_WARN("Protocol implementation not found for instance %p (JS thread path)", self);
        return;  // dataGuard cleans up
      }

      auto jsCallbackIt = it->second.jsCallbacks.find(selectorName);
      if (jsCallbackIt == it->second.jsCallbacks.end()) {
        NOBJC_WARN("JS callback not found for selector %s (JS thread path)",
              selectorName.c_str());
        return;  // dataGuard cleans up
      }

      stored_env = it->second.env;
      jsFn = jsCallbackIt->second.Value();
    }

    // Safely call the JS callback with proper V8 context setup
    // Wrap in try-catch to handle invalid env (e.g., in Electron when context
    // is destroyed)
    try {
      Napi::Env callEnv(stored_env);
      
      // Create a HandleScope to properly manage V8 handles
      // This is critical for Electron which may have multiple V8 contexts
      Napi::HandleScope scope(callEnv);
      
      // Transfer ownership to CallJSCallback - it will clean up
      CallJSCallback(callEnv, jsFn, dataGuard.release());
    } catch (const std::exception &e) {
      NOBJC_ERROR("Error calling JS callback directly (likely invalid env in Electron): %s", e.what());
      NOBJC_LOG("Falling back to ThreadSafeFunction for selector %s", selectorName.c_str());
      
      // Fallback to TSFN if direct call fails (e.g., invalid env in Electron)
      // Note: dataGuard.release() was already called, so we need to re-create data
      // Actually, if release() was called and CallJSCallback threw before taking ownership,
      // we have a leak. But CallJSCallback uses RAII internally, so it should be safe.
      // The exception would have to occur before CallJSCallback's guard takes over.
      // For safety, let's assume data was handled if release() was called.
      
      // Re-create data for fallback attempt
      auto fallbackData = new InvocationData();
      fallbackData->invocation = invocation;
      fallbackData->selectorName = selectorName;
      fallbackData->typeEncoding = typeEncoding;
      fallbackData->callbackType = CallbackType::Protocol;
      InvocationDataGuard fallbackGuard(fallbackData);
      
      // We need to re-acquire the TSFN
      {
        std::lock_guard<std::mutex> lock(g_implementations_mutex);
        auto it = g_implementations.find(ptr);
        if (it != g_implementations.end()) {
          auto callbackIt = it->second.callbacks.find(selectorName);
          if (callbackIt != it->second.callbacks.end()) {
            tsfn = callbackIt->second;
            napi_status acq_status = tsfn.Acquire();
            if (acq_status == napi_ok) {
              // Use helper function for fallback - transfers ownership
              if (FallbackToTSFN(tsfn, fallbackGuard.release(), selectorName)) {
                return; // Data cleaned up in callback
              }
            }
          }
        }
      }
      // If we get here, fallbackGuard cleans up
    }
  } else {
    // We're on a different thread (e.g., Cocoa callback from
    // ASAuthorizationController) Use NonBlockingCall + runloop pumping to avoid
    // deadlocks
    std::mutex completionMutex;
    std::condition_variable completionCv;
    bool isComplete = false;

    data->completionMutex = &completionMutex;
    data->completionCv = &completionCv;
    data->isComplete = &isComplete;

    // Transfer ownership to TSFN callback
    status = tsfn.NonBlockingCall(dataGuard.release(), CallJSCallback);
    tsfn.Release();

    if (status != napi_ok) {
      NOBJC_ERROR("Failed to call ThreadSafeFunction for selector %s (status: %d)",
            selectorName.c_str(), status);
      // NonBlockingCall failed, but we already released from guard
      // We need to clean up manually here
      [invocation release];
      delete data;
      return;
    }

    // Wait for callback by pumping CFRunLoop
    // This allows the event loop to process our callback
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
    // Data cleaned up in callback
  }

  // Return value (if any) has been set on the invocation
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
