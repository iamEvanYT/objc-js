#ifndef OBJCOBJECT_H
#define OBJCOBJECT_H

#include <napi.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <optional>
#include <variant>
#include <unordered_map>
#include <vector>

#ifdef __OBJC__
@class NSMethodSignature;
#else
typedef struct NSMethodSignature NSMethodSignature;
#endif

// MARK: - Prepared Send Handle

/**
 * Opaque handle for $prepareSend / $msgSendPrepared.
 * Caches SEL, method signature, and fast-path eligibility so that
 * repeated calls skip selector registration, respondsToSelector:,
 * and method signature lookup entirely.
 */
struct PreparedSend {
  SEL selector;
  NSMethodSignature *methodSignature;
  size_t expectedArgCount;    // numberOfArguments - 2 (self + _cmd)
  const char *returnType;     // simplified return type encoding (interned, lives in sig)
  bool isStructReturn;
  bool canUseFastPath;        // true if direct objc_msgSend cast is possible
  char fastReturnTypeCode;    // first char of simplified return type, for fast dispatch

  // Per-argument info for fast path
  struct ArgInfo {
    char typeCode;             // simplified type code
    bool isStruct;
  };
  std::vector<ArgInfo> argInfos;
};

class ObjcObject : public Napi::ObjectWrap<ObjcObject> {
public:
  __strong id objcObject;
  static Napi::FunctionReference constructor;
  static void Init(Napi::Env env, Napi::Object exports);
  ObjcObject(const Napi::CallbackInfo &info)
      : Napi::ObjectWrap<ObjcObject>(info), objcObject(nil) {
    if (info.Length() == 1 && info[0].IsExternal()) {
      // This better be an Napi::External<id>! We lost the type info at runtime.
      Napi::External<id> external = info[0].As<Napi::External<id>>();
      objcObject = *(external.Data());
      return;
    }
    // If someone tries `new ObjcObject()` from JS, forbid it:
    Napi::TypeError::New(info.Env(), "Cannot construct directly")
        .ThrowAsJavaScriptException();
  }
  static Napi::Object NewInstance(Napi::Env env, id obj);
  ~ObjcObject() = default;

private:
  Napi::Value $MsgSend(const Napi::CallbackInfo &info);
  Napi::Value $RespondsToSelector(const Napi::CallbackInfo &info);
  Napi::Value $PrepareSend(const Napi::CallbackInfo &info);
  Napi::Value $MsgSendPrepared(const Napi::CallbackInfo &info);
  Napi::Value GetPointer(const Napi::CallbackInfo &info);
};

#endif // OBJCOBJECT_H
