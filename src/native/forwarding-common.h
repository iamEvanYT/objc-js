#ifndef FORWARDING_COMMON_H
#define FORWARDING_COMMON_H

#include "memory-utils.h"
#include "protocol-storage.h"
#include <cstring>
#include <functional>
#include <napi.h>
#include <optional>

#ifdef __OBJC__
@class NSInvocation;
#else
typedef struct NSInvocation NSInvocation;
#endif

// MARK: - Forwarding Pipeline Cache

/**
 * Thread-local cache to avoid redundant lock acquisition in the
 * RespondsToSelector -> MethodSignatureForSelector pipeline.
 *
 * A single forwarded call triggers both methods sequentially on the same thread.
 * By caching the type encoding from RespondsToSelector, MethodSignatureForSelector
 * can skip the lock entirely on cache hit.
 */
struct ForwardingPipelineCache {
  void* key;        // instance ptr (protocols) or class ptr (subclasses)
  SEL selector;
  char typeEncoding[128];
  bool valid;

  void store(void* k, SEL sel, const char* encoding) {
    key = k;
    selector = sel;
    std::strncpy(typeEncoding, encoding, sizeof(typeEncoding) - 1);
    typeEncoding[sizeof(typeEncoding) - 1] = '\0';
    valid = true;
  }

  void invalidate() { valid = false; }

  bool matches(void* k, SEL sel) const {
    return valid && key == k && selector == sel;
  }
};

inline ForwardingPipelineCache& GetForwardingCache() {
  static thread_local ForwardingPipelineCache cache = {nullptr, nullptr, "", false};
  return cache;
}

// MARK: - Forwarding Context

/**
 * Context data gathered during the initial lookup phase.
 * This contains everything needed to perform the invocation.
 * 
 * Performance optimization: We cache the JS function reference here
 * so that getJSFunction doesn't need to re-acquire the mutex.
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
  
  // Cached JS function reference (avoids re-acquiring mutex in getJSFunction)
  // This is a raw pointer to the FunctionReference stored in the global map.
  // It remains valid as long as the implementation exists.
  Napi::FunctionReference* cachedJsCallback;

  ForwardingContext()
      : js_thread(0), env(nullptr), skipDirectCallForElectron(false),
        instancePtr(nullptr), superClassPtr(nullptr), cachedJsCallback(nullptr) {}
};

/**
 * Callbacks for storage-specific operations.
 * This allows ForwardInvocationCommon to work with both protocols and subclasses.
 */
struct ForwardingCallbacks {
  // Look up context data under lock. Returns nullopt if not found.
  // Also acquires the TSFN.
  std::function<std::optional<ForwardingContext>(
      void *lookupKey, SEL selector)>
      lookupContext;

  // Get the JS function for direct call (called within HandleScope).
  // Returns empty function if not found.
  std::function<Napi::Function(void *lookupKey, SEL selector,
                                Napi::Env env)>
      getJSFunction;

  // Re-acquire TSFN for fallback path. Returns nullopt if not found.
  std::function<std::optional<Napi::ThreadSafeFunction>(
      void *lookupKey, SEL selector)>
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
                             SEL selector, void *lookupKey,
                             const ForwardingCallbacks &callbacks);

#endif // FORWARDING_COMMON_H
