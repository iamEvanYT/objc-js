# Protocol Implementation

**objc-js** supports creating Objective-C protocol implementations from JavaScript. This allows you to create delegate objects that can be passed to Objective-C APIs.

## Overview

The `NobjcProtocol.implement()` API enables you to create custom delegate objects that implement protocols like `ASAuthorizationControllerDelegate`, `NSCopying`, and any other Objective-C protocol.

### Features

- **Dynamic Class Creation**: Creates Objective-C classes at runtime using the Objective-C runtime APIs
- **Protocol Conformance**: Automatically adds protocol conformance when the protocol is found
- **Method Implementation**: Converts JavaScript functions to Objective-C method implementations
- **Automatic Memory Management**: JavaScript callbacks are kept alive for the lifetime of the delegate object
- **Argument Marshalling**: Automatically converts arguments between JavaScript and Objective-C types
- **Type Safety**: Supports all standard Objective-C types (primitives, objects, strings, etc.)

## Creating a Protocol Implementation

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

## Method Naming Convention

Method names use the `$` notation to represent colons in Objective-C selectors:

| Objective-C Selector                                    | JavaScript Method Name                                  |
| ------------------------------------------------------- | ------------------------------------------------------- |
| `method`                                                | `method`                                                |
| `method:`                                               | `method$`                                               |
| `method:withArg:`                                       | `method$withArg$`                                       |
| `authorizationController:didCompleteWithAuthorization:` | `authorizationController$didCompleteWithAuthorization$` |

## Type Conversion

Arguments and return values are automatically converted between JavaScript and Objective-C:

| Objective-C Type                            | JavaScript Type | Notes                |
| ------------------------------------------- | --------------- | -------------------- |
| `char`, `int`, `short`, `long`, `long long` | `number`        | Signed integers      |
| `unsigned char`, `unsigned int`, etc.       | `number`        | Unsigned integers    |
| `float`, `double`                           | `number`        | Floating point       |
| `BOOL`                                      | `boolean`       | Boolean values       |
| `char *`                                    | `string`        | C strings            |
| `id`, `NSObject *`                          | `NobjcObject`   | Objective-C objects  |
| `Class`                                     | `NobjcObject`   | Objective-C classes  |
| `SEL`                                       | `string`        | Selectors as strings |
| `nil`                                       | `null`          | Null values          |

## Memory Management

Memory is automatically managed:

1. **Callback Lifetime**: JavaScript callbacks are stored in a global map and kept alive
2. **Automatic Cleanup**: When the Objective-C object is deallocated, the callbacks are automatically released
3. **No Manual Cleanup**: You don't need to call any cleanup methods

## Implementation Details

### Native Implementation

The implementation uses the following Objective-C runtime APIs:

- `objc_getProtocol()`: Looks up the protocol by name
- `objc_allocateClassPair()`: Creates a new class at runtime
- `class_addMethod()`: Adds method implementations to the class
- `class_addProtocol()`: Makes the class conform to the protocol
- `objc_registerClassPair()`: Registers the class with the runtime
- `imp_implementationWithBlock()`: Creates method implementations from blocks

### Class Naming

Each protocol implementation gets a unique class name in the format:

```
JSProtocolImpl_<timestamp>_<counter>
```

This ensures that multiple implementations can coexist without conflicts.

### Method Signatures

When a protocol is found, method signatures are retrieved from the protocol metadata. If a protocol is not found (e.g., for informal protocols), default type encodings are used based on the number of arguments.

## Limitations and Future Enhancements

### Current Limitations

1. **Single-threaded**: Currently assumes callbacks are invoked on the main thread
2. **Limited Pointer Support**: Pointer types (other than objects) have limited support

### Future Enhancements

1. **Thread Safety**: Add support for callbacks from non-JavaScript threads
2. **Better Pointer Handling**: Improve support for arbitrary pointer types
3. **Struct Support**: Add support for passing structs by value

## Examples

### Basic Delegate

```typescript
import { NobjcLibrary, NobjcProtocol } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];

const delegate = NobjcProtocol.implement("NSCopying", {
  copyWithZone$: (zone) => {
    console.log("Copying object");
    // Return a copy
    return NSString.stringWithUTF8String$("Copy");
  }
});
```

### WebAuthn/Passkeys with AuthenticationServices

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

    if (credential.respondsToSelector$("rawClientDataJSON")) {
      // This is a passkey credential
      const clientDataJSON = credential.rawClientDataJSON();
      const authenticatorData = credential.rawAuthenticatorData();
      const signature = credential.signature();

      console.log("Passkey authentication successful!");
      // Process the credential...
    }
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

## Troubleshooting

### "Protocol X not found" Warning

This warning appears when the specified protocol name is not found in the Objective-C runtime. The implementation will still create a class with the specified methods, but it won't formally conform to the protocol. This is fine for informal protocols or when you just need an object with specific methods.

### "No type encoding found for selector" Warning

This warning appears when a method signature cannot be retrieved from the protocol. The implementation will use a default type encoding (assuming object arguments). If you need specific type encodings, make sure the protocol is properly registered in the runtime.

### Callbacks Not Being Invoked

If your callbacks aren't being invoked:

1. Make sure the method names match the expected selector names (use `$` for colons)
2. Check that the delegate is being retained (store it in a variable that stays in scope)
3. Verify that the Objective-C code is actually calling the delegate methods

## See Also

- [Subclassing Documentation](./subclassing.md)
- [API Reference](./api-reference.md)
