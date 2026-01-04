# Super Calls Implementation Plan - Full Struct Support with libffi

**Date:** 2026-01-04  
**Status:** READY TO IMPLEMENT  
**Estimated Time:** 8-10 hours

---

## PROBLEM STATEMENT

### The Bug

When calling `NobjcClass.super()` from within an overridden method, the current implementation uses `NSInvocation` with `[invocation setTarget:self]` followed by `[invocation invoke]`. This causes an infinite recursion loop because:

1. User's JS method calls `NobjcClass.super(self, selector, ...args)`
2. `CallSuper` creates NSInvocation with target=self
3. `[invocation invoke]` dispatches to self's implementation (not super!)
4. This triggers the forwarding mechanism again
5. Calls user's JS method again
6. Repeat until stack overflow

### Evidence from Logs

```
CallSuper: selector=_requestContextWithRequests:error:, self=0xbf8d165a0
CallSuper: instanceClass=WebauthnGetController
CallSuper: Found superclass from registry: ASAuthorizationController
CallSuper: Using NSInvocation approach for method with arguments
(repeats infinitely until)
ERROR: Maximum call stack size exceeded
```

### User's Use Case

Subclassing `ASAuthorizationController` and overriding the private method `_requestContextWithRequests:error:` with type signature `@@:@^@` (returns id, takes NSArray\* and NSError\*\*). The user needs to:

1. Call super to get the original context
2. Modify the context (set clientDataHash)
3. Return the modified context

---

## SOLUTION APPROACH

Replace the broken NSInvocation-based super calls with **libffi** implementation that directly invokes `objc_msgSendSuper` with dynamically constructed arguments. This approach:

- ✅ Eliminates infinite recursion (calls super's IMP directly)
- ✅ Supports all Objective-C types including structs/unions
- ✅ Uses standard macOS library (libffi ships with macOS)
- ✅ Handles ARM64 calling conventions automatically
- ✅ Provides fallback to old approach if FFI fails

---

## PROJECT OVERVIEW

**Objective:** Replace broken NSInvocation-based super calls with libffi implementation that supports ALL Objective-C types including structs/unions.

**Scope:** Full type support for macOS Objective-C runtime type encodings

**Platform:** macOS only

**Timeline:** 8-9 hours

---

## IMPLEMENTATION CHECKLIST

### PHASE 1: SETUP & INFRASTRUCTURE (1.5 hours)

#### Task 1.1: Update Build Configuration ⏱️ 15 min

- [ ] Open `binding.gyp`
- [ ] Add libffi to `libraries` array: `"-lffi"`
- [ ] Add libffi include path to `include_dirs`: `"<!@(pkg-config --cflags-only-I libffi | sed 's/-I//g')"`
- [ ] Verify pkg-config finds libffi: `pkg-config --exists libffi && echo "OK"`
- [ ] Test build: `npm run build` (should succeed without errors)
- [ ] **Verification:** Build completes successfully

#### Task 1.2: Create FFI Utilities Header ⏱️ 1 hour 15 min

- [ ] Create new file: `src/native/ffi-utils.h`
- [ ] Add header guards and includes:
  ```cpp
  #ifndef FFI_UTILS_H
  #define FFI_UTILS_H
  #include <ffi.h>
  #include <Foundation/Foundation.h>
  #include <napi.h>
  #include <objc/runtime.h>
  #include "debug.h"
  ```

##### Subtask 1.2.1: Type Size Calculation

- [ ] Implement `size_t GetSizeForTypeEncoding(char typeCode)`
  - [ ] Handle primitives: `c,i,s,l,q,C,I,S,L,Q,f,d,B`
  - [ ] Handle pointers: `@,#,:,*,^` (all sizeof(void\*))
  - [ ] Handle void: `v` (return 0)
  - [ ] Handle structs: `{` (use NSGetSizeAndAlignment)
  - [ ] Add default case with error logging

##### Subtask 1.2.2: FFI Type Mapping - Simple Types

- [ ] Implement `ffi_type* GetFFITypeForSimpleEncoding(char typeCode)`
  - [ ] Map `c` → `&ffi_type_sint8`
  - [ ] Map `i` → `&ffi_type_sint32`
  - [ ] Map `s` → `&ffi_type_sint16`
  - [ ] Map `l` → `&ffi_type_slong`
  - [ ] Map `q` → `&ffi_type_sint64`
  - [ ] Map `C` → `&ffi_type_uint8`
  - [ ] Map `I` → `&ffi_type_uint32`
  - [ ] Map `S` → `&ffi_type_uint16`
  - [ ] Map `L` → `&ffi_type_ulong`
  - [ ] Map `Q` → `&ffi_type_uint64`
  - [ ] Map `f` → `&ffi_type_float`
  - [ ] Map `d` → `&ffi_type_double`
  - [ ] Map `B` → `&ffi_type_uint8` (BOOL)
  - [ ] Map `@,#,:,*,^` → `&ffi_type_pointer`
  - [ ] Map `v` → `&ffi_type_void`

##### Subtask 1.2.3: Struct Type Parsing

- [ ] Implement `ffi_type* ParseStructEncoding(const char* encoding, size_t* outSize)`
  - [ ] Parse struct name: `{StructName=...}` format
  - [ ] Initialize vector for field types
  - [ ] Loop through field encodings:
    - [ ] Skip struct name (up to `=`)
    - [ ] For each field until `}`:
      - [ ] Get field type encoding
      - [ ] Recursively call `GetFFITypeForEncoding()` for field
      - [ ] Add to field types vector
      - [ ] Handle nested structs recursively
  - [ ] Allocate `ffi_type` struct on heap
  - [ ] Set `type` to `FFI_TYPE_STRUCT`
  - [ ] Allocate and populate `elements` array (null-terminated)
  - [ ] Calculate struct size with `NSGetSizeAndAlignment()`
  - [ ] Return allocated ffi_type\*
  - [ ] **Memory Note:** Add to cleanup list (needs to be freed)

##### Subtask 1.2.4: Main FFI Type Function

- [ ] Implement `ffi_type* GetFFITypeForEncoding(const char* encoding, size_t* outSize, std::vector<ffi_type*>& allocatedTypes)`
  - [ ] Simplify encoding (remove qualifiers)
  - [ ] Switch on first character:
    - [ ] `{` → Call `ParseStructEncoding()`
    - [ ] `(` → Call `ParseStructEncoding()` (union, same as struct for libffi)
    - [ ] Everything else → Call `GetFFITypeForSimpleEncoding()`
  - [ ] If struct, add to allocatedTypes vector for cleanup
  - [ ] Set outSize if requested
  - [ ] Return ffi_type\*

##### Subtask 1.2.5: Argument Extraction

- [ ] Implement `void ExtractJSArgumentToBuffer(Napi::Env env, const Napi::Value& jsValue, const char* typeEncoding, void* buffer, const ObjcArgumentContext& context)`
  - [ ] Reuse existing `AsObjCArgument()` logic
  - [ ] Extract value from ObjcType variant into buffer
  - [ ] Add visitor pattern to copy each type to buffer
  - [ ] Handle pointer types specially (^@)
  - [ ] Add error handling with context logging

##### Subtask 1.2.6: Return Value Conversion

- [ ] Implement `Napi::Value ConvertFFIReturnToJS(Napi::Env env, void* returnBuffer, const char* typeEncoding)`
  - [ ] Reuse existing `ObjCToJS()` logic
  - [ ] Switch on type encoding character
  - [ ] Read from returnBuffer and convert to Napi::Value
  - [ ] Handle structs: return Undefined for now (limitation)
  - [ ] Add logging for unsupported cases

- [ ] Close header guard: `#endif // FFI_UTILS_H`
- [ ] **Verification:** Header compiles without errors

---

### PHASE 2: CORE IMPLEMENTATION (3 hours)

#### Task 2.1: Refactor CallSuper - Setup ⏱️ 30 min

- [ ] Open `src/native/subclass-impl.mm`
- [ ] Add include: `#include "ffi-utils.h"` (after other includes)
- [ ] Locate `CallSuper` function (starts ~line 503)
- [ ] Keep existing validation code (lines 503-557):
  - [ ] Argument count check
  - [ ] Self and selector extraction
  - [ ] Debug logging
  - [ ] Superclass resolution
  - [ ] Method signature validation
  - [ ] Argument count validation

#### Task 2.2: Implement CallSuperWithFFI ⏱️ 2 hours

- [ ] Create new function signature above CallSuper:
  ```cpp
  static Napi::Value CallSuperWithFFI(
      Napi::Env env,
      id self,
      Class superClass,
      SEL selector,
      NSMethodSignature* methodSig,
      const Napi::CallbackInfo& info,
      size_t argStartIndex
  )
  ```

##### Subtask 2.2.1: Prepare objc_super struct

- [ ] Create objc_super struct:
  ```cpp
  struct objc_super superStruct;
  superStruct.receiver = self;
  superStruct.super_class = superClass;
  ```
- [ ] Add debug log: selector, self pointer, superClass name

##### Subtask 2.2.2: Determine objc_msgSend variant

- [ ] Get return type encoding: `[methodSig methodReturnType]`
- [ ] Get return length: `[methodSig methodReturnLength]`
- [ ] Determine if using stret:
  ```cpp
  bool useStret = false;
  if (returnType[0] == '{' || returnType[0] == '(') {
      #if defined(__arm64__) || defined(__aarch64__)
          useStret = returnLength > 16;
      #elif defined(__x86_64__)
          useStret = returnLength > 16;
      #endif
  }
  ```
- [ ] Select function pointer:
  ```cpp
  void* msgSendFn = useStret ? (void*)objc_msgSendSuper2_stret
                              : (void*)objc_msgSendSuper2;
  ```
- [ ] Add debug log: using stret or not

##### Subtask 2.2.3: Build FFI type arrays

- [ ] Calculate total arg count: `size_t totalArgs = [methodSig numberOfArguments]`
- [ ] Create vectors:
  ```cpp
  std::vector<ffi_type*> argFFITypes;
  std::vector<ffi_type*> allocatedTypes; // For cleanup
  ```
- [ ] Add objc_super pointer type: `argFFITypes.push_back(&ffi_type_pointer)`
- [ ] Add SEL type: `argFFITypes.push_back(&ffi_type_pointer)`
- [ ] Loop through method arguments (index 2 to totalArgs):
  - [ ] Get argument type: `[methodSig getArgumentTypeAtIndex:i]`
  - [ ] Call `GetFFITypeForEncoding(encoding, nullptr, allocatedTypes)`
  - [ ] Add to argFFITypes vector
  - [ ] Log each argument type being processed

##### Subtask 2.2.4: Build return FFI type

- [ ] Get return encoding: `SimplifyTypeEncoding([methodSig methodReturnType])`
- [ ] Call `GetFFITypeForEncoding(returnEncoding, &returnSize, allocatedTypes)`
- [ ] Store as `ffi_type* returnFFIType`
- [ ] Log return type

##### Subtask 2.2.5: Prepare FFI CIF

- [ ] Declare: `ffi_cif cif`
- [ ] Call `ffi_prep_cif()`:
  ```cpp
  ffi_status status = ffi_prep_cif(
      &cif,
      FFI_DEFAULT_ABI,
      argFFITypes.size(),
      returnFFIType,
      argFFITypes.data()
  );
  ```
- [ ] Check status:
  - [ ] If not FFI_OK, log error
  - [ ] Cleanup allocated types
  - [ ] Throw Napi::Error
- [ ] Log: "FFI CIF prepared successfully"

##### Subtask 2.2.6: Prepare argument value buffers

- [ ] Create vectors:
  ```cpp
  std::vector<void*> argValues;
  std::vector<std::unique_ptr<uint8_t[]>> argBuffers;
  ```
- [ ] Add objc_super pointer:
  ```cpp
  struct objc_super* superPtr = &superStruct;
  argValues.push_back(&superPtr);
  ```
- [ ] Add selector:
  ```cpp
  argValues.push_back(&selector);
  ```
- [ ] Loop through JS arguments (from argStartIndex):
  - [ ] Get type encoding for this arg index
  - [ ] Calculate size: `GetSizeForTypeEncoding()`
  - [ ] Allocate buffer: `std::make_unique<uint8_t[]>(size)`
  - [ ] Handle special case for ^@ (out-params):
    - [ ] If type is ^@ and JS value is null/undefined:
      - [ ] Create nullptr pointer: `id* errorPtr = nullptr`
      - [ ] Copy to buffer
      - [ ] Continue to next arg
  - [ ] Otherwise call `ExtractJSArgumentToBuffer()` to fill buffer
  - [ ] Add buffer pointer to argValues
  - [ ] Move buffer to argBuffers vector (keep alive)
  - [ ] Log each argument extracted

##### Subtask 2.2.7: Prepare return buffer

- [ ] Get return size: Already calculated in step 2.2.4
- [ ] Handle special cases:
  - [ ] If void return: skip buffer allocation
  - [ ] If stret: allocate large enough buffer
  - [ ] Otherwise: allocate returnSize bytes
- [ ] Allocate: `auto returnBuffer = std::make_unique<uint8_t[]>(returnSize)`
- [ ] Zero initialize: `memset(returnBuffer.get(), 0, returnSize)`

##### Subtask 2.2.8: Make the FFI call

- [ ] Log: "Calling ffi_call with objc_msgSendSuper"
- [ ] Call:
  ```cpp
  ffi_call(&cif, FFI_FN(msgSendFn), returnBuffer.get(), argValues.data());
  ```
- [ ] Log: "ffi_call completed successfully"

##### Subtask 2.2.9: Convert return value

- [ ] If void return: `return env.Undefined()`
- [ ] Otherwise call `ConvertFFIReturnToJS(env, returnBuffer.get(), returnEncoding)`
- [ ] Store result in Napi::Value

##### Subtask 2.2.10: Cleanup

- [ ] Loop through allocatedTypes vector:
  - [ ] For each ffi_type\* that's a struct:
    - [ ] Free elements array
    - [ ] Free ffi_type itself
- [ ] Clear vectors
- [ ] Return Napi::Value result

##### Subtask 2.2.11: Wrap in try-catch

- [ ] Wrap entire function body in try-catch
- [ ] Catch block:
  - [ ] Log error
  - [ ] Cleanup allocated types
  - [ ] Re-throw or return Null

#### Task 2.3: Modify CallSuper to use new function ⏱️ 30 min

- [ ] After validation code, before current invocation code:
- [ ] Add call to new function:
  ```cpp
  try {
      return CallSuperWithFFI(env, self, superClass, selector,
                             methodSig, info, 2);
  } catch (const std::exception& e) {
      NOBJC_ERROR("CallSuper: FFI approach failed: %s", e.what());
      // Fall through to NSInvocation fallback
  }
  ```
- [ ] Keep existing NSInvocation code as fallback
- [ ] Add warning log before NSInvocation: "Using fallback approach (may recurse)"
- [ ] Remove old debug logs that are now redundant

---

### PHASE 3: TESTING (2.5 hours)

#### Task 3.1: Create Test File ⏱️ 15 min

- [ ] Create `tests/test-subclass-super-call.test.ts`
- [ ] Add imports:
  ```typescript
  import { NobjcLibrary, NobjcClass, NobjcObject } from "../dist/index.js";
  import { describe, test, expect } from "bun:test";
  ```
- [ ] Load Foundation framework
- [ ] Set up test helpers

#### Task 3.2: Basic Super Call Tests ⏱️ 45 min

- [ ] Test: "super call with no arguments"
  - [ ] Subclass NSObject
  - [ ] Override `description` (@@:)
  - [ ] Call super
  - [ ] Verify returns NSString
  - [ ] Verify no crash

- [ ] Test: "super call returns correct value"
  - [ ] Subclass NSNumber
  - [ ] Override `intValue` (i@:)
  - [ ] Call super
  - [ ] Verify returns same int value

- [ ] Test: "super call with primitive argument"
  - [ ] Create custom Objective-C class with method taking int
  - [ ] Subclass it
  - [ ] Override method
  - [ ] Call super with int argument
  - [ ] Verify works

- [ ] Test: "super call with object argument"
  - [ ] Subclass NSString
  - [ ] Override `stringByAppendingString:` (@@:@)
  - [ ] Call super
  - [ ] Verify result is correct concatenation

#### Task 3.3: User-Specific Test Case ⏱️ 30 min

- [ ] Test: "ASAuthorizationController \_requestContextWithRequests:error:"
  - [ ] Load AuthenticationServices framework
  - [ ] Create subclass of ASAuthorizationController
  - [ ] Override `_requestContextWithRequests:error:` (@@:@^@)
  - [ ] Implementation:
    - [ ] Log entry
    - [ ] Call super with requests and null error
    - [ ] Log return value
    - [ ] Verify context is not null
    - [ ] Return context
  - [ ] Create test scenario:
    - [ ] Create credential provider
    - [ ] Create request
    - [ ] Create controller instance
    - [ ] Trigger method (may need to mock or use private API)
  - [ ] Verify no infinite recursion (test completes)
  - [ ] Verify return value is valid

#### Task 3.4: Infinite Recursion Prevention Test ⏱️ 20 min

- [ ] Test: "no infinite recursion when calling super in override"
  - [ ] Create simple class with method
  - [ ] Subclass and override
  - [ ] Call super in override
  - [ ] Add timeout (5 seconds)
  - [ ] Verify completes before timeout
  - [ ] Verify doesn't throw "Maximum call stack" error

#### Task 3.5: Edge Cases & Complex Types ⏱️ 30 min

- [ ] Test: "super call with pointer argument (^@)"
  - [ ] Override method with NSError\*\* parameter
  - [ ] Call super with null
  - [ ] Verify works

- [ ] Test: "super call with multiple arguments"
  - [ ] Override method with 3+ arguments
  - [ ] Call super with all arguments
  - [ ] Verify all passed correctly

- [ ] Test: "super call with mixed argument types"
  - [ ] Override method: (@@:ifd@) (int, float, double, object)
  - [ ] Call super with mixed values
  - [ ] Verify all converted correctly

- [ ] Test: "super call void return"
  - [ ] Override method returning void
  - [ ] Call super
  - [ ] Verify returns undefined

#### Task 3.6: Struct Tests (if time permits) ⏱️ 30 min

- [ ] Test: "super call with CGRect argument"
  - [ ] Override `setFrame:` on NSView
  - [ ] Call super with CGRect
  - [ ] Verify struct passed correctly

- [ ] Test: "super call with NSRange argument"
  - [ ] Override method taking NSRange
  - [ ] Call super
  - [ ] Verify works

- [ ] Note: These may fail initially - acceptable for Phase 1

#### Task 3.7: Run All Tests ⏱️ 10 min

- [ ] Run test suite: `bun test tests/test-subclass-super-call.test.ts`
- [ ] Verify all tests pass
- [ ] Check for any warnings in output
- [ ] Verify no memory leaks (use instruments if needed)

---

### PHASE 4: INTEGRATION & VERIFICATION (1.5 hours)

#### Task 4.1: Run Existing Test Suite ⏱️ 30 min

- [ ] Run all existing tests: `bun test`
- [ ] Verify no regressions:
  - [ ] test-get-pointer.test.ts passes
  - [ ] test-js-code.test.ts passes
  - [ ] test-native-code.test.ts passes
  - [ ] test-object-arguments.test.ts passes
  - [ ] test-protocol-implementation.test.ts passes
  - [ ] test-string-lifetime.test.ts passes
  - [ ] test-subclass.test.ts passes
- [ ] If any failures, debug and fix

#### Task 4.2: Build Verification ⏱️ 15 min

- [ ] Clean build: `npm run clean` (if exists) or `rm -rf dist build`
- [ ] Full rebuild: `npm run build`
- [ ] Verify no compiler warnings
- [ ] Verify no linker errors
- [ ] Check binary size (should be slightly larger due to libffi)

#### Task 4.3: Manual Testing with Examples ⏱️ 30 min

- [ ] Test with `examples/asauthorization-subclass.ts`:
  - [ ] Update if needed to use super calls
  - [ ] Run example: `bun run examples/asauthorization-subclass.ts`
  - [ ] Verify no infinite recursion
  - [ ] Verify returns valid context object
  - [ ] Check debug logs show FFI path being used

#### Task 4.4: Memory Leak Check ⏱️ 15 min

- [ ] Run tests under Xcode Instruments (Leaks template)
- [ ] Verify no memory leaks from:
  - [ ] Allocated ffi_type structs
  - [ ] Argument buffers
  - [ ] Return value buffers
- [ ] If leaks found, fix cleanup code

---

### PHASE 5: CLEANUP & DOCUMENTATION (1.5 hours)

#### Task 5.1: Code Cleanup ⏱️ 30 min

- [ ] Remove old commented-out code from CallSuper
- [ ] Ensure all debug logs use NOBJC_LOG macro
- [ ] Add comprehensive code comments:
  - [ ] Explain why libffi is needed (NSInvocation recursion bug)
  - [ ] Document struct parsing algorithm
  - [ ] Explain objc_msgSendSuper vs objc_msgSendSuper2_stret
  - [ ] Note memory management for allocated ffi_types
- [ ] Format code consistently (indentation, spacing)
- [ ] Remove any unused includes

#### Task 5.2: Disable Debug Logging ⏱️ 5 min

- [ ] Open `src/native/debug.h`
- [ ] Set `NOBJC_DEBUG` to `0`
- [ ] Rebuild to verify no debug output
- [ ] Commit this separately if using git

#### Task 5.3: Update Documentation ⏱️ 45 min

##### Subtask 5.3.1: Update subclassing.md

- [ ] Open `docs/subclassing.md`
- [ ] Add new section: "Calling Super Methods"
- [ ] Explain the super call syntax:
  ```typescript
  const result = NobjcClass.super(self, "methodName:withArg:", arg1, arg2);
  ```
- [ ] Add note about supported types (all Objective-C types including structs)
- [ ] Add example with struct argument
- [ ] Mention libffi dependency

##### Subtask 5.3.2: Update README.md

- [ ] Open `README.md`
- [ ] Add "System Requirements" section:
  - [ ] macOS 13.3+
  - [ ] libffi (included with macOS)
- [ ] Update "Features" section to mention super call support
- [ ] Add note about struct support in super calls

##### Subtask 5.3.3: Create Architecture Doc (Optional)

- [ ] Consider creating `docs/architecture/super-calls.md`
- [ ] Explain:
  - [ ] Why NSInvocation doesn't work (infinite recursion)
  - [ ] How libffi solves it (direct function call)
  - [ ] Type mapping details
  - [ ] Struct parsing algorithm
  - [ ] Memory management strategy

##### Subtask 5.3.4: Update super-calls-with-arguments-task.md

- [ ] Open `docs/super-calls-with-arguments-task.md`
- [ ] Mark as RESOLVED
- [ ] Add link to implementation
- [ ] Note completion date

#### Task 5.4: Add Type Definitions (if needed) ⏱️ 10 min

- [ ] Check `types/native/nobjc_native.d.ts`
- [ ] Verify `NobjcClass.super` is properly typed
- [ ] Update if needed with better type signature

---

### PHASE 6: FINAL VALIDATION (30 min)

#### Task 6.1: Pre-Release Checklist

- [ ] All tests pass (old + new)
- [ ] No compiler warnings
- [ ] No memory leaks
- [ ] Debug mode disabled
- [ ] Documentation updated
- [ ] Code comments added
- [ ] No console.log statements (should use NOBJC_LOG)
- [ ] Examples work correctly

#### Task 6.2: User Acceptance Test

- [ ] Provide to user for testing
- [ ] User tests with their `_requestContextWithRequests:error:` case
- [ ] Verify:
  - [ ] No infinite recursion
  - [ ] Returns valid context object
  - [ ] Can modify context as needed
  - [ ] No crashes or segfaults

#### Task 6.3: Performance Check

- [ ] Benchmark super call vs. direct call (if possible)
- [ ] Verify overhead is acceptable (< 10% expected)
- [ ] Log timing in debug mode if needed

---

## SUCCESS CRITERIA

✅ **All items checked off in all phases**  
✅ **No infinite recursion in super calls**  
✅ **Return values correctly passed from super**  
✅ **Arguments correctly forwarded to super**  
✅ **Struct types supported (arguments and returns)**  
✅ **All existing tests pass (no regressions)**  
✅ **User's `_requestContextWithRequests:error:` case works**  
✅ **No memory leaks detected**  
✅ **Documentation complete and accurate**  
✅ **Code is clean and well-commented**

---

## RISK MITIGATION

| Risk                                    | Mitigation                                    | Status              |
| --------------------------------------- | --------------------------------------------- | ------------------- |
| Struct parsing too complex              | Use NSGetSizeAndAlignment, test incrementally | ⚠️ High complexity  |
| Memory leaks from ffi_type              | Use RAII, vectors, careful cleanup            | ✅ Planned          |
| objc_msgSendSuper2 vs objc_msgSendSuper | Use correct variant per platform              | ✅ Planned          |
| ARM64 calling convention                | Let libffi handle it                          | ✅ libffi does this |
| Test coverage insufficient              | Comprehensive test suite in Phase 3           | ✅ Planned          |

---

## ESTIMATED TOTAL TIME: 8-10 HOURS

| Phase                         | Time      |
| ----------------------------- | --------- |
| 1. Setup & Infrastructure     | 1.5h      |
| 2. Core Implementation        | 3.0h      |
| 3. Testing                    | 2.5h      |
| 4. Integration & Verification | 1.5h      |
| 5. Cleanup & Documentation    | 1.5h      |
| 6. Final Validation           | 0.5h      |
| **Buffer for debugging**      | +1h       |
| **TOTAL**                     | **9-10h** |

---

## OPEN QUESTIONS

1. **Struct Return Limitation:** Should `ConvertFFIReturnToJS` return undefined for struct returns initially, or attempt to convert to JS object? (Conversion is complex)
   - **Decision:** Return undefined for now, document as limitation

2. **Nested Structs:** How deep should we support nested struct parsing? (1 level? Arbitrary depth?)
   - **Decision:** Support arbitrary depth with recursive parsing

3. **Union Types:** Treat unions same as structs for libffi purposes? (Yes is standard)
   - **Decision:** Yes, unions use same struct handling

4. **Error Handling:** Should we fail fast on any FFI error, or try to continue with fallback?
   - **Decision:** Fall back to NSInvocation approach (may recurse, but better than hard failure)

5. **Test Coverage:** Do you want performance benchmarks included, or just functional tests?
   - **Decision:** Functional tests are priority, performance check is optional validation step

---

## TECHNICAL NOTES

### Objective-C Type Encodings

```
c = char                  C = unsigned char
i = int                   I = unsigned int
s = short                 S = unsigned short
l = long                  L = unsigned long
q = long long             Q = unsigned long long
f = float                 d = double
B = BOOL (C++ bool)       v = void
* = char* (C string)      @ = id (object)
# = Class                 : = SEL (selector)
^ = pointer               ? = unknown
{ = struct                ( = union
[ = array
```

### libffi Type Mapping

```
ffi_type_sint8      ffi_type_uint8
ffi_type_sint16     ffi_type_uint16
ffi_type_sint32     ffi_type_uint32
ffi_type_sint64     ffi_type_uint64
ffi_type_slong      ffi_type_ulong
ffi_type_float      ffi_type_double
ffi_type_pointer    ffi_type_void
```

### objc_msgSendSuper Variants

- **objc_msgSendSuper2**: Standard call for scalar/object returns
- **objc_msgSendSuper2_stret**: Structure return (>16 bytes on ARM64/x86_64)

### Memory Management Strategy

1. **Argument Buffers:** Use `std::unique_ptr<uint8_t[]>` for automatic cleanup
2. **FFI Types:** Allocate structs on heap, track in vector, manually free in cleanup
3. **Return Buffer:** Use `std::unique_ptr<uint8_t[]>` for automatic cleanup
4. **RAII Pattern:** Ensure exception safety with smart pointers and vectors

---

## NOTES

- This document should be updated as implementation progresses
- Mark items as complete with ✅
- Add notes for any deviations from plan
- Track actual time spent vs. estimates
