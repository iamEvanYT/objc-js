#include "forwarding-common.h"
#include "constants.h"
#include "debug.h"
#include "method-forwarding.h"
#include <Foundation/Foundation.h>
#include <atomic>
#include <chrono>

// MARK: - ForwardInvocationCommon Implementation

void ForwardInvocationCommon(NSInvocation *invocation,
                             SEL selector, void *lookupKey,
                             const ForwardingCallbacks &callbacks) {
  const char *selectorCStr = sel_getName(selector);

  // Look up context data (acquires TSFN)
  auto contextOpt = callbacks.lookupContext(lookupKey, selector);
  if (!contextOpt) {
    NOBJC_WARN("Lookup failed for selector %s", selectorCStr);
    [invocation release];
    return;
  }

  ForwardingContext ctx = std::move(*contextOpt);

  // Check if we're on the JS thread
  bool is_js_thread = pthread_equal(pthread_self(), ctx.js_thread);

  // Create invocation data with RAII guard
  auto data = new InvocationData();
  data->invocation = invocation;
  data->selectorName = selectorCStr;
  data->typeEncoding = ctx.typeEncoding;
  data->callbackType = callbacks.callbackType;
  data->instancePtr = ctx.instancePtr;
  data->superClassPtr = ctx.superClassPtr;

  InvocationDataGuard dataGuard(data);

  napi_status status;

  // IMPORTANT: We call directly on the JS thread so return values are set
  // synchronously; otherwise we use a ThreadSafeFunction to marshal work.
  // EXCEPTION: For protocols in Electron, we ALWAYS use TSFN even on the JS
  // thread because Electron's V8 context may not be properly set up.
  bool use_direct_call = is_js_thread && !ctx.skipDirectCallForElectron;

  if (use_direct_call) {
    NOBJC_LOG("ForwardInvocationCommon: Using direct call path for selector %s",
              selectorCStr);

    // Release the TSFN since we're calling directly
    ctx.tsfn.Release();

    data->completionMutex = nullptr;
    data->completionCv = nullptr;
    data->isComplete = nullptr;

    try {
      Napi::Env callEnv(ctx.env);
      Napi::HandleScope scope(callEnv);

      // Use cached JS function reference (avoids re-acquiring mutex)
      Napi::Function jsFn;
      if (ctx.cachedJsCallback && !ctx.cachedJsCallback->IsEmpty()) {
        jsFn = ctx.cachedJsCallback->Value();
      }
      
      // Fallback to callback lookup if cache miss (shouldn't happen)
      if (jsFn.IsEmpty()) {
        jsFn = callbacks.getJSFunction(lookupKey, selector, callEnv);
      }
      
      if (jsFn.IsEmpty()) {
        NOBJC_WARN("JS function not found for selector %s (direct path)",
                   selectorCStr);
        return; // dataGuard cleans up
      }

      // Transfer ownership to CallJSCallback - it will clean up
      CallJSCallback(callEnv, jsFn, dataGuard.release());
      NOBJC_LOG("ForwardInvocationCommon: Direct call succeeded for %s",
                selectorCStr);
    } catch (const std::exception &e) {
      NOBJC_ERROR("Error calling JS callback directly: %s", e.what());
      NOBJC_LOG("Falling back to ThreadSafeFunction for selector %s",
                selectorCStr);

      // Re-create data for fallback since we may have released it
      auto fallbackData = new InvocationData();
      fallbackData->invocation = invocation;
      fallbackData->selectorName = selectorCStr;
      fallbackData->typeEncoding = ctx.typeEncoding;
      fallbackData->callbackType = callbacks.callbackType;
      fallbackData->instancePtr = ctx.instancePtr;
      fallbackData->superClassPtr = ctx.superClassPtr;
      InvocationDataGuard fallbackGuard(fallbackData);

      // Re-acquire TSFN for fallback
      auto tsfnOpt = callbacks.reacquireTSFN(lookupKey, selector);
      if (tsfnOpt) {
        std::string selectorStr(selectorCStr);
        if (FallbackToTSFN(*tsfnOpt, fallbackGuard.release(), selectorStr)) {
          return; // Data cleaned up in callback
        }
        NOBJC_ERROR("ForwardInvocationCommon: Fallback failed for %s",
                    selectorCStr);
      }
      // If we get here, fallbackGuard cleans up
    }
  } else {
    // Cross-thread call via TSFN (or Electron forcing TSFN)
    NOBJC_LOG("ForwardInvocationCommon: Using TSFN+runloop path for selector %s",
              selectorCStr);

    std::mutex completionMutex;
    std::condition_variable completionCv;
    bool isComplete = false;

    data->completionMutex = &completionMutex;
    data->completionCv = &completionCv;
    data->isComplete = &isComplete;

    // Transfer ownership to TSFN callback
    status = ctx.tsfn.NonBlockingCall(dataGuard.release(), CallJSCallback);
    ctx.tsfn.Release();

    if (status != napi_ok) {
      NOBJC_ERROR("Failed to call ThreadSafeFunction for selector %s (status: %d)",
                  selectorCStr, status);
      // We already released from guard, so clean up manually
      [invocation release];
      delete data;
      return;
    }

    // Wait for callback by pumping CFRunLoop
    int iterations = 0;

    while (true) {
      {
        std::unique_lock<std::mutex> lock(completionMutex);
        if (isComplete) {
          break;
        }
      }
      iterations++;
      if (iterations % nobjc::kRunLoopDebugLogInterval == 0) {
        NOBJC_LOG("ForwardInvocationCommon: Still waiting... (%d iterations)",
                  iterations);
      }
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, nobjc::kRunLoopPumpInterval, true);
    }
    // Data cleaned up in callback
  }

  // Return value (if any) has been set on the invocation
}
