# Block Support Design Document

## Overview

This document describes the design and implementation of Objective-C block support in objc-js. Blocks (closures) are a fundamental part of modern Objective-C APIs, used for enumeration, completion handlers, sorting, filtering, and more.

The implementation automatically converts JavaScript functions to Objective-C blocks when a method parameter has the `@?` type encoding.

---

## 1. Block ABI

Objective-C blocks follow a well-defined ABI. A block literal on the stack has this layout:

```c
struct BlockLiteral {
    void *isa;           // Points to _NSConcreteStackBlock (or _NSConcreteMallocBlock after copy)
    int flags;           // Block flags (BLOCK_HAS_COPY_DISPOSE, BLOCK_HAS_SIGNATURE, etc.)
    int reserved;        // Reserved, usually 0
    void *invoke;        // Function pointer: the block's implementation
    void *descriptor;    // Points to BlockDescriptor
};

struct BlockDescriptor {
    unsigned long reserved;  // 0
    unsigned long size;      // sizeof(BlockLiteral)
};
```

Key constants:

- `BLOCK_HAS_COPY_DISPOSE = (1 << 25)` -- block has copy/dispose helpers
- `BLOCK_HAS_SIGNATURE = (1 << 30)` -- block has a type signature

We use `_NSConcreteStackBlock` (from `<Block.h>`) as the `isa` pointer, then call `_Block_copy()` to move the block to the heap for safe retention by Objective-C code.

### Important: \_NSConcreteStackBlock Declaration

The macOS SDK declares `_NSConcreteStackBlock` as `void *[32]` (not `void *`). We must NOT redeclare it -- just `#include <Block.h>` and use `&_NSConcreteStackBlock` as a `void *`.

---

## 2. Type Encoding

### Method-Level Encoding

In a method's type encoding, a block parameter is encoded as `@?`:

```
v24@0:8@?16    -- void method with one block parameter
```

### Extended Block Encoding (Compile-Time Only)

At compile time, blocks can have extended encodings with their full signature:

```
@?<v@?q>       -- block taking (NSInteger) returning void
@?<v@?@Q^B>    -- block taking (id, NSUInteger, BOOL*) returning void
```

Format: `@?<returnType @? param1 param2...>` where the `@?` after the return type is the block's self parameter (always present, always skipped).

### Runtime Limitation

**Extended block encodings are NOT available at runtime.** Both `method_getTypeEncoding()` and `[NSMethodSignature getArgumentTypeAtIndex:]` return only `@?` without the `<...>` extended encoding. This is a fundamental limitation.

**Solution:** Infer the block parameter count from the JavaScript function's `.length` property, and use heuristic type detection at invocation time.

---

## 3. Architecture

### 3.1 Detection Flow

```
JS calls method with function arg
  → $MsgSend / $MsgSendPrepared
    → Check arg type encoding for @?
      → If @? and arg is JS function:
        → CreateBlockFromJSFunction()
        → Pass block pointer to NSInvocation
```

Block detection happens BEFORE `AsObjCArgument()` is called, similar to how struct arguments are intercepted.

### 3.2 Fast Path Bypass

The fast path (`TryFastMsgSend`) checks the first character of each arg's type encoding. Since `@?` starts with `@`, it would match the object case and try to pass the JS function as an ObjC object (crash). The fix: when `code == '@'` and `argType[1] == '?'`, bail out of the fast path.

### 3.3 Key Data Structures

```cpp
// Parsed block signature
struct BlockSignature {
    std::string returnType;              // "v" for void
    std::vector<std::string> paramTypes; // e.g., ["@", "Q", "^B"]
};

// Info about a created block -- stored in global registry
struct BlockInfo {
    Napi::FunctionReference jsFunction;  // prevents GC of JS function
    napi_env env;
    pthread_t js_thread;
    BlockSignature signature;
    ffi_closure *closure;
    ffi_cif cif;
    ffi_type *returnFFIType;
    ffi_type **argFFITypes;
    ffi_type *argFFITypeStorage;
};

// Data passed between threads for async block invocations
struct BlockCallData {
    BlockInfo *info;
    std::vector<std::vector<uint8_t>> argBuffers; // copied arg data
    bool completed;
    std::mutex mutex;
    std::condition_variable cv;
};
```

### 3.4 Global Registry

```cpp
static std::vector<std::unique_ptr<BlockInfo>> g_blockRegistry;
static std::mutex g_blockMutex;
```

Block info structs are stored here and never freed (v1 design). This prevents use-after-free for async callbacks where the block might be invoked after the creating scope exits.

---

## 4. Block Creation (`CreateBlockFromJSFunction`)

1. Parse the block signature (if extended encoding available) or infer from JS function `.length`
2. Build FFI type arrays: return type + block self pointer + parameter types
3. Allocate and prepare an `ffi_closure` via `ffi_closure_alloc()`
4. Call `ffi_prep_closure_loc()` to bind the closure to `BlockInvokeCallback`
5. Build a `BlockLiteral` on the stack with `isa = &_NSConcreteStackBlock` and `invoke = closureCodePtr`
6. Call `_Block_copy()` to move the block to the heap
7. Store the `BlockInfo` in `g_blockRegistry`
8. Return the heap block as `void *`

---

## 5. Block Invocation (`BlockInvokeCallback`)

When Objective-C invokes the block, the FFI closure calls `BlockInvokeCallback`:

1. Retrieve `BlockInfo *` from the `userdata` pointer
2. Check if we're on the JS thread via `pthread_equal()`
3. **If on JS thread (synchronous):**
   - Convert each block arg to a JS value (skip `args[0]` which is block self)
   - Call the JS function directly
   - Convert the return value back to ObjC if non-void
4. **If on a background thread (async):**
   - Copy arg data into `BlockCallData` buffers
   - Call the TSFN (ThreadSafeFunction) to schedule on the JS thread
   - Pump the CFRunLoop while waiting for completion (same pattern as protocol forwarding)

---

## 6. Heuristic Type Detection

Without extended block encodings at runtime, we use `ConvertBlockArgHeuristic()` to determine argument types:

```cpp
inline Napi::Value ConvertBlockArgHeuristic(Napi::Env env, void *argPtr) {
    void *value = *(void **)argPtr;

    if (!value) return Napi::Number::New(env, 0);   // zero/nil

    uintptr_t ptrVal = (uintptr_t)value;

    // Tagged pointer check (arm64): high bit set = ObjC object
    if (ptrVal & (1ULL << 63)) {
        return ObjcObject::NewInstance(env, (id)value);
    }

    // Heap allocation check: malloc_zone_from_ptr returns non-null for heap objects
    if (malloc_zone_from_ptr(value)) {
        return ObjcObject::NewInstance(env, (id)value);
    }

    // Default: treat as integer
    return Napi::Number::New(env, (double)ptrVal);
}
```

This correctly identifies:

- **ObjC objects**: Heap-allocated (detected by `malloc_zone_from_ptr`) or tagged pointers (arm64 high bit)
- **NSUInteger/NSInteger**: Small integer values (not heap pointers)
- **BOOL \* (stop parameter)**: Stack pointers (not in any malloc zone)
- **nil/0**: Zero value (returned as number 0, works for both nil and integer 0)

---

## 7. Proxy Wrapping

ObjcObject instances created via `ObjcObject::NewInstance` in native code are raw N-API objects without the TypeScript Proxy wrapper that provides method call syntax (`obj.methodName$()`).

To fix this, `unwrapArg()` in `index.ts` wraps function arguments:

```typescript
if (typeof arg === "function") {
  const origFn = arg;
  const wrapped = function (...innerArgs: any[]) {
    const wrappedInnerArgs = innerArgs.map((a) => wrapObjCObjectIfNeeded(a));
    const result = origFn.apply(this, wrappedInnerArgs);
    return unwrapArg(result);
  };
  Object.defineProperty(wrapped, "length", { value: origFn.length });
  return wrapped;
}
```

This ensures:

- Block callback arguments are wrapped with the Proxy (so `obj.intValue()` works)
- The function's `.length` is preserved (used for parameter count inference)
- Return values are unwrapped back to raw ObjC objects

---

## 8. Threading

The implementation uses the same threading pattern as protocol/subclass forwarding:

- **JS thread**: Direct invocation via `Napi::HandleScope` + `jsFunction.Call()`
- **Background thread**: TSFN callback + CFRunLoop pumping for synchronous semantics
- Thread detection via `pthread_equal(pthread_self(), info->js_thread)`

---

## 9. Memory Management

### ARC Status

Despite `-fobjc-arc` being in `binding.gyp`, it's only in `OTHER_CFLAGS` (C files), not `OTHER_CPLUSPLUSFLAGS`. The `.mm` files compile **without ARC**. This means:

- `__bridge` casts are no-ops
- No automatic retain/release
- Block memory is managed manually

### Current Strategy (v1)

- `_Block_copy()` moves blocks to the heap -- they are never freed
- `BlockInfo` structs are stored in `g_blockRegistry` and never freed
- `FunctionReference` prevents the JS function from being garbage collected
- This is acceptable for typical usage (hundreds of blocks, not millions)

### Future Improvement

Add reference counting or weak reference tracking to free blocks when they're no longer needed by Objective-C.

---

## 10. Files

### Created

- `src/native/nobjc_block.h` -- Block ABI, creation, invocation, heuristic detection (~885 lines)
- `tests/test-blocks.test.ts` -- Block support tests (5 tests)
- `docs/blocks.md` -- User-facing documentation

### Modified

- `src/native/ObjcObject.mm` -- Block detection in fast path, slow path, and prepared sends
- `src/native/type-conversion.h` -- `SkipOneFieldEncoding()` fix for `@?` and `@?<...>`
- `src/native/ffi-utils.h` -- `@?` handling in `GetFFITypeForEncoding()`
- `src/ts/index.ts` -- `unwrapArg()` function wrapping for proxy support

---

## 11. Testing

Five tests verify block support:

1. **NSArray enumeration** -- `enumerateObjectsUsingBlock:` with 3 elements, verifies values and indices
2. **NSDictionary enumeration** -- `enumerateKeysAndObjectsUsingBlock:` with single entry
3. **Empty array** -- Block should not be called
4. **Multiple dictionary entries** -- 3 entries, verifies all keys and values
5. **String objects** -- Single element array with NSString, verifies UTF8String extraction

All tests pass in both Bun and Node.js.

---

## 12. Known Limitations

1. **No `stop` parameter support**: Cannot set `*stop = YES` to stop enumeration early
2. **Heuristic type detection**: Large integers could theoretically be misidentified as heap pointers
3. **Memory leak (by design)**: Blocks and their info structs are never freed
4. **No non-void return heuristic path**: When using heuristic detection (no extended encoding), return type is assumed void
5. **Zero value ambiguity**: `0` could be `nil` (object) or `0` (integer) -- returned as JS number, which works for both
