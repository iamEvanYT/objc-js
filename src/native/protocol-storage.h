#ifndef PROTOCOL_STORAGE_H
#define PROTOCOL_STORAGE_H

#include <condition_variable>
#include <mutex>
#include <napi.h>
#include <pthread.h>
#include <string>
#include <unordered_map>

// Forward declarations for Objective-C types
#ifdef __OBJC__
@class NSInvocation;
#else
typedef struct NSInvocation NSInvocation;
#endif

// MARK: - Data Structures

// Data passed from native thread to JS thread for invocation handling
struct InvocationData {
  NSInvocation *invocation;
  std::string selectorName;
  std::string typeEncoding;
  // Synchronization: we use NonBlockingCall + runloop pumping to avoid
  // deadlocks in Electron while still getting return values
  std::mutex *completionMutex;
  std::condition_variable *completionCv;
  bool *isComplete;
};

// Stores information about a protocol implementation instance
struct ProtocolImplementation {
  // ThreadSafeFunction for each selector - allows calling JS from any thread
  std::unordered_map<std::string, Napi::ThreadSafeFunction> callbacks;
  // Original JS functions for direct calls (kept alive by persistent refs)
  std::unordered_map<std::string, Napi::FunctionReference> jsCallbacks;
  // Type encodings for each selector
  std::unordered_map<std::string, std::string> typeEncodings;
  // Dynamically generated class name
  std::string className;
  // Store the environment for direct calls
  napi_env env;
  // Store the JS thread ID for thread detection
  pthread_t js_thread;
  // Flag to indicate if running in Electron (requires TSFN path always)
  bool isElectron;
};

// MARK: - Global Storage

// Global map: instance pointer -> implementation details
// This keeps JavaScript callbacks alive for the lifetime of the Objective-C
// object
extern std::unordered_map<void *, ProtocolImplementation> g_implementations;
extern std::mutex g_implementations_mutex;

// MARK: - Storage Access Helpers

// Helper to signal completion of an invocation
inline void SignalInvocationComplete(InvocationData *data) {
  if (data->completionMutex && data->completionCv && data->isComplete) {
    std::lock_guard<std::mutex> lock(*data->completionMutex);
    *data->isComplete = true;
    data->completionCv->notify_one();
  }
}

// Look up implementation for an instance pointer
// Returns nullptr if not found
// Caller must hold g_implementations_mutex
inline ProtocolImplementation *
FindImplementation(void *instancePtr) {
  auto it = g_implementations.find(instancePtr);
  if (it != g_implementations.end()) {
    return &it->second;
  }
  return nullptr;
}

#endif // PROTOCOL_STORAGE_H

