# API Reference

Complete reference for the **objc-js** public API.

## NobjcLibrary

Creates a proxy for accessing Objective-C classes from a framework.

### Constructor

```typescript
const framework = new NobjcLibrary(path: string);
```

**Parameters:**

- `path` (string): The full path to the framework. Example: `/System/Library/Frameworks/Foundation.framework/Foundation`

**Example:**

```typescript
import { NobjcLibrary } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");
const authServices = new NobjcLibrary("/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices");
```

### Accessing Classes

Access classes using bracket notation:

```typescript
const NSString = framework["NSString"];
const NSArray = framework["NSArray"];
```

The returned object is a `NobjcObject` representing the class, which can be used to call class methods or create instances.

## NobjcObject

Wrapper for Objective-C objects. Methods can be called using the `$` notation where `$` represents colons in Objective-C selectors.

### Calling Methods

```typescript
const result = object.methodName$arg1$arg2$(arg1, arg2);
```

**Example:**

```typescript
const str = NSString.stringWithUTF8String$("Hello");
const length = str.length();
const substring = str.substringFromIndex$(5);
```

### Common Methods

All Objective-C objects support standard NSObject methods:

```typescript
// Get description
const desc = object.description();

// Check if responds to selector
if (object.respondsToSelector$("methodName")) {
  object.methodName();
}

// Get class
const cls = object.class();

// Check if kind of class
if (object.isKindOfClass$(NSString)) {
  // object is an NSString
}

// Check instance of class
if (object.isMemberOfClass$(NSString)) {
  // object is exactly NSString, not a subclass
}
```

### Memory Management

Memory is handled automatically by the bridge. Reference counting follows Objective-C semantics:

```typescript
// Create and use objects
const obj = NSString.alloc().initWithString$("Hello");
console.log(obj.toString());
// obj is automatically released when no longer referenced
```

## NobjcClass

Static class for defining new Objective-C classes and subclassing existing ones.

### NobjcClass.define()

Defines a new Objective-C class that can be subclassed from JavaScript.

```typescript
NobjcClass.define(definition: ClassDefinition): NobjcObject
```

**Parameters:**

The `definition` parameter is an object with:

- `name` (string): The name of the new Objective-C class (must be unique)
- `superclass` (string): The name of the superclass (e.g., "NSObject", "NSView")
- `protocols` (string[], optional): Array of protocol names to conform to
- `methods` (object): Object mapping selector names to method definitions

**Method Definition:**

```typescript
{
  [selectorName]: {
    types: string;        // Type encoding (required)
    implementation: function; // Implementation function (required)
  }
}
```

**Type Encoding:**

A string describing the method signature. See [Subclassing Documentation](./subclassing.md#method-type-encodings) for details.

**Returns:** The new class object (can call `.alloc().init()` on it)

**Example:**

```typescript
import { NobjcClass } from "objc-js";

const MyClass = NobjcClass.define({
  name: "MyCustomClass",
  superclass: "NSObject",
  protocols: ["NSCopying"],
  methods: {
    description: {
      types: "@@:",
      implementation: (self) => {
        return NSString.stringWithUTF8String$("MyClass instance");
      }
    },
    processString$: {
      types: "v@:@",
      implementation: (self, str) => {
        console.log("Processing:", str.toString());
      }
    }
  }
});

const instance = MyClass.alloc().init();
instance.processString$(NSString.stringWithUTF8String$("Hello"));
```

See [Subclassing Documentation](./subclassing.md) for more details and examples.

### NobjcClass.super()

Call the superclass implementation of a method. Supports methods with any number of arguments, including methods with out-parameters (like `NSError**`).

```typescript
NobjcClass.super(self: NobjcObject, selector: string, ...args: any[]): any
```

**Parameters:**

- `self` (NobjcObject): The instance (received as first argument in method implementation)
- `selector` (string): The Objective-C selector name (e.g., `"description"`, `"initWithString:"`)
- `...args`: Arguments to pass to the superclass method

**Returns:** The return value from the superclass method

**Example:**

```typescript
description: {
  types: "@@:",
  implementation: (self) => {
    const superDesc = NobjcClass.super(self, "description");
    const prefix = NSString.stringWithUTF8String$("Custom: ");
    return prefix.stringByAppendingString$(superDesc);
  }
}
```

See [Subclassing Documentation](./subclassing.md#calling-super) for more details and examples.

## NobjcProtocol

Static class for creating protocol implementations.

### NobjcProtocol.implement()

Creates a new Objective-C object that implements the specified protocol.

```typescript
NobjcProtocol.implement(
  protocolName: string,
  methodImplementations: Record<string, (...args: any[]) => any>
): NobjcObject
```

**Parameters:**

- `protocolName` (string): The name of the Objective-C protocol (e.g., "NSCopying", "ASAuthorizationControllerDelegate")
- `methodImplementations` (object): An object mapping method names (using `$` notation) to JavaScript functions

**Returns:** A `NobjcObject` that can be passed to Objective-C APIs expecting the protocol

**Example:**

```typescript
import { NobjcProtocol } from "objc-js";

const delegate = NobjcProtocol.implement("ASAuthorizationControllerDelegate", {
  authorizationController$didCompleteWithAuthorization$: (controller, authorization) => {
    console.log("Authorization completed successfully!");
    const credential = authorization.credential();
    console.log("Credential:", credential);
  },
  authorizationController$didCompleteWithError$: (controller, error) => {
    console.error("Authorization failed:", error);
  }
});

authController.setDelegate$(delegate);
```

See [Protocol Implementation Documentation](./protocol-implementation.md) for more details and examples.

## getPointer()

Get the raw native pointer for a NobjcObject as a Node Buffer. This is useful for passing Objective-C objects to native APIs that expect raw pointers, such as Electron's native window handles.

```typescript
function getPointer(obj: NobjcObject): Buffer;
```

**Parameters:**

- `obj` (NobjcObject): The NobjcObject to get the pointer from

**Returns:** A Buffer containing the pointer address in little-endian format (8 bytes on 64-bit macOS)

**Example: Getting an NSView pointer**

```typescript
import { NobjcLibrary, getPointer } from "objc-js";

// Load AppKit framework
const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");

// Get an NSWindow and its content view
const NSApplication = appKit["NSApplication"];
const app = NSApplication.sharedApplication();
const window = app.mainWindow();
const view = window.contentView();

// Get the raw pointer as a Buffer
const pointerBuffer = getPointer(view);

// Read the pointer as a BigInt (64-bit unsigned integer)
const pointer = pointerBuffer.readBigUInt64LE(0);
console.log(`NSView pointer: 0x${pointer.toString(16)}`);

// Use with Electron or other native APIs
// const { BrowserWindow } = require('electron');
// const win = BrowserWindow.fromId(pointer);
```

**Note:** The pointer is returned as a Buffer in little-endian format. Use `readBigUInt64LE(0)` to read it as a 64-bit unsigned integer, which is the standard pointer size on macOS.

## fromPointer()

Create a NobjcObject from a raw native pointer. This is the inverse of `getPointer()` and allows you to reconstruct an Objective-C object from a pointer address.

```typescript
function fromPointer(pointer: Buffer | bigint): NobjcObject;
```

**Parameters:**

- `pointer` (Buffer | bigint): A Buffer (8 bytes in little-endian format) or BigInt containing the pointer address

**Returns:** A NobjcObject wrapping the native Objective-C object

**Example: Round-trip pointer conversion**

```typescript
import { NobjcLibrary, getPointer, fromPointer } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];

// Create an original object
const original = NSString.stringWithUTF8String$("Hello, World!");
console.log(original.toString()); // "Hello, World!"

// Get the pointer
const pointerBuffer = getPointer(original);
const pointer = pointerBuffer.readBigUInt64LE(0);
console.log(`Pointer: 0x${pointer.toString(16)}`);

// Reconstruct the object from the pointer
const reconstructed = fromPointer(pointer);
// or: const reconstructed = fromPointer(pointerBuffer);

console.log(reconstructed.toString()); // "Hello, World!"

// Both objects reference the same underlying Objective-C object
const ptr1 = getPointer(original).readBigUInt64LE(0);
const ptr2 = getPointer(reconstructed).readBigUInt64LE(0);
console.log(ptr1 === ptr2); // true
```

**Example: Using with external native APIs**

```typescript
// Receive a pointer from an external API
const externalPointer = 0x12345678n; // Example pointer from native code

// Convert it to a NobjcObject
const nsObject = fromPointer(externalPointer);

// Now you can call Objective-C methods on it
console.log(nsObject.description());
```

### ⚠️ Safety Warning

This function is **inherently unsafe** and should be used with extreme caution:

- **Invalid pointers will crash your program**: The pointer must point to a valid Objective-C object
- **Dangling pointers**: The object must still be alive (not deallocated). Accessing a deallocated object will crash
- **No type checking**: There's no way to verify the pointer points to the expected type of object
- **Memory management**: Be aware of Objective-C reference counting. The object must remain valid for the lifetime of your usage

Only use this function when:

- You received the pointer from `getPointer()` and the object is still alive
- You received the pointer from a trusted native API that guarantees the object's validity
- You're interfacing with external native code that provides valid Objective-C object pointers

## Framework Paths

Common framework paths for macOS:

### Foundation Framework

```typescript
const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
```

Provides basic Objective-C classes: `NSString`, `NSArray`, `NSDictionary`, `NSNumber`, `NSDate`, etc.

### AppKit Framework

```typescript
const appKit = new NobjcLibrary("/System/Library/Frameworks/AppKit.framework/AppKit");
```

Provides macOS GUI classes: `NSWindow`, `NSView`, `NSButton`, `NSTextField`, `NSApplication`, etc.

### AuthenticationServices Framework

```typescript
const authServices = new NobjcLibrary("/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices");
```

Provides authentication classes: `ASAuthorizationController`, `ASAuthorizationControllerDelegate`, etc.

### CoreGraphics Framework

```typescript
const coreGraphics = new NobjcLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics");
```

Provides graphics-related functionality.

### Other Frameworks

Most macOS system frameworks follow the same path pattern:

```typescript
/System/Library/Frameworks/[FrameworkName].framework/[FrameworkName]
```

## See Also

- [Basic Usage](./basic-usage.md)
- [Subclassing Documentation](./subclassing.md)
- [Protocol Implementation Documentation](./protocol-implementation.md)
