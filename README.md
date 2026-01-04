# objc-js

> [!WARNING]
> This is not production ready.

**objc-js** is an Objective-C bridge for Node.js. This is a fork of [nobjc](https://github.com/nmggithub/nobjc) by [Noah Gregory](https://github.com/nmggithub).

## Usage

### Basic Usage

```typescript
import { NobjcLibrary } from "objc-js";

// Load a framework
const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

// Get a class and call methods
const NSString = foundation["NSString"];
const str = NSString.stringWithUTF8String$("Hello, World!");
console.log(str.toString());
```

### Subclassing Objective-C Classes

**objc-js** supports defining new Objective-C classes and subclassing existing ones from JavaScript. This allows you to override methods, implement custom behavior, and integrate deeply with macOS frameworks.

See [Subclassing Documentation](./docs/subclassing.md) for detailed usage and examples.

#### Quick Example

```typescript
import { NobjcClass } from "objc-js";

const MyClass = NobjcClass.define({
  name: "MyCustomClass",
  superclass: "NSObject",
  methods: {
    description: {
      types: "@@:", // returns NSString
      implementation: (self) => {
        const superDesc = NobjcClass.super(self, "description");
        const prefix = NSString.stringWithUTF8String$("Custom: ");
        return prefix.stringByAppendingString$(superDesc);
      }
    }
  }
});

const instance = MyClass.alloc().init();
console.log(instance.description().toString()); // "Custom: <MyCustomClass: 0x...>"
```

### Protocol Implementation

**objc-js** supports creating Objective-C protocol implementations from JavaScript. This allows you to create delegate objects that can be passed to Objective-C APIs.

#### Creating a Protocol Implementation

Use `NobjcProtocol.implement()` to create an object that implements a protocol:

```typescript
import { NobjcProtocol } from "objc-js";

const delegate = NobjcProtocol.implement("ASAuthorizationControllerDelegate", {
  authorizationController$didCompleteWithAuthorization$: (controller, authorization) => {
    console.log("Authorization completed successfully!");
    console.log("Authorization:", authorization);
  },
  authorizationController$didCompleteWithError$: (controller, error) => {
    console.error("Authorization failed:", error);
  }
});

// Pass the delegate to an Objective-C API
authController.setDelegate$(delegate);
```

#### Method Naming Convention

Method names use the `$` notation to represent colons in Objective-C selectors:

- Objective-C: `authorizationController:didCompleteWithAuthorization:`
- JavaScript: `authorizationController$didCompleteWithAuthorization$`

#### Argument and Return Value Marshalling

Arguments are automatically converted between JavaScript and Objective-C:

- **Primitives**: Numbers, booleans, and strings are automatically converted
- **Objects**: Objective-C objects are wrapped in `NobjcObject` instances
- **null/nil**: JavaScript `null` maps to Objective-C `nil` and vice versa

#### Memory Management

Memory is automatically managed:

- JavaScript callbacks are kept alive as long as the delegate object exists
- When the Objective-C object is deallocated, the callbacks are automatically released
- No manual cleanup is required

#### Example: WebAuthn/Passkeys with AuthenticationServices

```typescript
import { NobjcLibrary, NobjcProtocol } from "objc-js";

const authServices = new NobjcLibrary(
  "/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices"
);

// Create authorization requests
const ASAuthorizationController = authServices["ASAuthorizationController"];
const controller = ASAuthorizationController.alloc().initWithAuthorizationRequests$(requests);

// Create a delegate
const delegate = NobjcProtocol.implement("ASAuthorizationControllerDelegate", {
  authorizationController$didCompleteWithAuthorization$: (controller, authorization) => {
    // Handle successful authorization
    const credential = authorization.credential();
    console.log("Credential:", credential);
  },
  authorizationController$didCompleteWithError$: (controller, error) => {
    // Handle error
    console.error("Authorization error:", error.localizedDescription());
  }
});

// Set the delegate and perform requests
controller.setDelegate$(delegate);
controller.performRequests();
```

#### Notes

- Protocol implementations are created at runtime using the Objective-C runtime APIs
- If a protocol is not found, a class is still created (useful for informal protocols)
- Method signatures are inferred from the protocol or from the method name
- Thread safety: Currently assumes single-threaded (main thread) usage

### API Reference

#### `NobjcLibrary`

Creates a proxy for accessing Objective-C classes from a framework.

```typescript
const framework = new NobjcLibrary(path: string);
```

#### `NobjcObject`

Wrapper for Objective-C objects. Methods can be called using the `$` notation.

```typescript
const result = object.methodName$arg1$arg2$(arg1, arg2);
```

#### `NobjcClass`

Static class for defining new Objective-C classes and subclassing existing ones.

```typescript
NobjcClass.define(definition: ClassDefinition): NobjcObject
```

**Parameters:**

- `definition.name`: The name of the new Objective-C class (must be unique)
- `definition.superclass`: The name of the superclass (e.g., "NSObject", "NSView")
- `definition.protocols`: (Optional) Array of protocol names to conform to
- `definition.methods`: Object mapping selector names to method definitions

**Returns:** The new class object (can call `.alloc().init()` on it)

See [Subclassing Documentation](./docs/subclassing.md) for more details.

```typescript
NobjcClass.super(self: NobjcObject, selector: string, ...args: any[]): any
```

Call the superclass implementation of a method. Supports methods with any number of arguments, including methods with out-parameters (like `NSError**`).

#### `NobjcProtocol`

Static class for creating protocol implementations.

```typescript
NobjcProtocol.implement(
  protocolName: string,
  methodImplementations: Record<string, (...args: any[]) => any>
): NobjcObject
```

**Parameters:**

- `protocolName`: The name of the Objective-C protocol (e.g., "NSCopying", "ASAuthorizationControllerDelegate")
- `methodImplementations`: An object mapping method names (using `$` notation) to JavaScript functions

**Returns:** A `NobjcObject` that can be passed to Objective-C APIs expecting the protocol

#### `getPointer()`

Get the raw native pointer for a NobjcObject as a Node Buffer. This is useful for passing Objective-C objects to native APIs that expect raw pointers, such as Electron's native window handles.

```typescript
function getPointer(obj: NobjcObject): Buffer;
```

**Parameters:**

- `obj`: The NobjcObject to get the pointer from

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

#### `fromPointer()`

Create a NobjcObject from a raw native pointer. This is the inverse of `getPointer()` and allows you to reconstruct an Objective-C object from a pointer address.

```typescript
function fromPointer(pointer: Buffer | bigint): NobjcObject;
```

**Parameters:**

- `pointer`: A Buffer (8 bytes in little-endian format) or BigInt containing the pointer address

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

**⚠️ Safety Warning:**

This function is **inherently unsafe** and should be used with extreme caution:

- **Invalid pointers will crash your program**: The pointer must point to a valid Objective-C object
- **Dangling pointers**: The object must still be alive (not deallocated). Accessing a deallocated object will crash
- **No type checking**: There's no way to verify the pointer points to the expected type of object
- **Memory management**: Be aware of Objective-C reference counting. The object must remain valid for the lifetime of your usage

Only use this function when:

- You received the pointer from `getPointer()` and the object is still alive
- You received the pointer from a trusted native API that guarantees the object's validity
- You're interfacing with external native code that provides valid Objective-C object pointers
