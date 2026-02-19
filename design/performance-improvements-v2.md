# Performance Improvements Plan v2

Further performance bottlenecks and proposed optimizations identified after implementing [v1](./performance-improvements.md). Organized by expected impact across the TypeScript and C++ layers.

---

## HIGH IMPACT — Hot path optimizations

### 1. Eliminate double FFI round-trip per method access — DONE

**File:** `src/ts/index.ts:104`

The `get` trap calls `if (!(methodName in receiver))`, which triggers the `has` trap, which calls `$msgSend("respondsToSelector:", ...)` via FFI. Then the actual method is looked up and invoked — a second FFI call. This means **every uncached method access crosses the native boundary twice**.

Since the method cache (lines 109-118) already stores methods on hit, the `respondsToSelector:` check is only useful on cache miss. Even then, it's redundant: `$msgSend` will fail if the selector doesn't exist.

**Proposed change:** Remove the `in` check entirely. Attempt the `$msgSend` directly and let the native side throw if the selector is invalid. Alternatively, keep a negative result cache (a `Set<string>` of known-bad selectors per object) to avoid repeated FFI calls for non-existent methods.

```typescript
// Before (two FFI calls on cache miss):
if (!(methodName in receiver)) {
  // FFI: respondsToSelector:
  throw new Error(`Method ${methodName} not found`);
}
return NobjcMethod(object, methodName); // FFI: actual $msgSend

// After (one FFI call on cache miss):
let method = cache.get(methodName);
if (!method) {
  method = NobjcMethod(object, methodName); // Will throw natively if invalid
  cache.set(methodName, method);
}
return method;
```

### 2. Avoid Proxy trap overhead in `unwrapArg` — DONE

**File:** `src/ts/index.ts:134-139`

`unwrapArg` checks `NATIVE_OBJC_OBJECT in arg` (triggers Proxy `has` trap) and then accesses `arg[NATIVE_OBJC_OBJECT]` (triggers Proxy `get` trap). That's **two Proxy trap dispatches per argument** on every ObjC method call.

**Proposed change:** Store native objects in a `WeakMap` side-channel, bypassing the Proxy entirely.

```typescript
const nativeObjectMap = new WeakMap<object, NobjcNative.ObjcObject>();

// In NobjcObject constructor:
nativeObjectMap.set(proxy, object);

// New unwrapArg:
function unwrapArg(arg: any): any {
  if (arg && typeof arg === "object") {
    return nativeObjectMap.get(arg) ?? arg;
  }
  return arg;
}
```

This also fixes the same overhead in `getPointer` (line 210-217), which duplicates the `in` + access pattern.

### 3. Cache class objects in `NobjcLibrary` — DONE

**File:** `src/ts/index.ts:39-44`

Every access to `library.NSString` calls `GetClassObject("NSString")` (native FFI call) and creates a new `NobjcObject` wrapper. ObjC class objects are immutable singletons — they never change at runtime.

**Proposed change:** Add a `Map<string, NobjcObject>` cache inside the `get` trap.

```typescript
const classCache = new Map<string, NobjcObject>();
get(_, className: string) {
  let cls = classCache.get(className);
  if (!cls) {
    if (!wasLoaded) { LoadLibrary(library); wasLoaded = true; }
    cls = new NobjcObject(GetClassObject(className));
    classCache.set(className, cls);
  }
  return cls;
}
```

### 4. Add `@autoreleasepool` to `$MsgSend` and forwarding functions — DONE

**File:** `src/native/ObjcObject.mm:51-191`

`$MsgSend` calls `[NSInvocation invocationWithMethodSignature:]` and `[invocation invoke]`, both of which create autoreleased objects. Without an `@autoreleasepool`, these accumulate until an outer pool drains — which in a Node.js event loop may be **never**, causing unbounded memory growth when calling ObjC methods in a loop.

**Affected functions:**

- `$MsgSend` (`ObjcObject.mm:51`)
- `CallJSCallback` (`method-forwarding.mm:21`)
- `ForwardInvocation` (`method-forwarding.mm:229`)
- `RespondsToSelector` (`method-forwarding.mm:176`)
- `MethodSignatureForSelector` (`method-forwarding.mm:205`)
- `GetClassObject` (`nobjc.mm:22`)
- `CallSuperNoArgs` / `CallSuperWithFFI` (`subclass-impl.mm:416,531`)

**Proposed change:** Wrap each function body in `@autoreleasepool { ... }`.

### 5. Stack-allocate selector string in `$MsgSend` — DONE

**File:** `src/native/ObjcObject.mm:60`

`info[0].As<Napi::String>().Utf8Value()` heap-allocates a `std::string` on every `$msgSend` call. This is the hottest path in the entire bridge. Most selector names are under 64 bytes.

**Proposed change:** Use `napi_get_value_string_utf8` with a stack buffer.

```cpp
// Before
std::string selectorName = info[0].As<Napi::String>().Utf8Value();
SEL selector = sel_registerName(selectorName.c_str());

// After
char selectorBuf[128];
size_t selectorLen;
napi_get_value_string_utf8(env, info[0], selectorBuf, sizeof(selectorBuf), &selectorLen);
SEL selector = sel_registerName(selectorBuf);
```

### 6. Replace `NSStringFromSelector` with `sel_getName` — DONE

**Files:** `method-forwarding.mm:183,211,240,247`, `subclass-impl.mm:52,83,123`

`NSStringFromSelector(selector)` creates an `NSString*` (ObjC heap allocation + autorelease pool entry), then `[selectorString UTF8String]` extracts a C string, then it's often copied into `std::string`. That's 2+ allocations for something `sel_getName()` returns directly as a `const char*` with **zero allocation**.

**Proposed change:**

```cpp
// Before (3 allocations)
NSString *selectorString = NSStringFromSelector(selector);
std::string selName = [selectorString UTF8String];

// After (1 allocation, for the std::string only)
std::string selName(sel_getName(selector));

// Or with string_view (0 allocations)
const char* selNameCStr = sel_getName(selector);
```

### 7. Combine `ProtocolImplementation`'s three separate maps — DONE

**File:** `src/native/protocol-storage.h:48-52`

`callbacks`, `jsCallbacks`, and `typeEncodings` are three separate `unordered_map<string, ...>` keyed by the same selector name. Every forwarded method call requires three separate hash lookups across three separate heap-allocated hash table structures.

**Proposed change:** Combine into a single map.

```cpp
// Before
std::unordered_map<std::string, Napi::ThreadSafeFunction> callbacks;
std::unordered_map<std::string, Napi::FunctionReference> jsCallbacks;
std::unordered_map<std::string, std::string> typeEncodings;

// After
struct MethodInfo {
  Napi::ThreadSafeFunction tsfn;
  Napi::FunctionReference jsCallback;
  std::string typeEncoding;
};
std::unordered_map<std::string, MethodInfo> methods;
```

This matches the pattern already used in `SubclassImplementation::methods`.

---

## MEDIUM IMPACT

### 8. Specialize `NobjcMethod` for common argument counts — DONE

**File:** `src/ts/index.ts:157,161`

`NobjcMethod` uses `...args` (rest params, always allocates an array) and `object.$msgSend(selector, ...args)` (spread). Zero-argument ObjC messages (`obj.init()`, `obj.retain()`, `obj.description()`) are extremely common but still allocate an empty array and spread it.

**Proposed change:** Add fast paths for 0-3 arguments.

```typescript
function methodFunc(...args: any[]): any {
  switch (args.length) {
    case 0:
      return wrapObjCObjectIfNeeded(object.$msgSend(selector));
    case 1:
      return wrapObjCObjectIfNeeded(object.$msgSend(selector, unwrapArg(args[0])));
    case 2:
      return wrapObjCObjectIfNeeded(object.$msgSend(selector, unwrapArg(args[0]), unwrapArg(args[1])));
    default:
      for (let i = 0; i < args.length; i++) args[i] = unwrapArg(args[i]);
      return wrapObjCObjectIfNeeded(object.$msgSend(selector, ...args));
  }
}
```

### 9. Cache `toString` function and capability check — DONE

**File:** `src/ts/index.ts:90-97`

Every `.toString` **access** (not call) allocates a new arrow function closure. Additionally, `"UTF8String" in receiver` (line 92) triggers the `has` trap, which calls `$msgSend("respondsToSelector:", "UTF8String")` — an FFI round-trip just to decide how to format.

**Proposed change:** Cache the toString function in the method cache alongside regular methods.

```typescript
if (methodName === "toString") {
  let cache = methodCache.get(object);
  if (!cache) {
    cache = new Map();
    methodCache.set(object, cache);
  }
  let fn = cache.get("toString");
  if (!fn) {
    const hasUTF8 = target.$msgSend("respondsToSelector:", "UTF8String") as boolean;
    fn = hasUTF8
      ? () => String(object.$msgSend("UTF8String"))
      : () => String(wrapObjCObjectIfNeeded(object.$msgSend("description")));
    cache.set("toString", fn);
  }
  return fn;
}
```

### 10. Mutate args in-place in protocol/class callbacks — DONE

**Files:** `src/ts/index.ts:176,368,424`

`args.map(...)` allocates a new array on every callback invocation. These fire on every delegate/protocol method call (e.g., `tableView:cellForRowAtIndexPath:` during scrolling). `NobjcClass.super` (line 424) has the same issue with `args.map(unwrapArg)`.

**Proposed change:** Use in-place mutation (same pattern already used in `NobjcMethod`).

```typescript
// Before (index.ts:174-178)
convertedMethods[selector] = function (...args: any[]) {
  const wrappedArgs = args.map((arg) => {
    return wrapObjCObjectIfNeeded(arg);
  });
  const result = impl(...wrappedArgs);

// After
convertedMethods[selector] = function (...args: any[]) {
  for (let i = 0; i < args.length; i++) {
    args[i] = wrapObjCObjectIfNeeded(args[i]);
  }
  const result = impl(...args);
```

Same for `NobjcClass.define` (line 368) and `NobjcClass.super` (line 424).

### 11. Move `customInspectSymbol` into Proxy `get` trap — DONE

**File:** `src/ts/index.ts:127`

`(object as any)[customInspectSymbol] = () => proxy.toString()` mutates the native `ObjcObject` instance after construction. In V8, adding properties after construction causes **hidden class transitions**, which deoptimize inline caches for all subsequent property accesses on objects of the same class.

**Proposed change:** Handle `customInspectSymbol` inside the Proxy's `get` trap instead of mutating the native object.

```typescript
// Remove line 127 entirely. Add to the get trap:
if (methodName === customInspectSymbol) {
  return () => proxy.toString();
}
```

### 12. Use small-buffer optimization for `storedArgs` — DONE

**File:** `src/native/ObjcObject.mm:129-133`

`std::vector<ObjcType> storedArgs` and `std::vector<std::vector<uint8_t>> structBuffers` are heap-allocated on every `$MsgSend` call, even with `reserve`. Most methods have 0-3 arguments.

**Proposed change:** Use a fixed-size stack buffer for the common case.

```cpp
// A simple small-buffer approach:
// Stack-allocate for <=4 args, heap for larger
constexpr size_t kSmallArgCount = 4;
ObjcType smallArgBuf[kSmallArgCount];
std::vector<ObjcType> heapArgBuf;
auto& storedArgs = (expectedArgCount <= kSmallArgCount)
    ? /* use smallArgBuf via span */ : heapArgBuf;
```

Alternatively, use a `llvm::SmallVector`-style container if available, or a simple inline buffer wrapper.

### 13. Defer `className` construction to error path only — DONE

**File:** `src/native/ObjcObject.mm:136`

`const std::string className(object_getClassName(objcObject))` heap-allocates on every `$MsgSend` call, but is only used inside `ObjcArgumentContext` — which only matters when argument conversion fails (the rare error path).

**Proposed change:** Store the raw `const char*` and defer `std::string` construction to error paths.

```cpp
// Before
const std::string className(object_getClassName(objcObject));

// After
const char* classNameCStr = object_getClassName(objcObject);
// Only construct std::string in error formatting if needed
```

This requires changing `ObjcArgumentContext::className` from `std::string` to `const char*` or `std::string_view` (see item 14).

### 14. Use `string_view` in `ObjcArgumentContext` — DONE

**File:** `src/native/bridge.h:68-72`

`ObjcArgumentContext` has `std::string className` and `std::string selectorName` members that get **copied** on every loop iteration in `$MsgSend` (lines 139-143). The struct is always constructed from existing strings that outlive the context.

**Proposed change:**

```cpp
// Before
struct ObjcArgumentContext {
  std::string className;
  std::string selectorName;
  int argumentIndex;
};

// After
struct ObjcArgumentContext {
  std::string_view className;
  std::string_view selectorName;
  int argumentIndex;
};
```

Combined with item 13, this eliminates all string copies in the argument loop.

### 15. Reduce lock acquisitions per forwarded invocation — DONE

**Files:** `method-forwarding.mm:180,208,255-341`, `subclass-impl.mm:47,79,142`

A single forwarded method call acquires the `ProtocolManager` mutex 3+ times: `RespondsToSelector` (line 180) -> `MethodSignatureForSelector` (line 208) -> `ForwardInvocation` (which itself does `lookupContext` + `getJSFunction` + `reacquireTSFN`, each acquiring again at lines 257, 304, 322).

**Proposed change:** Cache the lookup result from `RespondsToSelector` using ObjC associated objects or thread-local storage, so subsequent calls in the same forwarding pipeline don't re-lookup.

```objc
// In RespondsToSelector: store result
objc_setAssociatedObject(self, selector, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

// In MethodSignatureForSelector: use cached result instead of re-locking
```

Alternatively, combine `RespondsToSelector` + `MethodSignatureForSelector` into a single locked lookup that returns both pieces of information.

### 16. Use `shared_mutex` for `SubclassManager` — DONE

**File:** `src/native/subclass-manager.h:164`

`SubclassManager` uses `std::mutex` — all operations (including reads like `Find`, `Contains`, `FindSuperClassInHierarchy`) take an exclusive lock. Reads are far more frequent than writes (registration happens once, lookups happen on every forwarded call).

**Proposed change:** Change to `std::shared_mutex` with `shared_lock` for reads, matching the pattern already used in `ProtocolManager`.

### 17. Use `WithLockConst` for read-only ProtocolManager lookups — DONE

**Files:** `method-forwarding.mm:180,208`

`RespondsToSelector` and `MethodSignatureForSelector` only read the map, but call `WithLock` (exclusive lock) instead of `WithLockConst` (shared lock).

**Proposed change:** Change to `WithLockConst` for these read-only call sites. `ProtocolManager` already has `WithLockConst` available.

---

## LOWER IMPACT (good hygiene)

### 18. Remove redundant `p.toString()` in `has` trap

**File:** `src/ts/index.ts:73`

By line 73, `typeof p === "symbol"` has already been filtered (line 68), so `p` is guaranteed to be a `string`. The `.toString()` call is a no-op method dispatch.

```typescript
// Before
return target.$msgSend("respondsToSelector:", NobjcMethodNameToObjcSelector(p.toString()));

// After
return target.$msgSend("respondsToSelector:", NobjcMethodNameToObjcSelector(p));
```

### 19. Extract `try/catch` from `has` trap hot path

**File:** `src/ts/index.ts:72-76`

The `has` trap runs on every method access (via the `in` check at line 104). A `try/catch` in a hot path may inhibit TurboFan optimization in some V8 versions.

**Proposed change:** Extract to a separate helper function so the JIT can optimize the hot path independently.

```typescript
function respondsToSelector(target: NobjcNative.ObjcObject, name: string): boolean {
  try {
    return target.$msgSend("respondsToSelector:", NobjcMethodNameToObjcSelector(name)) as boolean;
  } catch (e) {
    return false;
  }
}
```

Note: This becomes less relevant if item 1 (removing the `in` check) is implemented.

### 20. Use `replaceAll` with string argument instead of RegExp

**File:** `src/ts/index.ts:52,56`

```typescript
// Before
return methodName.replace(/\$/g, ":");
return selector.replace(/:/g, "$");

// After
return methodName.replaceAll("$", ":");
return selector.replaceAll(":", "$");
```

Avoids RegExp object entirely. Simpler and marginally faster.

### 21. Improve hash combiner for method signature cache

**File:** `src/native/ObjcObject.mm:22`

`h1 ^ (h2 << 1)` is a weak hash combiner for aligned pointers (which are typically multiples of 8 or 16, causing poor bit distribution).

```cpp
// Before
return h1 ^ (h2 << 1);

// After (golden ratio mixing)
return h1 ^ (h2 * 0x9e3779b97f4a7c15ULL + 0x9e3779b97f4a7c15ULL);
```

### 22. Replace `strlen` with single-char check

**File:** `src/native/ObjcObject.mm:113`

`strlen(returnType)` scans the entire string but we only need to know if it's a single character.

```cpp
// Before
strlen(returnType) != 1

// After
returnType[0] == '\0' || returnType[1] != '\0'
```

### 23. Replace `strchr` linear scan with lookup table

**File:** `src/native/ObjcObject.mm:114`

`strchr(validReturnTypes, *returnType)` linearly scans 18 characters on every `$MsgSend` call.

```cpp
// Before
const char *validReturnTypes = "cislqCISLQfdB*v@#:";
if (strchr(validReturnTypes, *returnType) == nullptr) { ... }

// After (compile-time lookup table)
static constexpr bool validReturnType[256] = {
  ['c']=1,['i']=1,['s']=1,['l']=1,['q']=1,
  ['C']=1,['I']=1,['S']=1,['L']=1,['Q']=1,
  ['f']=1,['d']=1,['B']=1,['*']=1,['v']=1,
  ['@']=1,['#']=1,[':']=1,
};
if (!validReturnType[(unsigned char)*returnType]) { ... }
```

### 24. Avoid `std::function` heap allocation in `ForwardingCallbacks`

**File:** `src/native/forwarding-common.h:50-66`

Three `std::function` objects are constructed per forwarded invocation. Each `std::function` that captures variables may heap-allocate (small-buffer optimization varies by stdlib implementation).

**Proposed change:** Use a virtual interface or template `ForwardInvocationCommon` on the callback struct to avoid `std::function` overhead entirely.

```cpp
// Before
struct ForwardingCallbacks {
  std::function<std::optional<ForwardingContext>(void*, const std::string&)> lookupContext;
  std::function<Napi::Function(void*, const std::string&, Napi::Env)> getJSFunction;
  std::function<std::optional<Napi::ThreadSafeFunction>(void*, const std::string&)> reacquireTSFN;
};

// After
struct ForwardingCallbacks {
  virtual std::optional<ForwardingContext> lookupContext(void*, const std::string&) = 0;
  virtual Napi::Function getJSFunction(void*, const std::string&, Napi::Env) = 0;
  virtual std::optional<Napi::ThreadSafeFunction> reacquireTSFN(void*, const std::string&) = 0;
  virtual ~ForwardingCallbacks() = default;
};
```

### 25. Deduplicate `KNOWN_STRUCT_FIELDS` across translation units

**File:** `src/native/struct-utils.h:41-58`

Declared `static` in a header, so every `.mm` file that includes it gets its own copy. For ~10 entries with string keys, cache locality is poor (hash table nodes scattered across the heap).

**Proposed change:** Use a flat `constexpr` array with linear scan (faster for small N due to cache locality) and declare it `inline` to deduplicate across TUs.

```cpp
struct KnownStructEntry {
  const char* name;
  const char* fields[4];  // max 4 fields
  size_t fieldCount;
};

inline constexpr KnownStructEntry KNOWN_STRUCT_FIELDS[] = {
  {"CGPoint", {"x", "y"}, 2},
  {"CGSize",  {"width", "height"}, 2},
  {"CGRect",  {"origin", "size"}, 2},
  {"NSRange", {"location", "length"}, 2},
  // ...
};
```

### 26. Use `__unsafe_unretained` for `ObjcObject::NewInstance` parameter

**File:** `src/native/ObjcObject.mm:43`

The `id obj` parameter is `__strong` by default under ARC. ARC inserts a retain on function entry and a release on exit, in addition to the retain in the constructor assignment — **an extra retain/release pair per returned object**.

```cpp
// Before
Napi::Object ObjcObject::NewInstance(Napi::Env env, id obj)

// After (caller must guarantee obj is alive)
Napi::Object ObjcObject::NewInstance(Napi::Env env, __unsafe_unretained id obj)
```

### 27. Enable heterogeneous lookup for string-keyed maps

**Files:** All `unordered_map<std::string, ...>::find(selName)` call sites

Every lookup constructs a `std::string` from `const char*` just for the hash+compare, even though the map already stores strings. C++20 transparent/heterogeneous lookup allows querying with `std::string_view` without constructing a temporary `std::string`.

```cpp
// C++20 heterogeneous lookup support
struct StringHash {
  using is_transparent = void;
  size_t operator()(std::string_view sv) const { return std::hash<std::string_view>{}(sv); }
  size_t operator()(const std::string& s) const { return std::hash<std::string>{}(s); }
  size_t operator()(const char* s) const { return std::hash<std::string_view>{}(s); }
};
struct StringEqual {
  using is_transparent = void;
  bool operator()(std::string_view a, std::string_view b) const { return a == b; }
};

std::unordered_map<std::string, MethodInfo, StringHash, StringEqual> methods;
// Now: methods.find(string_view_or_cstr) — no allocation
```

---

## Summary Table

| #   | Area | Impact | Effort  | Status | Description                                               |
| --- | ---- | ------ | ------- | ------ | --------------------------------------------------------- |
| 1   | TS   | High   | Low     | ✅     | Eliminate double FFI round-trip per method access         |
| 2   | TS   | High   | Low     | ✅     | Avoid Proxy trap overhead in `unwrapArg`                  |
| 3   | TS   | High   | Trivial | ✅     | Cache class objects in `NobjcLibrary`                     |
| 4   | C++  | High   | Low     | ✅     | Add `@autoreleasepool` to `$MsgSend` and forwarding funcs |
| 5   | C++  | High   | Low     | ✅     | Stack-allocate selector string in `$MsgSend`              |
| 6   | C++  | High   | Low     | ✅     | Replace `NSStringFromSelector` with `sel_getName`         |
| 7   | C++  | High   | Medium  | ✅     | Combine `ProtocolImplementation`'s three maps into one    |
| 8   | TS   | Medium | Low     | ✅     | Specialize `NobjcMethod` for common argument counts       |
| 9   | TS   | Medium | Low     | ✅     | Cache `toString` function and capability check            |
| 10  | TS   | Medium | Trivial | ✅     | Mutate args in-place in protocol/class callbacks          |
| 11  | TS   | Medium | Trivial | ✅     | Move `customInspectSymbol` into Proxy `get` trap          |
| 12  | C++  | Medium | Medium  | ✅     | Use small-buffer optimization for `storedArgs`            |
| 13  | C++  | Medium | Trivial | ✅     | Defer `className` construction to error path only         |
| 14  | C++  | Medium | Low     | ✅     | Use `string_view` in `ObjcArgumentContext`                |
| 15  | C++  | Medium | Medium  | ✅     | Reduce lock acquisitions per forwarded invocation         |
| 16  | C++  | Medium | Low     | ✅     | Use `shared_mutex` for `SubclassManager`                  |
| 17  | C++  | Medium | Trivial | ✅     | Use `WithLockConst` for read-only ProtocolManager lookups |
| 18  | TS   | Low    | Trivial |        | Remove redundant `p.toString()` in `has` trap             |
| 19  | TS   | Low    | Trivial |        | Extract `try/catch` from `has` trap hot path              |
| 20  | TS   | Low    | Trivial |        | Use `replaceAll` with string arg instead of RegExp        |
| 21  | C++  | Low    | Trivial |        | Improve hash combiner for method signature cache          |
| 22  | C++  | Low    | Trivial |        | Replace `strlen` with single-char check                   |
| 23  | C++  | Low    | Trivial |        | Replace `strchr` linear scan with lookup table            |
| 24  | C++  | Low    | Medium  |        | Avoid `std::function` heap allocation in forwarding       |
| 25  | C++  | Low    | Low     |        | Deduplicate `KNOWN_STRUCT_FIELDS` across TUs              |
| 26  | C++  | Low    | Trivial |        | Use `__unsafe_unretained` for `NewInstance` parameter     |
| 27  | C++  | Low    | Low     |        | Enable heterogeneous lookup for string-keyed maps         |

## Notes

- Items 1-3 are pure TypeScript changes and can be benchmarked immediately with the existing `benchmarks/bench.ts` suite.
- Item 4 (`@autoreleasepool`) is a correctness fix as much as a performance fix — without it, memory can grow unboundedly in tight loops.
- Items 13-14 are tightly coupled and should be implemented together.
- Item 19 becomes irrelevant if item 1 is implemented (the `has` trap would no longer be called from `get`).
- Items 15-17 are all related to lock contention in the forwarding path and could be addressed together.
- The existing benchmark suite can measure the impact of most of these changes. The `$msgSend throughput` and `method proxy access` categories are most relevant for items 1-3, 5, 8. The `struct operations` category covers items 12-14, 25.
