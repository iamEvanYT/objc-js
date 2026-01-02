#ifndef PROTOCOL_IMPL_H
#define PROTOCOL_IMPL_H

#include <napi.h>
#include <objc/runtime.h>
#include <string>
#include <unordered_map>
#include <vector>

// Forward declarations for Objective-C types
#ifdef __OBJC__
@class NSMethodSignature;
@class NSInvocation;
#else
typedef struct NSMethodSignature NSMethodSignature;
typedef struct NSInvocation NSInvocation;
#endif

// MARK: - Data Structures

// Data passed from native thread to JS thread for invocation handling
struct InvocationData {
  NSInvocation *invocation;
  std::string selectorName;
  std::string typeEncoding;
  // The invocation itself stores the return value, so we don't need separate storage
  // BlockingCall ensures the callback completes before returning, so no sync primitives needed
};

// Stores information about a protocol implementation instance
struct ProtocolImplementation {
  std::unordered_map<std::string, Napi::ThreadSafeFunction> callbacks;
  std::unordered_map<std::string, Napi::FunctionReference> jsCallbacks; // Original JS functions for direct calls
  std::unordered_map<std::string, std::string> typeEncodings;
  std::string className;
  napi_env env; // Store the environment for direct calls
  pthread_t js_thread; // Store the JS thread ID
};

// Global map: instance pointer -> implementation details
// This keeps JavaScript callbacks alive for the lifetime of the Objective-C object
extern std::unordered_map<void *, ProtocolImplementation> g_implementations;

// MARK: - Function Declarations

// Main entry point: creates a new Objective-C class that implements a protocol
Napi::Value CreateProtocolImplementation(const Napi::CallbackInfo &info);

// Override respondsToSelector to return YES for implemented methods
BOOL RespondsToSelector(id self, SEL _cmd, SEL selector);

// Method signature provider for message forwarding
NSMethodSignature* MethodSignatureForSelector(id self, SEL _cmd, SEL selector);

// Forward invocation handler for dynamic method dispatch
void ForwardInvocation(id self, SEL _cmd, NSInvocation *invocation);

// Helper: Parses an Objective-C method signature to extract argument types
std::vector<std::string> ParseMethodSignature(const char *typeEncoding);

// Helper: Converts an Objective-C value to a JavaScript value
Napi::Value ConvertObjCValueToJS(Napi::Env env, void *value,
                                 const char *typeEncoding);

// Deallocation implementation to clean up when instance is destroyed
void DeallocImplementation(id self, SEL _cmd);

#endif // PROTOCOL_IMPL_H

