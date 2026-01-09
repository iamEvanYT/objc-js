#pragma once

// ============================================================================
// super-call-helpers.h - Helper Functions for CallSuper Implementation
// ============================================================================
//
// These functions break up the large CallSuperWithFFI function into
// smaller, focused units for better maintainability and readability.
//

#include "constants.h"
#include "debug.h"
#include "ffi-utils.h"
#include "type-conversion.h"
#include <Foundation/Foundation.h>
#include <memory>
#include <napi.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string>
#include <vector>

// MARK: - FFI Argument Context

/// Context structure for building FFI arguments
struct FFIArgumentContext {
  std::vector<ffi_type*> argFFITypes;
  std::vector<void*> argValues;
  std::vector<std::unique_ptr<uint8_t[]>> argBuffers;
  std::vector<ffi_type*> allocatedTypes;
};

// MARK: - PrepareFFIArgumentTypes

/// Build FFI type arrays for the method arguments.
/// Returns the FFI return type and populates ctx.argFFITypes.
inline ffi_type* PrepareFFIArgumentTypes(
    NSMethodSignature* methodSig,
    const char* returnEncoding,
    size_t* outReturnSize,
    FFIArgumentContext& ctx) {
  
  size_t totalArgs = [methodSig numberOfArguments];
  
  // First arg: objc_super pointer
  ctx.argFFITypes.push_back(&ffi_type_pointer);
  // Second arg: SEL
  ctx.argFFITypes.push_back(&ffi_type_pointer);
  
  // Remaining args: method arguments (starting from index 2)
  for (size_t i = 2; i < totalArgs; i++) {
    const char* argEncoding = [methodSig getArgumentTypeAtIndex:i];
    ffi_type* argType = GetFFITypeForEncoding(argEncoding, nullptr, ctx.allocatedTypes);
    ctx.argFFITypes.push_back(argType);
    NOBJC_LOG("PrepareFFIArgumentTypes: Arg %zu type encoding: %s", i - 2, argEncoding);
  }
  
  // Build return FFI type
  ffi_type* returnFFIType = GetFFITypeForEncoding(returnEncoding, outReturnSize, ctx.allocatedTypes);
  NOBJC_LOG("PrepareFFIArgumentTypes: Return type encoding: %s, size: %zu",
            returnEncoding, *outReturnSize);
  
  return returnFFIType;
}

// MARK: - AddFixedFFIArguments

/// Add the fixed arguments (objc_super* and SEL) to the argument buffers.
inline void AddFixedFFIArguments(
    struct objc_super* superPtr,
    SEL selector,
    FFIArgumentContext& ctx) {
  
  // Add objc_super pointer
  // libffi expects argValues[i] to point to the actual argument value
  auto superPtrBuffer = std::make_unique<uint8_t[]>(sizeof(objc_super*));
  memcpy(superPtrBuffer.get(), &superPtr, sizeof(objc_super*));
  void* superPtrBufferRawPtr = superPtrBuffer.get();
  ctx.argBuffers.push_back(std::move(superPtrBuffer));
  ctx.argValues.push_back(superPtrBufferRawPtr);
  NOBJC_LOG("AddFixedFFIArguments: Added objc_super* buffer at %p (points to %p)", 
            superPtrBufferRawPtr, superPtr);
  
  // Add selector
  auto selectorBuffer = std::make_unique<uint8_t[]>(sizeof(SEL));
  memcpy(selectorBuffer.get(), &selector, sizeof(SEL));
  void* selectorBufferRawPtr = selectorBuffer.get();
  ctx.argBuffers.push_back(std::move(selectorBuffer));
  ctx.argValues.push_back(selectorBufferRawPtr);
  NOBJC_LOG("AddFixedFFIArguments: Added SEL buffer at %p (value=%p, name=%s)", 
            selectorBufferRawPtr, selector, sel_getName(selector));
}

// MARK: - ExtractOutParamArgument

/// Handle out-param arguments (e.g., NSError**).
/// Returns true if this was an out-param that was handled.
inline bool ExtractOutParamArgument(
    const SimplifiedTypeEncoding& simpleArgEncoding,
    size_t argIndex,
    FFIArgumentContext& ctx) {
  
  if (simpleArgEncoding[0] != '^' || simpleArgEncoding[1] != '@') {
    return false;
  }
  
  NOBJC_LOG("ExtractOutParamArgument: Arg %zu is out-param (^@)", argIndex);
  
  // Buffer 1: Storage for the id* (initialized to nil)
  auto errorStorage = std::make_unique<uint8_t[]>(sizeof(id));
  id nullObj = nil;
  memcpy(errorStorage.get(), &nullObj, sizeof(id));
  void* errorStoragePtr = errorStorage.get();
  
  NOBJC_LOG("ExtractOutParamArgument: Allocated error storage at %p", errorStoragePtr);
  
  // Buffer 2: Storage for the pointer to errorStorage
  auto pointerBuffer = std::make_unique<uint8_t[]>(sizeof(void*));
  memcpy(pointerBuffer.get(), &errorStoragePtr, sizeof(void*));
  void* pointerBufferPtr = pointerBuffer.get();
  
  NOBJC_LOG("ExtractOutParamArgument: Allocated pointer buffer at %p", pointerBufferPtr);
  
  ctx.argValues.push_back(pointerBufferPtr);
  ctx.argBuffers.push_back(std::move(errorStorage));
  ctx.argBuffers.push_back(std::move(pointerBuffer));
  
  return true;
}

// MARK: - ExtractRegularArgument

/// Extract a regular (non-out-param) argument from JS to buffer.
inline void ExtractRegularArgument(
    Napi::Env env,
    Napi::Value jsValue,
    const char* argEncoding,
    const SimplifiedTypeEncoding& simpleArgEncoding,
    const std::string& className,
    const std::string& selectorName,
    size_t argIndex,
    FFIArgumentContext& ctx) {
  
  // Calculate size for this argument
  size_t argSize = GetSizeForTypeEncoding(simpleArgEncoding[0]);
  if (argSize == 0) {
    // For complex types, use NSGetSizeAndAlignment
    NSUInteger size, alignment;
    NSGetSizeAndAlignment(argEncoding, &size, &alignment);
    argSize = size;
    NOBJC_LOG("ExtractRegularArgument: Complex type, size: %zu", argSize);
  }
  
  // Allocate buffer
  NOBJC_LOG("ExtractRegularArgument: Allocating buffer of %zu bytes for arg %zu", 
            argSize, argIndex);
  auto buffer = std::make_unique<uint8_t[]>(argSize);
  memset(buffer.get(), 0, argSize);
  void* bufferPtr = buffer.get();
  
  // Extract JS argument to buffer
  ObjcArgumentContext context = {
      .className = className,
      .selectorName = selectorName,
      .argumentIndex = (int)argIndex,
  };
  
  ExtractJSArgumentToBuffer(env, jsValue, argEncoding, bufferPtr, context);
  NOBJC_LOG("ExtractRegularArgument: Extracted argument %zu (size: %zu)", argIndex, argSize);
  
  // For object types, log the actual pointer value
  if (simpleArgEncoding[0] == '@') {
    [[maybe_unused]] id* objPtr = (id*)bufferPtr;
    NOBJC_LOG("ExtractRegularArgument: Argument %zu is object: buffer=%p, contains id=%p", 
              argIndex, bufferPtr, *objPtr);
  }
  
  ctx.argValues.push_back(bufferPtr);
  ctx.argBuffers.push_back(std::move(buffer));
}

// MARK: - ExtractMethodArguments

/// Extract all method arguments from JS values.
inline void ExtractMethodArguments(
    Napi::Env env,
    const Napi::CallbackInfo& info,
    size_t argStartIndex,
    NSMethodSignature* methodSig,
    Class superClass,
    const std::string& selectorName,
    FFIArgumentContext& ctx) {
  
  NOBJC_LOG("ExtractMethodArguments: Processing %zu method arguments...", 
            info.Length() - argStartIndex);
  
  std::string className = class_getName(superClass);
  
  for (size_t i = argStartIndex; i < info.Length(); i++) {
    size_t argIndex = i - argStartIndex + 2; // +2 for self and _cmd
    const char* argEncoding = [methodSig getArgumentTypeAtIndex:argIndex];
    SimplifiedTypeEncoding simpleArgEncoding(argEncoding);
    
    NOBJC_LOG("ExtractMethodArguments: Processing JS arg %zu (method arg %zu), encoding=%s",
              i - argStartIndex, argIndex, argEncoding);
    
    // Try out-param first
    if (ExtractOutParamArgument(simpleArgEncoding, i - argStartIndex, ctx)) {
      continue;
    }
    
    // Regular argument
    ExtractRegularArgument(env, info[i], argEncoding, simpleArgEncoding,
                           className, selectorName, i - argStartIndex, ctx);
  }
  
  NOBJC_LOG("ExtractMethodArguments: Finished preparing %zu argument buffers", 
            ctx.argBuffers.size());
}

// MARK: - LogFFICallSetup

/// Log the FFI call setup for debugging.
inline void LogFFICallSetup(
    [[maybe_unused]] void* msgSendFn,
    [[maybe_unused]] const std::vector<void*>& argValues,
    [[maybe_unused]] const struct objc_super& superStruct,
    [[maybe_unused]] Class superClass,
    [[maybe_unused]] NSMethodSignature* methodSig) {
  
  NOBJC_LOG("LogFFICallSetup: ========== FFI CALL SETUP ==========");
  NOBJC_LOG("LogFFICallSetup: Function to call: objc_msgSendSuper at %p", msgSendFn);
  NOBJC_LOG("LogFFICallSetup: Number of arguments: %zu", argValues.size());
  
  if (argValues.size() > 0) {
    NOBJC_LOG("LogFFICallSetup: Arg 0 (objc_super*): argValues[0]=%p", argValues[0]);
    [[maybe_unused]] objc_super** superPtrPtr = (objc_super**)argValues[0];
    NOBJC_LOG("LogFFICallSetup:   Buffer contains pointer: %p", *superPtrPtr);
    NOBJC_LOG("LogFFICallSetup:   objc_super.receiver=%p", superStruct.receiver);
    NOBJC_LOG("LogFFICallSetup:   objc_super.super_class=%p (%s)", 
              superStruct.super_class, class_getName(superClass));
  }
  
  if (argValues.size() > 1) {
    NOBJC_LOG("LogFFICallSetup: Arg 1 (SEL*): argValues[1]=%p", argValues[1]);
    [[maybe_unused]] SEL* selPtr = (SEL*)argValues[1];
    NOBJC_LOG("LogFFICallSetup:   Buffer contains SEL: %p (%s)", 
              *selPtr, sel_getName(*selPtr));
  }
  
  for (size_t i = 2; i < argValues.size(); i++) {
    const char* argEncoding = [methodSig getArgumentTypeAtIndex:i];
    SimplifiedTypeEncoding simpleArgEncoding(argEncoding);
    NOBJC_LOG("LogFFICallSetup: Arg %zu: argValues[%zu]=%p, encoding=%s",
              i, i, argValues[i], simpleArgEncoding.c_str());
    if (simpleArgEncoding[0] == '@') {
      [[maybe_unused]] id* objPtrLocation = (id*)argValues[i];
      NOBJC_LOG("LogFFICallSetup:   Object pointer at %p points to id=%p",
                objPtrLocation, *objPtrLocation);
    } else if (simpleArgEncoding[0] == '^') {
      [[maybe_unused]] void** ptrLocation = (void**)argValues[i];
      NOBJC_LOG("LogFFICallSetup:   Pointer at %p contains: %p",
                ptrLocation, *ptrLocation);
    }
  }
}

// MARK: - ExecuteFFICallAndConvert

/// Execute the FFI call and convert the return value to JS.
inline Napi::Value ExecuteFFICallAndConvert(
    Napi::Env env,
    ffi_cif* cif,
    void* msgSendFn,
    FFIArgumentContext& ctx,
    const char* returnEncoding,
    size_t returnSize) {
  
  // Prepare return buffer
  std::unique_ptr<uint8_t[]> returnBuffer;
  if (returnEncoding[0] != 'v') {
    size_t bufferSize = returnSize > 0 ? returnSize : nobjc::kMinReturnBufferSize;
    returnBuffer = std::make_unique<uint8_t[]>(bufferSize);
    memset(returnBuffer.get(), 0, bufferSize);
    NOBJC_LOG("ExecuteFFICallAndConvert: Allocated return buffer of %zu bytes at %p", 
              bufferSize, returnBuffer.get());
  } else {
    NOBJC_LOG("ExecuteFFICallAndConvert: No return buffer needed (void return)");
  }
  
  // Make the FFI call
  NOBJC_LOG("ExecuteFFICallAndConvert: About to call ffi_call...");
  ffi_call(cif, FFI_FN(msgSendFn), 
           returnBuffer ? returnBuffer.get() : nullptr, 
           ctx.argValues.data());
  NOBJC_LOG("ExecuteFFICallAndConvert: ffi_call completed successfully!");
  
  // Convert return value
  Napi::Value result;
  if (returnEncoding[0] == 'v') {
    result = env.Undefined();
  } else {
    result = ConvertFFIReturnToJS(env, returnBuffer.get(), returnEncoding);
  }
  
  NOBJC_LOG("ExecuteFFICallAndConvert: Returning result");
  return result;
}

// MARK: - ValidateSuperMethod

/// Validate that the method exists on the superclass.
/// Returns the method signature on success, throws on failure.
inline NSMethodSignature* ValidateSuperMethod(
    Napi::Env env,
    Class superClass,
    SEL selector,
    const std::string& selectorName,
    size_t providedArgCount) {
  
  // Get method signature from superclass
  NSMethodSignature* methodSig = [superClass instanceMethodSignatureForSelector:selector];
  if (methodSig == nil) {
    NOBJC_ERROR("ValidateSuperMethod: Selector '%s' not found on superclass %s", 
                selectorName.c_str(), class_getName(superClass));
    throw Napi::Error::New(
        env, "Selector '" + selectorName + "' not found on superclass");
  }
  
  NOBJC_LOG("ValidateSuperMethod: Method signature: %s", [methodSig description].UTF8String);
  
  // Get the super method's IMP directly
  Method superMethod = class_getInstanceMethod(superClass, selector);
  if (superMethod == nil) {
    NOBJC_ERROR("ValidateSuperMethod: Could not get method implementation for selector '%s'", 
                selectorName.c_str());
    throw Napi::Error::New(
        env, "Could not get method implementation for selector '" + selectorName +
                 "' from superclass");
  }
  
  NOBJC_LOG("ValidateSuperMethod: Found method implementation at %p", 
            method_getImplementation(superMethod));
  
  // Validate argument count
  const size_t expectedArgCount = [methodSig numberOfArguments] - 2;
  
  NOBJC_LOG("ValidateSuperMethod: Expected %zu args, provided %zu args", 
            expectedArgCount, providedArgCount);
  
  if (providedArgCount != expectedArgCount) {
    NOBJC_ERROR("ValidateSuperMethod: Argument count mismatch for selector '%s'", 
                selectorName.c_str());
    throw Napi::Error::New(
        env, "Selector " + selectorName + " expected " +
                 std::to_string(expectedArgCount) + " argument(s), but got " +
                 std::to_string(providedArgCount));
  }
  
  return methodSig;
}
