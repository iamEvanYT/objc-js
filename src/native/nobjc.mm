#include "ObjcObject.h"
#include "call-function.h"
#include "pointer-utils.h"
#include "protocol-impl.h"
#include "subclass-impl.h"
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
  @autoreleasepool {
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
  } // @autoreleasepool
}

Napi::Value GetPointer(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() != 1 || !info[0].IsObject()) {
    throw Napi::TypeError::New(env, "Expected a single ObjcObject argument");
  }
  
  Napi::Object obj = info[0].As<Napi::Object>();
  if (!obj.InstanceOf(ObjcObject::constructor.Value())) {
    throw Napi::TypeError::New(env, "Argument must be an ObjcObject instance");
  }
  
  ObjcObject *objcObj = Napi::ObjectWrap<ObjcObject>::Unwrap(obj);
  return PointerToBuffer(env, objcObj->objcObject);
}

Napi::Value FromPointer(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  
  if (info.Length() != 1) {
    throw Napi::TypeError::New(env, "Expected a single Buffer or BigInt argument");
  }
  
  void *ptr = nullptr;
  
  if (info[0].IsBuffer()) {
    Napi::Buffer<uint8_t> buffer = info[0].As<Napi::Buffer<uint8_t>>();
    if (buffer.Length() != sizeof(void*)) {
      throw Napi::TypeError::New(env, "Buffer must be exactly 8 bytes for a 64-bit pointer");
    }
    ptr = ReadPointerFromBuffer(buffer.Data());
  } else if (info[0].IsBigInt()) {
    ptr = BigIntToPointer(env, info[0].As<Napi::BigInt>());
  } else {
    throw Napi::TypeError::New(env, "Expected a Buffer or BigInt argument");
  }
  
  if (ptr == nullptr) {
    return env.Null();
  }
  
  return ObjcObject::NewInstance(env, reinterpret_cast<id>(ptr));
}

Napi::Value PumpRunLoop(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  
  // Default timeout
  NSTimeInterval timeout = 0.0;  // Don't block — just process pending sources
  
  // Optional: accept a timeout in seconds as the first argument
  if (info.Length() >= 1 && info[0].IsNumber()) {
    timeout = info[0].As<Napi::Number>().DoubleValue();
  }
  
  // Pump the main run loop via NSRunLoop API.
  // We use NSRunLoop instead of CFRunLoopRunInMode because the CF function
  // crashes under Bun's N-API implementation (segfault in the CF call).
  // NSRunLoop.runMode:beforeDate: is functionally equivalent and works
  // correctly in both Node.js and Bun.
  @autoreleasepool {
    NSRunLoop *mainLoop = [NSRunLoop mainRunLoop];
    NSDate *limitDate = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL handled = [mainLoop runMode:NSDefaultRunLoopMode beforeDate:limitDate];
    return Napi::Boolean::New(env, handled);
  }
}

Napi::Object InitAll(Napi::Env env, Napi::Object exports) {
  ObjcObject::Init(env, exports);
  exports.Set("LoadLibrary", Napi::Function::New(env, LoadLibrary));
  exports.Set("GetClassObject", Napi::Function::New(env, GetClassObject));
  exports.Set("GetPointer", Napi::Function::New(env, GetPointer));
  exports.Set("FromPointer", Napi::Function::New(env, FromPointer));
  exports.Set("CreateProtocolImplementation",
              Napi::Function::New(env, CreateProtocolImplementation));
  exports.Set("DefineClass", Napi::Function::New(env, DefineClass));
  exports.Set("CallSuper", Napi::Function::New(env, CallSuper));
  exports.Set("CallFunction", Napi::Function::New(env, CallFunction));
  exports.Set("PumpRunLoop", Napi::Function::New(env, PumpRunLoop));
  return exports;
}

NODE_API_MODULE(nobjc_native, InitAll)