# Passing NobjcObject Arguments to Methods

## Overview

The `@iamevan/nobjc` library allows you to pass `NobjcObject` instances as arguments to Objective-C methods. This document explains how this works internally and provides examples of usage.

## The Problem

When calling Objective-C methods that accept object parameters, you need to pass `NobjcObject` instances. However, `NobjcObject` is implemented as a JavaScript Proxy wrapper around the native `ObjcObject`. The native code needs access to the underlying `ObjcObject`, not the Proxy.

### Example of the Issue

```typescript
import { NobjcLibrary } from "@iamevan/nobjc";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];

const str1 = NSString["stringWithUTF8String:"]("Hello");
const str2 = NSString["stringWithUTF8String:"]("World");

// Without unwrapping, this would fail:
// str1.isEqualToString$(str2); // ❌ Error: Invalid argument
```

## The Solution

The library automatically unwraps `NobjcObject` Proxy arguments before passing them to native code. This is done using a Symbol-based mechanism:

1. **Symbol for Native Access**: A private Symbol (`NATIVE_OBJC_OBJECT`) is used to access the underlying native object from a Proxy.

2. **Unwrapping Function**: Before calling `$msgSend`, all arguments are processed through an `unwrapArg` function that:
   - Checks if the argument is a `NobjcObject` Proxy (by testing for the Symbol)
   - Extracts the underlying native `ObjcObject` if it is
   - Returns primitive arguments unchanged

3. **Transparent to Users**: This unwrapping happens automatically, so you can pass `NobjcObject` instances directly.

## Usage Examples

### Example 1: String Comparison

```typescript
import { NobjcLibrary } from "@iamevan/nobjc";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];

const str1 = NSString["stringWithUTF8String:"]("Hello");
const str2 = NSString["stringWithUTF8String:"]("Hello");
const str3 = NSString["stringWithUTF8String:"]("World");

// Compare strings - automatically unwraps str2 and str3
const isEqual1 = str1.isEqualToString$(str2); // ✅ true
const isEqual2 = str1.isEqualToString$(str3); // ✅ false

console.log(`str1 equals str2: ${isEqual1}`);
console.log(`str1 equals str3: ${isEqual2}`);
```

### Example 2: Creating NSData from Bytes

```typescript
import { NobjcLibrary } from "@iamevan/nobjc";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSData = foundation["NSData"];

// Create data from a buffer
const buffer = Buffer.from("Hello, World!");
const data = NSData["dataWithBytes:length:"](buffer, buffer.length);

console.log(`Created NSData with length: ${data.length()}`);
```

### Example 3: Array Operations

```typescript
import { NobjcLibrary } from "@iamevan/nobjc";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSMutableArray = foundation["NSMutableArray"];
const NSString = foundation["NSString"];

// Create an array
const array = NSMutableArray.array();

// Add objects to the array - automatically unwraps the string objects
const str1 = NSString["stringWithUTF8String:"]("First");
const str2 = NSString["stringWithUTF8String:"]("Second");

array.addObject$(str1); // ✅ Works
array.addObject$(str2); // ✅ Works

console.log(`Array count: ${array.count()}`);

// Check if array contains an object
const contains = array.containsObject$(str1); // ✅ true
console.log(`Array contains str1: ${contains}`);
```

### Example 4: Dictionary Operations

```typescript
import { NobjcLibrary } from "@iamevan/nobjc";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSMutableDictionary = foundation["NSMutableDictionary"];
const NSString = foundation["NSString"];

// Create a dictionary
const dict = NSMutableDictionary.dictionary();

// Create key and value objects
const key = NSString["stringWithUTF8String:"]("name");
const value = NSString["stringWithUTF8String:"]("John");

// Set value for key - both arguments are automatically unwrapped
dict["setObject:forKey:"](value, key); // ✅ Works

// Get value for key - key argument is automatically unwrapped
const retrieved = dict.objectForKey$(key);
console.log(`Retrieved value: ${retrieved.toString()}`);
```

## How It Works Internally

### Architecture

```
User Code
    ↓
NobjcObject Proxy (wraps native ObjcObject)
    ↓
NobjcMethod (method call handler)
    ↓
unwrapArg() - extracts native ObjcObject from Proxy
    ↓
$msgSend(selector, unwrapped_arg1, unwrapped_arg2, ...)
    ↓
Native Objective-C Runtime
```

### Implementation Details

1. **Symbol-based Access**:

```typescript
const NATIVE_OBJC_OBJECT = Symbol("nativeObjcObject");
```

2. **Proxy Handler Returns Native Object**:

```typescript
get(target, methodName: string | symbol, receiver: NobjcObject) {
    if (methodName === NATIVE_OBJC_OBJECT) {
        return target;  // Return underlying native ObjcObject
    }
    // ... rest of handler
}
```

3. **Unwrapping Function**:

```typescript
function unwrapArg(arg: any): any {
  if (arg && typeof arg === "object" && NATIVE_OBJC_OBJECT in arg) {
    return arg[NATIVE_OBJC_OBJECT]; // Extract native object
  }
  return arg; // Return primitives unchanged
}
```

4. **Method Call with Unwrapping**:

```typescript
function methodFunc(): any {
  const unwrappedArgs = Array.from(arguments).map(unwrapArg);
  const result = object.$msgSend(selector, ...unwrappedArgs);
  // ... wrap result if needed
}
```

## Supported Argument Types

The unwrapping mechanism handles:

- ✅ **NobjcObject instances**: Automatically unwrapped to native `ObjcObject`
- ✅ **Primitive types**: Strings, numbers, booleans passed through unchanged
- ✅ **Buffers**: Node.js Buffer objects passed through unchanged
- ✅ **null/undefined**: Passed through unchanged

## Limitations

- **Arrays of objects**: If you need to pass an array of `NobjcObject` instances, you must create an `NSArray` instead:

  ```typescript
  // ❌ Won't work: [obj1, obj2, obj3]

  // ✅ Works: Create NSArray
  const array = NSMutableArray.array();
  array.addObject$(obj1);
  array.addObject$(obj2);
  array.addObject$(obj3);
  ```

- **Nested objects**: The unwrapping only happens at the top level of arguments. Nested objects in plain JavaScript objects won't be unwrapped.

## Troubleshooting

### "Invalid argument" errors

If you still get "Invalid argument" errors after this fix:

1. Make sure you've rebuilt the TypeScript: `npm run build` or `bun run build`
2. Verify you're passing the correct types expected by the Objective-C method
3. Check that the method signature matches what you're calling (use `respondsToSelector:` to verify)

### Type checking

TypeScript may not always know that a method accepts `NobjcObject` arguments. You can use type assertions if needed:

```typescript
const result = obj.someMethod$(arg as any);
```

## Summary

The automatic unwrapping of `NobjcObject` arguments makes the library much more ergonomic to use. You can pass `NobjcObject` instances directly to methods without worrying about the Proxy wrapper - the library handles it transparently.
