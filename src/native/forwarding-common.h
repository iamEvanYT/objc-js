#ifndef FORWARDING_COMMON_H
#define FORWARDING_COMMON_H

#include "memory-utils.h"
#include "protocol-storage.h"
#include <functional>
#include <napi.h>
#include <optional>

#ifdef __OBJC__
@class NSInvocation;
#else
typedef struct NSInvocation NSInvocation;
#endif

// MARK: - Forwarding Context

/**
 * Context data gathered during the initial lookup phase.
 * This contains everything needed to perform the invocation.
 */
struct ForwardingContext {
  Napi::ThreadSafeFunction tsfn;
  std::string typeEncoding;
  pthread_t js_thread;
  napi_env env;
  bool skipDirectCallForElectron;  // Protocol path skips direct for Electron

  // Subclass-specific (set to nullptr/0 for protocols)
  void *instancePtr;
  void *superClassPtr;

  ForwardingContext()
      : js_thread(0), env(nullptr), skipDirectCallForElectron(false),
        instancePtr(nullptr), superClassPtr(nullptr) {}
};

/**
 * Callbacks for storage-specific operations.
 * This allows ForwardInvocationCommon to work with both protocols and subclasses.
 */
struct ForwardingCallbacks {
  // Look up context data under lock. Returns nullopt if not found.
  // Also acquires the TSFN.
  std::function<std::optional<ForwardingContext>(
      void *lookupKey, const std::string &selectorName)>
      lookupContext;

  // Get the JS function for direct call (called within HandleScope).
  // Returns empty function if not found.
  std::function<Napi::Function(void *lookupKey, const std::string &selectorName,
                               Napi::Env env)>
      getJSFunction;

  // Re-acquire TSFN for fallback path. Returns nullopt if not found.
  std::function<std::optional<Napi::ThreadSafeFunction>(
      void *lookupKey, const std::string &selectorName)>
      reacquireTSFN;

  // What callback type to use
  CallbackType callbackType;
};

// MARK: - Common Implementation

/**
 * Common implementation for method forwarding.
 *
 * @param invocation The NSInvocation to forward
 * @param selectorName The selector name as a string
 * @param lookupKey The key to use for storage lookup (instance ptr for protocols,
 *                  class ptr for subclasses)
 * @param callbacks The storage-specific callback functions
 */
void ForwardInvocationCommon(NSInvocation *invocation,
                             const std::string &selectorName, void *lookupKey,
                             const ForwardingCallbacks &callbacks);

#endif // FORWARDING_COMMON_H
