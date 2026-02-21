#pragma once

// ============================================================================
// call-function.h - C Function Calling via dlsym + libffi
// ============================================================================
//
// Provides the ability to call C functions (like NSLog, CGRectMake, etc.)
// exported from loaded frameworks. Uses dlsym to look up the function
// symbol and libffi to perform the call with correct ABI handling.
//
// NOTE: No @autoreleasepool is used here. C functions like NSHomeDirectory()
// return autoreleased objects, and wrapping the call in @autoreleasepool would
// drain the pool before ObjcObject::NewInstance can retain the returned object,
// leaving the ObjcObject holding a dangling pointer. The caller's autorelease
// pool (from Node's/Bun's event loop) handles cleanup instead.
//

#include "constants.h"
#include "debug.h"
#include "ffi-utils.h"
#include "struct-utils.h"
#include "type-conversion.h"
#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <ffi.h>
#include <memory>
#include <napi.h>
#include <string>
#include <vector>

// MARK: - Argument Extraction

/// Extract a JS argument into a buffer based on the type encoding.
/// Handles struct types via PackJSValueAsStruct, and simple types via
/// ExtractJSArgumentToBuffer.
///
/// Returns the owned buffer (for structs) so the caller can keep it alive.
inline std::unique_ptr<uint8_t[]>
ExtractFunctionArgument(Napi::Env env, const Napi::Value &jsValue,
                        const std::string &typeEncoding, void **outArgPtr,
                        const std::string &functionName, int argIndex,
                        FFITypeGuard &guard) {
  const char *simplified = SimplifyTypeEncoding(typeEncoding.c_str());

  if (*simplified == '{') {
    // Struct argument: pack JS value into struct buffer
    auto structBytes = PackJSValueAsStruct(env, jsValue, typeEncoding.c_str());
    auto buffer = std::make_unique<uint8_t[]>(structBytes.size());
    memcpy(buffer.get(), structBytes.data(), structBytes.size());
    *outArgPtr = buffer.get();
    NOBJC_LOG("ExtractFunctionArgument: Packed struct arg %d (%zu bytes)",
              argIndex, structBytes.size());
    return buffer;
  }

  // Simple type: compute size and extract
  size_t argSize = GetSizeForTypeEncoding(*simplified);
  if (argSize == 0 && *simplified != 'v') {
    // Complex type - use NSGetSizeAndAlignment
    NSUInteger nsSize, nsAlignment;
    NSGetSizeAndAlignment(typeEncoding.c_str(), &nsSize, &nsAlignment);
    argSize = nsSize;
  }

  if (argSize == 0) {
    argSize = nobjc::kDefaultArgBufferSize;
  }

  auto buffer = std::make_unique<uint8_t[]>(argSize);
  memset(buffer.get(), 0, argSize);

  ObjcArgumentContext context = {
      .className = functionName,
      .selectorName = functionName,
      .argumentIndex = argIndex,
  };

  ExtractJSArgumentToBuffer(env, jsValue, typeEncoding.c_str(), buffer.get(),
                            context);
  *outArgPtr = buffer.get();

  NOBJC_LOG("ExtractFunctionArgument: Extracted arg %d (type=%s, size=%zu)",
            argIndex, typeEncoding.c_str(), argSize);
  return buffer;
}

// MARK: - Return Value Conversion

/// Convert an FFI return buffer to a JS value, handling structs.
inline Napi::Value ConvertFunctionReturnToJS(Napi::Env env, void *returnBuffer,
                                             const std::string &typeEncoding) {
  const char *simplified = SimplifyTypeEncoding(typeEncoding.c_str());

  if (*simplified == '{') {
    // Struct return: unpack to JS object
    return UnpackStructToJSValue(env, static_cast<const uint8_t *>(returnBuffer),
                                 typeEncoding.c_str());
  }

  // Simple type
  return ConvertFFIReturnToJS(env, returnBuffer, typeEncoding.c_str());
}

// MARK: - CallFunction Implementation

/// Native implementation of CallFunction.
///
/// Arguments:
///   info[0]: function name (string)
///   info[1]: return type encoding (string)
///   info[2]: argument type encodings (array of strings)
///   info[3]: fixed argument count (number) - if < total args, uses
///            ffi_prep_cif_var for variadic calling convention
///   info[4+]: actual arguments
inline Napi::Value CallFunction(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  // Validate minimum arguments
  if (info.Length() < 4) {
    throw Napi::TypeError::New(
        env,
        "CallFunction requires at least 4 arguments: name, returnType, "
        "argTypes, fixedArgCount");
  }

  // Parse function name
  if (!info[0].IsString()) {
    throw Napi::TypeError::New(env, "First argument (function name) must be "
                                    "a string");
  }
  std::string functionName = info[0].As<Napi::String>().Utf8Value();

  // Parse return type encoding
  if (!info[1].IsString()) {
    throw Napi::TypeError::New(
        env, "Second argument (return type) must be a string");
  }
  std::string returnType = info[1].As<Napi::String>().Utf8Value();

  // Parse argument type encodings
  if (!info[2].IsArray()) {
    throw Napi::TypeError::New(
        env, "Third argument (arg types) must be an array of strings");
  }
  Napi::Array argTypesArray = info[2].As<Napi::Array>();
  uint32_t argCount = argTypesArray.Length();

  std::vector<std::string> argTypes;
  argTypes.reserve(argCount);
  for (uint32_t i = 0; i < argCount; i++) {
    Napi::Value v = argTypesArray.Get(i);
    if (!v.IsString()) {
      throw Napi::TypeError::New(
          env,
          "Each element of argTypes must be a string (ObjC type encoding)");
    }
    argTypes.push_back(v.As<Napi::String>().Utf8Value());
  }

  // Parse fixed arg count
  if (!info[3].IsNumber()) {
    throw Napi::TypeError::New(
        env, "Fourth argument (fixedArgCount) must be a number");
  }
  int fixedArgCount = info[3].As<Napi::Number>().Int32Value();

  // Validate argument count
  uint32_t providedArgs = info.Length() - 4;
  if (providedArgs != argCount) {
    throw Napi::Error::New(
        env, "Expected " + std::to_string(argCount) +
                 " arguments but got " + std::to_string(providedArgs) +
                 " for function '" + functionName + "'");
  }

  NOBJC_LOG("CallFunction: Looking up '%s' (return=%s, %u args, %d fixed)",
            functionName.c_str(), returnType.c_str(), argCount,
            fixedArgCount);

  // Look up the function symbol
  void *funcPtr = dlsym(RTLD_DEFAULT, functionName.c_str());
  if (!funcPtr) {
    throw Napi::Error::New(
        env, "Function '" + functionName +
                 "' not found. Make sure the framework is loaded first. "
                 "dlsym error: " +
                 std::string(dlerror() ?: "unknown"));
  }

  NOBJC_LOG("CallFunction: Found '%s' at %p", functionName.c_str(), funcPtr);

  // Build FFI type arrays
  FFITypeGuard guard;

  // Return type
  size_t returnSize = 0;
  ffi_type *returnFFIType =
      GetFFITypeForEncoding(returnType.c_str(), &returnSize, guard);

  // Argument types
  std::vector<ffi_type *> argFFITypes;
  argFFITypes.reserve(argCount);
  for (uint32_t i = 0; i < argCount; i++) {
    ffi_type *argType =
        GetFFITypeForEncoding(argTypes[i].c_str(), nullptr, guard);
    argFFITypes.push_back(argType);
  }

  // Prepare the FFI CIF
  ffi_cif cif;
  ffi_status status;
  bool isVariadic =
      (fixedArgCount >= 0 && static_cast<uint32_t>(fixedArgCount) < argCount);

  if (isVariadic) {
    NOBJC_LOG("CallFunction: Using variadic CIF (%d fixed, %u total)",
              fixedArgCount, argCount);
    status = ffi_prep_cif_var(&cif, FFI_DEFAULT_ABI, fixedArgCount, argCount,
                              returnFFIType, argFFITypes.data());
  } else {
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, argCount, returnFFIType,
                          argFFITypes.data());
  }

  if (status != FFI_OK) {
    throw Napi::Error::New(env,
                           "Failed to prepare FFI call for function '" +
                               functionName + "' (ffi_prep_cif status: " +
                               std::to_string(status) + ")");
  }

  // Extract arguments from JS values
  std::vector<void *> argValues(argCount);
  std::vector<std::unique_ptr<uint8_t[]>> argBuffers;
  argBuffers.reserve(argCount);

  for (uint32_t i = 0; i < argCount; i++) {
    void *argPtr = nullptr;
    auto buffer = ExtractFunctionArgument(env, info[4 + i], argTypes[i],
                                          &argPtr, functionName, i, guard);
    argValues[i] = argPtr;
    argBuffers.push_back(std::move(buffer));
  }

  // Prepare return buffer
  std::unique_ptr<uint8_t[]> returnBuffer;
  const char *simplifiedReturn = SimplifyTypeEncoding(returnType.c_str());
  bool isVoidReturn = (*simplifiedReturn == 'v');

  if (!isVoidReturn) {
    size_t bufferSize =
        returnSize > 0 ? returnSize : nobjc::kMinReturnBufferSize;
    // Ensure minimum size for ffi_call (must be at least ffi_arg size)
    if (bufferSize < sizeof(ffi_arg)) {
      bufferSize = sizeof(ffi_arg);
    }
    returnBuffer = std::make_unique<uint8_t[]>(bufferSize);
    memset(returnBuffer.get(), 0, bufferSize);
  }

  // Make the FFI call
  NOBJC_LOG("CallFunction: Calling '%s' with %u args...",
            functionName.c_str(), argCount);
  ffi_call(&cif, FFI_FN(funcPtr), returnBuffer ? returnBuffer.get() : nullptr,
           argCount > 0 ? argValues.data() : nullptr);
  NOBJC_LOG("CallFunction: '%s' returned successfully", functionName.c_str());

  // Convert return value
  if (isVoidReturn) {
    return env.Undefined();
  }

  return ConvertFunctionReturnToJS(env, returnBuffer.get(), returnType);
}
