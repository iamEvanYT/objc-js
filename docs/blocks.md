# Blocks (Objective-C Closures)

**objc-js** supports passing JavaScript functions as Objective-C blocks. This works automatically -- when a method expects a block parameter and you pass a JavaScript function, it is converted to an Objective-C block at call time.

## Overview

Objective-C blocks are used extensively in Apple's APIs for callbacks, enumeration, sorting, and completion handlers. With block support, you can use these APIs directly from JavaScript.

### Features

- **Automatic Conversion**: JavaScript functions are automatically converted to blocks when passed to a method expecting a block parameter
- **No API Changes**: No new functions or classes -- just pass functions where blocks are expected
- **Heuristic Type Detection**: Block parameter types are inferred at runtime using pointer analysis
- **Synchronous Blocks**: Fully supported for enumeration, sorting, filtering, etc.
- **Async Blocks**: Supported for completion handlers called from background threads
- **Memory Safety**: Block references are kept alive for async callbacks

## Basic Usage

### Enumerating an NSArray

```typescript
import { NobjcLibrary } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSMutableArray = foundation["NSMutableArray"];
const NSNumber = foundation["NSNumber"];

// Create an array
const arr = NSMutableArray.array();
arr.addObject$(NSNumber.numberWithInt$(10));
arr.addObject$(NSNumber.numberWithInt$(20));
arr.addObject$(NSNumber.numberWithInt$(30));

// Enumerate using a block
arr.enumerateObjectsUsingBlock$((obj, idx, stop) => {
  console.log(`Index ${idx}: ${obj.intValue()}`);
});
// Output:
// Index 0: 10
// Index 1: 20
// Index 2: 30
```

### Enumerating an NSDictionary

```typescript
const NSMutableDictionary = foundation["NSMutableDictionary"];
const NSString = foundation["NSString"];

const dict = NSMutableDictionary.dictionary();
dict.setObject$forKey$(NSNumber.numberWithInt$(1), NSString.stringWithUTF8String$("a"));
dict.setObject$forKey$(NSNumber.numberWithInt$(2), NSString.stringWithUTF8String$("b"));
dict.setObject$forKey$(NSNumber.numberWithInt$(3), NSString.stringWithUTF8String$("c"));

dict.enumerateKeysAndObjectsUsingBlock$((key, obj, stop) => {
  console.log(`${key.UTF8String()}: ${obj.intValue()}`);
});
// Output (order may vary):
// a: 1
// b: 2
// c: 3
```

## How It Works

When you call a method and pass a JavaScript function as an argument:

1. The bridge checks the method's type encoding for the `@?` block type
2. A native Objective-C block is created that wraps your JavaScript function
3. The block is passed to the method as a normal argument
4. When Objective-C invokes the block, your JavaScript function is called with the arguments converted to JS values

### Parameter Type Detection

Since extended block type encodings are not available at runtime, the bridge uses heuristic detection to determine what each block argument is:

- **Objective-C objects** (NSString, NSNumber, etc.) are detected via heap pointer analysis and wrapped as `NobjcObject` instances -- you can call methods on them directly
- **Integers** (NSUInteger, NSInteger, etc.) are passed as JavaScript numbers
- **Pointers** (like the `stop` parameter in enumeration blocks) are passed as numbers representing the pointer address

### Function Arity

The number of parameters your JavaScript function declares (its `.length`) determines how many block arguments are passed. Make sure your function signature matches the expected block signature:

```typescript
// enumerateObjectsUsingBlock: expects (id obj, NSUInteger idx, BOOL *stop)
arr.enumerateObjectsUsingBlock$((obj, idx, stop) => {
  // 3 parameters declared, 3 arguments received
});
```

## Type Conversion

Block arguments are converted using the same rules as the rest of the bridge:

| Block Argument Type             | JavaScript Type | Notes                               |
| ------------------------------- | --------------- | ----------------------------------- |
| `id` (NSObject, NSString, etc.) | `NobjcObject`   | Can call ObjC methods directly      |
| `NSUInteger`, `NSInteger`       | `number`        | Integer values                      |
| `BOOL *`                        | `number`        | Pointer address (for `stop` params) |
| `float`, `double`               | `number`        | Floating point values               |

Block return values are converted back to Objective-C types when the block has a non-void return type.

## Async Blocks (Completion Handlers)

Blocks passed as completion handlers to async APIs work automatically, but the callback will only be delivered if the macOS CFRunLoop is being pumped. Node.js and Bun don't pump the CFRunLoop on their own, so you need to use `RunLoop.run()` to enable delivery.

### Example: NSColorSampler

```typescript
import { NobjcLibrary, RunLoop } from "objc-js";

const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");
const NSApplication = appKit["NSApplication"];
const NSColorSampler = appKit["NSColorSampler"];

// Initialize NSApplication (required for AppKit UI)
NSApplication.sharedApplication();

// Start pumping the run loop so async callbacks are delivered
const stop = RunLoop.run();

const sampler = NSColorSampler.alloc().init();
sampler.showSamplerWithSelectionHandler$((color) => {
  if (color) {
    console.log("Color:", color.description().UTF8String());
  } else {
    console.log("Cancelled");
  }
  stop(); // Stop pumping when done
});
```

### When Do You Need RunLoop?

| Block Type               | Example                            | Needs RunLoop? |
| ------------------------ | ---------------------------------- | -------------- |
| Synchronous enumeration  | `enumerateObjectsUsingBlock:`      | No             |
| Synchronous sorting      | `sortedArrayUsingComparator:`      | No             |
| Async completion handler | `showSamplerWithSelectionHandler:` | Yes            |
| Async dispatch to main   | Any callback via main queue        | Yes            |

See the [Run Loop guide](./run-loop.md) for full details on `RunLoop.run()`, `RunLoop.pump()`, and `RunLoop.stop()`.

## Limitations

1. **No `stop` pointer support**: The `BOOL *stop` parameter in enumeration blocks is passed as a raw number. Setting `*stop = YES` to stop enumeration early is not currently supported from JavaScript.
2. **Heuristic type detection**: Without extended block type encodings at runtime, the bridge uses heuristics to determine argument types. In rare cases, a large integer could be misidentified as an object pointer.
3. **Memory**: Block wrappers are currently not freed (they persist for the lifetime of the process). This is acceptable for typical usage patterns but could be a concern if creating millions of blocks.

## See Also

- [Run Loop](./run-loop.md) -- required for async completion handler delivery
- [Basic Usage](./basic-usage.md)
- [Protocol Implementation](./protocol-implementation.md) -- for delegate callbacks
- [Subclassing](./subclassing.md) -- for overriding methods
- [API Reference](./api-reference.md)
