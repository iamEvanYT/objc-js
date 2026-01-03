#include "method-forwarding.h"
#include "ObjcObject.h"
#include "protocol-storage.h"
#include "type-conversion.h"
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <napi.h>
#include <objc/runtime.h>

// MARK: - ThreadSafeFunction Callback Handler

// This function runs on the JavaScript thread
void CallJSCallback(Napi::Env env, Napi::Function jsCallback,
                    InvocationData *data) {
  if (!data) {
    NSLog(@"Error: InvocationData is null in CallJSCallback");
    return;
  }

  // Check if the callback is valid before proceeding
  if (jsCallback.IsEmpty()) {
    NSLog(@"Error: jsCallback is null/empty in CallJSCallback for selector %s",
          data->selectorName.c_str());
    if (data->invocation) {
      [data->invocation release];
    }
    SignalInvocationComplete(data);
    delete data;
    return;
  }

  NSInvocation *invocation = data->invocation;
  if (!invocation) {
    NSLog(@"Error: NSInvocation is null in CallJSCallback");
    SignalInvocationComplete(data);
    delete data;
    return;
  }

  // Extract arguments using NSInvocation
  NSMethodSignature *sig = [invocation methodSignature];
  if (!sig) {
    NSLog(@"Error: Failed to get method signature for selector %s",
          data->selectorName.c_str());
    SignalInvocationComplete(data);
    [invocation release];
    delete data;
    return;
  }

  std::vector<napi_value> jsArgs;

  // Skip first two arguments (self and _cmd)
  for (NSUInteger i = 2; i < [sig numberOfArguments]; i++) {
    const char *type = [sig getArgumentTypeAtIndex:i];
    SimplifiedTypeEncoding argType(type);
    jsArgs.push_back(ExtractInvocationArgumentToJS(env, invocation, i, argType[0]));
  }

  NSLog(@"[DEBUG] About to call JS callback for %s with %zu arguments",
        data->selectorName.c_str(), jsArgs.size());

  // Call the JavaScript callback
  try {
    Napi::Value result = jsCallback.Call(jsArgs);

    NSLog(@"[DEBUG] JS callback for %s returned, result type: %d",
          data->selectorName.c_str(), result.Type());

    // Handle return value if the method expects one
    const char *returnType = [sig methodReturnType];
    SimplifiedTypeEncoding retType(returnType);

    if (retType[0] != 'v') { // Not void
      NSLog(@"[DEBUG] Setting return value for %s, return type: %c, JS result is %s",
            data->selectorName.c_str(), retType[0],
            result.IsNull() ? "null" : result.IsUndefined() ? "undefined" : "value");
      SetInvocationReturnFromJS(invocation, result, retType[0],
                                data->selectorName.c_str());
      NSLog(@"[DEBUG] Return value set for %s", data->selectorName.c_str());
    }
  } catch (const Napi::Error &e) {
    NSLog(@"Error calling JavaScript callback for %s: %s",
          data->selectorName.c_str(), e.what());
  } catch (const std::exception &e) {
    NSLog(@"Exception calling JavaScript callback for %s: %s",
          data->selectorName.c_str(), e.what());
  } catch (...) {
    NSLog(@"Unknown error calling JavaScript callback for %s",
          data->selectorName.c_str());
  }

  // Signal completion to the waiting ForwardInvocation
  SignalInvocationComplete(data);

  // Clean up the invocation data
  // Release the invocation that we retained in ForwardInvocation
  [invocation release];
  delete data;
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
    NSLog(@"Error: ForwardInvocation called with nil invocation");
    return;
  }

  // Retain the invocation to keep it alive during async call
  // retainArguments only retains the arguments, not the invocation itself
  [invocation retainArguments];
  [invocation retain]; // Keep invocation alive until callback completes

  SEL selector = [invocation selector];
  NSString *selectorString = NSStringFromSelector(selector);
  if (!selectorString) {
    NSLog(@"Error: Failed to convert selector to string");
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
      NSLog(@"Warning: Protocol implementation not found for instance %p",
            self);
      return;
    }

    auto callbackIt = it->second.callbacks.find(selectorName);
    if (callbackIt == it->second.callbacks.end()) {
      NSLog(@"Warning: Callback not found for selector %s",
            selectorName.c_str());
      return;
    }

    // Get the ThreadSafeFunction - this is thread-safe by design
    // IMPORTANT: We must Acquire() to increment the ref count, because copying
    // a ThreadSafeFunction does NOT increment it. If DeallocImplementation
    // runs and calls Release() on the original, our copy would become invalid.
    tsfn = callbackIt->second;
    napi_status acq_status = tsfn.Acquire();
    if (acq_status != napi_ok) {
      NSLog(@"Warning: Failed to acquire ThreadSafeFunction for selector %s",
            selectorName.c_str());
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

  NSLog(@"[DEBUG] ForwardInvocation for %s: is_js_thread=%d, isElectron=%d, current_thread=%p, js_thread=%p",
        selectorName.c_str(), is_js_thread, isElectron, pthread_self(), js_thread);

  // IMPORTANT: We call directly on the JS thread so return values are set
  // synchronously; otherwise we use a ThreadSafeFunction to marshal work.
  // EXCEPTION: In Electron, we ALWAYS use TSFN even on the JS thread because
  // Electron's V8 context isn't properly set up for direct handle creation.

  // Create invocation data
  auto data = new InvocationData();
  data->invocation = invocation;
  data->selectorName = selectorName;
  data->typeEncoding = typeEncoding;

  napi_status status;

  if (is_js_thread && !isElectron) {
    // We're on the JS thread in Node/Bun (NOT Electron)
    // Call directly to ensure return values are set synchronously.
    NSLog(@"[DEBUG] Taking JS thread direct call path for %s", selectorName.c_str());
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
        NSLog(@"Warning: Protocol implementation not found for instance %p "
              @"(JS thread path)",
              self);
        [invocation release];
        delete data;
        return;
      }

      auto jsCallbackIt = it->second.jsCallbacks.find(selectorName);
      if (jsCallbackIt == it->second.jsCallbacks.end()) {
        NSLog(@"Warning: JS callback not found for selector %s "
              @"(JS thread path)",
              selectorName.c_str());
        [invocation release];
        delete data;
        return;
      }

      stored_env = it->second.env;
      jsFn = jsCallbackIt->second.Value();
    }

    // Safely call the JS callback with proper V8 context setup
    // Wrap in try-catch to handle invalid env (e.g., in Electron when context
    // is destroyed)
    try {
      NSLog(@"[DEBUG] Creating Napi::Env from stored_env for %s", selectorName.c_str());
      Napi::Env callEnv(stored_env);
      
      // Create a HandleScope to properly manage V8 handles
      // This is critical for Electron which may have multiple V8 contexts
      NSLog(@"[DEBUG] Creating HandleScope for %s", selectorName.c_str());
      Napi::HandleScope scope(callEnv);
      
      NSLog(@"[DEBUG] Calling CallJSCallback directly for %s", selectorName.c_str());
      CallJSCallback(callEnv, jsFn, data);
      NSLog(@"[DEBUG] CallJSCallback completed for %s", selectorName.c_str());
      // CallJSCallback releases invocation and deletes data.
    } catch (const std::exception &e) {
      NSLog(@"Error calling JS callback directly (likely invalid env in "
            @"Electron): %s",
            e.what());
      NSLog(@"Falling back to ThreadSafeFunction for selector %s",
            selectorName.c_str());
      
      // Fallback to TSFN if direct call fails (e.g., invalid env in Electron)
      // We need to re-acquire the TSFN and set up sync primitives
      {
        std::lock_guard<std::mutex> lock(g_implementations_mutex);
        auto it = g_implementations.find(ptr);
        if (it != g_implementations.end()) {
          auto callbackIt = it->second.callbacks.find(selectorName);
          if (callbackIt != it->second.callbacks.end()) {
            tsfn = callbackIt->second;
            napi_status acq_status = tsfn.Acquire();
            if (acq_status == napi_ok) {
              // Set up synchronization for fallback path
              std::mutex completionMutex;
              std::condition_variable completionCv;
              bool isComplete = false;

              data->completionMutex = &completionMutex;
              data->completionCv = &completionCv;
              data->isComplete = &isComplete;

              status = tsfn.NonBlockingCall(data, CallJSCallback);
              tsfn.Release();

              if (status == napi_ok) {
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
                return; // Data cleaned up in callback
              }
            }
          }
        }
      }
      
      // If fallback also failed, clean up manually
      [invocation release];
      delete data;
    }
  } else {
    // We're on a different thread (e.g., Cocoa callback from
    // ASAuthorizationController) Use NonBlockingCall + runloop pumping to avoid
    // deadlocks
    NSLog(@"[DEBUG] Taking non-JS thread path for %s", selectorName.c_str());
    std::mutex completionMutex;
    std::condition_variable completionCv;
    bool isComplete = false;

    data->completionMutex = &completionMutex;
    data->completionCv = &completionCv;
    data->isComplete = &isComplete;

    status = tsfn.NonBlockingCall(data, CallJSCallback);
    tsfn.Release();

    if (status != napi_ok) {
      NSLog(@"Error: Failed to call ThreadSafeFunction for selector %s "
            @"(status: %d)",
            selectorName.c_str(), status);
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
        NSLog(@"Warning: Exception during callback cleanup for instance %p",
              self);
      }
      g_implementations.erase(it);
    }
  }

  // Call the superclass dealloc
  // Note: Under ARC, we don't need to manually call [super dealloc]
  // The runtime handles this automatically
}
