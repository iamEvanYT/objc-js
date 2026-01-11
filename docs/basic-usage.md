# Basic Usage

## Getting Started

**objc-js** is an Objective-C bridge for Node.js. This guide covers the fundamentals of loading frameworks and calling Objective-C methods.

## Loading a Framework

```typescript
import { NobjcLibrary } from "objc-js";

// Load a framework
const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
```

## Getting a Class and Calling Methods

Once you have a framework loaded, you can access classes and call methods:

```typescript
import { NobjcLibrary } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

// Get a class
const NSString = foundation["NSString"];

// Call methods using $ notation for colons
const str = NSString.stringWithUTF8String$("Hello, World!");
console.log(str.toString());
```

## Method Naming Convention

Objective-C uses colons (`:`) to separate method arguments. In JavaScript, we use the `$` symbol instead:

| Objective-C              | JavaScript               |
| ------------------------ | ------------------------ |
| `stringWithUTF8String:`  | `stringWithUTF8String$`  |
| `initWithString:`        | `initWithString$`        |
| `containsObject:`        | `containsObject$`        |
| `arrayWithObject:count:` | `arrayWithObject$count$` |

## Common Patterns

### Creating Instances

```typescript
// Allocate memory
const instance = NSString.alloc();

// Initialize
const str = instance.initWithString$("Hello");

// Or chain them
const str2 = NSString.alloc().initWithString$("World");
```

### Calling Methods with Arguments

```typescript
const array = foundation["NSArray"];
const arr = array.arrayWithObjects$count$([obj1, obj2, obj3], 3);
```

### Checking if an Object Responds to a Selector

```typescript
if (obj.respondsToSelector$("methodName:")) {
  obj.methodName$("argument");
}
```

## Type Conversions

The library automatically converts between JavaScript and Objective-C types:

- **Strings**: JavaScript strings automatically convert to NSString
- **Numbers**: JavaScript numbers work with NSInteger, CGFloat, etc.
- **Objects**: Objective-C objects are wrapped in `NobjcObject` instances
- **null**: JavaScript `null` maps to Objective-C `nil`

## Common Frameworks

### Foundation Framework

```typescript
const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
```

Provides basic Objective-C classes like `NSString`, `NSArray`, `NSDictionary`, etc.

### AppKit Framework (macOS GUI)

```typescript
const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");
```

Provides UI classes like `NSWindow`, `NSView`, `NSButton`, etc.

### AuthenticationServices Framework

```typescript
const authServices = new NobjcLibrary(
  "/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices"
);
```

Provides authentication-related classes for WebAuthn/Passkeys.

## Next Steps

- Learn how to [subclass Objective-C classes](./subclassing.md)
- Implement [protocols](./protocol-implementation.md)
- Check the [API reference](./api-reference.md)
