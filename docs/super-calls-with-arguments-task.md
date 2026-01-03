# Task: Implement Super Calls with Arguments

## Problem Statement

The current `CallSuper` implementation in `src/native/subclass-impl.mm` (lines 643-905) only supports calling superclass methods **without arguments**. It uses direct `objc_msgSendSuper` calls with just `(struct objc_super*, SEL)` signatures, ignoring any arguments that were marshalled into the `NSInvocation`.

When JavaScript code calls `NobjcClass.super(self, "someMethod:withArg:", arg1, arg2)`, the arguments are converted and stored in an `NSInvocation` object, but then the code just calls `objc_msgSendSuper(&superStruct, selector)` without passing those arguments.

## Current Code Location

File: `/Users/evan/Developer/npm/nobjc/src/native/subclass-impl.mm`
Function: `CallSuper` (starts at line 643)

The problematic section is around lines 839-916, where we have a switch statement handling different return types but no argument passing.

## What Needs to Be Done

Implement proper argument passing to `objc_msgSendSuper` for methods that take parameters.

### Approach Options

**Option 1: Use NSInvocation with objc_msgSendSuper (Recommended)**

Since we already have the arguments marshalled into an `NSInvocation`, we can:

1. Extract the arguments from the `NSInvocation`
2. Build a proper call to `objc_msgSendSuper` or `objc_msgSendSuper_stret` with the right signature
3. This requires handling variadic calls or using assembly/FFI

**Option 2: Use libffi (Foreign Function Interface)**

Use libffi to dynamically construct the call with the correct signature:

```cpp
#include <ffi.h>

// 1. Parse the method signature to get argument types
// 2. Build ffi_cif (call interface) with return type and arg types
// 3. Extract arguments from NSInvocation into an array
// 4. Call ffi_call with objc_msgSendSuper as the function pointer
```

**Option 3: Template-based approach for common signatures**

Create template functions for common argument patterns:

```cpp
// For 1 object argument
case '@': {
  __unsafe_unretained id arg1;
  [invocation getArgument:&arg1 atIndex:2];
  id result = ((id(*)(struct objc_super*, SEL, id))objc_msgSendSuper)(
      &superStruct, selector, arg1);
  return ObjcObject::NewInstance(env, result);
}

// For 2 object arguments
// etc.
```

This is brittle but works for the most common cases.

## Technical Details

### Type Encoding Reference

Objective-C method signatures have the format: `returnType@:arg1Type arg2Type...`

- First type: return type
- `@`: self (implicit, skipped in encoding sometimes)
- `:`: \_cmd (SEL, implicit)
- Remaining: actual argument types

Common encodings:

- `@` = id (object pointer)
- `q` = long long / NSInteger (64-bit)
- `Q` = unsigned long long / NSUInteger
- `d` = double
- `f` = float
- `B` = BOOL
- `c` = char
- `v` = void
- `^@` = id\* (pointer to object, e.g., NSError\*\*)
- `^v` = void\* (generic pointer)

### Example: \_requestContextWithRequests:error:

For the primary use case (ASAuthorizationController):

```objc
- (id)_requestContextWithRequests:(NSArray*)requests error:(NSError**)outError
```

Type encoding: `@@:@^@`

- Return: `@` (id)
- self: `@` (implicit)
- \_cmd: `:` (SEL, implicit)
- arg1: `@` (NSArray\*)
- arg2: `^@` (NSError\*\*)

The super call needs to be:

```cpp
struct objc_super superStruct = { .receiver = self, .super_class = superClass };
NSError** errorPtr = /* extracted from invocation */;
NSArray* requests = /* extracted from invocation */;

id result = ((id(*)(struct objc_super*, SEL, id, id*))objc_msgSendSuper)(
    &superStruct,
    selector,
    requests,
    errorPtr
);
```

### Existing Code Structure

The `CallSuper` function already:

1. ✅ Finds the superclass correctly
2. ✅ Gets the method signature from the superclass
3. ✅ Validates argument count
4. ✅ Marshals JS arguments into an `NSInvocation` (lines 744-792)
5. ✅ Stores arguments in a `std::vector<ObjcType>` to keep them alive

What's missing: 6. ❌ Extract arguments from NSInvocation 7. ❌ Cast `objc_msgSendSuper` to the right function pointer type 8. ❌ Call with the actual arguments 9. ❌ Handle all return types + all argument type combinations

### Current Switch Statement Structure

Lines 839-916 have cases for return types:

- `v` (void)
- `@` / `#` (id/Class)
- `B` (BOOL)
- `c/i/s/l` (signed integers)
- `C/I/S/L` (unsigned integers)
- `q` (long long)
- `Q` (unsigned long long)
- `f` (float)
- `d` (double)
- `default` (unsupported)

Each case needs to be extended to handle argument passing.

## Implementation Steps

1. **Parse the method signature** to get argument types
   - Use `[methodSig getArgumentTypeAtIndex:]` for indices 2+ (skip self and \_cmd)
   - Store in a vector: `std::vector<SimplifiedTypeEncoding> argTypes`

2. **Extract arguments from NSInvocation**

   ```cpp
   // Example for extracting an object argument
   __unsafe_unretained id arg1;
   [invocation getArgument:&arg1 atIndex:2];

   // Example for extracting NSInteger
   long long arg2;
   [invocation getArgument:&arg2 atIndex:3];
   ```

3. **Create a mapping of common signatures**
   - Start with patterns needed for ASAuthorizationController
   - Example: `@@:@^@` (return id, take NSArray\* and NSError\*\*)
   - Example: `@@:` (return id, no args) - already works
   - Example: `@@:@` (return id, take one object)
   - Example: `v@:@` (return void, take one object)

4. **Build function pointer casts dynamically or use templates**

   ```cpp
   // Pseudo-code for dynamic approach
   if (argTypes.size() == 0) {
     // Current code works
   } else if (argTypes.size() == 1 && argTypes[0] == '@') {
     __unsafe_unretained id arg1;
     [invocation getArgument:&arg1 atIndex:2];

     switch (returnType[0]) {
       case '@': {
         id result = ((id(*)(struct objc_super*, SEL, id))objc_msgSendSuper)(
             &superStruct, selector, arg1);
         return ObjcObject::NewInstance(env, result);
       }
       case 'v': {
         ((void(*)(struct objc_super*, SEL, id))objc_msgSendSuper)(
             &superStruct, selector, arg1);
         return env.Undefined();
       }
       // ... more return types
     }
   } else if (argTypes.size() == 2 && argTypes[0] == '@' && argTypes[1] == '^' && argTypes[1][1] == '@') {
     // Handle NSArray* + NSError** case
     __unsafe_unretained id arg1;
     [invocation getArgument:&arg1 atIndex:2];

     id __autoreleasing *arg2;
     [invocation getArgument:&arg2 atIndex:3];

     switch (returnType[0]) {
       case '@': {
         id result = ((id(*)(struct objc_super*, SEL, id, id*))objc_msgSendSuper)(
             &superStruct, selector, arg1, arg2);
         return ObjcObject::NewInstance(env, result);
       }
       // ... more return types
     }
   }
   // ... more patterns
   ```

5. **Test with the ASAuthorizationController use case**
   ```typescript
   // This should work after implementation
   const MyController = NobjcClass.define({
     name: "MyAuthController",
     superclass: "ASAuthorizationController",
     methods: {
       "_requestContextWithRequests:error:": {
         types: "@@:@^@",
         implementation: (self, requests, errorOut) => {
           // Call super with arguments
           const context = NobjcClass.super(self, "_requestContextWithRequests:error:", requests, errorOut);
           if (context) {
             context.setClientDataHash$(myHash);
           }
           return context;
         }
       }
     }
   });
   ```

## Files to Modify

1. **`/Users/evan/Developer/npm/nobjc/src/native/subclass-impl.mm`**
   - Function: `CallSuper` (lines 643-905)
   - Modify the switch statement to extract and pass arguments

## Testing

Create a test in `/Users/evan/Developer/npm/nobjc/tests/test-subclass.test.ts`:

```typescript
test("should call super with arguments", () => {
  const MyString = NobjcClass.define({
    name: "TestSuperWithArgs",
    superclass: "NSMutableString",
    methods: {
      "initWithString:": {
        types: "@@:@",
        implementation: (self, str) => {
          // Call super's initWithString:
          return NobjcClass.super(self, "initWithString:", str);
        }
      }
    }
  });

  const testStr = NSString.stringWithUTF8String$("Test");
  const instance = (MyString as any).alloc().initWithString$(testStr);
  expect(instance.toString()).toBe("Test");
});

test("should call super with multiple arguments", () => {
  const MyArray = NobjcClass.define({
    name: "TestSuperMultiArgs",
    superclass: "NSMutableArray",
    methods: {
      "replaceObjectAtIndex:withObject:": {
        types: "v@:Q@", // void return, NSUInteger index, id object
        implementation: (self, index, obj) => {
          // Add logging, then call super
          console.log(`Replacing index ${index}`);
          return NobjcClass.super(self, "replaceObjectAtIndex:withObject:", index, obj);
        }
      }
    }
  });

  const arr = (MyArray as any).alloc().init();
  arr.addObject$(NSString.stringWithUTF8String$("First"));
  arr.replaceObjectAtIndex$withObject$(0, NSString.stringWithUTF8String$("Second"));

  expect(arr.objectAtIndex$(0).toString()).toBe("Second");
});
```

## Success Criteria

1. ✅ `NobjcClass.super(self, "method:arg:", value)` works with single object argument
2. ✅ `NobjcClass.super(self, "method:arg1:arg2:", val1, val2)` works with multiple arguments
3. ✅ Works with primitive types (NSInteger, BOOL, etc.) as arguments
4. ✅ Works with pointer types (NSError\*\*)
5. ✅ All existing tests still pass
6. ✅ The ASAuthorizationController use case works

## Additional Resources

- **objc_msgSendSuper reference**: `/usr/include/objc/message.h`
- **Method signature encoding**: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
- **Existing argument extraction code**: See `CallSubclassJSCallback` in `subclass-impl.mm` (lines 140-207) for how to extract arguments from NSInvocation
- **Type conversion**: See `AsObjCArgument` in `bridge.h` for how arguments are converted from JS

## Alternative: Simpler Short-term Solution

If full support is too complex, implement just the specific signature needed for ASAuthorizationController:

```cpp
// Special case for _requestContextWithRequests:error:
if (selectorName == "_requestContextWithRequests:error:" &&
    expectedArgCount == 2) {
  __unsafe_unretained id arg1;
  [invocation getArgument:&arg1 atIndex:2];

  id __autoreleasing *arg2;
  [invocation getArgument:&arg2 atIndex:3];

  id result = ((id(*)(struct objc_super*, SEL, id, id*))objc_msgSendSuper)(
      &superStruct, selector, arg1, arg2);

  if (result == nil) {
    return env.Null();
  }
  return ObjcObject::NewInstance(env, result);
}
```

This would unblock the primary use case while a more general solution is developed.

## Questions to Answer During Implementation

1. Should we use libffi for full dynamic support, or hard-code common patterns?
2. How many argument combinations should we support? (Start with 0-3 arguments?)
3. Should we support struct returns via `objc_msgSendSuper_stret`?
4. How should we handle blocks (`@?` type encoding) in super calls?
5. Should we cache function pointer casts for performance?

## Notes

- The current implementation already handles the complex parts: finding the superclass, getting the signature, and marshalling arguments
- The missing piece is just the final call to `objc_msgSendSuper` with the arguments
- On ARM64 (Apple Silicon), argument passing follows specific conventions but `objc_msgSendSuper` handles this
- The `storedArgs` vector keeps arguments alive during the call, so lifetime is already managed
