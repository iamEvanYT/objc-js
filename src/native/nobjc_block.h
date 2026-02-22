#ifndef NOBJC_BLOCK_H
#define NOBJC_BLOCK_H

/**
 * @file nobjc_block.h
 * @brief Objective-C Block support for nobjc.
 *
 * Enables transparent conversion of JavaScript functions to Objective-C blocks.
 * When a method expects a block parameter (@? type encoding) and a JS function
 * is provided, it is automatically wrapped in an ObjC block.
 *
 * Block ABI:
 *   A block is a struct with { isa, flags, reserved, invoke, descriptor }.
 *   We use _NSConcreteStackBlock as isa (then _Block_copy to move to heap).
 *   The invoke function pointer is an FFI closure that calls back into JS.
 *
 * Extended block type encoding format:
 *   @?<v@?q>  =>  return_type=v, block_self=@?, arg1=q
 *   @?<B@?@@>  =>  return_type=B, block_self=@?, arg1=@, arg2=@
 *
 * Memory management:
 *   BlockInfo structs (containing FFI closure, JS function ref, TSFN) are
 *   stored in a global registry and never freed (v1 simplification).
 *   The block itself is heap-copied via _Block_copy and stored as `id`
 *   in the ObjcType variant, so ARC manages the block pointer lifetime.
 *
 * Thread safety:
 *   Blocks may be called from background threads (e.g., completion handlers).
 *   We use TSFN + CFRunLoop pumping for cross-thread calls, same as protocol
 *   forwarding. Direct invocation is used when already on the JS thread.
 */

#include "debug.h"
#include "constants.h"
#include "forwarding-common.h"
#include "ObjcObject.h"
#include "type-conversion.h"
#include "struct-utils.h"
#include "ffi-utils.h"
#include <Foundation/Foundation.h>
#include <ffi.h>
#include <napi.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <malloc/malloc.h>
#include <mutex>
#include <condition_variable>
#include <vector>
#include <memory>
#include <string>

// MARK: - Block ABI Structures

// Block ABI descriptor (minimum viable — no copy/dispose helpers)
struct NobjcBlockDescriptor {
  unsigned long reserved;  // Always 0
  unsigned long size;      // sizeof(NobjcBlockLiteral)
};

// Block ABI literal struct
// This matches the runtime layout expected by objc_msgSend and _Block_copy.
struct NobjcBlockLiteral {
  void *isa;               // _NSConcreteStackBlock (before copy) or _NSConcreteMallocBlock (after)
  int flags;               // Block flags
  int reserved;            // Always 0
  void *invoke;            // Function pointer (FFI closure)
  NobjcBlockDescriptor *descriptor;
};

// _NSConcreteStackBlock is declared in <Block.h> (included via Foundation)
// as `extern void *_NSConcreteStackBlock[];`
// We use &_NSConcreteStackBlock[0] to get a void* for the isa field.

// MARK: - Block Signature Parsing

/**
 * Check if a type encoding represents a block type.
 * Block encodings start with @? (possibly preceded by type qualifiers).
 */
inline bool IsBlockTypeEncoding(const char *typeEncoding) {
  if (!typeEncoding) return false;
  const char *simplified = SimplifyTypeEncoding(typeEncoding);
  return simplified[0] == '@' && simplified[1] == '?';
}

/**
 * Parsed block signature: return type + parameter types.
 * The block self parameter (@?) is excluded from paramTypes.
 */
struct BlockSignature {
  std::string returnType;              // e.g., "v", "B", "@"
  std::vector<std::string> paramTypes; // e.g., ["@", "Q"] (excludes block self)
  bool valid;
};

// SkipOneBlockEncoding is replaced by the unified SkipOneTypeEncoding
// from type-conversion.h. Use SkipTypeQualifiers() when qualifiers need
// to be skipped before parsing.

/**
 * Parse a block's extended type encoding.
 *
 * Input: the full type encoding for the block parameter, e.g.:
 *   "@?<v@?q>"        → ret=v, params=[q]
 *   "@?<B@?@@>"       → ret=B, params=[@, @]
 *   "@?"              → no extended encoding available
 *
 * The format inside <...> is: returnType blockSelf(=@?) param1 param2 ...
 */
inline BlockSignature ParseBlockSignature(const char *encoding) {
  BlockSignature result;
  result.valid = false;

  if (!encoding) return result;

  const char *simplified = SimplifyTypeEncoding(encoding);

  // Must start with @?
  if (simplified[0] != '@' || simplified[1] != '?') return result;

  // Check for extended encoding
  if (simplified[2] != '<') {
    // No extended encoding — we can't determine the signature
    NOBJC_LOG("ParseBlockSignature: No extended encoding in '%s'", encoding);
    return result;
  }

  // Parse inside <...>
  const char *ptr = simplified + 3;  // Skip "@?<"

  // Find the closing '>'
  const char *end = ptr;
  int depth = 1;
  while (*end && depth > 0) {
    if (*end == '<') depth++;
    else if (*end == '>') depth--;
    end++;
  }
  // end now points past '>'

  // Create a null-terminated copy for safe parsing
  std::string inner(ptr, end - 1 - ptr);  // Exclude the closing '>'
  const char *innerPtr = inner.c_str();

  // First encoding: return type
  result.returnType = SkipOneTypeEncoding(innerPtr);

  // Second encoding: block self (@?) — skip it
  if (*innerPtr) {
    std::string blockSelf = SkipOneTypeEncoding(innerPtr);
    // Should be "@?" — we just skip it
    NOBJC_LOG("ParseBlockSignature: block self = '%s'", blockSelf.c_str());
  }

  // Remaining encodings: parameter types
  while (*innerPtr) {
    std::string paramType = SkipOneTypeEncoding(innerPtr);
    if (!paramType.empty()) {
      result.paramTypes.push_back(paramType);
    }
  }

  result.valid = true;
  NOBJC_LOG("ParseBlockSignature: ret='%s', %zu params",
            result.returnType.c_str(), result.paramTypes.size());

  return result;
}

// MARK: - Extended Block Encoding Extraction from Method Type

/**
 * Extract the type encoding for a specific argument index from a full method
 * type encoding string (as returned by method_getTypeEncoding()).
 *
 * The full method type has the format:
 *   returnType[offset] arg0Type[offset] arg1Type[offset] ...
 * where arg0 = self (@), arg1 = _cmd (:), arg2+ = user args.
 *
 * This is needed because [NSMethodSignature getArgumentTypeAtIndex:] strips
 * the extended block encoding (<...>), but method_getTypeEncoding() preserves it.
 *
 * @param methodTypeEncoding  Full type encoding from method_getTypeEncoding()
 * @param argIndex            0-based argument index (0 = self, 1 = _cmd, 2+ = user args)
 * @return The encoding for that argument, or empty string if not found.
 */
inline std::string ExtractArgEncodingFromMethodType(const char *methodTypeEncoding,
                                                     size_t argIndex) {
  if (!methodTypeEncoding) return "";

  const char *ptr = methodTypeEncoding;

  // Skip type qualifiers at start
  SkipTypeQualifiers(ptr);

  // First, skip the return type encoding
  SkipOneTypeEncoding(ptr);
  // Skip return type offset digits
  while (*ptr && isdigit(*ptr)) ptr++;

  // Now iterate through arguments 0, 1, ..., argIndex
  for (size_t i = 0; i <= argIndex; i++) {
    // Skip type qualifiers
    SkipTypeQualifiers(ptr);

    if (!*ptr) return "";

    if (i == argIndex) {
      // This is the argument we want — capture its encoding
      const char *start = ptr;
      SkipOneTypeEncoding(ptr);
      return std::string(start, ptr - start);
    }

    // Skip this argument's encoding
    SkipOneTypeEncoding(ptr);

    // Skip trailing offset digits
    while (*ptr && isdigit(*ptr)) ptr++;
  }

  return "";
}

/**
 * Get the extended block type encoding for a specific argument of a method.
 * Uses the ObjC runtime to get the full method type encoding which preserves
 * extended block encodings like @?<v@?q>.
 *
 * @param cls       The class that implements the method
 * @param selector  The selector of the method
 * @param argIndex  The NSInvocation-style argument index (0 = self, 1 = _cmd, 2+ = user args)
 * @return The extended encoding for that argument, or empty string if unavailable.
 */
inline std::string GetExtendedBlockEncoding(Class cls, SEL selector, size_t argIndex) {
  Method method = class_getInstanceMethod(cls, selector);
  if (!method) {
    // Try class method
    method = class_getClassMethod(cls, selector);
  }
  if (!method) return "";

  const char *fullType = method_getTypeEncoding(method);
  if (!fullType) return "";

  NOBJC_LOG("GetExtendedBlockEncoding: fullType='%s', argIndex=%zu", fullType, argIndex);

  std::string encoding = ExtractArgEncodingFromMethodType(fullType, argIndex);
  NOBJC_LOG("GetExtendedBlockEncoding: extracted='%s'", encoding.c_str());
  return encoding;
}

/**
 * BlockInfo holds all state for a single JS-function-backed block.
 * It owns the FFI closure, CIF, arg types, JS function reference, and TSFN.
 *
 * Stored in a global registry for lifetime management (never freed in v1).
 */
struct BlockInfo {
  // FFI closure and CIF
  ffi_closure *closure;
  ffi_cif cif;
  ffi_type *returnFFIType;
  std::vector<ffi_type *> argFFITypes;   // Includes block self (pointer) as arg[0]
  std::vector<ffi_type *> argFFIPtrs;    // Pointer array for ffi_prep_cif

  // Block signature
  BlockSignature signature;

  // Allocated FFI types (for struct types — cleaned up on destruction)
  FFITypeGuard ffiTypeGuard;

  // JS function reference (prevents GC)
  Napi::FunctionReference jsFunction;

  // Thread-safe function for cross-thread calls
  Napi::ThreadSafeFunction tsfn;

  // JS thread ID for thread detection
  pthread_t js_thread;

  // Napi environment
  napi_env env;

  // The block descriptor (must outlive the block)
  NobjcBlockDescriptor descriptor;

  // The block literal (stack block, before _Block_copy)
  NobjcBlockLiteral blockLiteral;

  // The heap-copied block (after _Block_copy)
  // Stored as void* since ARC is not enabled for .mm files in this project.
  // The block is never freed in v1 (stored in global registry).
  void *heapBlock;

  ~BlockInfo() {
    // Free the FFI closure
    if (closure) {
      ffi_closure_free(closure);
      closure = nullptr;
    }
    // Note: tsfn and jsFunction cleanup is tricky across threads.
    // In v1, BlockInfo is never destroyed, so this is moot.
  }
};

// MARK: - Block Call Data (transient, for cross-thread invocation)

/**
 * Data passed from the block invoke callback to the JS thread.
 * Holds argument values and synchronization primitives.
 */
struct BlockCallData {
  BlockInfo *blockInfo;                // Non-owning pointer to the BlockInfo
  std::vector<void *> argValues;       // Pointers to argument values (from FFI)
  void *returnValuePtr;                // Where to write the return value

  // Synchronization for cross-thread calls
  std::mutex completionMutex;
  std::condition_variable completionCv;
  bool isComplete;
};

// MARK: - Global Block Registry

/**
 * Global registry of all created blocks.
 * Blocks are never freed in v1 — this prevents crashes from async callbacks
 * referencing freed memory.
 */
static std::vector<std::unique_ptr<BlockInfo>> g_blockRegistry;
static std::mutex g_blockRegistryMutex;

// MARK: - Block Argument Conversion (ObjC → JS)

/**
 * Heuristic: try to determine if a pointer-sized value is an ObjC object.
 * Used when we don't have type encoding info (no extended block encoding).
 *
 * This takes the RAW value (not a pointer to it) — already dereferenced from
 * the FFI arg pointer.
 *
 * Strategy:
 * 1. Tagged pointers (arm64: high bit set) are always valid objects
 * 2. Use malloc_zone_from_ptr() to check if it's a heap allocation
 * 3. If it is, verify it has a valid class pointer
 */
inline bool LooksLikeObjCObject(uintptr_t val) {
  if (val == 0) return false;  // nil

  // Tagged pointer check (arm64: high bit set)
  if (val & (1ULL << 63)) return true;

  // Values below 4096 are definitely not objects — they're small integers
  // or null page addresses
  if (val < 4096) return false;

  // Check if this pointer was allocated via malloc (all ObjC heap objects are).
  // malloc_zone_from_ptr returns non-NULL only for valid heap allocations.
  void *ptr = (void *)val;
  malloc_zone_t *zone = malloc_zone_from_ptr(ptr);
  if (!zone) return false;

  // It's a heap allocation — very likely an ObjC object.
  // Do a final check: object_getClass should return a valid class.
  Class cls = object_getClass((__bridge id)ptr);
  return cls != nil;
}

/**
 * Convert a block argument to JS using heuristic type detection.
 * Used when no extended block encoding is available (@? without <...>).
 *
 * argPtr is a pointer TO the argument value (as provided by FFI).
 * The argument is pointer-sized.
 *
 * Strategy:
 * - If the value looks like an ObjC object, wrap it as ObjcObject
 * - Otherwise, interpret as a number (NSUInteger/NSInteger)
 */
inline Napi::Value ConvertBlockArgHeuristic(Napi::Env env, void *argPtr) {
  // Read the raw pointer-sized value
  uintptr_t value = *static_cast<uintptr_t *>(argPtr);

  // Zero could be nil (for objects) or 0 (for integers).
  // Return as number 0 — this works for NSUInteger and for nil objects
  // (the proxy layer handles numeric values correctly).
  if (value == 0) return Napi::Number::New(env, 0);

  if (LooksLikeObjCObject(value)) {
    id obj = (__bridge id)(void *)value;
    return ObjcObject::NewInstance(env, obj);
  }

  // Treat as unsigned integer
  return Napi::Number::New(env, static_cast<double>(value));
}

/**
 * Convert a single block argument from ObjC to JS.
 * Used inside the FFI callback when the block is invoked.
 */
inline Napi::Value ConvertBlockArgToJS(Napi::Env env, void *argPtr,
                                        const std::string &typeEncoding) {
  const char *simplified = SimplifyTypeEncoding(typeEncoding.c_str());
  char code = simplified[0];

  // Unknown type (inferred params) — use heuristic
  if (code == '?') {
    return ConvertBlockArgHeuristic(env, argPtr);
  }

  // Handle @? (block) args as opaque objects
  if (code == '@' && simplified[1] == '?') {
    id value = *(static_cast<id *>(argPtr));
    if (value == nil) return env.Null();
    return ObjcObject::NewInstance(env, value);
  }

  // Handle struct types
  if (code == '{') {
    return UnpackStructToJSValue(env, static_cast<const uint8_t *>(argPtr),
                                 simplified);
  }

  // Simple types
  return ObjCToJS(env, argPtr, code);
}

// MARK: - Block Return Value Conversion (JS → ObjC)

/**
 * Convert a JS return value to ObjC and write it to the return buffer.
 * Used inside the FFI callback after the JS function returns.
 */
inline void SetBlockReturnFromJS(Napi::Value result, void *returnPtr,
                                  const std::string &typeEncoding) {
  const char *simplified = SimplifyTypeEncoding(typeEncoding.c_str());
  char code = simplified[0];

  if (code == 'v') return;  // Void return — nothing to do

  if (result.IsNull() || result.IsUndefined()) {
    // For object types, set nil
    if (code == '@' || code == '#') {
      id nilVal = nil;
      memcpy(returnPtr, &nilVal, sizeof(id));
    }
    // For numeric types, leave as-is (zero-initialized by FFI)
    return;
  }

  switch (code) {
    case 'c': { char v = static_cast<char>(result.As<Napi::Number>().Int32Value()); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'i': { int v = result.As<Napi::Number>().Int32Value(); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 's': { short v = static_cast<short>(result.As<Napi::Number>().Int32Value()); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'l': { long v = static_cast<long>(result.As<Napi::Number>().Int64Value()); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'q': { long long v = result.As<Napi::Number>().Int64Value(); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'C': { unsigned char v = static_cast<unsigned char>(result.As<Napi::Number>().Uint32Value()); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'I': { unsigned int v = result.As<Napi::Number>().Uint32Value(); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'S': { unsigned short v = static_cast<unsigned short>(result.As<Napi::Number>().Uint32Value()); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'L': { unsigned long v = static_cast<unsigned long>(result.As<Napi::Number>().Int64Value()); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'Q': { unsigned long long v = static_cast<unsigned long long>(result.As<Napi::Number>().Int64Value()); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'f': { float v = static_cast<float>(result.As<Napi::Number>().DoubleValue()); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'd': { double v = result.As<Napi::Number>().DoubleValue(); memcpy(returnPtr, &v, sizeof(v)); break; }
    case 'B': {
      bool v = false;
      if (result.IsBoolean()) v = result.As<Napi::Boolean>().Value();
      else if (result.IsNumber()) v = result.As<Napi::Number>().Int32Value() != 0;
      memcpy(returnPtr, &v, sizeof(v));
      break;
    }
    case '@': case '#': {
      id objcVal = nil;
      if (result.IsObject()) {
        Napi::Object obj = result.As<Napi::Object>();
        if (obj.InstanceOf(ObjcObject::constructor.Value())) {
          ObjcObject *wrapper = Napi::ObjectWrap<ObjcObject>::Unwrap(obj);
          objcVal = wrapper->objcObject;
        }
      }
      memcpy(returnPtr, &objcVal, sizeof(id));
      break;
    }
    default:
      NOBJC_WARN("SetBlockReturnFromJS: Unsupported return type '%c'", code);
      break;
  }
}

// MARK: - TSFN Callback for Cross-Thread Block Invocation

/**
 * Called on the JS thread via ThreadSafeFunction when a block is invoked
 * from a background thread.
 */
inline void BlockTSFNCallback(Napi::Env env, Napi::Function /*jsCallback*/,
                               BlockCallData *callData) {
  if (!callData || !callData->blockInfo) {
    NOBJC_ERROR("BlockTSFNCallback: null callData or blockInfo");
    if (callData) {
      std::lock_guard<std::mutex> lock(callData->completionMutex);
      callData->isComplete = true;
      callData->completionCv.notify_one();
    }
    return;
  }

  BlockInfo *info = callData->blockInfo;

  @autoreleasepool {
    try {
      Napi::HandleScope scope(env);

      // Build JS arguments (skip arg[0] which is the block self)
      std::vector<napi_value> jsArgs;
      jsArgs.reserve(info->signature.paramTypes.size());

      for (size_t i = 0; i < info->signature.paramTypes.size(); i++) {
        // argValues[0] is block self, actual params start at index 1
        void *argPtr = callData->argValues[i + 1];
        Napi::Value jsVal = ConvertBlockArgToJS(env, argPtr,
                                                 info->signature.paramTypes[i]);
        jsArgs.push_back(jsVal);
      }

      // Call the JS function
      Napi::Value result = info->jsFunction.Value().Call(jsArgs);

      // Handle return value
      if (callData->returnValuePtr) {
        SetBlockReturnFromJS(result, callData->returnValuePtr,
                              info->signature.returnType);
      }
    } catch (const Napi::Error &e) {
      NOBJC_ERROR("BlockTSFNCallback: JS error: %s", e.what());
    } catch (const std::exception &e) {
      NOBJC_ERROR("BlockTSFNCallback: exception: %s", e.what());
    } catch (...) {
      NOBJC_ERROR("BlockTSFNCallback: unknown exception");
    }
  }

  // Signal completion
  {
    std::lock_guard<std::mutex> lock(callData->completionMutex);
    callData->isComplete = true;
    callData->completionCv.notify_one();
  }
}

// MARK: - FFI Closure Callback (Block Invoke)

/**
 * This is the function pointer stored in the block's `invoke` field.
 * Called by the ObjC runtime when the block is invoked.
 *
 * FFI closure signature: void(ffi_cif *, void *ret, void **args, void *userdata)
 *
 * args[0] = pointer to the block literal itself (block self)
 * args[1..n] = pointers to the actual block parameters
 */
inline void BlockInvokeCallback(ffi_cif *cif, void *ret, void **args,
                                  void *userdata) {
  BlockInfo *info = static_cast<BlockInfo *>(userdata);
  if (!info) {
    NOBJC_ERROR("BlockInvokeCallback: null userdata");
    return;
  }

  bool is_js_thread = pthread_equal(pthread_self(), info->js_thread);

  if (is_js_thread) {
    // Direct call on JS thread
    @autoreleasepool {
      try {
        Napi::Env env(info->env);
        Napi::HandleScope scope(env);

        // Build JS arguments (skip args[0] which is block self)
        std::vector<napi_value> jsArgs;
        jsArgs.reserve(info->signature.paramTypes.size());

        for (size_t i = 0; i < info->signature.paramTypes.size(); i++) {
          void *argPtr = args[i + 1];  // +1 to skip block self
          Napi::Value jsVal = ConvertBlockArgToJS(env, argPtr,
                                                    info->signature.paramTypes[i]);
          jsArgs.push_back(jsVal);
        }

        // Call the JS function
        Napi::Value result = info->jsFunction.Value().Call(jsArgs);

        // Handle return value
        if (ret && info->signature.returnType != "v") {
          SetBlockReturnFromJS(result, ret, info->signature.returnType);
        }
      } catch (const Napi::Error &e) {
        NOBJC_ERROR("BlockInvokeCallback: JS error: %s", e.what());
      } catch (const std::exception &e) {
        NOBJC_ERROR("BlockInvokeCallback: exception: %s", e.what());
      } catch (...) {
        NOBJC_ERROR("BlockInvokeCallback: unknown exception");
      }
    }
  } else {
    // Cross-thread call via TSFN
    BlockCallData callData;
    callData.blockInfo = info;
    callData.returnValuePtr = ret;
    callData.isComplete = false;

    // Copy arg pointers
    size_t totalArgs = info->signature.paramTypes.size() + 1;  // +1 for block self
    callData.argValues.resize(totalArgs);
    for (size_t i = 0; i < totalArgs; i++) {
      callData.argValues[i] = args[i];
    }

    // Acquire the TSFN
    napi_status acq_status = info->tsfn.Acquire();
    if (acq_status != napi_ok) {
      NOBJC_ERROR("BlockInvokeCallback: Failed to acquire TSFN");
      return;
    }

    // Call via TSFN
    napi_status status = info->tsfn.NonBlockingCall(&callData, BlockTSFNCallback);
    info->tsfn.Release();

    if (status != napi_ok) {
      NOBJC_ERROR("BlockInvokeCallback: TSFN call failed (status=%d)", status);
      return;
    }

    // Wait for completion by pumping CFRunLoop
    PumpRunLoopUntilComplete(callData.completionMutex, callData.isComplete);
  }
}

// MARK: - Block Creation

/**
 * Create an Objective-C block from a JavaScript function.
 *
 * @param env         Napi environment
 * @param jsFunction  The JS function to wrap
 * @param typeEncoding The full type encoding for the block parameter (e.g., "@?<v@?q>")
 * @return The heap-copied block as an `id`, or nil on failure.
 *
 * The returned block is heap-allocated via _Block_copy and managed by ARC
 * when stored in the ObjcType variant as `id`.
 */
inline id CreateBlockFromJSFunction(Napi::Env env,
                                     const Napi::Value &jsFunction,
                                     const char *typeEncoding) {
  NOBJC_LOG("CreateBlockFromJSFunction: encoding='%s'", typeEncoding);

  // Parse the block signature
  BlockSignature sig = ParseBlockSignature(typeEncoding);
  if (!sig.valid) {
    // No extended encoding — infer from JS function's .length
    // All params are treated as pointer-sized (heuristic detection in callback)
    Napi::Function fn = jsFunction.As<Napi::Function>();
    uint32_t jsParamCount = fn.Get("length").As<Napi::Number>().Uint32Value();

    NOBJC_LOG("CreateBlockFromJSFunction: No extended block encoding, "
              "inferring %u params from JS function.length. Encoding: '%s'",
              jsParamCount, typeEncoding);

    sig.returnType = "v";  // Assume void return
    sig.paramTypes.clear();
    for (uint32_t i = 0; i < jsParamCount; i++) {
      sig.paramTypes.push_back("?");  // Unknown type — use heuristic in callback
    }
    sig.valid = true;
  }

  // Create BlockInfo
  auto blockInfo = std::make_unique<BlockInfo>();
  blockInfo->signature = sig;
  blockInfo->env = env;
  blockInfo->js_thread = pthread_self();
  blockInfo->closure = nullptr;
  blockInfo->heapBlock = nullptr;

  // Store JS function reference
  blockInfo->jsFunction = Napi::Persistent(jsFunction.As<Napi::Function>());

  // Create TSFN for cross-thread calls
  blockInfo->tsfn = CreateMethodTSFN(env, jsFunction.As<Napi::Function>(),
                                     "nobjc_block_tsfn");

  // Build FFI types for the block invocation
  // Block invoke signature: returnType (blockSelf, param1, param2, ...)
  // blockSelf is always a pointer (the block literal)

  // Return type
  blockInfo->returnFFIType = GetFFITypeForSimpleEncoding(
      SimplifyTypeEncoding(sig.returnType.c_str())[0]);

  // Arg types: [blockSelf(ptr), param1, param2, ...]
  blockInfo->argFFITypes.push_back(&ffi_type_pointer);  // block self
  for (const auto &paramType : sig.paramTypes) {
    const char *simplified = SimplifyTypeEncoding(paramType.c_str());
    ffi_type *ffiType;
    if (simplified[0] == '?') {
      // Unknown type (inferred from JS function.length) — treat as pointer
      ffiType = &ffi_type_pointer;
    } else if (simplified[0] == '{') {
      // Struct type — need full parsing
      size_t structSize = 0;
      ffiType = GetFFITypeForEncoding(simplified, &structSize, blockInfo->ffiTypeGuard);
    } else {
      ffiType = GetFFITypeForSimpleEncoding(simplified[0]);
    }
    blockInfo->argFFITypes.push_back(ffiType);
  }

  // Build pointer array for ffi_prep_cif
  blockInfo->argFFIPtrs.resize(blockInfo->argFFITypes.size());
  for (size_t i = 0; i < blockInfo->argFFITypes.size(); i++) {
    blockInfo->argFFIPtrs[i] = blockInfo->argFFITypes[i];
  }

  // Allocate FFI closure
  void *codePtr = nullptr;
  blockInfo->closure = static_cast<ffi_closure *>(
      ffi_closure_alloc(sizeof(ffi_closure), &codePtr));

  if (!blockInfo->closure || !codePtr) {
    Napi::Error::New(env, "Failed to allocate FFI closure for block")
        .ThrowAsJavaScriptException();
    return nil;
  }

  // Prepare the CIF
  ffi_status ffiStatus = ffi_prep_cif(
      &blockInfo->cif,
      FFI_DEFAULT_ABI,
      static_cast<unsigned int>(blockInfo->argFFIPtrs.size()),
      blockInfo->returnFFIType,
      blockInfo->argFFIPtrs.data());

  if (ffiStatus != FFI_OK) {
    ffi_closure_free(blockInfo->closure);
    blockInfo->closure = nullptr;
    Napi::Error::New(env, "ffi_prep_cif failed for block")
        .ThrowAsJavaScriptException();
    return nil;
  }

  // Prepare the closure
  ffiStatus = ffi_prep_closure_loc(
      blockInfo->closure,
      &blockInfo->cif,
      BlockInvokeCallback,
      blockInfo.get(),  // userdata = BlockInfo*
      codePtr);

  if (ffiStatus != FFI_OK) {
    ffi_closure_free(blockInfo->closure);
    blockInfo->closure = nullptr;
    Napi::Error::New(env, "ffi_prep_closure_loc failed for block")
        .ThrowAsJavaScriptException();
    return nil;
  }

  // Build the block literal (stack block)
  blockInfo->descriptor.reserved = 0;
  blockInfo->descriptor.size = sizeof(NobjcBlockLiteral);

  blockInfo->blockLiteral.isa = _NSConcreteStackBlock;
  blockInfo->blockLiteral.flags = 0;  // No flags — we don't provide copy/dispose helpers or a signature field in the descriptor
  blockInfo->blockLiteral.reserved = 0;
  blockInfo->blockLiteral.invoke = codePtr;
  blockInfo->blockLiteral.descriptor = &blockInfo->descriptor;

  // Copy to heap via _Block_copy
  void *heapBlockPtr = _Block_copy(&blockInfo->blockLiteral);
  if (!heapBlockPtr) {
    Napi::Error::New(env, "_Block_copy failed")
        .ThrowAsJavaScriptException();
    return nil;
  }

  // Store the heap block pointer (no ARC — manual retain from _Block_copy)
  blockInfo->heapBlock = heapBlockPtr;

  id result = (id)blockInfo->heapBlock;

  // Store in global registry (never freed in v1)
  {
    std::lock_guard<std::mutex> lock(g_blockRegistryMutex);
    g_blockRegistry.push_back(std::move(blockInfo));
  }

  NOBJC_LOG("CreateBlockFromJSFunction: created block %p", result);
  return result;
}

#endif // NOBJC_BLOCK_H
