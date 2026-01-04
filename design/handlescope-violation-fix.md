# V8 HandleScope Violation in Subclass Method Forwarding

## Issue

After fixing the initial Electron hanging issue, calling the second subclassed method `_requestContextWithRequests$error$` resulted in a segmentation fault with the error:

```
Fatal error in V8: v8::HandleScope::CreateHandle() Cannot create a handle without a HandleScope
```

## Root Cause

The code was calling `.Value()` on a `Napi::FunctionReference` **outside** of a V8 `HandleScope`:

```cpp
// BROKEN: Before fix (lines 208-217 in subclass-impl.mm)
Napi::Function jsFn;
napi_env stored_env;
{
    std::lock_guard<std::mutex> lock(g_subclasses_mutex);
    // ... lookup code ...

    stored_env = it->second.env;
    jsFn = methodIt->second.jsCallback.Value();  // ❌ OUTSIDE HandleScope!
}

try {
    Napi::Env callEnv(stored_env);
    Napi::HandleScope scope(callEnv);
    CallJSCallback(callEnv, jsFn, data);
}
```

**The problem**: When you call `.Value()` on a `Napi::FunctionReference`, it creates a new V8 handle from the persistent reference. In V8, all handles must be created within a `HandleScope`. Creating handles outside a scope causes V8 to abort with a fatal error.

## Why It Happened

The code structure had:

1. Get the `napi_env` from storage (outside HandleScope) ✅ OK - just a pointer
2. Call `.Value()` to get the function (outside HandleScope) ❌ WRONG - creates V8 handle
3. Create `Napi::Env` and `HandleScope` (inside try block)
4. Call the function

## The Fix

**Move the `.Value()` call inside the HandleScope:**

```cpp
// FIXED: After fix (lines 208-229 in subclass-impl.mm)
napi_env stored_env;
{
    std::lock_guard<std::mutex> lock(g_subclasses_mutex);
    // ... lookup code ...

    stored_env = it->second.env;
    // Don't get the function value here - do it inside the HandleScope
}

try {
    Napi::Env callEnv(stored_env);
    Napi::HandleScope scope(callEnv);

    // Get the JS function within the HandleScope ✅
    Napi::Function jsFn;
    {
        std::lock_guard<std::mutex> lock(g_subclasses_mutex);
        auto it = g_subclasses.find(clsPtr);
        if (it != g_subclasses.end()) {
            auto methodIt = it->second.methods.find(selectorName);
            if (methodIt != it->second.methods.end()) {
                jsFn = methodIt->second.jsCallback.Value();  // ✅ INSIDE HandleScope!
            }
        }
    }

    CallJSCallback(callEnv, jsFn, data);
}
```

## Why This Works

1. We retrieve the `napi_env` pointer outside the HandleScope (safe - it's just a pointer)
2. We create the `Napi::Env` wrapper and `HandleScope`
3. We then acquire the lock again and call `.Value()` inside the scope
4. All V8 handles are now created within a proper scope

## Key Principles

### What can be done outside HandleScope:

- Getting raw pointers (`napi_env`, `void*`, etc.)
- Copying strings, numbers, and other C++ data
- Mutex operations

### What MUST be done inside HandleScope:

- Creating new V8 handles (via `.Value()`, `New()`, etc.)
- Calling JavaScript functions
- Accessing JavaScript object properties
- Any operation that touches the V8 heap

## Why It Only Crashed on Second Method

The first method (`setClientDataHash$`) worked because of luck - its simplicity and timing meant the handle creation happened to work. The second method (`_requestContextWithRequests$error$`) had more complex argument handling, which triggered the V8 assertion before it could execute.

## Related Issues

This is a common pitfall when working with Node-API:

- `Napi::FunctionReference::Value()` creates a new handle
- `Napi::Reference<T>::Value()` creates a new handle
- Any `Napi::*::New()` method creates a new handle
- All require an active HandleScope

## Files Changed

- `src/native/subclass-impl.mm` (lines 208-229): Moved `.Value()` call inside HandleScope

## Prevention

When writing Node-API code:

1. Always establish a HandleScope before creating V8 handles
2. Be careful with persistent references - `.Value()` creates a new handle
3. Test in Electron - it often has stricter V8 enforcement than Node.js
4. Use `Napi::EscapableHandleScope` when returning handles from a scope

## Testing

After the fix:

- ✅ Both simple and complex subclass methods work
- ✅ No more segmentation faults
- ✅ V8 handle creation happens within proper scopes
