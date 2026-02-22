# Structs

## Overview

Many Objective-C APIs use C structs for geometry, ranges, and other compound values. **objc-js** automatically converts between JavaScript objects and Objective-C structs like `CGRect`, `CGPoint`, `CGSize`, `NSRange`, and others.

Structs are represented as plain JavaScript objects with named fields:

```typescript
// CGRect — nested struct with CGPoint origin and CGSize size
const rect = {
  origin: { x: 100, y: 100 },
  size: { width: 800, height: 600 }
};

// NSRange — flat struct with two fields
const range = { location: 7, length: 5 };
```

Both struct arguments (JS to ObjC) and struct return values (ObjC to JS) are supported.

## Passing Structs as Arguments

Pass a plain JavaScript object wherever an Objective-C method expects a struct parameter. The bridge reads the method signature to determine the struct layout and packs your object into the correct binary format automatically.

### NSRange

```typescript
import { NobjcLibrary } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];

const str = NSString.stringWithUTF8String$("Hello, World!");

// Pass NSRange as a named object
const range = { location: 7, length: 5 };
const substring = str.substringWithRange$(range);
console.log(substring.UTF8String()); // "World"
```

### CGRect (Nested Struct)

`CGRect` contains two nested structs: a `CGPoint` origin and a `CGSize` size. Pass them as nested objects:

```typescript
const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");
const NSWindow = appKit["NSWindow"];

const rect = {
  origin: { x: 100, y: 100 },
  size: { width: 800, height: 600 }
};

const styleMask = 1 | 2 | 4 | 8; // titled | closable | miniaturizable | resizable
const backingStore = 2; // NSBackingStoreBuffered

const window = NSWindow.alloc().initWithContentRect$styleMask$backing$defer$(rect, styleMask, backingStore, false);
```

### CGPoint and CGSize

```typescript
const NSValue = foundation["NSValue"];

const point = { x: 42.5, y: 99.0 };
const pointValue = NSValue.valueWithPoint$(point);

const size = { width: 640.0, height: 480.0 };
const sizeValue = NSValue.valueWithSize$(size);
```

### Arrays as Structs

You can also pass structs as flat arrays, where values are assigned to fields in order:

```typescript
// NSRange as [location, length]
const range = [7, 5];
const substring = str.substringWithRange$(range);
```

This works for any struct, but named objects are recommended for readability, especially with nested structs.

## Receiving Structs as Return Values

When an Objective-C method returns a struct, the bridge automatically converts it to a JavaScript object with named fields.

### NSRange Return

```typescript
const str = NSString.stringWithUTF8String$("Hello, World!");
const search = NSString.stringWithUTF8String$("World");

const range = str.rangeOfString$(search);
console.log(range.location); // 7
console.log(range.length); // 5
```

When the search string is not found, `location` is set to `NSNotFound` (the maximum value of `NSUInteger`):

```typescript
const notFound = str.rangeOfString$(NSString.stringWithUTF8String$("Foo"));
console.log(notFound.length); // 0
```

### CGRect Return

```typescript
const frame = window.frame();
console.log(frame.origin.x); // 100
console.log(frame.origin.y); // 100
console.log(frame.size.width); // 800
console.log(frame.size.height); // 600
```

### Roundtrip Through NSValue

Structs can be stored in `NSValue` and retrieved back:

```typescript
const NSValue = foundation["NSValue"];

// Store
const original = {
  origin: { x: 1.5, y: 2.5 },
  size: { width: 100.25, height: 200.75 }
};
const value = NSValue.valueWithRect$(original);

// Retrieve
const retrieved = value.rectValue();
console.log(retrieved.origin.x); // 1.5
console.log(retrieved.origin.y); // 2.5
console.log(retrieved.size.width); // 100.25
console.log(retrieved.size.height); // 200.75
```

## Supported Structs

The following structs have built-in field name mappings:

| Struct                    | Fields                                 | Type Encoding                      |
| ------------------------- | -------------------------------------- | ---------------------------------- |
| `CGPoint` / `NSPoint`     | `x`, `y`                               | `{CGPoint=dd}`                     |
| `CGSize` / `NSSize`       | `width`, `height`                      | `{CGSize=dd}`                      |
| `CGRect` / `NSRect`       | `origin` (CGPoint), `size` (CGSize)    | `{CGRect={CGPoint=dd}{CGSize=dd}}` |
| `NSRange`                 | `location`, `length`                   | `{_NSRange=QQ}`                    |
| `CGVector`                | `dx`, `dy`                             | `{CGVector=dd}`                    |
| `NSEdgeInsets`            | `top`, `left`, `bottom`, `right`       | `{NSEdgeInsets=dddd}`              |
| `NSDirectionalEdgeInsets` | `top`, `leading`, `bottom`, `trailing` | `{NSDirectionalEdgeInsets=dddd}`   |
| `CGAffineTransform`       | `a`, `b`, `c`, `d`, `tx`, `ty`         | `{CGAffineTransform=dddddd}`       |

### Unknown Structs

Structs not in the table above still work, but their fields will be named `field0`, `field1`, etc. since the Objective-C runtime does not include field names in type encodings. You can pass them as objects with these positional names, or as arrays.

## Full Example: NSWindow with Structs

```typescript
import { NobjcLibrary } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");

const NSApplication = appKit["NSApplication"];
const NSWindow = appKit["NSWindow"];
const NSString = foundation["NSString"];

// Create a window with a CGRect struct
const window = NSWindow.alloc().initWithContentRect$styleMask$backing$defer$(
  { origin: { x: 100, y: 100 }, size: { width: 800, height: 600 } },
  1 | 2 | 4 | 8,
  2,
  false
);

// Set the title
window.setTitle$(NSString.stringWithUTF8String$("My Window"));

// Read back the frame as a struct
const frame = window.frame();
console.log(`Window at (${frame.origin.x}, ${frame.origin.y})`);
console.log(`Window size: ${frame.size.width} x ${frame.size.height}`);

// Show the window and run the app
window.makeKeyAndOrderFront$(null);
NSApplication.sharedApplication().run();
```

## See Also

- [Basic Usage](./basic-usage.md)
- [API Reference](./api-reference.md)

## TypeScript Types for Structs (objcjs-types)

The **[objcjs-types](https://www.npmjs.com/package/objcjs-types)** companion package provides TypeScript type definitions for common structs, so you can type-check your struct values at compile time:

```typescript
import type { CGPoint, CGSize, CGRect, NSRange } from "objcjs-types/structs";

const frame: CGRect = {
  origin: { x: 100, y: 100 },
  size: { width: 800, height: 600 }
};
```
