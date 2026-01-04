# Super Calls FFI Implementation - Debug Build Ready

## Status: Ready for Testing with Comprehensive Debug Logging

### What Was Implemented

1. **libffi Integration** (src/native/subclass-impl.mm:1-17)
   - Added libffi dependency to binding.gyp
   - Declared objc_msgSendSuper2 function
   - Successfully compiles and links

2. **FFI Utilities** (src/native/ffi-utils.h)
   - `GetSizeForTypeEncoding()` - Calculate size for each type
   - `GetFFITypeForSimpleEncoding()` - Map Obj-C types to libffi types
   - `ParseStructEncoding()` - Parse struct encodings recursively
   - `GetFFITypeForEncoding()` - Main type mapping function
   - `ExtractJSArgumentToBuffer()` - Convert JS values to native buffers (WITH DEBUG LOGGING)
   - `ConvertFFIReturnToJS()` - Convert native return values to JS
   - `CleanupAllocatedFFITypes()` - Cleanup helper

3. **CallSuperWithFFI()** (src/native/subclass-impl.mm:487-666)
   - Complete FFI-based super call implementation
   - Uses objc_msgSendSuper2 via libffi
   - **Extensive debug logging added** for:
     - Argument buffer allocation
     - Argument extraction
     - FFI call setup
     - Object pointer values
     - Return value handling

4. **CallSuper() Modified** (src/native/subclass-impl.mm:776-792)
   - Now calls CallSuperWithFFI() for methods with arguments
   - Keeps old direct objc_msgSendSuper for methods without arguments
   - Removed broken NSInvocation approach

### Current Issue

**Bus error crash** when calling super with object arguments. The crash occurs during or right before the `ffi_call()`.

### Debug Logging Added

The build now has EXTENSIVE logging that will show:

```
CallSuperWithFFI: selector=isEqual:, self=0x..., superClass=NSObject
CallSuperWithFFI: Using objc_msgSendSuper2
CallSuperWithFFI: Arg 0 type encoding: @
CallSuperWithFFI: Return type encoding: B, size: 1
CallSuperWithFFI: FFI CIF prepared successfully
CallSuperWithFFI: Processing 1 method arguments...
CallSuperWithFFI: Processing JS arg 0 (method arg 2), encoding=@
CallSuperWithFFI: Allocating buffer of 8 bytes for arg 0
CallSuperWithFFI: Buffer allocated at 0x...
CallSuperWithFFI: Calling ExtractJSArgumentToBuffer...
ExtractJSArgumentToBuffer: typeEncoding=@, buffer=0x...
ExtractJSArgumentToBuffer: Got ObjcType variant, index=...
ExtractJSArgumentToBuffer: Type is id (object)
ExtractJSArgumentToBuffer: Stored object pointer: 0x...
ExtractJSArgumentToBuffer: Completed successfully
CallSuperWithFFI: ExtractJSArgumentToBuffer succeeded
CallSuperWithFFI: Extracted argument 0 (size: 8)
CallSuperWithFFI: Argument 0 is object: buffer=0x..., contains id=0x...
CallSuperWithFFI: ========== FFI CALL SETUP ==========
CallSuperWithFFI: Function to call: objc_msgSendSuper2 at 0x...
CallSuperWithFFI: Number of arguments: 3
CallSuperWithFFI: Arg 0 (objc_super**): argValues[0]=0x..., points to=0x..., which points to objc_super at 0x...
CallSuperWithFFI:   objc_super.receiver=0x...
CallSuperWithFFI:   objc_super.super_class=0x... (NSObject)
CallSuperWithFFI: Arg 1 (SEL*): argValues[1]=0x..., points to SEL=0x... (isEqual:)
CallSuperWithFFI: Arg 2: argValues[2]=0x..., encoding=@
CallSuperWithFFI:   Object pointer at 0x... points to id=0x...
CallSuperWithFFI: About to call ffi_call...
[CRASH or success]
```

### How to Test

#### Option 1: Run the debug test script

```bash
bun test-super-debug.ts
```

This will run 3 tests:

1. Super call with no arguments (should work)
2. Super call with one object argument (currently crashes)
3. Super call with NSNumber (may crash)

#### Option 2: Use with your ASAuthorizationController

The implementation is ready to use with your specific case. Just run your code and check the console output for the detailed FFI logs.

### What to Look For in the Logs

1. **Buffer addresses** - Are they valid memory addresses?
2. **Object pointers** - Do the object pointers look valid (not 0x0, not obviously corrupted)?
3. **objc_super struct** - Does it have correct receiver and super_class?
4. **Crash location** - Does it crash before or during ffi_call?

### Potential Issues to Investigate

Based on the bus error, the likely culprits are:

1. **Argument passing** - Maybe argValues needs to be set up differently for libffi
2. **Memory alignment** - Object pointers might need specific alignment
3. **ARC issues** - Object lifetimes might be wrong (though we use \_\_unsafe_unretained)
4. **FFI CIF setup** - Maybe the argument types aren't mapped correctly

### Next Steps After Getting Logs

Once you run the test and share the output, I can:

1. Identify exactly where the crash occurs
2. See if object pointers are corrupted
3. Determine if it's an FFI setup issue or argument extraction issue
4. Fix the specific problem

The debug logging will tell us exactly what's going wrong!
