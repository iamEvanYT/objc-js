#ifndef TYPE_CONVERSION_H
#define TYPE_CONVERSION_H

#include "ObjcObject.h"
#include "type-dispatch.h"
#include <Foundation/Foundation.h>
#include <napi.h>
#include <objc/runtime.h>
#include <string>

// MARK: - Type Encoding Utilities

// Helper class to manage the lifetime of simplified type encodings
class SimplifiedTypeEncoding {
private:
  std::string simplified;

public:
  SimplifiedTypeEncoding(const char *typeEncoding) : simplified(typeEncoding) {
    // Remove any leading qualifiers (r=const, n=in, N=inout, o=out, O=bycopy,
    // R=byref, V=oneway)
    while (!simplified.empty() &&
           (simplified[0] == 'r' || simplified[0] == 'n' ||
            simplified[0] == 'N' || simplified[0] == 'o' ||
            simplified[0] == 'O' || simplified[0] == 'R' ||
            simplified[0] == 'V')) {
      simplified.erase(0, 1);
    }
  }

  const char *c_str() const { return simplified.c_str(); }
  char operator[](size_t index) const { return simplified[index]; }
  operator const char *() const { return simplified.c_str(); }
};

// Legacy function for compatibility - returns pointer to internal string
// WARNING: The returned pointer is only valid as long as the typeEncoding
// parameter is valid
inline const char *SimplifyTypeEncoding(const char *typeEncoding) {
  // For simple cases where there are no qualifiers, return the original pointer
  if (typeEncoding && typeEncoding[0] != 'r' && typeEncoding[0] != 'n' &&
      typeEncoding[0] != 'N' && typeEncoding[0] != 'o' &&
      typeEncoding[0] != 'O' && typeEncoding[0] != 'R' &&
      typeEncoding[0] != 'V') {
    return typeEncoding;
  }

  // For complex cases, we need to skip qualifiers
  // This is a temporary fix - callers should use SimplifiedTypeEncoding class
  static thread_local std::string buffer;
  buffer = typeEncoding;
  while (!buffer.empty() &&
         (buffer[0] == 'r' || buffer[0] == 'n' || buffer[0] == 'N' ||
          buffer[0] == 'o' || buffer[0] == 'O' || buffer[0] == 'R' ||
          buffer[0] == 'V')) {
    buffer.erase(0, 1);
  }
  return buffer.c_str();
}

// MARK: - ObjC to JS Conversion

// Visitor for converting ObjC values to JS
struct ObjCToJSVisitor {
  Napi::Env env;
  void* valuePtr;

  // Numeric types -> Number (or Boolean for bool)
  template <typename T>
  auto operator()(std::type_identity<T>) const 
      -> std::enable_if_t<is_numeric_v<T> && !std::is_same_v<T, bool>, Napi::Value> {
    T value = *static_cast<T*>(valuePtr);
    return Napi::Number::New(env, static_cast<double>(value));
  }

  // Bool -> Boolean
  Napi::Value operator()(std::type_identity<bool>) const {
    bool value = *static_cast<bool*>(valuePtr);
    return Napi::Boolean::New(env, value);
  }

  // C string -> String or Null
  Napi::Value operator()(std::type_identity<ObjCCStringTag>) const {
    char* value = *static_cast<char**>(valuePtr);
    if (value == nullptr) {
      return env.Null();
    }
    return Napi::String::New(env, value);
  }

  // id -> ObjcObject or Null
  Napi::Value operator()(std::type_identity<ObjCIdTag>) const {
    id value = *static_cast<__strong id*>(valuePtr);
    if (value == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, value);
  }

  // Class -> ObjcObject or Null
  Napi::Value operator()(std::type_identity<ObjCClassTag>) const {
    Class value = *static_cast<Class*>(valuePtr);
    if (value == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, value);
  }

  // SEL -> String or Null
  Napi::Value operator()(std::type_identity<ObjCSELTag>) const {
    SEL value = *static_cast<SEL*>(valuePtr);
    if (value == nullptr) {
      return env.Null();
    }
    NSString* selectorString = NSStringFromSelector(value);
    if (selectorString == nil) {
      return env.Null();
    }
    return Napi::String::New(env, [selectorString UTF8String]);
  }

  // Pointer -> Undefined (not fully supported)
  Napi::Value operator()(std::type_identity<ObjCPointerTag>) const {
    return env.Undefined();
  }

  // Void -> Undefined
  Napi::Value operator()(std::type_identity<ObjCVoidTag>) const {
    return env.Undefined();
  }
};

// Convert an Objective-C value (from a pointer) to a JavaScript value
inline Napi::Value ObjCToJS(Napi::Env env, void *valuePtr, char typeCode) {
  return DispatchByTypeCode(typeCode, ObjCToJSVisitor{env, valuePtr});
}

// Visitor for extracting NSInvocation arguments to JS
struct ExtractInvocationArgVisitor {
  Napi::Env env;
  NSInvocation* invocation;
  NSUInteger index;

  // Numeric types -> Number (or Boolean for bool)
  template <typename T>
  auto operator()(std::type_identity<T>) const 
      -> std::enable_if_t<is_numeric_v<T> && !std::is_same_v<T, bool>, Napi::Value> {
    T value;
    [invocation getArgument:&value atIndex:index];
    return Napi::Number::New(env, static_cast<double>(value));
  }

  // Bool -> Boolean
  Napi::Value operator()(std::type_identity<bool>) const {
    bool value;
    [invocation getArgument:&value atIndex:index];
    return Napi::Boolean::New(env, value);
  }

  // C string -> String or Null
  Napi::Value operator()(std::type_identity<ObjCCStringTag>) const {
    char* value;
    [invocation getArgument:&value atIndex:index];
    if (value == nullptr) {
      return env.Null();
    }
    return Napi::String::New(env, value);
  }

  // id -> ObjcObject or Null
  Napi::Value operator()(std::type_identity<ObjCIdTag>) const {
    __unsafe_unretained id value;
    [invocation getArgument:&value atIndex:index];
    if (value == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, value);
  }

  // Class -> ObjcObject or Null
  Napi::Value operator()(std::type_identity<ObjCClassTag>) const {
    Class value;
    [invocation getArgument:&value atIndex:index];
    if (value == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, value);
  }

  // SEL -> String or Null
  Napi::Value operator()(std::type_identity<ObjCSELTag>) const {
    SEL value;
    [invocation getArgument:&value atIndex:index];
    if (value == nullptr) {
      return env.Null();
    }
    NSString* selString = NSStringFromSelector(value);
    if (selString == nil) {
      return env.Null();
    }
    return Napi::String::New(env, [selString UTF8String]);
  }

  // Pointer -> Undefined (not fully supported)
  Napi::Value operator()(std::type_identity<ObjCPointerTag>) const {
    void* value;
    [invocation getArgument:&value atIndex:index];
    if (value == nullptr) {
      return env.Null();
    }
    return env.Undefined();
  }

  // Void -> Undefined
  Napi::Value operator()(std::type_identity<ObjCVoidTag>) const {
    return env.Undefined();
  }
};

// Extract an argument from NSInvocation and convert to JS value
inline Napi::Value ExtractInvocationArgumentToJS(Napi::Env env,
                                                 NSInvocation *invocation,
                                                 NSUInteger index,
                                                 char typeCode) {
  return DispatchByTypeCode(typeCode, ExtractInvocationArgVisitor{env, invocation, index});
}

// MARK: - JS to ObjC Return Value Conversion

// Set the return value on an NSInvocation from a JS value
inline void SetInvocationReturnFromJS(NSInvocation *invocation,
                                      Napi::Value result, char typeCode,
                                      const char *selectorName) {
  if (result.IsUndefined() || result.IsNull()) {
    // For null/undefined, set nil for object types, skip for others
    if (typeCode == '@') {
      id objcValue = nil;
      [invocation setReturnValue:&objcValue];
    }
    return;
  }

  auto asSigned64 = [&](int64_t &out) -> bool {
    if (result.IsBoolean()) {
      out = result.As<Napi::Boolean>().Value() ? 1 : 0;
      return true;
    }
    if (result.IsNumber()) {
      out = result.As<Napi::Number>().Int64Value();
      return true;
    }
    return false;
  };

  auto asUnsigned64 = [&](uint64_t &out) -> bool {
    if (result.IsBoolean()) {
      out = result.As<Napi::Boolean>().Value() ? 1 : 0;
      return true;
    }
    if (result.IsNumber()) {
      out = static_cast<uint64_t>(result.As<Napi::Number>().Int64Value());
      return true;
    }
    return false;
  };

  auto asDouble = [&](double &out) -> bool {
    if (result.IsBoolean()) {
      out = result.As<Napi::Boolean>().Value() ? 1.0 : 0.0;
      return true;
    }
    if (result.IsNumber()) {
      out = result.As<Napi::Number>().DoubleValue();
      return true;
    }
    return false;
  };

  switch (typeCode) {
  case 'c': {
    int64_t value = 0;
    if (!asSigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    char valueChar = static_cast<char>(value);
    [invocation setReturnValue:&valueChar];
    break;
  }
  case 'i': {
    int64_t value = 0;
    if (!asSigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    int valueInt = static_cast<int>(value);
    [invocation setReturnValue:&valueInt];
    break;
  }
  case 's': {
    int64_t value = 0;
    if (!asSigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    short valueShort = static_cast<short>(value);
    [invocation setReturnValue:&valueShort];
    break;
  }
  case 'l': {
    int64_t value = 0;
    if (!asSigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    long valueLong = static_cast<long>(value);
    [invocation setReturnValue:&valueLong];
    break;
  }
  case 'q': {
    int64_t value = 0;
    if (!asSigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    long long valueLongLong = static_cast<long long>(value);
    [invocation setReturnValue:&valueLongLong];
    break;
  }
  case 'C': {
    uint64_t value = 0;
    if (!asUnsigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    unsigned char valueChar = static_cast<unsigned char>(value);
    [invocation setReturnValue:&valueChar];
    break;
  }
  case 'I': {
    uint64_t value = 0;
    if (!asUnsigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    unsigned int valueInt = static_cast<unsigned int>(value);
    [invocation setReturnValue:&valueInt];
    break;
  }
  case 'S': {
    uint64_t value = 0;
    if (!asUnsigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    unsigned short valueShort = static_cast<unsigned short>(value);
    [invocation setReturnValue:&valueShort];
    break;
  }
  case 'L': {
    uint64_t value = 0;
    if (!asUnsigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    unsigned long valueLong = static_cast<unsigned long>(value);
    [invocation setReturnValue:&valueLong];
    break;
  }
  case 'Q': {
    uint64_t value = 0;
    if (!asUnsigned64(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    unsigned long long valueLongLong =
        static_cast<unsigned long long>(value);
    [invocation setReturnValue:&valueLongLong];
    break;
  }
  case 'f': {
    double value = 0;
    if (!asDouble(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    float valueFloat = static_cast<float>(value);
    [invocation setReturnValue:&valueFloat];
    break;
  }
  case 'd': {
    double value = 0;
    if (!asDouble(value)) {
      NSLog(@"Warning: result is not a number/boolean for selector %s",
            selectorName);
      break;
    }
    [invocation setReturnValue:&value];
    break;
  }
  case 'B': {
    bool value = false;
    if (result.IsBoolean()) {
      value = result.As<Napi::Boolean>().Value();
    } else if (result.IsNumber()) {
      value = result.As<Napi::Number>().Int32Value() != 0;
    } else {
      NSLog(@"Warning: result is not a boolean/number for selector %s",
            selectorName);
      break;
    }
    [invocation setReturnValue:&value];
    break;
  }
  case '@': {
    if (result.IsObject()) {
      Napi::Object resultObj = result.As<Napi::Object>();
      if (resultObj.InstanceOf(ObjcObject::constructor.Value())) {
        ObjcObject *objcObj = Napi::ObjectWrap<ObjcObject>::Unwrap(resultObj);
        id objcValue = objcObj->objcObject;
        [invocation setReturnValue:&objcValue];
      }
    }
    break;
  }
  default:
    NSLog(@"Warning: Unsupported return type '%c' for selector %s", typeCode,
          selectorName);
    break;
  }
}

// MARK: - Return Value Extraction from NSInvocation

// Visitor for getting return values from NSInvocation
struct GetInvocationReturnVisitor {
  Napi::Env env;
  NSInvocation* invocation;

  // Numeric types -> Number (or Boolean for bool)
  template <typename T>
  auto operator()(std::type_identity<T>) const 
      -> std::enable_if_t<is_numeric_v<T> && !std::is_same_v<T, bool>, Napi::Value> {
    T result;
    [invocation getReturnValue:&result];
    return Napi::Number::New(env, static_cast<double>(result));
  }

  // Bool -> Boolean
  Napi::Value operator()(std::type_identity<bool>) const {
    bool result;
    [invocation getReturnValue:&result];
    return Napi::Boolean::New(env, result);
  }

  // C string -> String or Null
  Napi::Value operator()(std::type_identity<ObjCCStringTag>) const {
    char* result = nullptr;
    [invocation getReturnValue:&result];
    if (result == nullptr) {
      return env.Null();
    }
    return Napi::String::New(env, result);
  }

  // id -> ObjcObject or Null
  Napi::Value operator()(std::type_identity<ObjCIdTag>) const {
    id result = nil;
    [invocation getReturnValue:&result];
    if (result == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, result);
  }

  // Class -> ObjcObject or Null (same as id)
  Napi::Value operator()(std::type_identity<ObjCClassTag>) const {
    id result = nil;
    [invocation getReturnValue:&result];
    if (result == nil) {
      return env.Null();
    }
    return ObjcObject::NewInstance(env, result);
  }

  // SEL -> String or Null
  Napi::Value operator()(std::type_identity<ObjCSELTag>) const {
    SEL result = nullptr;
    [invocation getReturnValue:&result];
    if (result == nullptr) {
      return env.Null();
    }
    NSString* selectorString = NSStringFromSelector(result);
    if (selectorString == nil) {
      return env.Null();
    }
    return Napi::String::New(env, [selectorString UTF8String]);
  }

  // Pointer -> Error (unsupported)
  Napi::Value operator()(std::type_identity<ObjCPointerTag>) const {
    Napi::TypeError::New(env, "Unsupported return type (pointer)")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // Void -> Undefined
  Napi::Value operator()(std::type_identity<ObjCVoidTag>) const {
    return env.Undefined();
  }
};

// Get return value from NSInvocation and convert to JS
inline Napi::Value GetInvocationReturnAsJS(Napi::Env env,
                                           NSInvocation *invocation,
                                           NSMethodSignature *methodSignature) {
  SimplifiedTypeEncoding returnType([methodSignature methodReturnType]);
  return DispatchByTypeCode(returnType[0], GetInvocationReturnVisitor{env, invocation});
}

#endif // TYPE_CONVERSION_H
