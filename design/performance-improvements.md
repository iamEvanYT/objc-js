# Performance Improvements Plan

Identified performance bottlenecks and proposed optimizations, organized by expected impact.

---

## HIGH IMPACT — Hot path optimizations

### 1. Cache `NobjcMethod` proxies per object

**File:** `src/ts/index.ts:136-147`

Every property access on a `NobjcObject` creates a **new function + new Proxy** via `NobjcMethod()`. For code like `obj.doSomething$(arg)`, the method proxy is created, called once, then garbage collected. If a method is called in a loop, this is significant GC pressure.

**Proposed change:** Add a `WeakMap<NobjcNative.ObjcObject, Map<string, NobjcMethod>>` cache. On the `get` trap, return a cached method proxy if one exists for that selector.

```typescript
const methodCache = new WeakMap<NobjcNative.ObjcObject, Map<string, NobjcMethod>>();

// In the get trap:
let cache = methodCache.get(object);
if (!cache) {
  cache = new Map();
  methodCache.set(object, cache);
}
let method = cache.get(methodName);
if (!method) {
  method = NobjcMethod(object, methodName);
  cache.set(methodName, method);
}
return method;
```

### 2. Hoist `builtInProps` to module scope

**File:** `src/ts/index.ts:82-94`

The `builtInProps` array is recreated as a new array literal on **every single property access**. It should be a module-level `Set` for O(1) lookups instead of an array with `.includes()` (O(n)).

```typescript
// Before (line 82-96, runs every get)
const builtInProps = ["constructor", "valueOf", ...];
if (builtInProps.includes(methodName)) { ... }

// After (module scope, runs once)
const BUILT_IN_PROPS = new Set([
  "constructor",
  "valueOf",
  "hasOwnProperty",
  "isPrototypeOf",
  "propertyIsEnumerable",
  "toLocaleString",
  "__proto__",
  "__defineGetter__",
  "__defineSetter__",
  "__lookupGetter__",
  "__lookupSetter__"
]);

// In get trap:
if (BUILT_IN_PROPS.has(methodName)) { ... }
```

### 3. Cache struct encoding parse results

**File:** `src/native/struct-utils.h:506-536`

`ParseStructEncodingWithNames` is called on **every struct argument and return value** — each time it re-parses the type encoding string, calls `NSGetSizeAndAlignment`, and builds `ParsedStructType` with nested vectors. Struct encodings like `{CGRect={CGPoint=dd}{CGSize=dd}}` are always identical for the same type.

**Proposed change:** Add a `static std::unordered_map<std::string, ParsedStructType>` cache keyed by the encoding string. This eliminates repeated parsing of the same struct types (CGRect, NSRange, CGPoint, etc.).

```cpp
inline const ParsedStructType& GetOrParseStructEncoding(const char *encoding) {
  static std::unordered_map<std::string, ParsedStructType> cache;
  std::string key(encoding);
  auto it = cache.find(key);
  if (it != cache.end()) {
    return it->second;
  }
  auto [inserted, _] = cache.emplace(key, ParseStructEncodingWithNames(encoding));
  return inserted->second;
}
```

Then update `PackJSValueAsStruct` and `UnpackStructToJSValue` to use the cached version.

---

## MEDIUM IMPACT

### 4. Use `unordered_map` for `KNOWN_STRUCT_FIELDS`

**File:** `src/native/struct-utils.h:40`

Currently uses `std::map` (red-black tree, O(log n) lookup). Since this is a simple string-keyed lookup table with no ordering requirement, `std::unordered_map` gives O(1) average lookup.

```cpp
// Before
static const std::map<std::string, std::vector<std::string>> KNOWN_STRUCT_FIELDS = { ... };

// After
static const std::unordered_map<std::string, std::vector<std::string>> KNOWN_STRUCT_FIELDS = { ... };
```

### 5. Avoid redundant `className` string construction per argument

**File:** `src/native/ObjcObject.mm:107-108`

Inside the argument loop of `$MsgSend`, `object_getClassName(objcObject)` is converted to a `std::string` for every argument via the `ObjcArgumentContext`. This should be hoisted above the loop:

```cpp
// Before: inside loop at line 108
for (size_t i = 1; i < info.Length(); ++i) {
  const ObjcArgumentContext context = {
      .className = std::string(object_getClassName(objcObject)), // allocates each iteration
      ...
  };
}

// After: hoist above loop
const std::string className(object_getClassName(objcObject));
for (size_t i = 1; i < info.Length(); ++i) {
  const ObjcArgumentContext context = {
      .className = className,
      ...
  };
}
```

### 6. Eliminate unnecessary `NobjcMethod` Proxy wrapper

**File:** `src/ts/index.ts:145-146`

The `NobjcMethod` creates a Proxy around the function, but the handler is an **empty object** `{}` — it intercepts nothing. The Proxy adds overhead for zero functionality. Just return the raw function instead.

```typescript
// Before
const handler: ProxyHandler<any> = {};
return new Proxy(methodFunc, handler) as NobjcMethod;

// After
return methodFunc as NobjcMethod;
```

### 7. Replace `Array.from(arguments).map(unwrapArg)` with a loop

**File:** `src/ts/index.ts:141`

`Array.from(arguments)` creates an intermediate array, then `.map()` creates another. A simple rest parameter with in-place mutation avoids both allocations:

```typescript
// Before
function methodFunc(): any {
  const unwrappedArgs = Array.from(arguments).map(unwrapArg);
  const result = object.$msgSend(selector, ...unwrappedArgs);
  return wrapObjCObjectIfNeeded(result);
}

// After
function methodFunc(...args: any[]): any {
  for (let i = 0; i < args.length; i++) {
    args[i] = unwrapArg(args[i]);
  }
  return wrapObjCObjectIfNeeded(object.$msgSend(selector, ...args));
}
```

---

## LOWER IMPACT (good hygiene)

### 8. Reduce mutex acquisitions in forwarding path

**File:** `src/native/method-forwarding.mm:180-298`

`RespondsToSelector` and `MethodSignatureForSelector` each acquire the global `ProtocolManager` mutex on every call. Then `ForwardInvocation` acquires it again. For a single ObjC message forward, the mutex is acquired 3+ times.

**Proposed change:** Consider a combined lookup function that returns all needed data (responds yes/no, method signature, TSFN, JS callback) in a single lock acquisition. Alternatively, use a `shared_mutex` with `shared_lock` for reads and `unique_lock` only for writes (registration/dealloc).

### 9. Cache `methodSignatureForSelector:` results on the native side

**File:** `src/native/ObjcObject.mm:50-51`

Every `$msgSend` calls `[objcObject methodSignatureForSelector:]` and `[objcObject respondsToSelector:]`. The ObjC runtime has its own caching, so this may not be a bottleneck in practice, but for very hot paths (calling the same method in a tight loop), a C++ side cache keyed by `(Class, SEL)` could help.

**Proposed change:** Use a `static std::unordered_map<std::pair<Class, SEL>, NSMethodSignature*>` (or a small LRU cache) to avoid redundant ObjC runtime calls for repeated `$msgSend` invocations on the same class/selector pair.

---

## Summary Table

| #   | Area | Impact | Effort  | Description                                               |
| --- | ---- | ------ | ------- | --------------------------------------------------------- |
| 1   | TS   | High   | Low     | Cache method proxies per object                           |
| 2   | TS   | High   | Trivial | Hoist `builtInProps` to module-scope `Set`                |
| 3   | C++  | High   | Low     | Cache parsed struct encodings                             |
| 4   | C++  | Medium | Trivial | `std::map` -> `std::unordered_map` for struct field names |
| 5   | C++  | Medium | Trivial | Hoist `className` string above argument loop              |
| 6   | TS   | Medium | Trivial | Remove no-op Proxy wrapper on method functions            |
| 7   | TS   | Medium | Trivial | Avoid double array allocation in method calls             |
| 8   | C++  | Low    | Medium  | Reduce mutex acquisitions in forwarding path              |
| 9   | C++  | Low    | Medium  | Cache method signatures on C++ side                       |

## Notes

- No benchmark suite currently exists. Creating one (even a simple one measuring `$msgSend` calls/second for common operations) would help validate and measure the impact of these changes.
- Debug logging is already compiled out (`NOBJC_DEBUG 0`), which is good.
- The direct-call vs TSFN path optimization and `cachedJsCallback` in `ForwardingContext` are already well-done existing optimizations.
- `NobjcLibrary` already lazily loads frameworks, which is correct.
