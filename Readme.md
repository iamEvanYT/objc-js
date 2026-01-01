# objc-js

> [!WARNING]
> This is not production ready.

**objc-js** is an Objective-C bridge for Node.js. This is a fork of [nobjc](https://github.com/nmggithub/nobjc) by [Noah Gregory](https://github.com/nmggithub).

## Usage

### Basic Usage

```typescript
import { NobjcLibrary } from "objc-js";

// Load a framework
const foundation = new NobjcLibrary(
  "/System/Library/Frameworks/Foundation.framework/Foundation"
);

// Get a class and call methods
const NSString = foundation["NSString"];
const str = NSString.stringWithUTF8String$("Hello, World!");
console.log(str.toString());
```

### Protocol Implementation

**objc-js** now supports creating Objective-C protocol implementations from JavaScript. This allows you to create delegate objects that can be passed to Objective-C APIs.

#### Creating a Protocol Implementation

Use `NobjcProtocol.implement()` to create an object that implements a protocol:

```typescript
import { NobjcProtocol } from "objc-js";

const delegate = NobjcProtocol.implement("ASAuthorizationControllerDelegate", {
  authorizationController$didCompleteWithAuthorization$: (
    controller,
    authorization
  ) => {
    console.log("Authorization completed successfully!");
    console.log("Authorization:", authorization);
  },
  authorizationController$didCompleteWithError$: (controller, error) => {
    console.error("Authorization failed:", error);
  },
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
const controller =
  ASAuthorizationController.alloc().initWithAuthorizationRequests$(requests);

// Create a delegate
const delegate = NobjcProtocol.implement("ASAuthorizationControllerDelegate", {
  authorizationController$didCompleteWithAuthorization$: (
    controller,
    authorization
  ) => {
    // Handle successful authorization
    const credential = authorization.credential();
    console.log("Credential:", credential);
  },
  authorizationController$didCompleteWithError$: (controller, error) => {
    // Handle error
    console.error("Authorization error:", error.localizedDescription());
  },
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
