# RunLoop Design Document

## Overview

This document describes the design and implementation of the `RunLoop` object in objc-js. The RunLoop bridges the macOS CFRunLoop with Node.js/Bun event loops, enabling asynchronous Objective-C callbacks (completion handlers, AppKit events, `performSelector:withObject:afterDelay:`, etc.) to be delivered in JavaScript.

Node.js and Bun do not pump the CFRunLoop by default. Without explicit pumping, any Objective-C API that schedules work on the run loop (timers, dispatch to main queue, AppKit events, completion handlers) will never fire. The `RunLoop` object solves this by periodically calling `[NSRunLoop runMode:beforeDate:]` from a `setInterval` timer.

---

## 1. Problem Statement

Many Objective-C APIs are inherently asynchronous and rely on the CFRunLoop for event delivery:

- **Completion handlers**: `NSColorSampler`, `NSOpenPanel`, network requests
- **AppKit events**: Window events, user interaction callbacks
- **Scheduled selectors**: `performSelector:withObject:afterDelay:`
- **Dispatch to main queue**: `dispatch_async(dispatch_get_main_queue(), ...)`
- **Timer-based callbacks**: `NSTimer`, CFRunLoopTimer

In a native macOS application, `[NSApp run]` or `CFRunLoopRun()` continuously pumps the run loop. In Node.js and Bun, neither runtime does this — the CFRunLoop sits idle and queued callbacks are never delivered.

---

## 2. Architecture

### 2.1 Design Approach

The RunLoop uses a **JavaScript-driven pump** via `setInterval` rather than a native C++ implementation. Each interval tick calls `[NSRunLoop mainRunLoop runMode:beforeDate:]` through proxy-wrapped NobjcObjects, which processes any pending run loop sources without blocking.

```
setInterval (JS event loop, every ~10ms)
  → RunLoop.pump()
    → _ensureRunLoop()          // lazy init: load Foundation, get NSRunLoop
    → NSDate.dateWithTimeIntervalSinceNow$(0)
    → mainRunLoop.runMode$beforeDate$(defaultMode, limitDate)
      → [NSRunLoop runMode:NSDefaultRunLoopMode beforeDate:]
        → CFRunLoopRunInMode (internal)
          → Processes pending sources, timers, observers
```

### 2.2 Why Not a Native Implementation?

A native `PumpRunLoop` function exists in `nobjc.mm` (lines 82–104) but is **unused** by the TypeScript RunLoop. There are two reasons:

1. **Bun crash**: Calling `[NSRunLoop runMode:beforeDate:]` from N-API C++ code crashes Bun with a segfault (see Section 3).
2. **Same-thread semantics**: The proxy path (`$prepareSend` + `$msgSendPrepared`) achieves the exact same result as the native function, without the crash.

The native `PumpRunLoop` is kept in `nobjc.mm` and exported from `native.ts` for backward compatibility, but is not imported or used by the `RunLoop` object.

### 2.3 Key Design Decisions

| Decision                         | Rationale                                                          |
| -------------------------------- | ------------------------------------------------------------------ |
| `setInterval` over native timer  | Keeps pumping in JS event loop; compatible with both runtimes      |
| `unref()` on the timer           | Prevents the pump timer from keeping the process alive             |
| Proxy-wrapped ObjC calls         | Avoids Bun crash (see Section 3)                                   |
| Lazy initialization              | No overhead until `RunLoop` is first used                          |
| Explicit `LoadLibrary()` call    | `NobjcLibrary` uses lazy loading; Foundation may not be loaded yet |
| `run()` returns cleanup function | Follows Node.js convention; composable with `async`/`await`        |

---

## 3. The Bun Crash

### Symptoms

Calling `PumpRunLoop()` from N-API C++ code crashes Bun with a segfault:

```
Thread 0 Crashed:
0   CoreFoundation   __CFRunLoopRun + ...
...
Signal: SIGSEGV (stack guard page hit)
```

The same code works in Node.js.

### What We Know

The crash is `SIGSEGV (stack guard page hit)` — a stack overflow. It only happens in Bun; the same native addon works fine in Node.js. Three calling patterns were tested:

1. **Native `PumpRunLoop` C++ function** — calls `[NSRunLoop runMode:beforeDate:]` directly in ObjC++. Crashes Bun.
2. **Raw `$msgSend` path** — JS calls `GetClassObject("NSRunLoop")` then `obj.$msgSend("mainRunLoop")`. Crashes Bun.
3. **Proxy `$prepareSend` + `$msgSendPrepared` path** — JS calls through a `NobjcObject` proxy. Works on both runtimes.

### Why We Don't Fully Understand It

Inspecting the C++ code reveals that `$MsgSend` and `$MsgSendPrepared` **both call the exact same `TryFastMsgSend` function** with the exact same `objc_msgSend` cast. For `runMode:beforeDate:` (2 `id` args, `BOOL` return), both paths hit the fast path and execute an identical function pointer cast:

```cpp
result = ((uintptr_t(*)(id, SEL, uintptr_t, uintptr_t))objc_msgSend)(target, selector, args[0], args[1]);
```

The only difference is that `$MsgSend` does more work before reaching `TryFastMsgSend` — selector string parsing, `sel_registerName()`, `respondsToSelector:`, method signature lookup, return type validation — while `$MsgSendPrepared` skips all of that (it was done in a prior `$prepareSend` call). But this adds maybe a few hundred bytes of stack locals. That alone shouldn't cause a stack overflow.

### Possible Explanations (Unconfirmed)

The root cause is likely in **Bun's N-API shim**. Bun runs on JavaScriptCore (not V8) and implements N-API as a compatibility layer. Some hypotheses:

1. **Smaller stack allocation for N-API callbacks.** If Bun gives N-API function calls a limited stack, then `CFRunLoopRunInMode` (which has a deep internal CoreFoundation call stack) could blow past it. The proxy path works because `$prepareSend` and `$msgSendPrepared` are **two separate N-API entries** — each gets a fresh stack.

2. **Re-entrancy issues.** `runMode:beforeDate:` pumps the CFRunLoop, which can fire sources that re-enter JavaScript/N-API. Bun's shim might not handle re-entrant N-API calls from within a CFRunLoop pump.

3. **JSC-specific stack accounting.** JavaScriptCore may track stack usage differently than V8, and the combination of JSC stack frames + N-API shim frames + CoreFoundation frames might exceed a limit that V8-based Node.js doesn't hit.

We never debugged Bun's internals to confirm which of these is the actual cause. The workaround was found empirically.

### The Workaround

Use **proxy-wrapped NobjcObjects** instead of raw native calls:

```typescript
// CRASHES BUN: Raw native call path
// PumpRunLoop(timeout);  // C++ → [NSRunLoop runMode:...] → CFRunLoopRunInMode → segfault

// CRASHES BUN: Raw $msgSend path
// const loop = GetClassObject("NSRunLoop");
// loop.$msgSend("mainRunLoop");  // → $msgSend C++ → ObjC → CF → segfault

// WORKS ON ALL RUNTIMES: Proxy-wrapped path
const NSRunLoop = wrapObjCObjectIfNeeded(GetClassObject("NSRunLoop"));
const mainRunLoop = NSRunLoop.mainRunLoop();
mainRunLoop.runMode$beforeDate$(defaultMode, limitDate);
// → $prepareSend (separate N-API call, returns to JS)
// → $msgSendPrepared (second N-API call, leaner stack)
// → objc_msgSend → [NSRunLoop runMode:...] → CFRunLoopRunInMode → works
```

The proxy path splits the work across two N-API boundary crossings. Whatever Bun's stack issue is, the split is enough to avoid it.

---

## 4. Implementation Details

### 4.1 RunLoop Object (`src/ts/index.ts`, lines 736–827)

```typescript
const RunLoop = {
  _timer: null as ReturnType<typeof setInterval> | null,
  _mainRunLoop: null as any,
  _defaultMode: null as any,
  _NSDate: null as any,

  _ensureRunLoop() { ... },  // Lazy init
  pump(timeout?: number): boolean { ... },  // Single pump
  run(intervalMs: number = 10): () => void { ... },  // Start continuous pumping
  stop(): void { ... }  // Stop continuous pumping
};
```

### 4.2 Lazy Initialization (`_ensureRunLoop`)

The `_ensureRunLoop()` method (line 752) runs once on first use:

1. **`LoadLibrary()` for Foundation** — Required because `NobjcLibrary` uses lazy loading. If the user hasn't accessed any Foundation class through a `NobjcLibrary` proxy, Foundation may not be loaded yet. Without this call, `GetClassObject("NSRunLoop")` returns `undefined`.

2. **Wrap `NSRunLoop` via proxy** — `wrapObjCObjectIfNeeded(GetClassObject("NSRunLoop"))` creates a proxy-wrapped NobjcObject. This is critical for Bun compatibility (see Section 3).

3. **Get `mainRunLoop`** — `NSRunLoop.mainRunLoop()` returns the main thread's run loop.

4. **Create `NSDefaultRunLoopMode` string** — The mode constant is created via `NSString.stringWithUTF8String$("kCFRunLoopDefaultMode")`. This is the string value of the `NSDefaultRunLoopMode` / `kCFRunLoopDefaultMode` constant.

5. **Cache `NSDate` class** — Used to create `limitDate` objects for `runMode:beforeDate:`.

### 4.3 `pump(timeout?)`

Single-shot pump (line 783):

```typescript
pump(timeout?: number): boolean {
  this._ensureRunLoop();
  const limitDate = this._NSDate.dateWithTimeIntervalSinceNow$(timeout ?? 0);
  const handled = this._mainRunLoop.runMode$beforeDate$(this._defaultMode, limitDate);
  return !!handled;
}
```

- `timeout = 0` (default): Non-blocking — returns immediately after processing any ready sources
- `timeout > 0`: Blocks up to `timeout` seconds waiting for a source to fire
- Returns `true` if a run loop source was processed, `false` otherwise

### 4.4 `run(intervalMs)`

Continuous pumping (line 797):

```typescript
run(intervalMs: number = 10): () => void {
  if (this._timer !== null) {
    clearInterval(this._timer);  // Replace existing timer
  }
  this._ensureRunLoop();
  this._timer = setInterval(() => {
    const limitDate = this._NSDate.dateWithTimeIntervalSinceNow$(0);
    this._mainRunLoop.runMode$beforeDate$(this._defaultMode, limitDate);
  }, intervalMs);
  if (this._timer && typeof this._timer === "object" && "unref" in this._timer) {
    (this._timer as any).unref();
  }
  const stop = () => this.stop();
  return stop;
}
```

Key behaviors:

- **Replaces previous timer**: Calling `run()` twice clears the old interval before starting a new one
- **`unref()`**: The timer is unreferenced so it won't keep the process alive when no other work remains. The `typeof` / `"in"` check handles both Node.js (returns `Timeout` object) and Bun (returns numeric ID)
- **Returns cleanup function**: Follows the pattern of returning a `stop()` function for easy cleanup

### 4.5 `stop()`

Stops the pump timer (line 821):

```typescript
stop(): void {
  if (this._timer !== null) {
    clearInterval(this._timer);
    this._timer = null;
  }
}
```

Idempotent — safe to call multiple times, safe to call when no timer is running.

---

## 5. Native PumpRunLoop (Unused)

The native function in `nobjc.mm` (lines 82–104) is functionally equivalent but crashes Bun:

```cpp
Napi::Value PumpRunLoop(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  NSTimeInterval timeout = 0.0;
  if (info.Length() >= 1 && info[0].IsNumber()) {
    timeout = info[0].As<Napi::Number>().DoubleValue();
  }
  @autoreleasepool {
    NSRunLoop *mainLoop = [NSRunLoop mainRunLoop];
    NSDate *limitDate = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL handled = [mainLoop runMode:NSDefaultRunLoopMode beforeDate:limitDate];
    return Napi::Boolean::New(env, handled);
  }
}
```

This function was the original implementation attempt. It uses `NSRunLoop` rather than `CFRunLoopRunInMode` directly (the CF function also crashes), but even the NSRunLoop wrapper crashes when called from N-API C++ in Bun. It is still registered in `InitAll` (line 117) and exported from `native.ts` for backward compatibility.

---

## 6. Files

### Created

- `tests/test-run-loop.test.ts` — 18 tests across 4 describe blocks
- `docs/run-loop.md` — User-facing documentation
- `design/run-loop.md` — This design document

### Modified

- `src/ts/index.ts` — Added `RunLoop` object (lines 736–827), added to exports (line 835), removed `PumpRunLoop` import
- `docs/blocks.md` — Updated with async callback section referencing RunLoop
- `docs/api-reference.md` — Added RunLoop API section
- `README.md` — Updated documentation index

### Unchanged (kept for backward compat)

- `src/native/nobjc.mm` — `PumpRunLoop` function still exported (line 117)
- `src/ts/native.ts` — Still exports `PumpRunLoop` type
- `types/native/nobjc_native.d.ts` — `PumpRunLoop` declaration (line 86)

---

## 7. Testing

18 tests across 4 describe blocks in `tests/test-run-loop.test.ts`:

### RunLoop.pump()

- ✅ Returns a boolean
- ✅ Accepts a timeout parameter
- ✅ Doesn't throw when no sources are pending
- ✅ Accepts a fractional timeout in seconds

### RunLoop.run() and RunLoop.stop()

- ✅ `run()` returns a cleanup function
- ✅ `run()` accepts an interval parameter
- ✅ Cleanup function stops pumping without error
- ✅ `run()` replaces previous timer when called multiple times
- ✅ `stop()` doesn't throw when no timer is running
- ✅ `stop()` stops a running pump loop
- ✅ `stop()` is safe to call multiple times (idempotent)
- ✅ Run-stop-run cycle works correctly
- ✅ `stop()` after cleanup function is safe

### RunLoop with synchronous blocks

- ✅ Blocks work without RunLoop (synchronous enumeration)
- ✅ Blocks work with RunLoop timer active (no interference)

### RunLoop pumping behavior

- ✅ `run()` does not block the event loop (async)
- ✅ `pump()` processes a scheduled CFRunLoop timer via `performSelector:withObject:afterDelay:` (async)
- ✅ `run()` delivers scheduled CFRunLoop timers automatically (async)

All 18 tests pass on both Bun and Node.js/Vitest.

---

## 8. Known Limitations

1. **Bun native PumpRunLoop crash**: The native C++ `PumpRunLoop` function and raw `$msgSend` path crash Bun. The TS proxy-based workaround solves this, but the root cause in Bun's N-API shim is not understood (see Section 3).

2. **Polling, not event-driven**: The `setInterval` approach polls at a fixed interval (default 10ms). This adds up to 10ms latency for callback delivery and consumes CPU cycles even when no sources are pending. A truly event-driven integration (hooking CFRunLoop into libuv/Bun's event loop) would be more efficient but is significantly more complex.

3. **Main thread only**: The RunLoop only pumps the main run loop (`[NSRunLoop mainRunLoop]`). Run loop sources scheduled on other threads' run loops are not processed.

4. **No AppKit event loop replacement**: This is not a substitute for `[NSApp run]`. Full AppKit applications with windows, menus, and the responder chain need a proper `NSApplication` event loop. The RunLoop is designed for headless or utility use cases (completion handlers, timers, dispatch_async).

5. **Process exit behavior**: The timer is `unref()`'d, so it won't keep the process alive. If all other work completes, the process exits even if the RunLoop is still "running". This is intentional — it prevents hanging — but means long-running async ObjC operations need something else to keep the process alive (e.g., a pending Promise).

---

## 9. Lessons Learned

1. **Bun's N-API is not identical to Node's**: Internal implementation differences can cause crashes for code that works perfectly in Node.js. Always test on both runtimes.

2. **Empirical workarounds are sometimes necessary**: The proxy path fix was found by experimentation, not by understanding the root cause. Both `$msgSend` and `$msgSendPrepared` call the same `TryFastMsgSend` → `objc_msgSend` code, yet one crashes and the other doesn't. The difference likely lies in Bun's N-API shim internals (stack allocation, re-entrancy handling, or JSC stack accounting), which we haven't debugged.

3. **Lazy loading requires explicit LoadLibrary**: `NobjcLibrary` uses `Proxy` with lazy loading, so frameworks aren't loaded until a class is accessed through the proxy. The RunLoop bypasses `NobjcLibrary` and uses `GetClassObject` directly, which requires an explicit `LoadLibrary()` call.

4. **`unref()` API differs across runtimes**: Node.js `setInterval` returns a `Timeout` object with `.unref()`. Bun returns a numeric ID. The `typeof` + `"in"` check handles both gracefully.
