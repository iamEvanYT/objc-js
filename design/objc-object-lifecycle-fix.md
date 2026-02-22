# ObjcObject Lifecycle Fix: Use-After-Free in Native Object References

## Issue

The Flow app (Electron + nobjc) crashes with `EXC_BREAKPOINT (SIGTRAP)` when JavaScript code accesses Objective-C objects received through completion handler block callbacks. Two representative crash stacks:

1. `ObjcObject::$MsgSendPrepared` -> `object_getClassName` (inspecting a freed object's class)
2. `ObjcObject::$RespondsToSelector` -> `objc_opt_respondsToSelector` (checking selectors on a freed object)

Both crashes originate from uv microtask evaluation on the main thread, routing through the native addon into the ObjC runtime with a stale pointer.

## Root Cause

**Every `ObjcObject` in the system holds an unretained reference to its underlying Objective-C object.** When ARC or autorelease pools reclaim the native object, the JS wrapper becomes a dangling pointer.

The root cause is a build configuration bug compounded by a missing manual retain/release:

### Build Configuration Bug

In `binding.gyp`, `-fobjc-arc` is specified in `OTHER_CFLAGS`:

```json
"OTHER_CPLUSPLUSFLAGS": ["-std=c++20", "-fexceptions"],
"OTHER_CFLAGS": ["-fobjc-arc"]
```

All source files are `.mm` (Objective-C++). The Xcode/node-gyp build system applies `OTHER_CPLUSPLUSFLAGS` to C++/ObjC++ compilations and `OTHER_CFLAGS` to C/ObjC compilations. Since no `.m` or `.c` files exist in the project, **`-fobjc-arc` is never applied to any compiled source file.** ARC is completely inactive.

### Missing Manual Retain/Release

The `ObjcObject` class declares its member as `__strong id objcObject`, but without ARC enabled, the `__strong` qualifier is an inert annotation:

```cpp
// Before fix
class ObjcObject : public Napi::ObjectWrap<ObjcObject> {
public:
  __strong id objcObject;  // __strong has no effect without ARC
  ObjcObject(const Napi::CallbackInfo &info)
      : Napi::ObjectWrap<ObjcObject>(info), objcObject(nil) {
    // ...
    objcObject = *(external.Data());  // Raw pointer copy, no retain
    return;
  }
  ~ObjcObject() = default;  // No release
};
```

The constructor performs a raw pointer copy. The destructor is defaulted (no-op for `id` without ARC). No `objc_retain` or `objc_release` is called anywhere.

### Why It Worked Most of the Time

For common synchronous usage patterns, the lack of retain is masked by several factors:

- **Class objects** (e.g., `NSString`, `NSNumber`) have infinite retain counts and are never deallocated
- **Synchronous method returns** are typically autoreleased; the autorelease pool doesn't drain until the current event loop tick completes, so objects survive long enough for immediate use
- **Synchronous block callbacks** (e.g., `enumerateObjectsUsingBlock:`) execute within the caller's stack frame, so the caller's references keep arguments alive

### Why It Crashes in Completion Handlers

Completion handler blocks break the synchronous assumption:

1. JS passes a callback function as a block argument to an ObjC API (e.g., `platformCredentialsForRelyingParty:completionHandler:`)
2. The framework retains the block and calls it later (possibly from a background thread via TSFN)
3. The block callback receives ObjC objects as arguments
4. `ConvertBlockArgToJS` wraps them via `ObjcObject::NewInstance` — **no retain**
5. The JS callback stores/resolves these objects (e.g., into a Promise)
6. The block callback returns; the framework releases its references to the argument objects
7. The autorelease pool drains or ARC reclaims the objects
8. JS code later accesses the resolved Promise value — **dangling pointer** -> SIGTRAP

## The Fix

Add explicit `objc_retain` in the `ObjcObject` constructor and `objc_release` in the destructor. This is a targeted fix that does not require enabling ARC globally (which would be a larger change requiring conversion of all manual `[invocation retain]`/`[invocation release]` calls).

### Changes to `src/native/ObjcObject.h`

```cpp
// Forward declarations for manual reference counting
extern "C" id objc_retain(id value);
extern "C" void objc_release(id value);

class ObjcObject : public Napi::ObjectWrap<ObjcObject> {
public:
  __strong id objcObject;
  // ...
  ObjcObject(const Napi::CallbackInfo &info)
      : Napi::ObjectWrap<ObjcObject>(info), objcObject(nil) {
    if (info.Length() == 1 && info[0].IsExternal()) {
      Napi::External<id> external = info[0].As<Napi::External<id>>();
      objcObject = *(external.Data());
      if (objcObject) objc_retain(objcObject);  // +1 retain
      return;
    }
    // ...
  }
  ~ObjcObject() {
    if (objcObject) {
      objc_release(objcObject);  // -1 release
      objcObject = nil;
    }
  }
};
```

### Why `objc_retain`/`objc_release` Instead of ARC

The project already uses manual retain/release (MRC) for `NSInvocation` objects in the forwarding pipeline:

- `subclass-impl.mm:122` — `[invocation retain]`
- `method-forwarding.mm:239` — `[invocation retain]`
- `forwarding-common.mm:20,132` — `[invocation release]`
- `memory-utils.h:104,140` — `[invocation release]`

Moving `-fobjc-arc` to `OTHER_CPLUSPLUSFLAGS` would require converting all of these to ARC-compatible patterns and auditing the entire codebase for ARC compatibility. The manual retain/release approach is targeted and safe.

`objc_retain`/`objc_release` are part of the stable ObjC ABI (available since macOS 10.12) but not declared in public SDK headers — they're what the ARC compiler emits calls to. We declare them via `extern "C"` forward declarations.

## Affected Code Paths

Every `ObjcObject::NewInstance` call site now implicitly benefits from the retain. There are 15 call sites across 7 files:

| Path                        | Context                                                             |
| --------------------------- | ------------------------------------------------------------------- |
| `ObjcObject.mm:106`         | Fast-path `$MsgSend` return values (`@`/`#` types)                  |
| `nobjc.mm:35`               | `GetClassObject` — wrapping looked-up ObjC classes                  |
| `nobjc.mm:79`               | `FromPointer` — wrapping raw pointers as objects                    |
| `nobjc_block.h:392`         | `ConvertBlockArgHeuristic` — block args without type encoding       |
| `nobjc_block.h:417`         | `ConvertBlockArgToJS` — typed block args (`@?`)                     |
| `type-conversion.h:254,263` | `ObjCToJSVisitor` — `id`/`Class` from value pointers                |
| `type-conversion.h:334,344` | `ExtractInvocationArgVisitor` — `id`/`Class` from NSInvocation args |
| `type-conversion.h:641,651` | `GetInvocationReturnVisitor` — `id`/`Class` return values           |
| `method-forwarding.mm:73`   | Wrapping `self` for subclass method callbacks                       |
| `protocol-impl.mm:254`      | Wrapping protocol implementation instances                          |
| `subclass-impl.mm:411`      | Returning newly defined subclasses                                  |
| `subclass-impl.mm:562`      | `CallSuperNoArgs` return values                                     |

## Correctness Analysis

### Retain Count Balance by Object Origin

| Object Source                                       | Before Fix                            | After Fix                                                       |
| --------------------------------------------------- | ------------------------------------- | --------------------------------------------------------------- |
| **Autoreleased returns** (most method calls)        | No retain → UAF after pool drain      | +1 retain, -1 on GC → correct                                   |
| **`alloc`/`new`/`copy` returns** (+1 by convention) | No retain, no release → leak          | +1 retain (+2 total), -1 on GC → still leaks one (pre-existing) |
| **Class objects** (infinite retain count)           | No issue                              | No issue (retain/release is no-op)                              |
| **Tagged pointers** (inline values)                 | No issue                              | No issue (`objc_retain` handles correctly)                      |
| **Block callback args** (completion handlers)       | No retain → UAF after handler returns | +1 retain, -1 on GC → correct                                   |
| **NSInvocation extracted args** (forwarding)        | No retain → risk of UAF               | +1 retain, -1 on GC → correct                                   |

The `alloc`/`new`/`copy` leak is pre-existing and orthogonal to this fix. Fixing it would require MRC naming convention analysis (inspecting selector names to determine ownership transfer) and is out of scope.

### Thread Safety

`objc_retain`/`objc_release` are thread-safe (they use atomic reference counting). The `ObjcObject` constructor runs on the JS thread (even for TSFN callbacks, since `BlockTSFNCallback` and `ConvertBlockArgToJS` run on the JS thread after being dispatched via `ThreadSafeFunction`). The destructor runs on the GC finalizer thread, which is also safe for `objc_release`.

### Edge Cases

- **`nil` objects**: Guarded by `if (objcObject)` checks. `objc_retain(nil)` is a no-op but we skip it for clarity.
- **Double-wrap**: If the same ObjC object is wrapped in multiple `ObjcObject` instances, each one independently retains and releases. This is correct — each JS wrapper keeps the native object alive independently.
- **GC timing**: The release happens when V8/JSC garbage collects the `ObjcObject` instance (via the N-API weak reference destructor callback). This may delay deallocation of ObjC objects compared to manual release, but prevents premature deallocation.

## Future Work

### Move `-fobjc-arc` to Correct Build Setting

The `-fobjc-arc` flag should be moved from `OTHER_CFLAGS` to `OTHER_CPLUSPLUSFLAGS` in `binding.gyp`. This would:

1. Make `__strong id objcObject` actually work via ARC (automatic retain on assignment, release on destruction)
2. Eliminate the need for explicit `objc_retain`/`objc_release` in `ObjcObject`
3. Require converting all manual `[invocation retain]`/`[invocation release]` calls to ARC-compatible patterns (e.g., `__strong` locals, `__bridge_retained`/`__bridge_transfer` casts)

### Fix `alloc`/`new`/`copy` Retain Count Leak

Methods following the `alloc`/`new`/`copy`/`mutableCopy` naming convention return +1 retained objects. Since we now add another +1 in the constructor, these leak one reference. Fixing this requires inspecting the selector name at `NewInstance` call sites and conditionally skipping the retain for ownership-transferring methods — or using `objc_autoreleaseReturnValue`/`objc_retainAutoreleasedReturnValue` to participate in the ObjC ABI's fast autorelease optimization.

## Files Changed

- `src/native/ObjcObject.h`: Added `objc_retain` in constructor, `objc_release` in destructor, forward declarations for retain/release functions
