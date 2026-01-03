#include "ObjcObject.h"
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
  uintptr_t ptrValue = reinterpret_cast<uintptr_t>(objcObj->objcObject);
  
  // Create a Buffer to hold the pointer (8 bytes on 64-bit macOS)
  Napi::Buffer<uint8_t> buffer = Napi::Buffer<uint8_t>::New(env, sizeof(void*));
  
  // Write the pointer value to the buffer in little-endian format
  uint8_t* data = buffer.Data();
  for (size_t i = 0; i < sizeof(void*); ++i) {
    data[i] = static_cast<uint8_t>((ptrValue >> (i * 8)) & 0xFF);
  }
  
  return buffer;
}

Napi::Value FromPointer(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  
  if (info.Length() != 1) {
    throw Napi::TypeError::New(env, "Expected a single Buffer or BigInt argument");
  }
  
  uintptr_t ptrValue = 0;
  
  if (info[0].IsBuffer()) {
    // Read pointer from Buffer
    Napi::Buffer<uint8_t> buffer = info[0].As<Napi::Buffer<uint8_t>>();
    if (buffer.Length() != sizeof(void*)) {
      throw Napi::TypeError::New(env, "Buffer must be exactly 8 bytes for a 64-bit pointer");
    }
    
    uint8_t* data = buffer.Data();
    for (size_t i = 0; i < sizeof(void*); ++i) {
      ptrValue |= (static_cast<uintptr_t>(data[i]) << (i * 8));
    }
  } else if (info[0].IsBigInt()) {
    // Read pointer from BigInt
    bool lossless = false;
    uint64_t value = info[0].As<Napi::BigInt>().Uint64Value(&lossless);
    if (!lossless) {
      throw Napi::RangeError::New(env, "BigInt value out of range for pointer");
    }
    ptrValue = static_cast<uintptr_t>(value);
  } else {
    throw Napi::TypeError::New(env, "Expected a Buffer or BigInt argument");
  }
  
  if (ptrValue == 0) {
    return env.Null();
  }
  
  // Convert the pointer value back to an Objective-C object pointer
  id obj = reinterpret_cast<id>(ptrValue);
  
  return ObjcObject::NewInstance(env, obj);
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
  return exports;
}

NODE_API_MODULE(nobjc_native, InitAll)