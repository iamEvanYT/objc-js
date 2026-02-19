#include "ObjcObject.h"
#include "bridge.h"
#include "pointer-utils.h"
#include "struct-utils.h"
#include <Foundation/Foundation.h>
#include <napi.h>
#include <objc/objc.h>
#include <objc/message.h>
#include <memory>
#include <string_view>
#include <unordered_map>
#include <vector>

// MARK: - Fast Path: Direct objc_msgSend (H1)

/**
 * Check if a type code is eligible for the direct objc_msgSend fast path.
 * All pointer-sized or smaller integer types, float, double, id, class, SEL,
 * bool, and void are eligible. Structs, C strings, and pointers are not
 * (structs need special handling, C strings need lifetime management).
 */
static inline bool IsFastPathTypeCode(char typeCode) {
  switch (typeCode) {
    // Integer types (all fit in a register)
    case 'c': case 'i': case 's': case 'l': case 'q':
    case 'C': case 'I': case 'S': case 'L': case 'Q':
    // Floating point
    case 'f': case 'd':
    // Bool
    case 'B':
    // Object types (pointer-sized)
    case '@': case '#': case ':':
    // Void (for return type only)
    case 'v':
      return true;
    default:
      return false;
  }
}

/**
 * Check if a type code is eligible as a fast-path argument.
 * Slightly more restrictive than return types — excludes void.
 */
static inline bool IsFastPathArgTypeCode(char typeCode) {
  return typeCode != 'v' && IsFastPathTypeCode(typeCode);
}

/**
 * Convert a JS value to a register-sized integer for passing to objc_msgSend.
 * Handles id (@), Class (#), SEL (:), bool (B), and all integer types.
 * Returns the value as a uintptr_t that can be passed in a general register.
 */
static inline uintptr_t JSValueToRegister(Napi::Env env,
                                          const Napi::Value &value,
                                          char typeCode,
                                          const ObjcArgumentContext &context) {
  switch (typeCode) {
    case '@': {
      id obj = ConvertToNativeValue<id>(value, context);
      return reinterpret_cast<uintptr_t>(obj);
    }
    case '#': {
      // Class is also an id
      id obj = ConvertToNativeValue<id>(value, context);
      return reinterpret_cast<uintptr_t>(obj);
    }
    case ':': {
      SEL sel = ConvertToNativeValue<SEL>(value, context);
      return reinterpret_cast<uintptr_t>(sel);
    }
    case 'B': {
      bool b = ConvertToNativeValue<bool>(value, context);
      return static_cast<uintptr_t>(b ? 1 : 0);
    }
    case 'c': return static_cast<uintptr_t>(
                   static_cast<unsigned char>(ConvertToNativeValue<char>(value, context)));
    case 'i': return static_cast<uintptr_t>(
                   static_cast<unsigned int>(ConvertToNativeValue<int>(value, context)));
    case 's': return static_cast<uintptr_t>(
                   static_cast<unsigned short>(ConvertToNativeValue<short>(value, context)));
    case 'l': return static_cast<uintptr_t>(
                   static_cast<unsigned long>(ConvertToNativeValue<long>(value, context)));
    case 'q': return static_cast<uintptr_t>(ConvertToNativeValue<long long>(value, context));
    case 'C': return static_cast<uintptr_t>(ConvertToNativeValue<unsigned char>(value, context));
    case 'I': return static_cast<uintptr_t>(ConvertToNativeValue<unsigned int>(value, context));
    case 'S': return static_cast<uintptr_t>(ConvertToNativeValue<unsigned short>(value, context));
    case 'L': return static_cast<uintptr_t>(ConvertToNativeValue<unsigned long>(value, context));
    case 'Q': return static_cast<uintptr_t>(ConvertToNativeValue<unsigned long long>(value, context));
    default:
      throw Napi::TypeError::New(env, "Unsupported fast-path argument type");
  }
}

/**
 * Convert a raw objc_msgSend integer return value to a JS value.
 */
static inline Napi::Value RegisterToJSValue(Napi::Env env, uintptr_t raw,
                                            char typeCode) {
  switch (typeCode) {
    case 'v': return env.Undefined();
    case '@': case '#': {
      id obj = reinterpret_cast<id>(raw);
      if (obj == nil) return env.Null();
      return ObjcObject::NewInstance(env, obj);
    }
    case ':': {
      SEL sel = reinterpret_cast<SEL>(raw);
      if (sel == nullptr) return env.Null();
      return Napi::String::New(env, sel_getName(sel));
    }
    case 'B': return Napi::Boolean::New(env, raw != 0);
    case 'c': return Napi::Number::New(env, static_cast<double>(static_cast<char>(raw)));
    case 'i': return Napi::Number::New(env, static_cast<double>(static_cast<int>(raw)));
    case 's': return Napi::Number::New(env, static_cast<double>(static_cast<short>(raw)));
    case 'l': return Napi::Number::New(env, static_cast<double>(static_cast<long>(raw)));
    case 'q': return Napi::Number::New(env, static_cast<double>(static_cast<long long>(raw)));
    case 'C': return Napi::Number::New(env, static_cast<double>(static_cast<unsigned char>(raw)));
    case 'I': return Napi::Number::New(env, static_cast<double>(static_cast<unsigned int>(raw)));
    case 'S': return Napi::Number::New(env, static_cast<double>(static_cast<unsigned short>(raw)));
    case 'L': return Napi::Number::New(env, static_cast<double>(static_cast<unsigned long>(raw)));
    case 'Q': return Napi::Number::New(env, static_cast<double>(static_cast<unsigned long long>(raw)));
    default:  return env.Undefined();
  }
}

/**
 * Attempt direct objc_msgSend fast path for 0-3 non-float args.
 * Returns true and sets result if handled; false to fall through to NSInvocation.
 *
 * On ARM64, objc_msgSend handles all non-struct returns (including float/double
 * which go through SIMD registers). We cast to the appropriate function pointer
 * type to ensure correct ABI behavior.
 */
static bool TryFastMsgSend(Napi::Env env, id target, SEL selector,
                           const Napi::CallbackInfo &info,
                           NSMethodSignature *methodSignature,
                           const char *returnType, size_t expectedArgCount,
                           const char *classNameCStr, std::string_view selectorView,
                           Napi::Value &outResult) {
  // Only handle 0-3 args on the fast path
  if (expectedArgCount > 3) return false;

  char returnTypeCode = *returnType;

  // Check return type eligibility (also allow 'f' and 'd')
  if (!IsFastPathTypeCode(returnTypeCode)) return false;

  // Check all argument types and collect type codes
  char argTypeCodes[3];
  bool hasFloatArgs = false;
  for (size_t i = 0; i < expectedArgCount; i++) {
    const char *argType = SimplifyTypeEncoding(
        [methodSignature getArgumentTypeAtIndex:i + 2]);
    char code = *argType;
    if (!IsFastPathArgTypeCode(code)) return false;
    argTypeCodes[i] = code;
    if (code == 'f' || code == 'd') hasFloatArgs = true;
  }

  // Build argument context for error messages
  const ObjcArgumentContext context = {
    .className = classNameCStr,
    .selectorName = selectorView,
    .argumentIndex = 0,
  };

  // Convert arguments. Float/double args need special handling on ARM64
  // because they go in SIMD registers, so we need proper function pointer casts.
  //
  // For simplicity and correctness, we handle the common cases:
  // - All-integer args (including id, SEL, etc.) with integer/void/bool/object return
  // - All-integer args with float/double return
  // - Float/double args require per-signature casts
  //
  // Strategy: cast objc_msgSend to the exact signature to ensure ABI correctness.

  if (!hasFloatArgs) {
    // All integer-register args: cast objc_msgSend based on arg count and return type
    uintptr_t args[3];
    for (size_t i = 0; i < expectedArgCount; i++) {
      ObjcArgumentContext argCtx = context;
      argCtx.argumentIndex = static_cast<int>(i);
      args[i] = JSValueToRegister(env, info[i + 1], argTypeCodes[i], argCtx);
    }

    if (returnTypeCode == 'f') {
      // Float return
      float result;
      switch (expectedArgCount) {
        case 0:
          result = ((float(*)(id, SEL))objc_msgSend)(target, selector);
          break;
        case 1:
          result = ((float(*)(id, SEL, uintptr_t))objc_msgSend)(target, selector, args[0]);
          break;
        case 2:
          result = ((float(*)(id, SEL, uintptr_t, uintptr_t))objc_msgSend)(
              target, selector, args[0], args[1]);
          break;
        case 3:
          result = ((float(*)(id, SEL, uintptr_t, uintptr_t, uintptr_t))objc_msgSend)(
              target, selector, args[0], args[1], args[2]);
          break;
      }
      outResult = Napi::Number::New(env, static_cast<double>(result));
      return true;
    } else if (returnTypeCode == 'd') {
      // Double return
      double result;
      switch (expectedArgCount) {
        case 0:
          result = ((double(*)(id, SEL))objc_msgSend)(target, selector);
          break;
        case 1:
          result = ((double(*)(id, SEL, uintptr_t))objc_msgSend)(target, selector, args[0]);
          break;
        case 2:
          result = ((double(*)(id, SEL, uintptr_t, uintptr_t))objc_msgSend)(
              target, selector, args[0], args[1]);
          break;
        case 3:
          result = ((double(*)(id, SEL, uintptr_t, uintptr_t, uintptr_t))objc_msgSend)(
              target, selector, args[0], args[1], args[2]);
          break;
      }
      outResult = Napi::Number::New(env, result);
      return true;
    } else {
      // Integer/pointer/void return
      uintptr_t result;
      switch (expectedArgCount) {
        case 0:
          result = ((uintptr_t(*)(id, SEL))objc_msgSend)(target, selector);
          break;
        case 1:
          result = ((uintptr_t(*)(id, SEL, uintptr_t))objc_msgSend)(target, selector, args[0]);
          break;
        case 2:
          result = ((uintptr_t(*)(id, SEL, uintptr_t, uintptr_t))objc_msgSend)(
              target, selector, args[0], args[1]);
          break;
        case 3:
          result = ((uintptr_t(*)(id, SEL, uintptr_t, uintptr_t, uintptr_t))objc_msgSend)(
              target, selector, args[0], args[1], args[2]);
          break;
      }
      outResult = RegisterToJSValue(env, result, returnTypeCode);
      return true;
    }
  }

  // For float/double arguments, we need exact ABI-correct casts.
  // Handle the most common case: single double arg (e.g., numberWithDouble:)
  if (expectedArgCount == 1 && argTypeCodes[0] == 'd') {
    ObjcArgumentContext argCtx = context;
    argCtx.argumentIndex = 0;
    double arg0 = ConvertToNativeValue<double>(info[1], argCtx);
    if (returnTypeCode == 'd') {
      double result = ((double(*)(id, SEL, double))objc_msgSend)(target, selector, arg0);
      outResult = Napi::Number::New(env, result);
    } else if (returnTypeCode == 'f') {
      float result = ((float(*)(id, SEL, double))objc_msgSend)(target, selector, arg0);
      outResult = Napi::Number::New(env, static_cast<double>(result));
    } else {
      uintptr_t result = ((uintptr_t(*)(id, SEL, double))objc_msgSend)(target, selector, arg0);
      outResult = RegisterToJSValue(env, result, returnTypeCode);
    }
    return true;
  }

  if (expectedArgCount == 1 && argTypeCodes[0] == 'f') {
    ObjcArgumentContext argCtx = context;
    argCtx.argumentIndex = 0;
    float arg0 = ConvertToNativeValue<float>(info[1], argCtx);
    if (returnTypeCode == 'd') {
      double result = ((double(*)(id, SEL, float))objc_msgSend)(target, selector, arg0);
      outResult = Napi::Number::New(env, result);
    } else if (returnTypeCode == 'f') {
      float result = ((float(*)(id, SEL, float))objc_msgSend)(target, selector, arg0);
      outResult = Napi::Number::New(env, static_cast<double>(result));
    } else {
      uintptr_t result = ((uintptr_t(*)(id, SEL, float))objc_msgSend)(target, selector, arg0);
      outResult = RegisterToJSValue(env, result, returnTypeCode);
    }
    return true;
  }

  // More than 1 float arg — fall through to NSInvocation (rare case)
  return false;
}

// MARK: - Method Signature Cache

/**
 * Cache for method signatures keyed by (Class, SEL) pair.
 * Avoids redundant ObjC runtime calls for repeated $msgSend invocations
 * on the same class/selector pair.
 */
struct ClassSELHash {
  size_t operator()(const std::pair<Class, SEL> &p) const {
    auto h1 = std::hash<void *>{}((__bridge void *)p.first);
    auto h2 = std::hash<void *>{}(p.second);
    return h1 ^ (h2 << 1);
  }
};

static std::unordered_map<std::pair<Class, SEL>, NSMethodSignature *, ClassSELHash>
    methodSignatureCache;

Napi::FunctionReference ObjcObject::constructor;

void ObjcObject::Init(Napi::Env env, Napi::Object exports) {
  Napi::Function func =
      DefineClass(env, "ObjcObject",
                  {
                      InstanceMethod("$msgSend", &ObjcObject::$MsgSend),
                      InstanceMethod("$respondsToSelector", &ObjcObject::$RespondsToSelector),
                      InstanceMethod("$prepareSend", &ObjcObject::$PrepareSend),
                      InstanceMethod("$msgSendPrepared", &ObjcObject::$MsgSendPrepared),
                      InstanceMethod("$getPointer", &ObjcObject::GetPointer),
                  });
  constructor = Napi::Persistent(func);
  constructor.SuppressDestruct();
  exports.Set("ObjcObject", func);
}

Napi::Object ObjcObject::NewInstance(Napi::Env env, id obj) {
  Napi::EscapableHandleScope scope(env);
  // `obj` is already a pointer, technically, but the Napi::External
  //  API expects a pointer, so we have to pointer to the pointer.
  Napi::Object jsObj = constructor.New({Napi::External<id>::New(env, &obj)});
  return scope.Escape(jsObj).ToObject();
}

Napi::Value ObjcObject::$MsgSend(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1 || !info[0].IsString()) {
    Napi::TypeError::New(env, "Expected at least one string argument")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // Stack-allocate selector string to avoid heap allocation in common case
  size_t selectorLen = 0;
  napi_get_value_string_utf8(env, info[0], nullptr, 0, &selectorLen);
  char selectorBuf[256];
  std::unique_ptr<char[]> selectorHeap;
  const char *selectorCStr;
  if (selectorLen < sizeof(selectorBuf)) {
    napi_get_value_string_utf8(env, info[0], selectorBuf, sizeof(selectorBuf), nullptr);
    selectorCStr = selectorBuf;
  } else {
    selectorHeap.reset(new char[selectorLen + 1]);
    napi_get_value_string_utf8(env, info[0], selectorHeap.get(), selectorLen + 1, nullptr);
    selectorCStr = selectorHeap.get();
  }
  SEL selector = sel_registerName(selectorCStr);

  if (![objcObject respondsToSelector:selector]) {
    Napi::Error::New(env, "Selector not found on object")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // Use cached method signature to avoid redundant ObjC runtime calls
  auto cacheKey = std::make_pair(object_getClass(objcObject), selector);
  auto cacheIt = methodSignatureCache.find(cacheKey);
  NSMethodSignature *methodSignature;
  if (cacheIt != methodSignatureCache.end()) {
    methodSignature = cacheIt->second;
  } else {
    methodSignature = [objcObject methodSignatureForSelector:selector];
    if (methodSignature != nil) {
      methodSignatureCache[cacheKey] = methodSignature;
    }
  }
  if (methodSignature == nil) {
    Napi::Error::New(env, "Failed to get method signature")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // The first two arguments of the signature are the target and selector.
  const size_t expectedArgCount = [methodSignature numberOfArguments] - 2;

  // The first provided argument is the selector name.
  const size_t providedArgCount = info.Length() - 1;

  if (providedArgCount != expectedArgCount) {
    std::string errorMessageStr =
        std::format("Selector {} (on {}) expected {} argument(s), but got {}",
                    selectorCStr, std::string(object_getClassName(objcObject)),
                    expectedArgCount, providedArgCount);
    const char *errorMessage = errorMessageStr.c_str();
    Napi::Error::New(env, errorMessage).ThrowAsJavaScriptException();
    return env.Null();
  }

  if ([methodSignature isOneway]) {
    Napi::Error::New(env, "One-way methods are not supported")
        .ThrowAsJavaScriptException();
    return env.Null();
  }
  const char *returnType =
      SimplifyTypeEncoding([methodSignature methodReturnType]);
  const bool isStructReturn = (*returnType == '{');
  const char *validReturnTypes = "cislqCISLQfdB*v@#:";
  if (!isStructReturn &&
      (strlen(returnType) != 1 ||
       strchr(validReturnTypes, *returnType) == nullptr)) {
    Napi::TypeError::New(env, "Unsupported return type (pre-invoke)")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // Fast path: direct objc_msgSend for simple signatures (H1)
  // Skip NSInvocation overhead for 0-3 simple args with simple return types.
  if (!isStructReturn) {
    const char* classNameCStr = object_getClassName(objcObject);
    std::string_view selectorView(selectorCStr);
    Napi::Value fastResult;
    if (TryFastMsgSend(env, objcObject, selector, info, methodSignature,
                       returnType, expectedArgCount, classNameCStr, selectorView,
                       fastResult)) {
      return fastResult;
    }
  }

  NSInvocation *invocation =
      [NSInvocation invocationWithMethodSignature:methodSignature];
  [invocation setSelector:selector];
  [invocation setTarget:objcObject];

  // Store all arguments to keep them alive until after invoke.
  // Small-buffer optimization: stack-allocate for common case (<=4 args),
  // fall back to heap vector for larger argument counts.
  constexpr size_t kSmallArgCount = 4;
  ObjcType smallArgBuf[kSmallArgCount];
  std::vector<ObjcType> heapArgBuf;
  const bool useHeap = expectedArgCount > kSmallArgCount;
  if (useHeap) {
    heapArgBuf.reserve(expectedArgCount);
  }

  // Store struct argument buffers to keep them alive until after invoke.
  std::vector<std::vector<uint8_t>> structBuffers;

  // Use raw const char* / string_view to avoid heap allocation per call
  // (strings are only needed for error messages, which are rare)
  const char* classNameCStr = object_getClassName(objcObject);
  std::string_view selectorView(selectorCStr);

  for (size_t i = 1; i < info.Length(); ++i) {
    const size_t argIdx = i - 1;
    const ObjcArgumentContext context = {
        .className = classNameCStr,
        .selectorName = selectorView,
        .argumentIndex = (int)argIdx,
    };
    const char *typeEncoding =
        SimplifyTypeEncoding([methodSignature getArgumentTypeAtIndex:i + 1]);

    if (IsStructTypeEncoding(typeEncoding)) {
      // Struct argument: pack JS object into a byte buffer and set directly
      auto buffer = PackJSValueAsStruct(env, info[i], typeEncoding);
      [invocation setArgument:buffer.data() atIndex:i + 1];
      structBuffers.push_back(std::move(buffer));
      // Push a placeholder to keep indices aligned
      if (useHeap) {
        heapArgBuf.push_back(BaseObjcType{std::monostate{}});
      } else {
        smallArgBuf[argIdx] = BaseObjcType{std::monostate{}};
      }
      continue;
    }

    auto arg = AsObjCArgument(info[i], typeEncoding, context);
    if (!arg.has_value()) {
      std::string errorMessageStr = std::format("Unsupported argument type {}",
                                                std::string(typeEncoding));
      const char *errorMessage = errorMessageStr.c_str();
      Napi::TypeError::New(env, errorMessage).ThrowAsJavaScriptException();
      return env.Null();
    }
    if (useHeap) {
      heapArgBuf.push_back(std::move(*arg));
    } else {
      smallArgBuf[argIdx] = std::move(*arg);
    }
    ObjcType& stored = useHeap ? heapArgBuf.back() : smallArgBuf[argIdx];
    std::visit(
        [&](auto &&outer) {
          using OuterT = std::decay_t<decltype(outer)>;
          if constexpr (std::is_same_v<OuterT, BaseObjcType>) {
            std::visit(SetObjCArgumentVisitor{invocation, i + 1}, outer);
          } else if constexpr (std::is_same_v<OuterT, BaseObjcType *>) {
            if (outer)
              std::visit(SetObjCArgumentVisitor{invocation, i + 1}, *outer);
          }
        },
        stored);
  }

  [invocation invoke];
  // smallArgBuf/heapArgBuf and structBuffers go out of scope here, after invoke

  if (isStructReturn) {
    // Struct return: read bytes from invocation and convert to JS object
    NSUInteger returnLength = [methodSignature methodReturnLength];
    std::vector<uint8_t> returnBuffer(returnLength, 0);
    [invocation getReturnValue:returnBuffer.data()];
    return UnpackStructToJSValue(env, returnBuffer.data(), returnType);
  }

  return ConvertReturnValueToJSValue(env, invocation, methodSignature);
}

Napi::Value ObjcObject::GetPointer(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  return PointerToBuffer(env, objcObject);
}

// MARK: - $RespondsToSelector (H4: avoid double FFI round-trip)

Napi::Value ObjcObject::$RespondsToSelector(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1 || !info[0].IsString()) {
    Napi::TypeError::New(env, "$respondsToSelector requires a string argument")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // Stack-allocate selector string (same pattern as $MsgSend)
  size_t selectorLen = 0;
  napi_get_value_string_utf8(env, info[0], nullptr, 0, &selectorLen);
  char selectorBuf[256];
  std::unique_ptr<char[]> selectorHeap;
  const char *selectorCStr;
  if (selectorLen < sizeof(selectorBuf)) {
    napi_get_value_string_utf8(env, info[0], selectorBuf, sizeof(selectorBuf), nullptr);
    selectorCStr = selectorBuf;
  } else {
    selectorHeap.reset(new char[selectorLen + 1]);
    napi_get_value_string_utf8(env, info[0], selectorHeap.get(), selectorLen + 1, nullptr);
    selectorCStr = selectorHeap.get();
  }

  SEL selector = sel_registerName(selectorCStr);
  BOOL responds = [objcObject respondsToSelector:selector];
  return Napi::Boolean::New(env, responds);
}

// MARK: - $PrepareSend / $MsgSendPrepared (H2: cache SEL + method signature)

/**
 * $prepareSend(selectorName: string) -> External<PreparedSend>
 *
 * One-time call that resolves the selector, checks respondsToSelector:,
 * looks up the method signature, and pre-computes fast-path eligibility.
 * Returns an opaque External handle for use with $msgSendPrepared.
 */
Napi::Value ObjcObject::$PrepareSend(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1 || !info[0].IsString()) {
    Napi::TypeError::New(env, "$prepareSend requires a string argument")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // Extract selector string
  size_t selectorLen = 0;
  napi_get_value_string_utf8(env, info[0], nullptr, 0, &selectorLen);
  char selectorBuf[256];
  std::unique_ptr<char[]> selectorHeap;
  const char *selectorCStr;
  if (selectorLen < sizeof(selectorBuf)) {
    napi_get_value_string_utf8(env, info[0], selectorBuf, sizeof(selectorBuf), nullptr);
    selectorCStr = selectorBuf;
  } else {
    selectorHeap.reset(new char[selectorLen + 1]);
    napi_get_value_string_utf8(env, info[0], selectorHeap.get(), selectorLen + 1, nullptr);
    selectorCStr = selectorHeap.get();
  }

  SEL selector = sel_registerName(selectorCStr);

  if (![objcObject respondsToSelector:selector]) {
    Napi::Error::New(env, std::string("$prepareSend: selector not found: ") + selectorCStr)
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // Look up or cache method signature
  auto cacheKey = std::make_pair(object_getClass(objcObject), selector);
  auto cacheIt = methodSignatureCache.find(cacheKey);
  NSMethodSignature *methodSignature;
  if (cacheIt != methodSignatureCache.end()) {
    methodSignature = cacheIt->second;
  } else {
    methodSignature = [objcObject methodSignatureForSelector:selector];
    if (methodSignature != nil) {
      methodSignatureCache[cacheKey] = methodSignature;
    }
  }
  if (methodSignature == nil) {
    Napi::Error::New(env, "$prepareSend: failed to get method signature")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  // Build PreparedSend handle
  auto *prepared = new PreparedSend();
  prepared->selector = selector;
  prepared->methodSignature = methodSignature;
  prepared->expectedArgCount = [methodSignature numberOfArguments] - 2;

  const char *returnType = SimplifyTypeEncoding([methodSignature methodReturnType]);
  prepared->returnType = returnType;
  prepared->fastReturnTypeCode = *returnType;
  prepared->isStructReturn = (*returnType == '{');

  // Determine fast-path eligibility
  bool canFast = !prepared->isStructReturn && IsFastPathTypeCode(prepared->fastReturnTypeCode)
                 && prepared->expectedArgCount <= 3;

  bool hasFloatArgs = false;
  prepared->argInfos.resize(prepared->expectedArgCount);
  for (size_t i = 0; i < prepared->expectedArgCount; i++) {
    const char *argType = SimplifyTypeEncoding(
        [methodSignature getArgumentTypeAtIndex:i + 2]);
    char code = *argType;
    prepared->argInfos[i] = {code, code == '{'};
    if (code == '{' || !IsFastPathArgTypeCode(code)) {
      canFast = false;
    }
    if (code == 'f' || code == 'd') hasFloatArgs = true;
  }

  // Float args with >1 arg need special per-signature casts we only handle for 1 arg
  if (hasFloatArgs && prepared->expectedArgCount > 1) {
    canFast = false;
  }

  prepared->canUseFastPath = canFast;

  // Return as External with destructor
  return Napi::External<PreparedSend>::New(env, prepared,
      [](Napi::Env, PreparedSend *p) { delete p; });
}

/**
 * $msgSendPrepared(handle: External<PreparedSend>, ...args) -> any
 *
 * Sends a message using a pre-computed PreparedSend handle.
 * Skips selector registration, respondsToSelector:, method signature lookup,
 * and return type validation. Goes straight to fast path or NSInvocation.
 */
Napi::Value ObjcObject::$MsgSendPrepared(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1 || !info[0].IsExternal()) {
    Napi::TypeError::New(env, "$msgSendPrepared requires a PreparedSend handle as first argument")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  PreparedSend *prepared = info[0].As<Napi::External<PreparedSend>>().Data();
  if (!prepared) {
    Napi::Error::New(env, "$msgSendPrepared: invalid handle")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  const size_t providedArgCount = info.Length() - 1;
  if (providedArgCount != prepared->expectedArgCount) {
    std::string errorMsg = std::format(
        "$msgSendPrepared: expected {} arg(s), got {}",
        prepared->expectedArgCount, providedArgCount);
    Napi::Error::New(env, errorMsg).ThrowAsJavaScriptException();
    return env.Null();
  }

  // Fast path: direct objc_msgSend
  if (prepared->canUseFastPath) {
    const char *classNameCStr = object_getClassName(objcObject);
    std::string_view selectorView(sel_getName(prepared->selector));
    Napi::Value fastResult;
    if (TryFastMsgSend(env, objcObject, prepared->selector, info,
                       prepared->methodSignature, prepared->returnType,
                       prepared->expectedArgCount, classNameCStr, selectorView,
                       fastResult)) {
      return fastResult;
    }
  }

  // Slow path: NSInvocation
  NSInvocation *invocation =
      [NSInvocation invocationWithMethodSignature:prepared->methodSignature];
  [invocation setSelector:prepared->selector];
  [invocation setTarget:objcObject];

  constexpr size_t kSmallArgCount = 4;
  ObjcType smallArgBuf[kSmallArgCount];
  std::vector<ObjcType> heapArgBuf;
  const bool useHeap = prepared->expectedArgCount > kSmallArgCount;
  if (useHeap) {
    heapArgBuf.reserve(prepared->expectedArgCount);
  }

  std::vector<std::vector<uint8_t>> structBuffers;

  const char *classNameCStr = object_getClassName(objcObject);
  std::string_view selectorView(sel_getName(prepared->selector));

  for (size_t i = 0; i < prepared->expectedArgCount; i++) {
    const size_t jsArgIdx = i + 1; // info[0] is the handle
    const ObjcArgumentContext context = {
        .className = classNameCStr,
        .selectorName = selectorView,
        .argumentIndex = (int)i,
    };
    const char *typeEncoding = SimplifyTypeEncoding(
        [prepared->methodSignature getArgumentTypeAtIndex:i + 2]);

    if (IsStructTypeEncoding(typeEncoding)) {
      auto buffer = PackJSValueAsStruct(env, info[jsArgIdx], typeEncoding);
      [invocation setArgument:buffer.data() atIndex:i + 2];
      structBuffers.push_back(std::move(buffer));
      if (useHeap) {
        heapArgBuf.push_back(BaseObjcType{std::monostate{}});
      } else {
        smallArgBuf[i] = BaseObjcType{std::monostate{}};
      }
      continue;
    }

    auto arg = AsObjCArgument(info[jsArgIdx], typeEncoding, context);
    if (!arg.has_value()) {
      Napi::TypeError::New(env, std::string("Unsupported argument type ") + typeEncoding)
          .ThrowAsJavaScriptException();
      return env.Null();
    }
    if (useHeap) {
      heapArgBuf.push_back(std::move(*arg));
    } else {
      smallArgBuf[i] = std::move(*arg);
    }
    ObjcType &stored = useHeap ? heapArgBuf.back() : smallArgBuf[i];
    std::visit(
        [&](auto &&outer) {
          using OuterT = std::decay_t<decltype(outer)>;
          if constexpr (std::is_same_v<OuterT, BaseObjcType>) {
            std::visit(SetObjCArgumentVisitor{invocation, i + 2}, outer);
          } else if constexpr (std::is_same_v<OuterT, BaseObjcType *>) {
            if (outer)
              std::visit(SetObjCArgumentVisitor{invocation, i + 2}, *outer);
          }
        },
        stored);
  }

  [invocation invoke];

  if (prepared->isStructReturn) {
    NSUInteger returnLength = [prepared->methodSignature methodReturnLength];
    std::vector<uint8_t> returnBuffer(returnLength, 0);
    [invocation getReturnValue:returnBuffer.data()];
    return UnpackStructToJSValue(env, returnBuffer.data(), prepared->returnType);
  }

  return ConvertReturnValueToJSValue(env, invocation, prepared->methodSignature);
}