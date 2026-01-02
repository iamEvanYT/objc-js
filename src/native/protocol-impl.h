#ifndef PROTOCOL_IMPL_H
#define PROTOCOL_IMPL_H

#include <napi.h>
#include <string>
#include <vector>

// MARK: - Public API

// Main entry point: creates a new Objective-C class that implements a protocol
// Arguments:
//   - protocolName (string): Name of the Objective-C protocol to implement
//   - methodImplementations (object): Map of selector names to JS functions
// Returns: An ObjcObject wrapping the new instance
Napi::Value CreateProtocolImplementation(const Napi::CallbackInfo &info);

// MARK: - Utility Functions

// Helper: Parses an Objective-C method signature to extract argument types
std::vector<std::string> ParseMethodSignature(const char *typeEncoding);

#endif // PROTOCOL_IMPL_H
