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
typedef struct objc_class *Class;
#endif

// MARK: - Data Structures

// Callback type for method forwarding
enum class CallbackType {
  Protocol,  // Protocol implementation - args start at index 2
  Subclass   // Subclass override - include self at index 0 as first JS arg
};

// Data passed from native thread to JS thread for invocation handling
struct InvocationData {
  NSInvocation *invocation;
  std::string selectorName;
  std::string typeEncoding;
  // Type of callback (protocol or subclass)
  CallbackType callbackType;
  // Synchronization: we use NonBlockingCall + runloop pumping to avoid
  // deadlocks in Electron while still getting return values
  std::mutex *completionMutex;
  std::condition_variable *completionCv;
  bool *isComplete;
  // For subclass method calls: the instance pointer (for super calls)
  void *instancePtr;
  // For subclass method calls: the superclass for super calls
  void *superClassPtr;
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

// MARK: - Subclass Storage

// Information about an overridden method in a subclass
struct SubclassMethodInfo {
  Napi::ThreadSafeFunction callback;
  Napi::FunctionReference jsCallback;
  std::string typeEncoding;
  std::string selectorName;
  bool isClassMethod;
};

// Stores information about a JS-defined subclass
struct SubclassImplementation {
  // Class name
  std::string className;
  // The Objective-C Class object
  void *objcClass;       // Class
  // The superclass for super calls
  void *superClass;      // Class
  // Methods defined by JS (selector -> info)
  std::unordered_map<std::string, SubclassMethodInfo> methods;
  // Store the environment for direct calls
  napi_env env;
  // Store the JS thread ID for thread detection
  pthread_t js_thread;
  // Flag to indicate if running in Electron
  bool isElectron;
};

// MARK: - Global Storage (DEPRECATED - use ProtocolManager/SubclassManager instead)
// These declarations are kept for backward compatibility during migration.
// New code should use:
//   - nobjc::ProtocolManager::Instance() for protocol implementations
//   - nobjc::SubclassManager::Instance() for subclass implementations

// Note: These extern declarations are removed as storage is now in the manager singletons.
// If you need to access the storage, use the manager classes directly.
// See protocol-manager.h and subclass-manager.h for the new APIs.

// MARK: - Storage Access Helpers

// Helper to signal completion of an invocation
inline void SignalInvocationComplete(InvocationData *data) {
  if (data->completionMutex && data->completionCv && data->isComplete) {
    std::lock_guard<std::mutex> lock(*data->completionMutex);
    *data->isComplete = true;
    data->completionCv->notify_one();
  }
}

// DEPRECATED: Use nobjc::ProtocolManager::Instance().Find(instancePtr) instead
// This function is no longer available as global storage has been moved to manager classes.

// DEPRECATED: Use nobjc::SubclassManager::Instance().Find(classPtr) instead
// This function is no longer available as global storage has been moved to manager classes.

#endif // PROTOCOL_STORAGE_H

