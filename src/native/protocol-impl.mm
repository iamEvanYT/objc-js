#include "protocol-impl.h"
#include "ObjcObject.h"
#include "bridge.h"
#include <Foundation/Foundation.h>
#include <atomic>
#include <chrono>
#include <napi.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sstream>

// Global storage for protocol implementations
std::unordered_map<void *, ProtocolImplementation> g_implementations;

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

// Convert Objective-C value to JavaScript value
Napi::Value ConvertObjCValueToJS(Napi::Env env, void *valuePtr,
                                 const char *typeEncoding) {
  SimplifiedTypeEncoding simplifiedType(typeEncoding);

  switch (simplifiedType[0]) {
  case 'c': {
    char value = *(char *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'i': {
    int value = *(int *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 's': {
    short value = *(short *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'l': {
    long value = *(long *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'q': {
    long long value = *(long long *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'C': {
    unsigned char value = *(unsigned char *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'I': {
    unsigned int value = *(unsigned int *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'S': {
    unsigned short value = *(unsigned short *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'L': {
    unsigned long value = *(unsigned long *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'Q': {
    unsigned long long value = *(unsigned long long *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'f': {
    float value = *(float *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'd': {
    double value = *(double *)valuePtr;
    return Napi::Number::New(env, value);
  }
  case 'B': {
    bool value = *(bool *)valuePtr;
    return Napi::Boolean::New(env, value);
  }
  case '*': {
    char *value = *(char **)valuePtr;
    if (value == nullptr) {
      return env.Null();
    }
    return Napi::String::New(env, value);
  }
  case '@': {
    id value = *(__strong id *)valuePtr;
    if (value == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, value);
  }
  case '#': {
    Class value = *(Class *)valuePtr;
    if (value == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, value);
  }
  case ':': {
    SEL value = *(SEL *)valuePtr;
    if (value == nullptr) {
      return env.Null();
    }
    NSString *selectorString = NSStringFromSelector(value);
    if (selectorString == nil) {
      return env.Null();
    }
    return Napi::String::New(env, [selectorString UTF8String]);
  }
  case 'v':
    return env.Undefined();
  default:
    return env.Undefined();
  }
}

// MARK: - Method IMP Creation

// Create a method implementation from a JavaScript callback
IMP CreateMethodIMP(Napi::Env env, Napi::Function jsCallback,
                    const char *typeEncoding,
                    const std::string &selectorName) {
  // Parse the method signature to get argument types
  std::vector<std::string> argTypes = ParseMethodSignature(typeEncoding);

  // The first two arguments are always self and _cmd
  // We need to handle the remaining arguments

  // Create a block that will be called when the Objective-C method is invoked
  // We use __block to capture variables that need to be mutable
  id block = ^(id self, ...) {
    // Get the implementation details for this instance
    auto it = g_implementations.find((__bridge void *)self);
    if (it == g_implementations.end()) {
      NSLog(@"Warning: Protocol implementation not found for instance %p", self);
      return;
    }

    ProtocolImplementation &impl = it->second;
    auto callbackIt = impl.callbacks.find(selectorName);
    if (callbackIt == impl.callbacks.end()) {
      NSLog(@"Warning: Callback not found for selector %s",
            selectorName.c_str());
      return;
    }

    // Get the JavaScript callback
    Napi::FunctionReference &callback = callbackIt->second;
    
    // Get the env from the callback reference (safe to use within this scope)
    Napi::Env env = callback.Env();

    // Prepare to extract arguments
    va_list args;
    va_start(args, self);

    // Convert Objective-C arguments to JavaScript values
    std::vector<napi_value> jsArgs;

    // Skip first two types (return type, self, _cmd)
    for (size_t i = 3; i < argTypes.size(); i++) {
      SimplifiedTypeEncoding argType(argTypes[i].c_str());

      switch (argType[0]) {
      case 'c': {
        char value = (char)va_arg(args, int); // char is promoted to int
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'i': {
        int value = va_arg(args, int);
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 's': {
        short value = (short)va_arg(args, int); // short is promoted to int
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'l': {
        long value = va_arg(args, long);
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'q': {
        long long value = va_arg(args, long long);
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'C': {
        unsigned char value =
            (unsigned char)va_arg(args, unsigned int); // promoted
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'I': {
        unsigned int value = va_arg(args, unsigned int);
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'S': {
        unsigned short value =
            (unsigned short)va_arg(args, unsigned int); // promoted
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'L': {
        unsigned long value = va_arg(args, unsigned long);
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'Q': {
        unsigned long long value = va_arg(args, unsigned long long);
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'f': {
        float value = (float)va_arg(args, double); // float is promoted to double
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'd': {
        double value = va_arg(args, double);
        jsArgs.push_back(Napi::Number::New(env, value));
        break;
      }
      case 'B': {
        bool value = (bool)va_arg(args, int); // bool is promoted to int
        jsArgs.push_back(Napi::Boolean::New(env, value));
        break;
      }
      case '*': {
        char *value = va_arg(args, char *);
        if (value == nullptr) {
          jsArgs.push_back(env.Null());
        } else {
          jsArgs.push_back(Napi::String::New(env, value));
        }
        break;
      }
      case '@': {
        id value = va_arg(args, id);
        if (value == nil) {
          jsArgs.push_back(env.Null());
        } else {
          jsArgs.push_back(ObjcObject::NewInstance(env, value));
        }
        break;
      }
      case '#': {
        Class value = va_arg(args, Class);
        if (value == nil) {
          jsArgs.push_back(env.Null());
        } else {
          jsArgs.push_back(ObjcObject::NewInstance(env, value));
        }
        break;
      }
      case ':': {
        SEL value = va_arg(args, SEL);
        if (value == nullptr) {
          jsArgs.push_back(env.Null());
        } else {
          NSString *selectorString = NSStringFromSelector(value);
          if (selectorString == nil) {
            jsArgs.push_back(env.Null());
          } else {
            jsArgs.push_back(
                Napi::String::New(env, [selectorString UTF8String]));
          }
        }
        break;
      }
      case '^': {
        void *value = va_arg(args, void *);
        // For now, we'll pass pointers as null or undefined
        // TODO: Better pointer handling
        if (value == nullptr) {
          jsArgs.push_back(env.Null());
        } else {
          jsArgs.push_back(env.Undefined());
        }
        break;
      }
      default:
        // Unknown type, pass undefined
        jsArgs.push_back(env.Undefined());
        break;
      }
    }

    va_end(args);

    // Call the JavaScript callback
    try {
      callback.Call(jsArgs);
    } catch (const Napi::Error &e) {
      NSLog(@"Error calling JavaScript callback for %s: %s",
            selectorName.c_str(), e.what());
    }
  };

  // Convert the block to an IMP
  return imp_implementationWithBlock(block);
}

// Deallocation implementation
void DeallocImplementation(id self, SEL _cmd) {
  // Remove the implementation from the global map
  void *ptr = (__bridge void *)self;
  auto it = g_implementations.find(ptr);
  if (it != g_implementations.end()) {
    // Clear all callbacks (this will release the Napi::FunctionReference
    // objects)
    it->second.callbacks.clear();
    g_implementations.erase(it);
  }

  // Call the superclass dealloc
  // Note: Under ARC, we don't need to manually call [super dealloc]
  // The runtime handles this automatically
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
  Protocol *protocol = objc_getProtocol(protocolName.c_str());
  if (protocol == nullptr) {
    // Log warning but continue (for informal protocols)
    NSLog(@"Warning: Protocol %s not found, creating class without protocol "
          @"conformance",
          protocolName.c_str());
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

  // Store callbacks for this instance (we'll set the instance pointer later)
  ProtocolImplementation impl{
      .callbacks = {},
      .className = className,
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
      NSLog(@"Warning: Value for selector %s is not a function, skipping",
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

      NSLog(@"Warning: No type encoding found for selector %s, using default: "
            @"%s",
            selectorName.c_str(), typeEncoding);
    }

    // Store the callback (we'll use a temporary pointer for now)
    impl.callbacks[selectorName] =
        Napi::Persistent(jsCallback);

    // Create the IMP
    IMP methodIMP =
        CreateMethodIMP(env, jsCallback, typeEncoding, selectorName);

    // Add the method to the class
    if (!class_addMethod(newClass, selector, methodIMP, typeEncoding)) {
      NSLog(@"Warning: Failed to add method %s to class", selectorName.c_str());
    }
  }

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

  // Store the implementation in the global map
  void *instancePtr = (__bridge void *)instance;
  g_implementations.emplace(instancePtr, std::move(impl));

  // Return wrapped object
  return ObjcObject::NewInstance(env, instance);
}

