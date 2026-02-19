# Performance Improvements v3

Sorted by estimated impact (largest first). Reference: simple `$msgSend` is ~486 ns/op today.

---

## Tier 1 — High Impact

- [x] **Replace NSInvocation with direct `objc_msgSend` for common signatures** (`ObjcObject.mm:135-210`). NSInvocation adds ~200-400ns per call. For 0-3 pointer/int args returning a pointer, cast `objc_msgSend` to the correct fptr type and call directly. libffi is already linked but unused on the hot path. Could yield 2-5x speedup on simple calls.

- [x] **Add `$prepareSend`/`$msgSendPrepared` to cache SEL + method signature natively** (`ObjcObject.mm:62-100`, `index.ts:178-179`). Every `$msgSend` re-extracts the selector string, calls `sel_registerName`, `respondsToSelector:`, and does a cache lookup. A one-time `$prepareSend(selector)` returns an opaque handle; `$msgSendPrepared(handle, ...args)` skips all of that. Saves ~100-200ns per call.

- [x] **Specialize struct pack/unpack for CGRect, CGPoint, CGSize, NSRange** (`struct-utils.h`). CGRect roundtrip is 40,351 ns/op. Hand-coded fast paths skip recursive parsing, generic dispatch, and redundant N-API calls. Estimated savings: ~1,000-2,000ns per CGRect roundtrip.

- [x] **Eliminate double `respondsToSelector:` FFI round-trip on cache miss** (`index.ts:138` + `ObjcObject.mm:78`). JS `get` trap calls `respondsToSelector:` via full `$msgSend` machinery, then the actual `$msgSend` checks it again. Add a lightweight native `$respondsToSelector(string)` that skips NSInvocation, or remove the JS-side check entirely and catch the native error.

- [x] **Key forwarding maps on `SEL` instead of `std::string`** (`protocol-storage.h:55,86`). Every forwarded call hashes the full selector string O(n). SEL is an interned pointer — hash is O(1), compare is one instruction. Eliminates all `std::string` construction from the forwarding hot path.

## Tier 2 — Medium Impact

- [ ] **Use shared locks (`WithLockConst`) in forwarding lookup lambdas** (`method-forwarding.mm:264`, `subclass-impl.mm:146`). All six forwarding lambdas take exclusive locks but only read from the map. `tsfn.Acquire()` is atomic and doesn't need exclusive access. Serializes all concurrent forwarded calls unnecessarily.

- [ ] **Enable LTO and -O2 in binding.gyp** (`binding.gyp:27-37`). No optimization level is set (defaults to `-Os`). Add `"GCC_OPTIMIZATION_LEVEL": "2"`, `"LLVM_LTO": "YES_THIN"`, `"GCC_SYMBOLS_PRIVATE_EXTERN": "YES"`. Estimated 5-15% improvement on hot paths.

- [ ] **Use `arguments` object instead of rest params in `NobjcMethod`** (`index.ts:182`). `...args` always allocates a JS Array even for 0-arg calls. Using `arguments[i]` directly in the switch cases avoids the allocation entirely. Saves ~20-40ns per call.

- [ ] **Eliminate 3 `std::function` heap allocations per forwarded call** (`forwarding-common.h:87-107`). `ForwardingCallbacks` contains three `std::function` members that exceed SBO. Template `ForwardInvocationCommon` on a policy struct with static methods instead. Saves ~150-300ns per forwarded invocation.

- [ ] **Stack-allocate `InvocationData` on the direct-call path** (`forwarding-common.mm:28`). Every forwarded call heap-allocates `InvocationData` with two `std::string` members. On the same-thread path, the data doesn't escape — use a stack local. Saves ~100-200ns.

- [ ] **Identity-cache returned `NobjcObject` proxies** (`index.ts:166-171`). Every ObjC object return creates a new Proxy + WeakMap entry. Use `Map<pointer, WeakRef<Proxy>>` + FinalizationRegistry to reuse existing proxies for the same `id`. Reduces GC pressure and enables `===` identity.

- [ ] **Pre-create persistent JS string keys for common struct field names** (`struct-utils.h:447,502`). Each `Get("x")`/`Set("width")` converts a C++ string to a JS string via N-API. Cache `Napi::Reference<Napi::String>` for "x", "y", "width", "height", "origin", "size". Saves ~200-400ns per CGRect.

- [ ] **Use `const char*` / `string_view` for selector name throughout forwarding** (`method-forwarding.mm:253`, `forwarding-common.mm:30`). `sel_getName()` returns an interned `const char*` valid forever. Currently copied into `std::string` 2-3 times per forwarded call. Change `InvocationData::selectorName` to `const char*`.

## Tier 3 — Low Impact

- [ ] **Stack-allocate struct pack buffer for <= 64 bytes** (`struct-utils.h:535`). `std::vector<uint8_t>` heap-allocates per struct arg. CGRect is 32 bytes — use a stack buffer. Saves ~50-100ns per struct pack.

- [ ] **Stack-allocate `jsArgs` array in `CallJSCallback`** (`method-forwarding.mm:65`). `std::vector<napi_value>` heap-allocates. Use `napi_value stackArgs[8]` for the common case. Saves ~50-100ns per forwarded call.

- [ ] **Cache `has` trap results in methodCache** (`index.ts:79-84`). The `in` operator does a full `$msgSend` round-trip every time. If a method is already cached from a prior `get`, return `true` immediately.

- [ ] **Avoid redundant `typeof + instanceof ObjcObject` in `wrapObjCObjectIfNeeded`** (`index.ts:167`). `instanceof` on N-API wrapped objects crosses the native boundary. Use a symbol tag or move the wrapping decision to the native side.

- [ ] **Remove `@autoreleasepool` from `RespondsToSelector`** (`method-forwarding.mm:179`, `subclass-impl.mm:44`). These functions don't create autoreleased objects. Each pool push/pop costs ~20-50ns.

- [ ] **Use `std::string_view` key in struct encoding cache lookup** (`struct-utils.h:286-287`). Currently constructs a `std::string` on every cache hit just for the map key. Saves ~30-80ns per struct op.

- [ ] **Pre-compute simplified type code char in `StructFieldInfo`** (`struct-utils.h:384,476`). `SimplifyTypeEncoding` is re-called per leaf field on every pack/unpack. Store a single `char typeCode` during parse.

- [ ] **Remove `.toString()` on already-string `p` in `has` trap** (`index.ts:81`). `p` is guaranteed `string` at that point. Unnecessary call that also prevents V8 type specialization.

- [ ] **Change `ForwardingContext::typeEncoding` to `const char*`** (`forwarding-common.h:64`). Points into the map-owned string. Avoids a copy per forwarded call.

- [ ] **Fix `FindSuperClassInHierarchy` bug + single-lock hierarchy walk** (`subclass-manager.h:125-140`). Early `return nullptr` prevents hierarchy walking. Fix the loop and acquire the lock once instead of per-iteration.

- [ ] **Add `-fobjc-arc` to `OTHER_CPLUSPLUSFLAGS`** (`binding.gyp:30-33`). Currently only in `OTHER_CFLAGS`. Fragile — may not apply to `.mm` files on all toolchain versions.

- [ ] **Cache `[sig numberOfArguments]` before loop** (`method-forwarding.mm:81`). Called in loop condition on every iteration. Trivial fix.

- [ ] **Replace `std::ostringstream` with `snprintf` in protocol class name generation** (`protocol-impl.mm:118-120`). `ostringstream` costs ~1-5us. Registration-time only.

- [ ] **Change `KNOWN_STRUCT_FIELDS` from `static` to `inline`** (`struct-utils.h:41`). `static` in a header duplicates the map per translation unit.

- [ ] **Skip TSFN acquire/release on direct-call path** (`forwarding-common.mm:51`, `method-forwarding.mm:279`). The TSFN is acquired then immediately released on same-thread calls. Accept a `bool acquireTSFN` parameter.
