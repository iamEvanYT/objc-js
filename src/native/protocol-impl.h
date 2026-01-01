#ifndef PROTOCOL_IMPL_H
#define PROTOCOL_IMPL_H

#include <napi.h>
#include <objc/runtime.h>
#include <string>
#include <unordered_map>
#include <vector>

// MARK: - Data Structures

// Stores information about a protocol implementation instance
struct ProtocolImplementation {
  std::unordered_map<std::string, Napi::FunctionReference> callbacks;
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

// Helper: Creates an IMP (method implementation) from a JavaScript callback
IMP CreateMethodIMP(Napi::Env env, Napi::Function jsCallback,
                    const char *typeEncoding,
                    const std::string &selectorName);

// Helper: Parses an Objective-C method signature to extract argument types
std::vector<std::string> ParseMethodSignature(const char *typeEncoding);

// Helper: Converts an Objective-C value to a JavaScript value
Napi::Value ConvertObjCValueToJS(Napi::Env env, void *value,
                                 const char *typeEncoding);

// Deallocation implementation to clean up when instance is destroyed
void DeallocImplementation(id self, SEL _cmd);

#endif // PROTOCOL_IMPL_H

