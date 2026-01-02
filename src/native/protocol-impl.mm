#include "protocol-impl.h"
#include "ObjcObject.h"
#include "bridge.h"
#include <Foundation/Foundation.h>
#include <atomic>
#include <chrono>
#include <mutex>
#include <napi.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sstream>

// Global storage for protocol implementations
std::unordered_map<void *, ProtocolImplementation> g_implementations;
std::mutex g_implementations_mutex;

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

// MARK: - Message Forwarding Implementation

// Provide method signature for message forwarding
NSMethodSignature* MethodSignatureForSelector(id self, SEL _cmd, SEL selector) {
  void *ptr = (__bridge void *)self;
  
  std::lock_guard<std::mutex> lock(g_implementations_mutex);
  auto it = g_implementations.find(ptr);
  if (it != g_implementations.end()) {
    NSString *selectorString = NSStringFromSelector(selector);
    std::string selName = [selectorString UTF8String];
    auto encIt = it->second.typeEncodings.find(selName);
    if (encIt != it->second.typeEncodings.end()) {
      return [NSMethodSignature signatureWithObjCTypes:encIt->second.c_str()];
    }
  }
  // Fall back to superclass for methods we don't implement
  return [NSObject instanceMethodSignatureForSelector:selector];
}

// Handle forwarded invocations
void ForwardInvocation(id self, SEL _cmd, NSInvocation *invocation) {
  if (!invocation) {
    NSLog(@"Error: ForwardInvocation called with nil invocation");
    return;
  }
  
  SEL selector = [invocation selector];
  NSString *selectorString = NSStringFromSelector(selector);
  if (!selectorString) {
    NSLog(@"Error: Failed to convert selector to string");
    return;
  }
  
  std::string selectorName = [selectorString UTF8String];
  
  // Look up implementation and get callback reference
  // We need to copy the callback reference while holding the lock
  Napi::FunctionReference callback;
  std::string typeEncoding;
  {
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    void *ptr = (__bridge void *)self;
    auto it = g_implementations.find(ptr);
    if (it == g_implementations.end()) {
      NSLog(@"Warning: Protocol implementation not found for instance %p", self);
      return;
    }
    
    auto callbackIt = it->second.callbacks.find(selectorName);
    if (callbackIt == it->second.callbacks.end()) {
      NSLog(@"Warning: Callback not found for selector %s", selectorName.c_str());
      return;
    }
    
    // Get a reference to the callback (this is safe to use outside the lock)
    callback = Napi::Persistent(callbackIt->second.Value());
    
    // Also get the type encoding for return value handling
    auto encIt = it->second.typeEncodings.find(selectorName);
    if (encIt != it->second.typeEncodings.end()) {
      typeEncoding = encIt->second;
    }
  }
  
  if (callback.IsEmpty()) {
    NSLog(@"Error: JavaScript callback is empty for selector %s", selectorName.c_str());
    return;
  }
  
  Napi::Env env = callback.Env();
  
  // Extract arguments using NSInvocation
  NSMethodSignature *sig = [invocation methodSignature];
  if (!sig) {
    NSLog(@"Error: Failed to get method signature for selector %s", selectorName.c_str());
    return;
  }
  
  std::vector<napi_value> jsArgs;
  
  // Skip first two arguments (self and _cmd)
  for (NSUInteger i = 2; i < [sig numberOfArguments]; i++) {
    const char *type = [sig getArgumentTypeAtIndex:i];
    SimplifiedTypeEncoding argType(type);
    
    switch (argType[0]) {
    case 'c': {
      char value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'i': {
      int value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 's': {
      short value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'l': {
      long value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'q': {
      long long value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'C': {
      unsigned char value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'I': {
      unsigned int value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'S': {
      unsigned short value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'L': {
      unsigned long value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'Q': {
      unsigned long long value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'f': {
      float value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'd': {
      double value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Number::New(env, value));
      break;
    }
    case 'B': {
      bool value;
      [invocation getArgument:&value atIndex:i];
      jsArgs.push_back(Napi::Boolean::New(env, value));
      break;
    }
    case '*': {
      char *value;
      [invocation getArgument:&value atIndex:i];
      if (value == nullptr) {
        jsArgs.push_back(env.Null());
      } else {
        jsArgs.push_back(Napi::String::New(env, value));
      }
      break;
    }
    case '@': {
      __unsafe_unretained id value;
      [invocation getArgument:&value atIndex:i];
      if (value == nil) {
        jsArgs.push_back(env.Null());
      } else {
        jsArgs.push_back(ObjcObject::NewInstance(env, value));
      }
      break;
    }
    case '#': {
      Class value;
      [invocation getArgument:&value atIndex:i];
      if (value == nil) {
        jsArgs.push_back(env.Null());
      } else {
        jsArgs.push_back(ObjcObject::NewInstance(env, value));
      }
      break;
    }
    case ':': {
      SEL value;
      [invocation getArgument:&value atIndex:i];
      if (value == nullptr) {
        jsArgs.push_back(env.Null());
      } else {
        NSString *selString = NSStringFromSelector(value);
        if (selString == nil) {
          jsArgs.push_back(env.Null());
        } else {
          jsArgs.push_back(Napi::String::New(env, [selString UTF8String]));
        }
      }
      break;
    }
    case '^': {
      void *value;
      [invocation getArgument:&value atIndex:i];
      if (value == nullptr) {
        jsArgs.push_back(env.Null());
      } else {
        jsArgs.push_back(env.Undefined());
      }
      break;
    }
    default:
      jsArgs.push_back(env.Undefined());
      break;
    }
  }
  
  // Call the JavaScript callback
  try {
    Napi::Value result = callback.Call(jsArgs);
    
    // Handle return value if the method expects one
    const char *returnType = [sig methodReturnType];
    SimplifiedTypeEncoding retType(returnType);
    
    if (retType[0] != 'v') { // Not void
      // Convert JS return value to Objective-C and set it
      if (!result.IsUndefined() && !result.IsNull()) {
        switch (retType[0]) {
        case 'c': {
          char value = result.As<Napi::Number>().Int32Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'i': {
          int value = result.As<Napi::Number>().Int32Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 's': {
          short value = result.As<Napi::Number>().Int32Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'l': {
          long value = result.As<Napi::Number>().Int64Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'q': {
          long long value = result.As<Napi::Number>().Int64Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'C': {
          unsigned char value = result.As<Napi::Number>().Uint32Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'I': {
          unsigned int value = result.As<Napi::Number>().Uint32Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'S': {
          unsigned short value = result.As<Napi::Number>().Uint32Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'L': {
          unsigned long value = result.As<Napi::Number>().Int64Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'Q': {
          unsigned long long value = result.As<Napi::Number>().Int64Value();
          [invocation setReturnValue:&value];
          break;
        }
        case 'f': {
          float value = result.As<Napi::Number>().FloatValue();
          [invocation setReturnValue:&value];
          break;
        }
        case 'd': {
          double value = result.As<Napi::Number>().DoubleValue();
          [invocation setReturnValue:&value];
          break;
        }
        case 'B': {
          bool value = result.As<Napi::Boolean>().Value();
          [invocation setReturnValue:&value];
          break;
        }
        case '@': {
          // Return an Objective-C object
          if (result.IsObject()) {
            Napi::Object resultObj = result.As<Napi::Object>();
            // Check if it's an ObjcObject wrapper
            if (resultObj.Has("$")) {
              Napi::Value ptrValue = resultObj.Get("$");
              if (ptrValue.IsNumber()) {
                id objcValue = (__bridge id)(void *)(uintptr_t)ptrValue.As<Napi::Number>().Int64Value();
                [invocation setReturnValue:&objcValue];
              }
            }
          }
          break;
        }
        default:
          NSLog(@"Warning: Unsupported return type '%c' for selector %s", 
                retType[0], selectorName.c_str());
          break;
        }
      }
    }
  } catch (const Napi::Error &e) {
    NSLog(@"Error calling JavaScript callback for %s: %s",
          selectorName.c_str(), e.what());
  } catch (const std::exception &e) {
    NSLog(@"Exception calling JavaScript callback for %s: %s",
          selectorName.c_str(), e.what());
  } catch (...) {
    NSLog(@"Unknown error calling JavaScript callback for %s",
          selectorName.c_str());
  }
}

// Deallocation implementation
void DeallocImplementation(id self, SEL _cmd) {
  @autoreleasepool {
    // Remove the implementation from the global map
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    void *ptr = (__bridge void *)self;
    auto it = g_implementations.find(ptr);
    if (it != g_implementations.end()) {
      // Clear all callbacks (this will release the Napi::FunctionReference objects)
      // Do this carefully to avoid issues during shutdown
      try {
        it->second.callbacks.clear();
        it->second.typeEncodings.clear();
      } catch (...) {
        // Ignore errors during cleanup
        NSLog(@"Warning: Exception during callback cleanup for instance %p", self);
      }
      g_implementations.erase(it);
    }
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
  Protocol *protocol = nullptr;
  if (!protocolName.empty()) {
    protocol = objc_getProtocol(protocolName.c_str());
    if (protocol == nullptr) {
      // Log warning but continue (for informal protocols)
      NSLog(@"Warning: Protocol %s not found, creating class without protocol "
            @"conformance",
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

  // Store callbacks for this instance (we'll set the instance pointer later)
  ProtocolImplementation impl{
      .callbacks = {},
      .typeEncodings = {},
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

     // Store the callback and type encoding for message forwarding
    impl.callbacks[selectorName] = Napi::Persistent(jsCallback);
    impl.typeEncodings[selectorName] = std::string(typeEncoding);
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

  // Store the implementation in the global map
  void *instancePtr = (__bridge void *)instance;
  {
    std::lock_guard<std::mutex> lock(g_implementations_mutex);
    g_implementations.emplace(instancePtr, std::move(impl));
  }

  // Return wrapped object
  return ObjcObject::NewInstance(env, instance);
}

