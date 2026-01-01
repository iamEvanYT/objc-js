#include "ObjcObject.h"
#include "protocol-impl.h"
#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <napi.h>

Napi::Value LoadLibrary(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() != 1 || !info[0].IsString()) {
    throw Napi::TypeError::New(env, "Expected a single string argument");
  }
  std::string libPath = info[0].As<Napi::String>().Utf8Value();
  void *handle = dlopen(libPath.c_str(), RTLD_LAZY | RTLD_GLOBAL);
  if (!handle) {
    throw Napi::Error::New(env, dlerror());
  }
  return env.Undefined();
}

Napi::Value GetClassObject(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() != 1 || !info[0].IsString()) {
    throw Napi::TypeError::New(env, "Expected a single string argument");
  }
  std::string className = info[0].As<Napi::String>().Utf8Value();
  Class cls =
      NSClassFromString([NSString stringWithUTF8String:className.c_str()]);
  if (cls == nil) {
    return env.Undefined();
  }
  return ObjcObject::NewInstance(env, cls);
}

Napi::Object InitAll(Napi::Env env, Napi::Object exports) {
  ObjcObject::Init(env, exports);
  exports.Set("LoadLibrary", Napi::Function::New(env, LoadLibrary));
  exports.Set("GetClassObject", Napi::Function::New(env, GetClassObject));
  exports.Set("CreateProtocolImplementation",
              Napi::Function::New(env, CreateProtocolImplementation));
  return exports;
}

NODE_API_MODULE(nobjc_native, InitAll)