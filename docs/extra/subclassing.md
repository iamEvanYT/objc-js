# Subclassing Objective-C Classes

**objc-js** allows you to define new Objective-C classes and subclass existing ones from JavaScript. This enables you to override methods, implement custom behavior, and integrate deeply with macOS frameworks.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Defining a Class](#defining-a-class)
- [Method Type Encodings](#method-type-encodings)
- [Calling Super](#calling-super)
- [Protocol Conformance](#protocol-conformance)
- [Complete Examples](#complete-examples)
- [Limitations](#limitations)

## Basic Usage

Use `NobjcClass.define()` to create a new Objective-C class:

```typescript
import { NobjcClass } from "objc-js";

const MyClass = NobjcClass.define({
  name: "MyCustomClass",
  superclass: "NSObject",
  methods: {
    customMethod: {
      types: "v@:", // void return, self, _cmd
      implementation: (self) => {
        console.log("Custom method called!");
      }
    }
  }
});

// Create an instance
const instance = MyClass.alloc().init();
instance.customMethod();
```

## Defining a Class

The `NobjcClass.define()` method takes a `ClassDefinition` object with the following properties:

### Class Name

```typescript
{
  name: "MyClassName"; // Must be unique across your app
}
```

The class name must be unique. Attempting to define a class with an existing name will throw an error.

### Superclass

```typescript
{
  superclass: "NSObject"; // Any Objective-C class name
}
```

You can subclass any Objective-C class:

- `"NSObject"` - Base class for most objects
- `"NSView"` - macOS views
- `"NSViewController"` - macOS view controllers
- Any other framework class

**Note:** Subclassing class clusters (like `NSString`, `NSArray`, `NSDictionary`) requires implementing primitive methods and is not currently supported.

### Methods

```typescript
{
  methods: {
    "methodName": {
      types: "@@:",  // Type encoding
      implementation: (self, ...args) => {
        // Method implementation
      }
    },
    "methodWith$arg$": {
      types: "v@:@i",  // void return, object arg, int arg
      implementation: (self, obj, num) => {
        console.log(obj, num);
      }
    }
  }
}
```

#### Method Naming

- Use the Objective-C selector directly for simple methods: `"init"`, `"description"`
- Use `$` notation for methods with arguments: `"methodWith$arg$"` for `methodWith:arg:`

#### Method Implementation

The implementation function receives:

1. `self` - The instance receiving the message (as a `NobjcObject`)
2. Remaining arguments as specified in the method signature

The function should return the value specified by the return type encoding.

### Protocols (Optional)

```typescript
{
  protocols: ["NSCopying", "NSCoding"];
}
```

Specify protocol names the class should conform to. The class will be registered as conforming to these protocols, and you must implement the required methods.

## Method Type Encodings

Type encodings describe the method signature using Objective-C type encoding notation.

### Format

```
[return type][self][@][_cmd][:][argument types...]
```

- `[return type]` - Single character for return type
- `@` - Type for `self`
- `:` - Type for `_cmd` (selector)
- `[argument types]` - Types for each argument (beyond `self` and `_cmd`)

### Common Type Codes

| Code | Type                            | JavaScript Type     |
| ---- | ------------------------------- | ------------------- |
| `v`  | void                            | undefined           |
| `@`  | id (object)                     | NobjcObject         |
| `#`  | Class                           | NobjcObject (class) |
| `c`  | char                            | number              |
| `i`  | int                             | number              |
| `s`  | short                           | number              |
| `l`  | long                            | number              |
| `q`  | long long (NSInteger)           | number              |
| `C`  | unsigned char                   | number              |
| `I`  | unsigned int                    | number              |
| `S`  | unsigned short                  | number              |
| `L`  | unsigned long                   | number              |
| `Q`  | unsigned long long (NSUInteger) | number              |
| `f`  | float                           | number              |
| `d`  | double                          | number              |
| `B`  | BOOL                            | boolean             |
| `*`  | char\* (C string)               | string              |
| `^v` | void\* (pointer)                | (varies)            |

### Examples

```typescript
// void method, no arguments
"v@:";

// Returns NSString*, no arguments
"@@:";

// Returns NSInteger, no arguments
"q@:";

// Returns BOOL, no arguments
"B@:";

// void method, takes NSString* argument
"v@:@";

// Returns NSString*, takes NSString* and NSInteger arguments
"@@:@q";

// Returns id, takes id and BOOL arguments
"@@:@B";

// Returns void, takes pointer argument (e.g., NSZone*)
"v@:^v";
```

## Calling Super

Use `NobjcClass.super()` to call the superclass implementation:

```typescript
const MyClass = NobjcClass.define({
  name: "MyClass",
  superclass: "NSObject",
  methods: {
    description: {
      types: "@@:",
      implementation: (self) => {
        // Call super's description
        const superDesc = NobjcClass.super(self, "description");

        // Modify and return
        const prefix = NSString.stringWithUTF8String$("Custom: ");
        return prefix.stringByAppendingString$(superDesc);
      }
    }
  }
});
```

### Super Call Syntax

```typescript
NobjcClass.super(self, selectorName, ...args);
```

- `self` - The instance (received as first argument in method implementation)
- `selectorName` - The Objective-C selector name (e.g., `"description"`, `"initWithString:"`, `"contentsOfDirectoryAtPath:error:"`)
- `...args` - Arguments to pass to the superclass method

### Examples

#### Zero Arguments

```typescript
// Calling super.init()
init: {
  types: "@@:",
  implementation: (self) => {
    self = NobjcClass.super(self, "init");
    // Custom initialization
    return self;
  }
}
```

#### With Arguments

```typescript
// Calling super with an object argument
isEqual$: {
  types: "B@:@",
  implementation: (self, other) => {
    // First check if super considers them equal
    const superEqual = NobjcClass.super(self, "isEqual:", other);
    if (superEqual) return true;

    // Custom equality check
    return myCustomEqualityCheck(self, other);
  }
}
```

#### With Out-Parameters

Methods with out-parameters (like `NSError**`) are fully supported:

```typescript
// Calling super with an NSError** out-parameter
contentsOfDirectoryAtPath$error$: {
  types: "@@:@^@",  // Returns NSArray*, takes NSString* and NSError**
  implementation: (self, path, errorPtr) => {
    console.log("Custom directory listing for:", path.toString());

    // Call super - pass null for errorPtr
    const contents = NobjcClass.super(
      self,
      "contentsOfDirectoryAtPath:error:",
      path,
      null  // or errorPtr if you want to handle errors
    );

    // Custom processing
    if (contents) {
      console.log("Found", contents.count(), "items");
    }

    return contents;
  }
}
```

**Note:** For out-parameters like `NSError**`, you can pass `null` from JavaScript. The native code will allocate the appropriate storage and pass a valid pointer to the superclass method.

## Protocol Conformance

To conform to a protocol, specify it in the `protocols` array and implement its required methods:

```typescript
const MyClass = NobjcClass.define({
  name: "MyCopyable",
  superclass: "NSObject",
  protocols: ["NSCopying"],
  methods: {
    "copyWithZone:": {
      types: "@@:^v", // Returns id, takes NSZone* pointer
      implementation: (self, zone) => {
        // Create a copy
        const copy = MyClass.alloc().init();
        // ... copy data ...
        return copy;
      }
    }
  }
});
```

## Complete Examples

### Example 1: Simple Subclass

```typescript
import { NobjcLibrary, NobjcClass } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];

const MyClass = NobjcClass.define({
  name: "SimpleSubclass",
  superclass: "NSObject",
  methods: {
    greeting: {
      types: "@@:",
      implementation: (self) => {
        return NSString.stringWithUTF8String$("Hello from my subclass!");
      }
    }
  }
});

const instance = MyClass.alloc().init();
const message = instance.greeting();
console.log(message.toString()); // "Hello from my subclass!"
```

### Example 2: Overriding Init

```typescript
const MyClass = NobjcClass.define({
  name: "InitExample",
  superclass: "NSObject",
  methods: {
    init: {
      types: "@@:",
      implementation: (self) => {
        // Always call super.init() and return its result
        self = NobjcClass.super(self, "init");

        // Do custom initialization here
        console.log("Custom initialization!");

        return self;
      }
    }
  }
});

const instance = MyClass.alloc().init(); // Logs "Custom initialization!"
```

### Example 3: Methods with Arguments

```typescript
const MyClass = NobjcClass.define({
  name: "ArgumentExample",
  superclass: "NSObject",
  methods: {
    processString$withNumber$: {
      types: "v@:@q", // void, NSString*, NSInteger
      implementation: (self, str, num) => {
        console.log("String:", str.toString());
        console.log("Number:", num);
      }
    },
    addNumbers$and$: {
      types: "q@:qq", // returns NSInteger, takes two NSIntegers
      implementation: (self, a, b) => {
        return a + b;
      }
    }
  }
});

const instance = MyClass.alloc().init();
const str = NSString.stringWithUTF8String$("Test");
instance.processString$withNumber$(str, 42);

const sum = instance.addNumbers$and$(10, 20);
console.log(sum); // 30
```

### Example 4: Overriding Description

```typescript
const MyClass = NobjcClass.define({
  name: "DescriptionExample",
  superclass: "NSObject",
  methods: {
    description: {
      types: "@@:",
      implementation: (self) => {
        const superDesc = NobjcClass.super(self, "description");
        const prefix = NSString.stringWithUTF8String$("MyClass(");
        const suffix = NSString.stringWithUTF8String$(")");

        return prefix.stringByAppendingString$(superDesc).stringByAppendingString$(suffix);
      }
    }
  }
});

const instance = MyClass.alloc().init();
console.log(instance.description().toString());
// "MyClass(<DescriptionExample: 0x123456789>)"
```

### Example 5: ASAuthorizationController Subclass with Super Call

This example shows how to subclass `ASAuthorizationController` to override a private method for WebAuthn/passkey operations. This demonstrates calling super with both object arguments and out-parameters:

```typescript
import { NobjcLibrary, NobjcClass } from "objc-js";

const authServices = new NobjcLibrary(
  "/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices"
);
const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

const NSString = foundation["NSString"];
const NSData = foundation["NSData"];
const ASAuthorizationController = authServices["ASAuthorizationController"];

// Your clientDataHash for WebAuthn
const clientDataHash = Buffer.from("your-hash-here", "base64");

const MyAuthController = NobjcClass.define({
  name: "MyASAuthorizationController",
  superclass: "ASAuthorizationController",
  methods: {
    "_requestContextWithRequests:error:": {
      types: "@@:@^@", // Returns id, takes NSArray*, NSError**
      implementation: (self, requests, errorPtr) => {
        console.log("Custom implementation called");

        // Call super with arguments including the error out-parameter
        // Pass null for errorPtr - the native code handles this correctly
        const context = NobjcClass.super(
          self,
          "_requestContextWithRequests:error:",
          requests,
          null // errorPtr - automatically handled
        );

        if (context) {
          // Create NSData from Buffer
          const hashData = NSData.alloc().initWithBytes$length$(clientDataHash, clientDataHash.length);

          // Set the clientDataHash on the context
          context.setClientDataHash$(hashData);
          console.log("clientDataHash set successfully");
        }

        return context;
      }
    }
  }
});

// Use your custom controller instead of ASAuthorizationController
const controller = MyAuthController.alloc().initWithAuthorizationRequests$(requests);
controller.setDelegate$(delegate);
controller.performRequests();
```

**Key Points:**

- The method signature includes `^@` for the `NSError**` out-parameter
- When calling super, you can pass `null` for out-parameters
- The native code properly allocates storage and passes valid pointers to the superclass
- This pattern works for any method with out-parameters (NSError\*_, id_, etc.)

### Example 6: File Manager Subclass

This example demonstrates overriding a method with multiple arguments, including an out-parameter:

```typescript
import { NobjcLibrary, NobjcClass } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSFileManager = foundation["NSFileManager"];
const NSString = foundation["NSString"];

const LoggingFileManager = NobjcClass.define({
  name: "LoggingFileManager",
  superclass: "NSFileManager",
  methods: {
    contentsOfDirectoryAtPath$error$: {
      types: "@@:@^@", // Returns NSArray*, takes NSString* path, NSError** error
      implementation: (self, path, errorPtr) => {
        console.log("Reading directory:", path.toString());

        // Call super with both arguments
        const contents = NobjcClass.super(
          self,
          "contentsOfDirectoryAtPath:error:",
          path,
          null // errorPtr handled automatically
        );

        if (contents) {
          const count = contents.count();
          console.log(`  Found ${count} items`);
        } else {
          console.log("  Failed to read directory");
        }

        return contents;
      }
    }
  }
});

const manager = LoggingFileManager.alloc().init();
const tmpPath = NSString.stringWithUTF8String$("/tmp");
const contents = manager.contentsOfDirectoryAtPath$error$(tmpPath, null);
```

## Limitations

### Current Limitations

1. **Class clusters**: Cannot subclass class clusters like `NSString`, `NSArray`, `NSDictionary`, `NSNumber`, or `NSMutableString` because they require implementing primitive methods.

2. **Struct return types**: Methods that return structs (like `NSRect`, `NSPoint`, `NSSize`) may not work correctly on all architectures.

3. **Variadic methods**: Cannot define or call methods with variadic arguments (e.g., `stringWithFormat:, ...`).

### Out-Parameter Support

Out-parameters (like `NSError**`, `id**`) are fully supported in both method definitions and super calls:

- When defining methods with out-parameters, declare them in the type encoding (e.g., `^@` for `NSError**`)
- When calling super with out-parameters, pass `null` from JavaScript
- The native code automatically allocates the required storage and passes valid pointers
- If the superclass writes an error, it will be stored but not currently accessible from JavaScript (this is a limitation for future enhancement)

### Thread Safety

- Method implementations are called on the same thread that invokes the Objective-C method
- If the Objective-C runtime calls your method from a background thread, your JavaScript code will be marshaled to the JavaScript thread
- Return values are properly synchronized across threads

### Memory Management

- Subclass definitions are kept alive for the lifetime of the application
- JavaScript method implementations are automatically retained
- Instance data should be managed carefully - consider using associated objects or weak maps if you need per-instance state

## See Also

- [Protocol Implementation Documentation](./protocol-implementation.md)
- [Object Arguments Documentation](./object-arguments.md)
- [Subclassing Design Document](./subclassing-design.md)
