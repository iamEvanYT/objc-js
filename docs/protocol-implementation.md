# Protocol Implementation Support

## Overview

The `@iamevan/nobjc` library now supports creating Objective-C protocol implementations from JavaScript. This enables you to create custom delegate objects that implement protocols like `ASAuthorizationControllerDelegate`, `NSCopying`, and any other Objective-C protocol.

## Features

- **Dynamic Class Creation**: Creates Objective-C classes at runtime using the Objective-C runtime APIs
- **Protocol Conformance**: Automatically adds protocol conformance when the protocol is found
- **Method Implementation**: Converts JavaScript functions to Objective-C method implementations
- **Automatic Memory Management**: JavaScript callbacks are kept alive for the lifetime of the delegate object
- **Argument Marshalling**: Automatically converts arguments between JavaScript and Objective-C types
- **Type Safety**: Supports all standard Objective-C types (primitives, objects, strings, etc.)

## API

### `NobjcProtocol.implement(protocolName, methodImplementations)`

Creates a new Objective-C object that implements the specified protocol.

**Parameters:**

- `protocolName` (string): The name of the Objective-C protocol (e.g., "ASAuthorizationControllerDelegate")
- `methodImplementations` (object): An object mapping method names to JavaScript functions

**Returns:** A `NobjcObject` that can be passed to Objective-C APIs

**Example:**

```typescript
import { NobjcProtocol } from "@iamevan/nobjc";

const delegate = NobjcProtocol.implement("ASAuthorizationControllerDelegate", {
  authorizationController$didCompleteWithAuthorization$: (controller, authorization) => {
    console.log("Authorization completed successfully!");
  },
  authorizationController$didCompleteWithError$: (controller, error) => {
    console.error("Authorization failed:", error);
  }
});

// Use the delegate with an Objective-C API
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

1. **Callback Lifetime**: JavaScript callbacks are stored in a global map and kept alive using `Napi::FunctionReference`
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
2. **No Return Values**: Method implementations currently don't support return values (always return void)
3. **Limited Pointer Support**: Pointer types (other than objects) have limited support

### Future Enhancements

1. **Thread Safety**: Add support for callbacks from non-JavaScript threads using `Napi::ThreadSafeFunction`
2. **Return Values**: Add support for returning values from JavaScript callbacks
3. **Better Pointer Handling**: Improve support for arbitrary pointer types
4. **Struct Support**: Add support for passing structs by value
5. **Block Support**: Add support for block arguments

## Testing

The implementation includes comprehensive tests in `scripts/test-protocol-implementation.ts`:

- Creating protocol implementations
- Multiple protocol implementations
- Object and primitive arguments
- Memory management
- Real protocol conformance (NSCopying)

Run tests with:

```bash
npm run test-protocol-implementation
```

## Example: WebAuthn/Passkeys

Here's a complete example using `ASAuthorizationController`:

```typescript
import { NobjcLibrary, NobjcProtocol } from "@iamevan/nobjc";

// Load the AuthenticationServices framework
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

## Contributing

When adding new features or fixing bugs:

1. Update the native implementation in `src/native/protocol-impl.mm`
2. Update type definitions in `types/native/nobjc_native.d.ts`
3. Add tests to `scripts/test-protocol-implementation.ts`
4. Update documentation in this file and the README
