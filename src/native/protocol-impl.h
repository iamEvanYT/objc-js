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

// Stores information about a protocol implementation instance
struct ProtocolImplementation {
  std::unordered_map<std::string, Napi::FunctionReference> callbacks;
  std::unordered_map<std::string, std::string> typeEncodings;
  std::string className;
  // Note: We don't store Napi::Env directly as it's unsafe beyond callback scope.
  // Instead, we retrieve the env from the FunctionReference callbacks when needed.
};

// Global map: instance pointer -> implementation details
// This keeps JavaScript callbacks alive for the lifetime of the Objective-C object
extern std::unordered_map<void *, ProtocolImplementation> g_implementations;

// MARK: - Function Declarations

// Main entry point: creates a new Objective-C class that implements a protocol
Napi::Value CreateProtocolImplementation(const Napi::CallbackInfo &info);

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

