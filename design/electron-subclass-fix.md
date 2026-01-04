# Electron Subclass Method Forwarding Fix

## Issue

When calling subclassed methods in Electron (e.g., `setClientDataHash$` on a custom `ASAuthorizationController` subclass), the application would hang indefinitely before the JavaScript implementation was ever called. The same code worked correctly in Node.js and Bun.

## Symptoms

- Method calls hung before reaching JavaScript
- Logs showed: `SubclassForwardInvocation: Still waiting... (N iterations)`
- `NonBlockingCall` returned success status, but callback never executed
- Only occurred in Electron, not in Node.js or Bun

## Root Cause

The subclass forwarding code was using different execution paths for Electron vs Node.js/Bun:

```cpp
// BROKEN: Before fix (line 166 in subclass-impl.mm)
if (is_js_thread && !isElectron) {
    // Direct call path - only for Node/Bun
    // Calls JS function directly within a HandleScope
} else {
    // TSFN + runloop pumping - used for Electron
    // Uses NonBlockingCall + CFRunLoopRunInMode to wait
}
```

**The problem**: In Electron, even when already on the JS thread, the code was forcing the TSFN + runloop pumping path. However, Electron's event loop integration doesn't process Node-API ThreadSafeFunction callbacks during `CFRunLoopRunInMode`. This caused the callback to be queued but never executed, resulting in an infinite wait.

This is different from cross-thread calls where runloop pumping works because it allows the event loop to process the TSFN callback. But when already on the JS thread in Electron, the TSFN callback requires event loop processing that `CFRunLoopRunInMode` doesn't provide in Electron's context.

## The Fix

**Change the execution path logic to always use direct calls when on the JS thread:**

```cpp
// FIXED: After fix (line 166 in subclass-impl.mm)
if (is_js_thread) {
    // Direct call path - for Node/Bun/Electron when on JS thread
    // Calls JS function directly within a HandleScope
} else {
    // TSFN + runloop pumping - only for cross-thread calls
    // Uses NonBlockingCall + CFRunLoopRunInMode to wait
}
```

**Why this works**:

- When on the JS thread, we can call JavaScript directly without needing ThreadSafeFunction
- Direct calls work in all environments (Node.js, Bun, Electron) when on the correct thread
- TSFN + runloop pumping is only needed for cross-thread calls (e.g., Cocoa callbacks from system frameworks)

## Related Context

This issue was similar to one previously encountered with protocol implementations. The protocol implementation code already had the correct logic (always try direct call first on JS thread), but the subclass implementation had diverged.

## Files Changed

- `src/native/subclass-impl.mm` (line 166): Changed condition from `if (is_js_thread && !isElectron)` to `if (is_js_thread)`
- Removed unused `isElectron` variable from the direct call path

## Testing

After the fix:

- ✅ Subclass methods work correctly in Electron
- ✅ Subclass methods continue to work in Node.js and Bun
- ✅ Cross-thread callbacks still work (using TSFN + runloop path)

## Lessons Learned

1. **Electron's event loop integration is different**: What works in Node.js doesn't always work in Electron
2. **ThreadSafeFunction has limitations**: When already on the JS thread in Electron, TSFN + runloop pumping doesn't work as expected
3. **Direct calls are preferred**: When on the JS thread, always prefer direct calls over ThreadSafeFunction
4. **Keep implementations consistent**: Protocol and subclass implementations should use the same patterns
