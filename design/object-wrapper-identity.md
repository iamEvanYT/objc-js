# Object Wrapper Identity and Instance Data Storage

## Issue

When storing instance data on subclassed Objective-C objects using JavaScript's `WeakMap`, the data could not be retrieved later, even though the same native object was being used:

```typescript
const state = new WeakMap<any, Data>();

// In method 1:
state.set(self, data); // Store data

// In method 2 (same native object):
if (state.has(self)) {
  // Returns false! ❌
  const data = state.get(self);
}
```

## Root Cause

Each call to `ObjcObject::NewInstance()` creates a **new JavaScript wrapper object**, even when wrapping the same native pointer:

```cpp
// src/native/ObjcObject.mm (line 22-28)
Napi::Object ObjcObject::NewInstance(Napi::Env env, id obj) {
  Napi::EscapableHandleScope scope(env);
  Napi::Object jsObj = constructor.New({Napi::External<id>::New(env, &obj)});
  return scope.Escape(jsObj).ToObject();
  // ⚠️ Always creates a NEW JavaScript object
}
```

**The problem**: JavaScript's `WeakMap` uses **object identity** for keys. Even though two wrapper objects point to the same native object (`0x1140387ab80` in the logs), they are different JavaScript objects, so `WeakMap` treats them as different keys.

## Example

```javascript
// Native pointer: 0x1140387ab80
const wrapper1 = ObjcObject.NewInstance(env, nativePtr); // JS object #1
const wrapper2 = ObjcObject.NewInstance(env, nativePtr); // JS object #2

// Even though both wrap the same native pointer:
console.log(wrapper1 === wrapper2); // false ❌

// WeakMap fails:
const map = new WeakMap();
map.set(wrapper1, "data");
map.has(wrapper2); // false ❌
```

## Why We Don't Cache Wrappers

We could implement a cache to reuse wrapper objects:

```cpp
// Hypothetical caching (NOT implemented)
static std::unordered_map<id, Napi::ObjectReference> wrapperCache;

Napi::Object ObjcObject::NewInstance(Napi::Env env, id obj) {
    if (wrapperCache.contains(obj)) {
        return wrapperCache[obj].Value();  // Reuse existing wrapper
    }
    // Create new wrapper and cache it...
}
```

**Why we don't do this**:

1. **Memory management complexity**: Who owns the wrapper? When should it be released?
2. **Lifetime issues**: Native objects can be deallocated without JavaScript knowing
3. **Thread safety**: Would need synchronization across all environments
4. **Multi-context problems**: Electron and other environments may have multiple V8 contexts
5. **Performance overhead**: Every wrapper creation would need a hash lookup

## The Solution: Use Native Pointers as Keys

Instead of using the JavaScript wrapper object as the key, use the **native pointer value** itself:

```typescript
// ❌ WRONG: Using wrapper object as key
const state = new WeakMap<any, Data>();
state.set(self, data);

// ✅ CORRECT: Using native pointer value as key
import { getPointer } from "objc-js";

const state = new Map<bigint, Data>();
const ptr = getPointer(self).readBigUInt64LE(0);
state.set(ptr, data);
```

### Complete Example

```typescript
import { NobjcClass, getPointer } from "objc-js";

const controllerState = new Map<bigint, NSData>();

export const WebauthnGetController = NobjcClass.define({
  name: "WebauthnGetController",
  superclass: "ASAuthorizationController",
  methods: {
    setClientDataHash$: {
      types: "v@:@",
      implementation: (self: any, clientDataHash: any) => {
        // Get native pointer value
        const ptr = getPointer(self).readBigUInt64LE(0);

        // Store using pointer as key
        controllerState.set(ptr, clientDataHash);

        console.log("Stored at pointer:", ptr.toString(16));
      }
    },

    _requestContextWithRequests$error$: {
      types: "@@:@^@",
      implementation: (self: any, requests: any, outError: any) => {
        // Get same native pointer value
        const ptr = getPointer(self).readBigUInt64LE(0);

        // Retrieve data - works because pointer is the same!
        if (controllerState.has(ptr)) {
          // ✅ Returns true!
          const clientDataHash = controllerState.get(ptr);
          // Use the data...

          // Optional: Clean up after use
          controllerState.delete(ptr);
        }

        // ...
      }
    }
  }
});
```

## Why This Works

From the logs, we can see the native pointer is consistent:

```
CallJSCallback: About to create ObjcObject for self=0x1140387ab80
...
CallJSCallback: About to create ObjcObject for self=0x1140387ab80
```

Both method calls receive the **same native pointer** (`0x1140387ab80`), even though they get different JavaScript wrapper objects. By using the pointer value as the key, we can successfully correlate data across method calls.

## Trade-offs

### Map vs WeakMap

**Using `Map<bigint, Data>`**:

- ✅ Works correctly with pointer keys
- ✅ Simple and reliable
- ⚠️ Requires manual cleanup (no automatic garbage collection)
- ⚠️ Can leak memory if not cleaned up

**Cannot use `WeakMap`**:

- `WeakMap` only accepts objects as keys, not primitives like `bigint`
- Even if it did, it wouldn't help because we need to track native object lifetime, not JS object lifetime

### Memory Management

You should clean up the map entries when:

1. The data is no longer needed (e.g., after successful use)
2. The native object is deallocated

```typescript
// Example: Clean up after use
_requestContextWithRequests$error$: {
  implementation: (self: any, requests: any, outError: any) => {
    const ptr = getPointer(self).readBigUInt64LE(0);

    if (controllerState.has(ptr)) {
      const data = controllerState.get(ptr);
      // Use data...

      // Clean up immediately if no longer needed
      controllerState.delete(ptr);
    }
  },
},
```

For long-lived objects, you might implement a cleanup mechanism in the `dealloc` method or use a separate cleanup pattern.

## Alternative Approaches

### 1. Use Associated Objects (Native)

Store data directly on the Objective-C object using associated objects:

```objc
// Native code could implement:
objc_setAssociatedObject(self, &key, data, OBJC_ASSOCIATION_RETAIN);
```

This would require native code changes and isn't currently implemented.

### 2. Subclass-Level Storage

Store data at the class level instead of per-instance:

```typescript
let globalData: Data | null = null;

// Only works if you have one instance at a time
```

Not suitable for multiple instances.

### 3. Return Data from First Method

If possible, return data from the first method and pass it to subsequent calls:

```typescript
// Not always feasible due to framework constraints
```

## Design Decision

We chose **not** to implement wrapper caching because:

1. The `Map<bigint, Data>` solution is simple and works well
2. It gives developers explicit control over memory management
3. It avoids complex native-side caching issues
4. It's transparent and easy to debug

## Related Patterns

This pattern is common in native bindings:

- Node.js addon patterns often use external data with native pointers
- React Native uses similar patterns for native component references
- Other FFI libraries (like node-ffi) use pointer values for correlation

## Files Involved

- `src/native/ObjcObject.mm`: Wrapper creation (no caching)
- User code: Must use `getPointer()` for instance correlation

## Best Practices

When working with subclassed Objective-C objects:

1. **Never use WeakMap with `self`** - wrapper identity doesn't persist
2. **Always use `getPointer(self)` as the key** for instance data
3. **Use `Map<bigint, Data>`** not `WeakMap`
4. **Clean up map entries** when data is no longer needed
5. **Consider using TypeScript** to enforce correct types

## Testing Considerations

When testing subclass methods:

- Verify data persists across multiple method calls to the same instance
- Test with multiple instances to ensure pointer keys don't collide
- Test cleanup to prevent memory leaks
- Use the pointer values in logs to debug data correlation issues
