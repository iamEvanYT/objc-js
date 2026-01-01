#include "ObjcObject.h"
#include "bridge.h"
#include <Foundation/Foundation.h>
#include <napi.h>
#include <objc/objc.h>
#include <vector>

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

  std::string selectorName = info[0].As<Napi::String>().Utf8Value();
  SEL selector = sel_registerName(selectorName.c_str());

  if (![objcObject respondsToSelector:selector]) {
    Napi::Error::New(env, "Selector not found on object")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  NSMethodSignature *methodSignature =
      [objcObject methodSignatureForSelector:selector];
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
                    selectorName, std::string(object_getClassName(objcObject)),
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
  const char *validReturnTypes = "cislqCISLQfdB*v@#:";
  if (strlen(returnType) != 1 ||
      strchr(validReturnTypes, *returnType) == nullptr) {
    Napi::TypeError::New(env, "Unsupported return type (pre-invoke)")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  NSInvocation *invocation =
      [NSInvocation invocationWithMethodSignature:methodSignature];
  [invocation setSelector:selector];
  [invocation setTarget:objcObject];

  // Store all arguments to keep them alive until after invoke.
  // This is critical for string arguments where we pass a pointer to the
  // internal buffer of a std::string - if the string is destroyed before
  // invoke, the pointer becomes dangling.
  std::vector<ObjcType> storedArgs;
  storedArgs.reserve(info.Length() - 1);

  for (size_t i = 1; i < info.Length(); ++i) {
    const ObjcArgumentContext context = {
        .className = std::string(object_getClassName(objcObject)),
        .selectorName = selectorName,
        .argumentIndex = (int)i - 1,
    };
    const char *typeEncoding =
        SimplifyTypeEncoding([methodSignature getArgumentTypeAtIndex:i + 1]);
    auto arg = AsObjCArgument(info[i], typeEncoding, context);
    if (!arg.has_value()) {
      std::string errorMessageStr = std::format("Unsupported argument type {}",
                                                std::string(typeEncoding));
      const char *errorMessage = errorMessageStr.c_str();
      Napi::TypeError::New(env, errorMessage).ThrowAsJavaScriptException();
      return env.Null();
    }
    storedArgs.push_back(std::move(*arg));
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
        storedArgs.back());
  }

  [invocation invoke];
  // storedArgs goes out of scope here, after invoke has completed
  return ConvertReturnValueToJSValue(env, invocation, methodSignature);
}

Napi::Value ObjcObject::GetPointer(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  
  // Get the pointer value of the Objective-C object
  uintptr_t ptrValue = reinterpret_cast<uintptr_t>(objcObject);
  
  // Create a Buffer to hold the pointer (8 bytes on 64-bit macOS)
  Napi::Buffer<uint8_t> buffer = Napi::Buffer<uint8_t>::New(env, sizeof(void*));
  
  // Write the pointer value to the buffer in little-endian format
  uint8_t* data = buffer.Data();
  for (size_t i = 0; i < sizeof(void*); ++i) {
    data[i] = static_cast<uint8_t>((ptrValue >> (i * 8)) & 0xFF);
  }
  
  return buffer;
}