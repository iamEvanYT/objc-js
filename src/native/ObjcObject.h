#ifndef OBJCOBJECT_H
#define OBJCOBJECT_H

#include "env-lifetime.h"
#include <napi.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <optional>
#include <variant>
#include <unordered_map>
#include <vector>

// objc_retain/objc_release are part of the stable ObjC ABI (macOS 10.12+)
// but not declared in public headers. We use them for manual reference counting
// since ARC is not enabled for .mm files in this project.
extern "C" id objc_retain(id value);
extern "C" void objc_release(id value);

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

struct NobjcEnvData {
  Napi::FunctionReference objcObjectConstructor;
  EnvLifetimeRef lifetime = std::make_shared<EnvLifetime>();
};

class ObjcObject : public Napi::ObjectWrap<ObjcObject> {
public:
  __strong id objcObject;
  // Set by $dispose(). The wrapper rejects any further use.
  bool disposed = false;
  // Calls currently running on this wrapper (JS thread only). Disposing it
  // from a callback inside one of them defers the release until they return,
  // so the receiver can't be freed mid-call.
  int activeCalls = 0;
  static void Init(Napi::Env env, Napi::Object exports);
  static NobjcEnvData *GetEnvData(Napi::Env env);
  static Napi::FunctionReference &GetConstructorRef(Napi::Env env);
  static bool IsInstance(Napi::Env env, const Napi::Value &value);
  ObjcObject(const Napi::CallbackInfo &info)
      : Napi::ObjectWrap<ObjcObject>(info), objcObject(nil) {
    if (info.Length() == 1 && info[0].IsExternal()) {
      // This better be an Napi::External<id>! We lost the type info at runtime.
      Napi::External<id> external = info[0].As<Napi::External<id>>();
      objcObject = *(external.Data());
      // Retain the ObjC object so it stays alive as long as this JS wrapper
      // exists. Without this, ARC/autorelease can deallocate the object while
      // JS still holds a reference, causing Use-After-Free crashes (SIGTRAP)
      // in completion handler callbacks and other async contexts.
      // Note: ARC is not enabled for .mm files in this project (the -fobjc-arc
      // flag is in OTHER_CFLAGS, not OTHER_CPLUSPLUSFLAGS), so __strong has
      // no effect — we must manage retain/release manually.
      if (objcObject) objc_retain(objcObject);
      return;
    }
    // If someone tries `new ObjcObject()` from JS, forbid it:
    Napi::TypeError::New(info.Env(), "Cannot construct directly")
        .ThrowAsJavaScriptException();
  }
  static Napi::Object NewInstance(Napi::Env env, id obj);
  ~ObjcObject() { ReleaseObject(); }

  /**
   * The wrapped object. Throws if the wrapper was disposed, so a disposed
   * object can't silently become nil when passed to Objective-C.
   */
  id GetObjcObject(Napi::Env env) const {
    if (disposed) {
      throw Napi::Error::New(env, "Objective-C object has been disposed");
    }
    return objcObject;
  }

  void ReleaseObject() {
    id object = objcObject;
    objcObject = nil;
    if (object) objc_release(object);
  }

private:
  Napi::Value $MsgSend(const Napi::CallbackInfo &info);
  Napi::Value $RespondsToSelector(const Napi::CallbackInfo &info);
  Napi::Value $PrepareSend(const Napi::CallbackInfo &info);
  Napi::Value $MsgSendPrepared(const Napi::CallbackInfo &info);
  Napi::Value GetPointer(const Napi::CallbackInfo &info);
  Napi::Value $Dispose(const Napi::CallbackInfo &info);
};

#endif // OBJCOBJECT_H
