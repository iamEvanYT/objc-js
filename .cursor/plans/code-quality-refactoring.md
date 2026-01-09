# Code Quality, Performance & Memory Leak Refactoring Plan

**Created**: 2026-01-09
**Status**: In Progress

## Overview

This plan addresses code quality, performance, redundant code removal, and memory leak fixes across the nobjc codebase (~4000 lines of native C++/Objective-C code).

## Checklist

### Phase 1: Memory Leak Fixes & RAII Wrappers

- [x] Create `memory-utils.h` with `InvocationDataGuard` RAII class
- [x] Create `FFITypeGuard` RAII class in `ffi-utils.h`
- [x] Refactor `ForwardInvocation()` to use RAII
- [x] Refactor `SubclassForwardInvocation()` to use RAII
- [x] Refactor `CallJSCallback()` to use RAII
- [x] Audit ThreadSafeFunction lifecycle (✓ protocols clean up correctly; subclasses are per-Class and intentionally persist)
- [x] Run tests after Phase 1 (90 pass, 2 skip, 0 fail)

### Phase 2: Remove Code Duplication

- [x] Create `ForwardInvocationCommon()` shared logic (forwarding-common.h/mm)
- [x] Create `pointer-utils.h` with `WritePointerToBuffer()`, `ReadPointerFromBuffer()`, etc.
- [x] Create template-based type dispatch in `type-dispatch.h` with `DispatchByTypeCode()`
- [x] Create `runtime-detection.h` with `IsElectronRuntime()`
- [x] Consolidate duplicate code paths (ForwardInvocation now uses common impl)
- [x] Refactored `type-conversion.h` to use visitor pattern (ObjCToJS, ExtractInvocationArgToJS, GetInvocationReturnAsJS)
- [x] Run tests after Phase 2 (90 pass, 2 skip, 0 fail)

### Phase 3: Performance Optimizations

- [ ] Reduce mutex contention in `SubclassForwardInvocation`
- [ ] Reduce mutex contention in `ForwardInvocation`
- [ ] Cache selector strings in `InvocationData`
- [ ] Optimize `SimplifyTypeEncoding` parser
- [ ] Replace repeated map lookups with iterators
- [ ] Run tests after Phase 3

### Phase 4: Code Quality Improvements

- [ ] Create `constants.h` with named constants
- [ ] Break up `CallSuperWithFFI` (275 lines)
- [ ] Break up `CallSuper` (214 lines)
- [ ] Reduce nesting depth across codebase
- [ ] Standardize error handling patterns
- [ ] Run tests after Phase 4

### Phase 5: Architectural Improvements

- [ ] Create `ProtocolManager` singleton class
- [ ] Create `SubclassManager` singleton class
- [ ] Split `type-conversion.h` into focused modules
- [ ] Add header documentation
- [ ] Final cleanup and code review
- [ ] Run tests after Phase 5

---

## Phase Details

### Phase 1: Memory Leak Fixes & RAII Wrappers (Critical)

**Problem**:

- 16 `new`/`delete` pairs for `InvocationData` with multiple cleanup paths
- FFI struct allocations rely on manual cleanup
- ThreadSafeFunction lifecycle edge cases

**Solution**:

1. **Create `InvocationDataGuard` RAII class** (new file: `memory-utils.h`)
   - Wraps `InvocationData*` with automatic cleanup
   - Debug logging in non-production builds (`#if NOBJC_DEBUG`)
   - Handles `invocation release` and `delete data` on scope exit
   - Has `release()` method to transfer ownership on success paths

2. **Create `FFITypeGuard` RAII class** (in `ffi-utils.h`)
   - Replaces `std::vector<ffi_type*>` + manual `CleanupAllocatedFFITypes`
   - Auto-cleanup on destruction

3. **Refactor cleanup paths in**:
   - `method-forwarding.mm`: `ForwardInvocation()` - 6 paths → 1 RAII
   - `subclass-impl.mm`: `SubclassForwardInvocation()` - 5 paths → 1 RAII
   - `method-forwarding.mm`: `CallJSCallback()` - 4 paths → 1 RAII

---

### Phase 2: Remove Code Duplication (~500 lines saved)

**2.1. Unify Method Forwarding** (~300 lines saved)

Create `ForwardInvocationCommon()`:

- Takes callback lookup function as parameter
- Handles mutex acquisition, TSFN management, direct/indirect calls, runloop pumping
- Both `ForwardInvocation` and `SubclassForwardInvocation` become thin wrappers

**2.2. Consolidate Pointer Conversion** (~30 lines saved)

Create `pointer-utils.h` with:

- `WritePointerToBuffer(uintptr_t ptr, uint8_t* buffer)`
- `ReadPointerFromBuffer(const uint8_t* buffer) -> uintptr_t`

**2.3. Unify Type Conversion Code** (~150 lines saved)

Create template-based type dispatch:

```cpp
template<typename Visitor>
auto DispatchByTypeCode(char typeCode, Visitor&& visitor);
```

**2.4. Extract Electron Detection** (~20 lines saved)

Create `runtime-detection.h` with `IsElectronRuntime(Napi::Env)`.

---

### Phase 3: Performance Optimizations

**3.1. Reduce Mutex Contention**

- Consolidate multiple mutex acquisitions → single lock
- Cache all needed data in one critical section

**3.2. Cache Selector Strings**

- Store `selectorName` immediately after conversion
- Avoid repeated `NSStringFromSelector` calls

**3.3. Optimize Type Encoding Parser**

- Pre-allocate thread_local buffer
- Use pointer arithmetic instead of string mutations

**3.4. Use Iterators**

- Replace `find()` + `operator[]` with single iterator

---

### Phase 4: Code Quality Improvements

**4.1. Break Up Monster Functions**

`CallSuperWithFFI` (275 lines) → Split into:

- `PrepareFFICall()`
- `ExtractFFIArguments()`
- `ExecuteFFICall()`
- `ConvertFFIResult()`

`CallSuper` (214 lines) → Split into:

- `FindSuperClass()`
- `ValidateSuperCall()`
- `CallSuperNoArgs()`
- `CallSuperWithArgs()`

**4.2. Define Named Constants** (in `constants.h`)

```cpp
constexpr CFTimeInterval kRunLoopPumpInterval = 0.001;
constexpr int kRunLoopDebugLogInterval = 1000;
constexpr size_t kMinReturnBufferSize = 16;
constexpr size_t kTypeEncodingBufferSize = 64;
```

**4.3. Reduce Nesting & Standardize Error Handling**

---

### Phase 5: Architectural Improvements

**5.1. Manager Classes**

```cpp
class ProtocolManager {
  std::unordered_map<void*, ProtocolImplementation> implementations_;
  std::mutex mutex_;
public:
  static ProtocolManager& Instance();
  ProtocolImplementation* Find(void* ptr);
  void Register(void* ptr, ProtocolImplementation&& impl);
  void Unregister(void* ptr);
};
```

**5.2. Split type-conversion.h** (~600 lines → 3 files)

- `type-encoding.h`: Encoding utilities
- `js-to-objc.h`: JS→ObjC conversion
- `objc-to-js.h`: ObjC→JS conversion

---

## File Changes Summary

| File                   | Action       | Purpose                 |
| ---------------------- | ------------ | ----------------------- |
| `memory-utils.h`       | Create       | RAII wrappers           |
| `constants.h`          | Create       | Named constants         |
| `pointer-utils.h`      | Create       | Pointer serialization   |
| `runtime-detection.h`  | Create       | Runtime detection       |
| `type-encoding.h`      | Create       | Type encoding utilities |
| `js-to-objc.h`         | Create       | JS→ObjC conversion      |
| `objc-to-js.h`         | Create       | ObjC→JS conversion      |
| `ffi-utils.h`          | Modify       | Add FFITypeGuard        |
| `method-forwarding.mm` | Modify       | RAII, shared logic      |
| `subclass-impl.mm`     | Modify       | RAII, shared logic      |
| `protocol-impl.mm`     | Modify       | Use utilities           |
| `ObjcObject.mm`        | Modify       | Use pointer utilities   |
| `nobjc.mm`             | Modify       | Use pointer utilities   |
| `protocol-storage.h`   | Modify       | Add managers            |
| `type-conversion.h`    | Modify/Split | Refactor                |
| `bridge.h`             | Modify       | Update includes         |

---

## Risk Mitigation

1. **Test after each phase** - catches regressions early
2. **Debug logging in RAII wrappers** - helps diagnose issues
3. **Git commit after each phase** - fine-grained history
4. **Keep TypeScript API stable** - no breaking changes for users
