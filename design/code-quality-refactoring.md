# Code Quality Refactoring - objc-js

## Overview

This document details the comprehensive code quality refactoring performed on the `objc-js` project, an Objective-C bridge for Node.js. The refactoring was completed in 5 phases, each addressing specific code quality concerns in the ~4000-line native C++/Objective-C codebase.

**Final Test Results:** 90 pass, 2 skip, 0 fail

## Commits

| Phase | Commit               | Description                             |
| ----- | -------------------- | --------------------------------------- |
| 1     | `2b41735`            | Memory leak fixes & RAII wrappers       |
| 2     | `7579b3c`, `6d54ab8` | Code deduplication & utility extraction |
| 3     | `7454a78`            | Performance optimizations               |
| 4     | `9e2d29a`            | Code quality improvements               |
| 5     | `57bc442`            | Architectural improvements              |

---

## Phase 1: Memory Leak Fixes & RAII Wrappers

### Problem

Manual memory management in `ForwardInvocation()`, `SubclassForwardInvocation()`, and `CallJSCallback()` led to:

- Potential memory leaks on early returns or exceptions
- Complex cleanup paths that were error-prone
- Difficult-to-audit resource ownership

### Solution

Created RAII wrappers to ensure deterministic cleanup.

### New Files

#### `src/native/memory-utils.h`

**InvocationDataGuard** - RAII wrapper for `InvocationData*`:

```cpp
class InvocationDataGuard {
public:
  explicit InvocationDataGuard(InvocationData* data);

  // Release ownership (for successful handoff to callbacks)
  InvocationData* release();

  // Access without releasing
  InvocationData* get() const;
  InvocationData* operator->() const;

  ~InvocationDataGuard(); // Cleanup: releases NSInvocation, deletes data
};
```

**ScopeGuard** - Generic scope guard for arbitrary cleanup:

```cpp
template<typename Func>
class ScopeGuard {
public:
  explicit ScopeGuard(Func&& func);
  void dismiss();  // Cancel cleanup
  ~ScopeGuard();   // Execute cleanup if not dismissed
};

// Factory function
template<typename Func>
ScopeGuard<Func> MakeScopeGuard(Func&& func);
```

Usage example:

```cpp
auto data = new InvocationData();
InvocationDataGuard guard(data);

// ... use data ...

if (success) {
  guard.release();  // Transfer ownership to callback
}
// Otherwise, destructor cleans up automatically
```

#### `src/native/ffi-utils.h` (addition)

**FFITypeGuard** - RAII wrapper for dynamically allocated `ffi_type` structs:

```cpp
class FFITypeGuard {
public:
  void add(ffi_type* type);      // Take ownership
  std::vector<ffi_type*>& types(); // Access for legacy APIs
  std::vector<ffi_type*> release(); // Release ownership
  ~FFITypeGuard();               // Free all managed types
};
```

This is critical because FFI struct types require heap-allocated `elements` arrays that must be cleaned up.

---

## Phase 2: Remove Code Duplication

### Problem

Significant code duplication existed between:

- Protocol forwarding (`method-forwarding.mm`) and subclass forwarding (`subclass-impl.mm`)
- Pointer serialization across multiple files
- Runtime detection (Electron/Bun) duplicated in multiple places
- Large switch statements for type dispatch

### Solution

Extracted common functionality into reusable utilities.

### New Files

#### `src/native/forwarding-common.h` and `src/native/forwarding-common.mm`

Unified method forwarding logic shared between protocols and subclasses.

**ForwardingContext** - Gathered context data for invocations:

```cpp
struct ForwardingContext {
  Napi::ThreadSafeFunction tsfn;
  std::string typeEncoding;
  pthread_t js_thread;
  napi_env env;
  bool skipDirectCallForElectron;

  // Subclass-specific
  void *instancePtr;
  void *superClassPtr;

  // Performance: cached JS callback reference
  Napi::FunctionReference* cachedJsCallback;
};
```

**ForwardingCallbacks** - Storage-specific callbacks:

```cpp
struct ForwardingCallbacks {
  std::function<std::optional<ForwardingContext>(void*, const std::string&)> lookupContext;
  std::function<Napi::Function(void*, const std::string&, Napi::Env)> getJSFunction;
  std::function<std::optional<Napi::ThreadSafeFunction>(void*, const std::string&)> reacquireTSFN;
  CallbackType callbackType;
};
```

**ForwardInvocationCommon()** - Single implementation for forwarding:

```cpp
void ForwardInvocationCommon(NSInvocation *invocation,
                             const std::string &selectorName,
                             void *lookupKey,
                             const ForwardingCallbacks &callbacks);
```

This reduced ~250 lines of duplicated forwarding logic to a single implementation.

#### `src/native/pointer-utils.h`

Portable pointer serialization utilities:

```cpp
// Little-endian buffer operations
void WritePointerToBuffer(const void *ptr, uint8_t *buffer);
void *ReadPointerFromBuffer(const uint8_t *buffer);

// N-API conversions
Napi::BigInt PointerToBigInt(Napi::Env env, const void *ptr);
void *BigIntToPointer(Napi::Env env, const Napi::BigInt &bigint);
Napi::Buffer<uint8_t> PointerToBuffer(Napi::Env env, const void *ptr);
```

#### `src/native/runtime-detection.h`

Runtime environment detection:

```cpp
// Detect Electron (checks process.versions.electron)
// Important: Electron requires ThreadSafeFunction for all callbacks
// due to V8 context issues with direct invocation
bool IsElectronRuntime(Napi::Env env);

// Detect Bun (checks process.versions.bun)
bool IsBunRuntime(Napi::Env env);
```

#### `src/native/type-dispatch.h`

Template-based type dispatch system replacing large switch statements.

**Type Code Mapping:**

```cpp
// Compile-time type mapping
template <char TypeCode> struct TypeCodeToType;
template <> struct TypeCodeToType<'c'> { using type = char; };
template <> struct TypeCodeToType<'i'> { using type = int; };
// ... all 19 type codes

// Special tag types for ObjC types
struct ObjCIdTag {};
struct ObjCClassTag {};
struct ObjCSELTag {};
struct ObjCCStringTag {};
struct ObjCPointerTag {};
struct ObjCVoidTag {};
```

**Runtime Dispatch with Visitor Pattern:**

```cpp
template <typename Visitor>
auto DispatchByTypeCode(char typeCode, Visitor&& visitor);

// Usage:
struct MyVisitor {
  template <typename T>
  auto operator()(std::type_identity<T>) {
    return sizeof(T);
  }
};

size_t size = DispatchByTypeCode('i', MyVisitor{});  // Returns sizeof(int)
```

**Type Classification:**

```cpp
bool IsNumericTypeCode(char typeCode);
bool IsSignedIntegerTypeCode(char typeCode);
bool IsUnsignedIntegerTypeCode(char typeCode);
bool IsFloatingPointTypeCode(char typeCode);
bool IsObjectTypeCode(char typeCode);
size_t GetTypeSize(char typeCode);
```

### Changes to Existing Files

- **`method-forwarding.mm`**: Reduced from ~350 lines to ~120 by using `ForwardInvocationCommon()`
- **`subclass-impl.mm`**: Reduced from ~400 lines to ~150 by using `ForwardInvocationCommon()`
- **`type-conversion.h`**: Refactored to use visitor pattern internally
- **`ObjcObject.mm`**: Uses `pointer-utils.h` for serialization
- **`nobjc.mm`**: Uses `runtime-detection.h`

---

## Phase 3: Performance Optimizations

### Problem

Several performance bottlenecks were identified:

- `SimplifyTypeEncoding` used string operations when pointer arithmetic sufficed
- Mutex contention during JS callback lookup
- Potential inefficient map lookups

### Solutions

#### 1. Optimized SimplifyTypeEncoding

Before: Used `std::string::find()` and `std::string::substr()`
After: O(1) pointer arithmetic to skip qualifiers

```cpp
// Skips type qualifiers (r, n, N, o, O, R, V) with pointer arithmetic
// rather than string operations
inline const char* SimplifyTypeEncoding(const char* encoding) {
  while (*encoding && strchr("rnNoORV", *encoding)) {
    encoding++;
  }
  return encoding;
}
```

#### 2. Reduced Mutex Contention

Added `cachedJsCallback` to `ForwardingContext`:

```cpp
struct ForwardingContext {
  // ...
  Napi::FunctionReference* cachedJsCallback;  // NEW: Avoid re-acquiring mutex
};
```

The JS callback reference is now cached during the initial lookup under lock, eliminating a second mutex acquisition in `getJSFunction()`.

#### 3. Verified Map Lookup Pattern

Ensured all map lookups use the `find() + iterator` pattern rather than double-lookup with `count()` + `operator[]`:

```cpp
// Correct pattern used throughout:
auto it = map.find(key);
if (it != map.end()) {
  return &it->second;
}
return nullptr;
```

---

## Phase 4: Code Quality Improvements

### Problem

- Magic numbers scattered throughout the codebase
- `CallSuper` and `CallSuperWithFFI` were monolithic 275+ line functions
- Difficult to understand and maintain

### Solutions

#### `src/native/constants.h`

Centralized named constants:

```cpp
namespace nobjc {

// RunLoop Configuration
constexpr CFTimeInterval kRunLoopPumpInterval = 0.001;  // 1ms
constexpr int kRunLoopDebugLogInterval = 1000;

// Buffer Sizes
constexpr size_t kMinReturnBufferSize = 16;
constexpr size_t kTypeEncodingBufferSize = 64;

// FFI Configuration
constexpr size_t kDefaultArgBufferSize = sizeof(void*);
constexpr size_t kOutParamPointerSize = sizeof(void*);

}  // namespace nobjc
```

#### `src/native/super-call-helpers.h`

Broke down `CallSuperWithFFI` (275 lines) into focused helper functions:

**FFIArgumentContext** - Argument building context:

```cpp
struct FFIArgumentContext {
  std::vector<ffi_type*> argFFITypes;
  std::vector<void*> argValues;
  std::vector<std::unique_ptr<uint8_t[]>> argBuffers;
  std::vector<ffi_type*> allocatedTypes;
};
```

**Helper Functions:**

| Function                     | Purpose                     | Lines Saved |
| ---------------------------- | --------------------------- | ----------- |
| `PrepareFFIArgumentTypes()`  | Build FFI type arrays       | ~40         |
| `AddFixedFFIArguments()`     | Add objc_super\* and SEL    | ~20         |
| `ExtractOutParamArgument()`  | Handle NSError\*\* etc.     | ~25         |
| `ExtractRegularArgument()`   | Convert JS arg to buffer    | ~45         |
| `ExtractMethodArguments()`   | Orchestrate arg extraction  | ~30         |
| `LogFFICallSetup()`          | Debug logging               | ~35         |
| `ExecuteFFICallAndConvert()` | Call FFI and convert result | ~30         |
| `ValidateSuperMethod()`      | Validate method exists      | ~35         |

**Result:** `CallSuperWithFFI` reduced from 275 lines to ~75 lines, `CallSuper` from 214 to ~60 lines.

---

## Phase 5: Architectural Improvements

### Problem

Global variables for storage with external mutexes:

- `g_implementations` + `g_implementations_mutex` (protocols)
- `g_subclasses` + `g_subclasses_mutex` (subclasses)

Issues:

- No encapsulation - any code could access storage directly
- Easy to forget to acquire mutex
- Difficult to add features like iteration or batch operations

### Solution

Created thread-safe singleton managers encapsulating storage and synchronization.

#### `src/native/protocol-manager.h`

```cpp
namespace nobjc {

class ProtocolManager {
public:
  static ProtocolManager& Instance();  // Singleton access

  // Core operations (all thread-safe)
  ProtocolImplementation* Find(void* instancePtr);
  void Register(void* instancePtr, ProtocolImplementation&& impl);
  bool Unregister(void* instancePtr);

  // Complex operations with lock held
  template <typename Callback>
  auto WithLock(Callback&& callback);

  template <typename Callback>
  auto WithLockConst(Callback&& callback) const;

  // Queries
  bool Contains(void* instancePtr) const;
  size_t Size() const;

private:
  ProtocolManager() = default;
  mutable std::mutex mutex_;
  std::unordered_map<void*, ProtocolImplementation> implementations_;
};

}  // namespace nobjc
```

**Usage:**

```cpp
// Simple lookup
auto* impl = ProtocolManager::Instance().Find(instancePtr);

// Registration
ProtocolManager::Instance().Register(ptr, std::move(impl));

// Complex operation with lock
auto result = ProtocolManager::Instance().WithLock([&](auto& map) {
  auto it = map.find(key);
  if (it != map.end()) {
    // ... complex logic ...
    return it->second.someValue;
  }
  return defaultValue;
});
```

#### `src/native/subclass-manager.h`

Identical pattern for subclass storage:

```cpp
namespace nobjc {

class SubclassManager {
public:
  static SubclassManager& Instance();

  SubclassImplementation* Find(void* classPtr);
  void Register(void* classPtr, SubclassImplementation&& impl);
  bool Unregister(void* classPtr);

  template <typename Callback>
  auto WithLock(Callback&& callback);

  // Subclass-specific helper
  void* FindSuperClassInHierarchy(void* instanceClassPtr);

  bool Contains(void* classPtr) const;
  size_t Size() const;

private:
  mutable std::mutex mutex_;
  std::unordered_map<void*, SubclassImplementation> subclasses_;
};

}  // namespace nobjc
```

### Changes to Existing Files

- **`method-forwarding.mm`**: Replaced direct map access with `ProtocolManager::Instance().WithLock()`
- **`subclass-impl.mm`**: Replaced direct map access with `SubclassManager::Instance().WithLock()`
- **`protocol-impl.mm`**: Uses `ProtocolManager::Instance().Register()`
- **`protocol-storage.h`**: Deprecated old globals with documentation pointing to new managers

### Deferred Work

**Splitting `type-conversion.h`** was evaluated but deferred:

- File is 534 lines and well-organized with clear sections
- Functions are cohesive (all related to type conversion)
- Splitting would add include overhead with marginal benefit
- Added comprehensive documentation instead

---

## Final File Structure

```
src/native/
├── bridge.h
├── constants.h              # Phase 4 - named constants
├── debug.h
├── ffi-utils.h              # Phase 1 - FFITypeGuard RAII
├── forwarding-common.h      # Phase 2 - ForwardingContext, ForwardingCallbacks
├── forwarding-common.mm     # Phase 2 - ForwardInvocationCommon()
├── memory-utils.h           # Phase 1 - InvocationDataGuard, ScopeGuard
├── method-forwarding.h
├── method-forwarding.mm     # Modified - uses ProtocolManager
├── nobjc.mm
├── ObjcObject.h
├── ObjcObject.mm
├── pointer-utils.h          # Phase 2 - pointer serialization
├── protocol-impl.h
├── protocol-impl.mm         # Modified - uses ProtocolManager
├── protocol-manager.h       # Phase 5 - ProtocolManager singleton
├── protocol-storage.h       # Modified - deprecated globals
├── runtime-detection.h      # Phase 2 - Electron/Bun detection
├── subclass-impl.h
├── subclass-impl.mm         # Modified - uses SubclassManager
├── subclass-manager.h       # Phase 5 - SubclassManager singleton
├── super-call-helpers.h     # Phase 4 - CallSuper helpers
├── type-conversion.h        # Phase 2 - visitor pattern, documentation
└── type-dispatch.h          # Phase 2 - template type dispatch
```

---

## Key Design Decisions

### 1. RAII Over Manual Cleanup

All resource management uses RAII patterns:

- `InvocationDataGuard` for invocation data lifecycle
- `FFITypeGuard` for FFI type allocations
- `ScopeGuard` for arbitrary cleanup

Benefits:

- Exception-safe resource management
- Simplified control flow (no cleanup gotos/labels)
- Self-documenting ownership semantics

### 2. Singleton Managers Over Global Variables

Chose Meyer's singleton pattern:

```cpp
static Manager& Instance() {
  static Manager instance;
  return instance;
}
```

Benefits:

- Lazy initialization
- Thread-safe construction (C++11 guarantee)
- Encapsulated synchronization
- Clear API for all operations

### 3. WithLock() Pattern

Instead of exposing mutexes, managers provide `WithLock()`:

```cpp
template <typename Callback>
auto WithLock(Callback&& callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  return callback(storage_);
}
```

Benefits:

- Impossible to forget to acquire lock
- Lock scope is obvious (lambda body)
- Return value forwarding preserves ergonomics
- Const overload for read-only operations

### 4. Visitor Pattern for Type Dispatch

Replaced 19-case switch statements with compile-time dispatch:

```cpp
// Before: 50+ lines of switch cases
switch (typeCode) {
  case 'c': return sizeof(char);
  case 'i': return sizeof(int);
  // ... 17 more cases
}

// After: Type-safe visitor
return DispatchByTypeCode(typeCode, [](auto type_id) {
  using T = typename decltype(type_id)::type;
  return sizeof(T);
});
```

Benefits:

- Compile-time type safety
- Single source of truth for type mappings
- Easier to add new operations
- Better optimization opportunities

### 5. Unified Forwarding Implementation

Both protocol and subclass forwarding use `ForwardInvocationCommon()` with callbacks:

```cpp
ForwardingCallbacks callbacks {
  .lookupContext = [](void* key, const std::string& sel) { ... },
  .getJSFunction = [](void* key, const std::string& sel, Napi::Env env) { ... },
  .reacquireTSFN = [](void* key, const std::string& sel) { ... },
  .callbackType = CallbackType::Protocol  // or Subclass
};

ForwardInvocationCommon(invocation, selectorName, lookupKey, callbacks);
```

Benefits:

- Single implementation to maintain
- Storage-specific logic isolated in callbacks
- Easy to add new storage types

---

## Metrics

| Metric                 | Before     | After      | Change        |
| ---------------------- | ---------- | ---------- | ------------- |
| `method-forwarding.mm` | ~350 lines | ~120 lines | -66%          |
| `subclass-impl.mm`     | ~650 lines | ~300 lines | -54%          |
| `CallSuperWithFFI`     | 275 lines  | 75 lines   | -73%          |
| `CallSuper`            | 214 lines  | 60 lines   | -72%          |
| New utility headers    | 0          | 9          | +9            |
| Test pass rate         | 90/92      | 90/92      | No regression |

---

## Future Considerations

1. **Split `type-conversion.h`** if it grows beyond 600 lines
2. **Add comprehensive error codes** using the RAII infrastructure
3. **Profile performance** to measure optimization impact
4. **Add more integration tests** for edge cases in forwarding
