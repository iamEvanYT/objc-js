# Run Loop

**objc-js** provides a `RunLoop` utility for pumping the macOS CFRunLoop from Node.js or Bun. This is required for async Objective-C callbacks -- such as completion handlers, AppKit events, and dispatch_async to the main queue -- to be delivered to your JavaScript code.

## Why It's Needed

Node.js and Bun run their own event loops (libuv and the Bun event loop, respectively) on the main thread. macOS Objective-C APIs often dispatch callbacks to the main thread via the CFRunLoop or the main dispatch queue. Since neither Node.js nor Bun pump the CFRunLoop, these callbacks sit in the queue forever and never fire.

This affects any API that delivers results asynchronously to the main thread, including:

- **Completion handlers** dispatched to the main queue (e.g., `NSColorSampler`, `NSSharingService`)
- **AppKit events** that rely on the run loop for delivery
- **Timers and observers** registered with the CFRunLoop

Synchronous blocks (e.g., enumeration blocks like `enumerateObjectsUsingBlock:`) are not affected because they execute inline during the method call.

## Basic Usage

### Start Pumping (Recommended)

Use `RunLoop.run()` to start continuously pumping the CFRunLoop on a timer. This is the simplest way to enable async callbacks:

```typescript
import { NobjcLibrary, RunLoop } from "objc-js";

const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");
const NSColorSampler = appKit["NSColorSampler"];

// Start pumping the run loop
const stop = RunLoop.run();

// Now async callbacks will be delivered
const sampler = NSColorSampler.alloc().init();
sampler.showSamplerWithSelectionHandler$((color) => {
  if (color) {
    console.log("Selected color:", color.description().UTF8String());
  } else {
    console.log("Color selection cancelled");
  }
  // Stop pumping when done
  stop();
});
```

### Pump Once

Use `RunLoop.pump()` to process pending run loop sources without blocking. This is useful when you want manual control over when the run loop is pumped:

```typescript
import { RunLoop } from "objc-js";

// Process any pending callbacks right now
const didProcess = RunLoop.pump();
console.log("Processed a source:", didProcess);

// Pump with a timeout (in seconds) -- waits up to the given duration
// for a source to become ready
RunLoop.pump(0.1); // Wait up to 100ms
```

### Stop Pumping

There are two ways to stop a running pump loop:

```typescript
// Option 1: Use the cleanup function returned by run()
const stop = RunLoop.run();
// ... later ...
stop();

// Option 2: Call RunLoop.stop() directly
RunLoop.run();
// ... later ...
RunLoop.stop();
```

## API

### RunLoop.pump(timeout?)

Pump the CFRunLoop once. Processes any pending run loop sources (AppKit events, dispatch_async to main queue, timers, etc.) and returns immediately if none are pending.

| Parameter | Type     | Default | Description                           |
| --------- | -------- | ------- | ------------------------------------- |
| `timeout` | `number` | `0`     | Timeout in seconds (0 = non-blocking) |

**Returns:** `boolean` -- `true` if a source was processed, `false` otherwise.

### RunLoop.run(intervalMs?)

Start continuously pumping the CFRunLoop on a regular interval. If already running, the previous timer is replaced.

| Parameter    | Type     | Default | Description                   |
| ------------ | -------- | ------- | ----------------------------- |
| `intervalMs` | `number` | `10`    | Pump interval in milliseconds |

**Returns:** `() => void` -- a cleanup function that stops the pump loop.

The internal timer is `unref()`'d, so it does not prevent the process from exiting on its own. The process stays alive as long as other handles (like a pending async block callback) are active.

### RunLoop.stop()

Stop pumping the CFRunLoop. Safe to call even if the run loop is not currently being pumped.

**Returns:** `void`

## How It Works

1. `RunLoop.run()` creates a `setInterval` timer that pumps the macOS run loop on each tick
2. On each tick, it calls `[[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:]` via the Objective-C bridge, which processes one pending run loop source
3. When an Objective-C API dispatches a callback to the main queue, the next pump tick picks it up and delivers it to your JavaScript function via the block bridge
4. The timer is `unref()`'d so it doesn't keep the process alive by itself -- the process stays alive because the async block's thread-safe function reference (TSFN) holds an active handle on the event loop until the callback fires

## Example: Color Picker

A complete example using `NSColorSampler` to pick a color from anywhere on screen:

```typescript
import { NobjcLibrary, RunLoop } from "objc-js";

const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");
const NSApplication = appKit["NSApplication"];
const NSColorSampler = appKit["NSColorSampler"];

// NSApplication must be initialized for AppKit UI
NSApplication.sharedApplication();

// Start pumping the run loop for async callback delivery
const stop = RunLoop.run();

const sampler = NSColorSampler.alloc().init();
sampler.showSamplerWithSelectionHandler$((color) => {
  if (color) {
    const r = color.redComponent();
    const g = color.greenComponent();
    const b = color.blueComponent();
    console.log(`RGB: ${r.toFixed(3)}, ${g.toFixed(3)}, ${b.toFixed(3)}`);
  } else {
    console.log("Cancelled");
  }
  stop();
});
```

## Tips

- **Default interval**: The default 10ms pump interval is a good balance between responsiveness and CPU usage. Increase it if you want lower CPU overhead and can tolerate slightly delayed callbacks.
- **Multiple async operations**: You only need one `RunLoop.run()` call, even if you have multiple pending async callbacks. Stop it when all callbacks have been received.
- **Synchronous blocks don't need this**: Blocks passed to synchronous APIs like `enumerateObjectsUsingBlock:` execute immediately during the method call and do not require run loop pumping.
- **Process exit**: The run loop timer is `unref()`'d, so if your async callback is the only thing keeping the process alive and it fires and you have no other work, the process will exit naturally.

## See Also

- [Blocks](./blocks.md) -- passing JavaScript functions as Objective-C blocks
- [Protocol Implementation](./protocol-implementation.md) -- for delegate callbacks
- [API Reference](./api-reference.md)
