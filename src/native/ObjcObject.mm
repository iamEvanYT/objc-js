#include "ObjcObject.h"
#include "bridge.h"
#include "pointer-utils.h"
#include "struct-utils.h"
#include <Foundation/Foundation.h>
#include <napi.h>
#include <objc/objc.h>
#include <memory>
#include <string_view>
#include <unordered_map>
#include <vector>

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