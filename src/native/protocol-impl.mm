#include "protocol-impl.h"
#include "debug.h"
#include "method-forwarding.h"
#include "ObjcObject.h"
#include "protocol-manager.h"
#include "protocol-storage.h"
#include "runtime-detection.h"
#include "type-conversion.h"
#include <Foundation/Foundation.h>
#include <atomic>
#include <chrono>
#include <napi.h>
#include <objc/runtime.h>
#include <sstream>

using nobjc::ProtocolManager;

// MARK: - Helper Functions

// Parse Objective-C method signature to extract argument types
std::vector<std::string> ParseMethodSignature(const char *typeEncoding) {
  std::vector<std::string> types;
  if (!typeEncoding || strlen(typeEncoding) == 0) {
    return types;
  }

  const char *ptr = typeEncoding;
  while (*ptr) {
    // Skip digits (stack offsets)
    while (*ptr >= '0' && *ptr <= '9') {
      ptr++;
    }
    if (*ptr == '\0')
      break;

    // Start of a type
    const char *typeStart = ptr;

    // Handle type qualifiers
    while (*ptr == 'r' || *ptr == 'n' || *ptr == 'N' || *ptr == 'o' ||
           *ptr == 'O' || *ptr == 'R' || *ptr == 'V') {
      ptr++;
    }

    // Get the main type character
    if (*ptr) {
      char mainType = *ptr;
      ptr++;

      // Handle pointer types (need to read the pointed-to type)
      if (mainType == '^') {
        if (*ptr) {
          ptr++; // Skip the pointed-to type for now
        }
      }
      // Handle struct/union types (skip to closing brace)
      else if (mainType == '{' || mainType == '(') {
        char closingChar = (mainType == '{') ? '}' : ')';
        int depth = 1;
        while (*ptr && depth > 0) {
          if (*ptr == mainType)
            depth++;
          else if (*ptr == closingChar)
            depth--;
          ptr++;
        }
      }

      // Store the type
      std::string type(typeStart, ptr - typeStart);
      types.push_back(type);
    }
  }

  return types;
}

// MARK: - Main Implementation

Napi::Value CreateProtocolImplementation(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  // Validate arguments
  if (info.Length() != 2) {
    throw Napi::TypeError::New(env, "Expected 2 arguments: protocolName and "
                                    "methodImplementations");
  }

  if (!info[0].IsString()) {
    throw Napi::TypeError::New(env, "First argument must be a string");
  }

  if (!info[1].IsObject()) {
    throw Napi::TypeError::New(env, "Second argument must be an object");
  }

  std::string protocolName = info[0].As<Napi::String>().Utf8Value();
  Napi::Object methodImplementations = info[1].As<Napi::Object>();

  // Lookup the protocol
  Protocol *protocol = nullptr;
  if (!protocolName.empty()) {
    protocol = objc_getProtocol(protocolName.c_str());
    if (protocol == nullptr) {
      // Log warning but continue (for informal protocols)
      NOBJC_WARN("Protocol %s not found, creating class without protocol conformance",
            protocolName.c_str());
    }
  }

  // Generate a unique class name using timestamp and a counter
  static std::atomic<uint64_t> classCounter{0};
  auto now = std::chrono::system_clock::now();
  auto timestamp = std::chrono::duration_cast<std::chrono::nanoseconds>(
                       now.time_since_epoch())
                       .count();
  uint64_t counter = classCounter.fetch_add(1);
  std::ostringstream classNameStream;
  classNameStream << "JSProtocolImpl_" << timestamp << "_" << counter;
  std::string className = classNameStream.str();

  // Allocate a new class pair
  Class newClass =
      objc_allocateClassPair([NSObject class], className.c_str(), 0);
  if (newClass == nil) {
    throw Napi::Error::New(env, "Failed to allocate class pair");
  }

  // Get the method implementations object's property names
  Napi::Array propertyNames = methodImplementations.GetPropertyNames();

  // Detect if we're running in Electron
  bool isElectron = IsElectronRuntime(env);

  // Store callbacks for this instance (we'll set the instance pointer later)
  ProtocolImplementation impl{
      .methods = {},
      .className = className,
      .env = env,
      .js_thread = pthread_self(), // Store the current (JS) thread ID
      .isElectron = isElectron
  };

  // Store default type encodings to keep them alive
  std::vector<std::string> defaultTypeEncodings;

  // Iterate over provided methods
  for (uint32_t i = 0; i < propertyNames.Length(); i++) {
    Napi::Value key = propertyNames[i];
    if (!key.IsString()) {
      continue;
    }

    std::string selectorName = key.As<Napi::String>().Utf8Value();
    Napi::Value value = methodImplementations.Get(key);

    if (!value.IsFunction()) {
      NOBJC_WARN("Value for selector %s is not a function, skipping",
            selectorName.c_str());
      continue;
    }

    Napi::Function jsCallback = value.As<Napi::Function>();

    // Register the selector
    SEL selector = sel_registerName(selectorName.c_str());

    // Get method signature from protocol (if available)
    const char *typeEncoding = nullptr;
    if (protocol != nullptr) {
      struct objc_method_description methodDesc =
          protocol_getMethodDescription(protocol, selector, YES, YES);
      if (methodDesc.name == nullptr) {
        // Try optional methods
        methodDesc = protocol_getMethodDescription(protocol, selector, NO, YES);
      }
      if (methodDesc.name != nullptr) {
        typeEncoding = methodDesc.types;
      }
    }

    // If we couldn't get the type encoding from the protocol, use a default
    // This assumes: void return, object arguments
    if (typeEncoding == nullptr) {
      // Count colons to determine number of arguments
      size_t colonCount = 0;
      for (size_t j = 0; j < selectorName.length(); j++) {
        if (selectorName[j] == ':') {
          colonCount++;
        }
      }

      // Build a type encoding: v@:@@ (void, self, _cmd, arg1, arg2, ...)
      std::string defaultEncoding = "v@:";
      for (size_t j = 0; j < colonCount; j++) {
        defaultEncoding += "@";
      }

      // Store the string to keep it alive, then use its c_str()
      defaultTypeEncodings.push_back(std::move(defaultEncoding));
      typeEncoding = defaultTypeEncodings.back().c_str();

      NOBJC_WARN("No type encoding found for selector %s, using default: %s",
            selectorName.c_str(), typeEncoding);
    }

    // Create a ThreadSafeFunction for this callback
    Napi::ThreadSafeFunction tsfn = Napi::ThreadSafeFunction::New(
        env,
        jsCallback,         // The JS function to call
        "ProtocolCallback", // Resource name
        0,                  // Max queue size (0 = unlimited)
        1,                  // Initial thread count
        [](Napi::Env) {}    // Finalizer (no context to clean up)
    );

    // Store method info (TSFN, JS callback, type encoding) in single map
    impl.methods[selector] = ProtocolMethodInfo{
        .tsfn = tsfn,
        .jsCallback = Napi::Persistent(jsCallback),
        .typeEncoding = std::string(typeEncoding),
    };
  }

  // Override respondsToSelector
  // Use class_addMethod since the class is being created and doesn't have
  // methods yet
  if (!class_addMethod(newClass, @selector(respondsToSelector:),
                       (IMP)RespondsToSelector, "B@::")) {
    NOBJC_WARN("Failed to add respondsToSelector: method");
  }

  // Add message forwarding methods to the class
  class_addMethod(newClass, @selector(methodSignatureForSelector:),
                  (IMP)MethodSignatureForSelector, "@@::");
  class_addMethod(newClass, @selector(forwardInvocation:),
                  (IMP)ForwardInvocation, "v@:@");

  // Add dealloc method
  class_addMethod(newClass, sel_registerName("dealloc"),
                  (IMP)DeallocImplementation, "v@:");

  // Add protocol conformance (if protocol was found)
  if (protocol != nullptr) {
    class_addProtocol(newClass, protocol);
  }

  // Register the class
  objc_registerClassPair(newClass);

  // Instantiate the class
  id instance = [[newClass alloc] init];
  if (instance == nil) {
    throw Napi::Error::New(env, "Failed to instantiate class");
  }

  // Store the implementation in the manager
  void *instancePtr = (__bridge void *)instance;
  ProtocolManager::Instance().Register(instancePtr, std::move(impl));

  // Return wrapped object
  return ObjcObject::NewInstance(env, instance);
}
