#include "ObjcObject.h"
#include "type-conversion.h"
#include <Foundation/Foundation.h>
#include <format>
#include <napi.h>
#include <objc/objc.h>

#ifndef NATIVE_BRIDGE_H
#define NATIVE_BRIDGE_H

// MARK: - Type Variant and Visitor

using BaseObjcType = std::variant<char,               // c
                                  int,                // i
                                  short,              // s
                                  long,               // l
                                  long long,          // q
                                  unsigned char,      // C
                                  unsigned int,       // I
                                  unsigned short,     // S
                                  unsigned long,      // L
                                  unsigned long long, // Q
                                  float,              // f
                                  double,             // d
                                  bool,               // B
                                  std::monostate,     // v (c type: void)
                                  std::string,        // * (c type: char *)
                                  id,                 // @
                                  Class,              // #
                                  SEL,                // :
                                  void *              // ^ (pointer)
                                  >;
using ObjcType = std::variant<BaseObjcType, BaseObjcType *>;

struct SetObjCArgumentVisitor {
  NSInvocation *invocation;
  size_t index;

  void operator()(const std::string &str) const {
    const char *cstr = str.c_str();
    [invocation setArgument:&cstr atIndex:index];
  }

  void operator()(std::monostate) const {
    // void type, do nothing.
  }

  void operator()(void *ptr) const {
    [invocation setArgument:&ptr atIndex:index];
  }

  template <typename T> void operator()(T v) const {
    [invocation setArgument:&v atIndex:index];
  }
};

template <typename T1, typename T2> bool IsInRange(T1 value) {
  static_assert(std::is_arithmetic_v<T1> && std::is_arithmetic_v<T2>,
                "IsInRange<T1, T2>: both T1 and T2 must be arithmetic types");
  long double v = static_cast<long double>(value);
  long double lo = static_cast<long double>(std::numeric_limits<T2>::lowest());
  long double hi = static_cast<long double>(std::numeric_limits<T2>::max());
  return v >= lo && v <= hi;
}

// MARK: - Conversion Implementation

struct ObjcArgumentContext {
  std::string className;
  std::string selectorName;
  int argumentIndex;
};

#define CONVERT_ARG_ERROR_MSG(message)                                         \
  std::format("Error converting argument {} of {} (on {}): {}",                \
              context.argumentIndex, context.selectorName, context.className,  \
              message)

template <typename T>
T ConvertJSNumberToNativeValue(const Napi::Value &value,
                               const ObjcArgumentContext &context) {
  static_assert(
      std::is_arithmetic_v<T>,
      "ConvertJSNumberToNativeValue<T>: T must be an arithmetic type");
  if (!value.IsNumber()) {
    throw Napi::TypeError::New(value.Env(),
                               CONVERT_ARG_ERROR_MSG("Expected a number"));
  }
  double d = value.As<Napi::Number>().DoubleValue();
  if (std::isnan(d)) {
    throw Napi::TypeError::New(value.Env(),
                               CONVERT_ARG_ERROR_MSG("Number cannot be NaN"));
  }
  if (std::isinf(d)) {
    throw Napi::RangeError::New(
        value.Env(), CONVERT_ARG_ERROR_MSG("Number cannot be infinite"));
  }
  if (!IsInRange<double, T>(d)) {
    throw Napi::RangeError::New(
        value.Env(), CONVERT_ARG_ERROR_MSG("Number is out of range"));
  }
  if constexpr (std::is_integral_v<T>) {
    if (std::floor(d) != d) {
      throw Napi::TypeError::New(
          value.Env(), CONVERT_ARG_ERROR_MSG("Number must be an integer"));
    }
  }
  return static_cast<T>(d);
}

template <typename T>
T ConvertJSBigIntToNativeValue(const Napi::Value &value,
                               const ObjcArgumentContext &context) {
  static_assert(
      std::is_arithmetic_v<T>,
      "ConvertJSBigIntToNativeValue<T>: T must be an arithmetic type");
  if (!value.IsBigInt()) {
    throw Napi::TypeError::New(value.Env(),
                               CONVERT_ARG_ERROR_MSG("Expected a BigInt"));
  }
  bool lossless = false;

  if constexpr (std::is_integral_v<T>) {

    if constexpr (std::is_unsigned_v<T>) {
      uint64_t v = value.As<Napi::BigInt>().Uint64Value(&lossless);
      if (!lossless) {
        throw Napi::RangeError::New(
            value.Env(),
            CONVERT_ARG_ERROR_MSG(
                "BigInt out of range for an unsigned 64-bit integer"));
      }
      if (!IsInRange<uint64_t, T>(v)) {
        throw Napi::RangeError::New(
            value.Env(), CONVERT_ARG_ERROR_MSG("BigInt out of range"));
      }
      return static_cast<T>(v);
    } else if constexpr (std::is_signed_v<T>) {
      int64_t v = value.As<Napi::BigInt>().Int64Value(&lossless);
      if (!lossless) {
        throw Napi::RangeError::New(
            value.Env(),
            CONVERT_ARG_ERROR_MSG(
                "BigInt out of range for a signed 64-bit integer"));
      }
      if (!IsInRange<int64_t, T>(v)) {
        throw Napi::RangeError::New(
            value.Env(), CONVERT_ARG_ERROR_MSG("BigInt out of range"));
      }
      return static_cast<T>(v);
    }
  } else if constexpr (std::is_floating_point_v<T>) {
    int64_t vs = value.As<Napi::BigInt>().Int64Value(&lossless);
    if (lossless) {
      return static_cast<T>(vs);
    }
    uint64_t vu = value.As<Napi::BigInt>().Uint64Value(&lossless);
    if (lossless) {
      if (!IsInRange<long double, T>(static_cast<long double>(vu))) {
        throw Napi::RangeError::New(
            value.Env(),
            CONVERT_ARG_ERROR_MSG("BigInt too large for floating point value"));
      }
      return static_cast<T>(vu);
    }
    throw Napi::RangeError::New(
        value.Env(),
        CONVERT_ARG_ERROR_MSG("BigInt out of 64-bit representable range"));
  }
}

template <typename T>
T ConvertToNativeValue(const Napi::Value &value,
                       const ObjcArgumentContext &context) {
  if constexpr (std::is_same_v<T, id>) {
    // is value an ObjcObject instance?
    if (value.IsObject()) {
      Napi::Object obj = value.As<Napi::Object>();
      if (obj.InstanceOf(ObjcObject::constructor.Value())) {
        ObjcObject *objcObj = Napi::ObjectWrap<ObjcObject>::Unwrap(obj);
        return objcObj->objcObject;
      }
    }
  }
  if constexpr (std::is_same_v<T, SEL>) {
    if (!value.IsString()) {
      throw Napi::TypeError::New(value.Env(),
                                 CONVERT_ARG_ERROR_MSG("Expected a string"));
    }
    std::string selName = value.As<Napi::String>().Utf8Value();
    return sel_registerName(selName.c_str());
  }
  if constexpr (std::is_same_v<T, bool>) {
    if (!value.IsBoolean()) {
      throw Napi::TypeError::New(value.Env(),
                                 CONVERT_ARG_ERROR_MSG("Expected a boolean"));
    }
    return value.As<Napi::Boolean>().Value();
  } else if constexpr (std::is_same_v<T, std::string>) {
    if (!value.IsString()) {
      throw Napi::TypeError::New(value.Env(),
                                 CONVERT_ARG_ERROR_MSG("Expected a string"));
    }
    return value.As<Napi::String>().Utf8Value();
  } else if constexpr (std::is_arithmetic_v<T>) {
    if (value.IsNumber()) {
      return ConvertJSNumberToNativeValue<T>(value, context);
    } else if (value.IsBigInt()) {
      return ConvertJSBigIntToNativeValue<T>(value, context);
    } else {
      throw Napi::TypeError::New(
          value.Env(), CONVERT_ARG_ERROR_MSG("Expected a number or bigint"));
    }
  } else {
    throw Napi::TypeError::New(
        value.Env(), CONVERT_ARG_ERROR_MSG("Unsupported argument type"));
  }
}

// MARK: - Conversion Top Layer

// Convert a Napi::Value to an ObjcType based on the provided type encoding.
inline auto AsObjCArgument(const Napi::Value &value, const char *typeEncoding,
                           const ObjcArgumentContext &context)
    -> std::optional<ObjcType> {
  const char *simplifiedTypeEncoding = SimplifyTypeEncoding(typeEncoding);
  switch (*simplifiedTypeEncoding) {
  case 'c':
    return ConvertToNativeValue<char>(value, context);
  case 'i':
    return ConvertToNativeValue<int>(value, context);
  case 's':
    return ConvertToNativeValue<short>(value, context);
  case 'l':
    return ConvertToNativeValue<long>(value, context);
  case 'q':
    return ConvertToNativeValue<long long>(value, context);
  case 'C':
    return ConvertToNativeValue<unsigned char>(value, context);
  case 'I':
    return ConvertToNativeValue<unsigned int>(value, context);
  case 'S':
    return ConvertToNativeValue<unsigned short>(value, context);
  case 'L':
    return ConvertToNativeValue<unsigned long>(value, context);
  case 'Q':
    return ConvertToNativeValue<unsigned long long>(value, context);
  case 'f':
    return ConvertToNativeValue<float>(value, context);
  case 'd':
    return ConvertToNativeValue<double>(value, context);
  case 'B':
    return ConvertToNativeValue<bool>(value, context);
  case '*':
    return ConvertToNativeValue<std::string>(value, context);
  case ':':
    return ConvertToNativeValue<SEL>(value, context);
  case '@':
    return ConvertToNativeValue<id>(value, context);
  case '^': // Pointer type (^v, ^c, etc.)
    if (value.IsBuffer()) {
      Napi::Buffer<uint8_t> buffer = value.As<Napi::Buffer<uint8_t>>();
      return static_cast<void *>(buffer.Data());
    }
    if (value.IsTypedArray()) {
      Napi::TypedArray typedArray = value.As<Napi::TypedArray>();
      return static_cast<void *>(
          reinterpret_cast<uint8_t *>(typedArray.ArrayBuffer().Data()) +
          typedArray.ByteOffset());
    }
    if (value.IsNull() || value.IsUndefined()) {
      return static_cast<void *>(nullptr);
    }
    return std::nullopt;
  }
  return std::nullopt;
}

// Convert the return value of an Objective-C method to a Napi::Value.
// This is an alias for GetInvocationReturnAsJS for backward compatibility.
inline Napi::Value
ConvertReturnValueToJSValue(Napi::Env env, NSInvocation *invocation,
                            NSMethodSignature *methodSignature) {
  return GetInvocationReturnAsJS(env, invocation, methodSignature);
}

#endif // NATIVE_BRIDGE_H
