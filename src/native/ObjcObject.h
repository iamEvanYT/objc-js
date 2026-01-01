#include <napi.h>
#include <objc/objc.h>
#include <optional>
#include <variant>

#ifndef OBJCOBJECT_H
#define OBJCOBJECT_H

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
  Napi::Value GetPointer(const Napi::CallbackInfo &info);
};

#endif // OBJCOBJECT_H