# Calling C Functions

## Overview

Many macOS frameworks export plain C functions alongside Objective-C classes. Examples include `NSLog`, `NSHomeDirectory`, `NSStringFromClass`, `CGRectMake`, and hundreds of others. **objc-js** lets you call these functions directly from JavaScript using `callFunction` and `callVariadicFunction`.

Under the hood, the bridge uses `dlsym` to look up the function symbol at runtime and `libffi` to invoke it with the correct calling convention.

## Non-Variadic Functions

Use `callFunction` for functions with a fixed number of arguments:

```typescript
callFunction(name: string, ...args: any[]): any
callFunction(name: string, options: CallFunctionOptions, ...args: any[]): any
```

**Parameters:**

- `name` — The C function name (e.g., `"NSHomeDirectory"`, `"NSStringFromClass"`)
- `options` (optional) — A `CallFunctionOptions` object to specify return type and/or argument types
- `...args` — The actual argument values

**Type Inference:**

Argument types are inferred from JS values by default:

| JS Value    | Inferred Encoding | ObjC Type            |
| ----------- | ----------------- | -------------------- |
| NobjcObject | `@`               | id (object)          |
| string      | `@`               | id (auto → NSString) |
| boolean     | `B`               | BOOL                 |
| number      | `d`               | double / CGFloat     |
| null        | `@`               | nil                  |

The return type defaults to `"v"` (void). If the function returns a value, you **must** specify the return type — see [Why Return Type Can't Be Inferred](#why-return-type-cant-be-inferred).

### Options Object

When type inference isn't sufficient, pass a `CallFunctionOptions` object as the second argument:

```typescript
interface CallFunctionOptions {
  returns?: string; // Return type encoding (default: "v")
  args?: string[]; // Argument type encodings (overrides inference)
  types?: string; // Combined type string: return + arg types (e.g., "@#")
}
```

You can use `returns`, `args`, or `types`:

- **`{ returns }`** — Just specify the return type; arg types are still inferred
- **`{ returns, args }`** — Specify both return and argument types explicitly
- **`{ types }`** — A combined string where the first encoding is the return type and the rest are argument types (e.g., `"@:"` means return `@`, arg `:`)

### Examples

```typescript
import { NobjcLibrary, callFunction } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];

// NSLog — void return, arg type inferred from NobjcObject
const msg = NSString.stringWithUTF8String$("Hello from Node.js!");
callFunction("NSLog", msg);

// NSHomeDirectory() — no arguments, returns NSString
const homeDir = callFunction("NSHomeDirectory", { returns: "@" });
console.log(homeDir.toString()); // "/Users/you"

// NSTemporaryDirectory() — no arguments, returns NSString
const tmpDir = callFunction("NSTemporaryDirectory", { returns: "@" });
console.log(tmpDir.toString());

// NSUserName() — no arguments, returns NSString
const userName = callFunction("NSUserName", { returns: "@" });
console.log(userName.toString());

// NSStringFromClass(Class) — arg type inferred (NobjcObject → @, works because Class is-an id)
const className = callFunction("NSStringFromClass", { returns: "@" }, NSString);
console.log(className.toString()); // "NSString"

// NSStringFromSelector(SEL) — needs explicit ":" arg type (string would infer as @)
const selName = callFunction("NSStringFromSelector", { returns: "@", args: [":"] }, "description");
console.log(selName.toString()); // "description"

// NSSelectorFromString(NSString) — arg inferred, returns SEL (as string)
const sel = callFunction("NSSelectorFromString", { returns: ":" }, NSString.stringWithUTF8String$("description"));
console.log(sel); // "description"

// NSClassFromString(NSString) — arg inferred, returns Class
const cls = callFunction("NSClassFromString", { returns: "#" }, NSString.stringWithUTF8String$("NSArray"));
console.log(cls.description().toString()); // "NSArray"

// Combined type string: "@#" = return @, arg #
const name = callFunction("NSStringFromClass", { types: "@#" }, NSString);
console.log(name.toString()); // "NSString"
```

## Variadic Functions

Use `callVariadicFunction` for functions that accept a variable number of arguments. This is important on Apple Silicon (ARM64), where variadic and non-variadic calling conventions differ — variadic arguments go on the stack while fixed arguments go in registers.

```typescript
callVariadicFunction(name: string, fixedArgCount: number, ...args: any[]): any
callVariadicFunction(name: string, options: CallFunctionOptions, fixedArgCount: number, ...args: any[]): any
```

**Parameters:**

- `name` — The C function name
- `options` (optional) — A `CallFunctionOptions` object (same as `callFunction`)
- `fixedArgCount` — Number of fixed (non-variadic) arguments
- `...args` — The actual argument values (fixed args first, then variadic args)

### Examples

```typescript
import { NobjcLibrary, callVariadicFunction } from "objc-js";

const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"];

// NSLog is variadic: void NSLog(NSString *format, ...)
// fixedArgCount = 1 (only the format string is fixed)

// Simple log — no variadic args (arg type inferred)
const message = NSString.stringWithUTF8String$("Hello from Node.js!");
callVariadicFunction("NSLog", 1, message);

// With format substitutions (arg types inferred as @)
const format = NSString.stringWithUTF8String$("Hello, %@!");
const name = NSString.stringWithUTF8String$("World");
callVariadicFunction("NSLog", 1, format, name);

// Multiple variadic arguments
const fmt = NSString.stringWithUTF8String$("%@ + %@ = %@");
const a = NSString.stringWithUTF8String$("1");
const b = NSString.stringWithUTF8String$("2");
const c = NSString.stringWithUTF8String$("3");
callVariadicFunction("NSLog", 1, fmt, a, b, c);

// Integer variadic arg — needs explicit "i" (numbers default to "d")
const intFmt = NSString.stringWithUTF8String$("number = %d");
callVariadicFunction("NSLog", { args: ["@", "i"] }, 1, intFmt, 42);
```

> **Tip:** If a variadic function is called with only its fixed arguments (no extra variadic args), you can use `callFunction` instead. Both work in that case. Use `callVariadicFunction` when passing additional variadic arguments.

## callFunction for Variadic Functions Without Extra Args

When you call a variadic function like `NSLog` with only its fixed arguments (no format substitutions), `callFunction` works fine:

```typescript
// This works because there are no variadic arguments
const msg = NSString.stringWithUTF8String$("Simple message, no format args");
callFunction("NSLog", msg);
```

## Why Return Type Can't Be Inferred

Unlike Objective-C methods (which have runtime metadata via `method_getTypeEncoding`), C functions have **no runtime type information**. There's no way to ask the system what a C function returns. Getting it wrong is dangerous: if you call a `void` function but tell `libffi` it returns a pointer, it will read garbage from a register and try to ARC-retain it, causing a crash.

For safety, the return type defaults to `"v"` (void). Always specify `{ returns: "..." }` when the function returns a value.

## When to Specify Arg Types Explicitly

You only need explicit arg types when inference gets it wrong:

| Situation                          | Why inference fails                                                    | Fix                         |
| ---------------------------------- | ---------------------------------------------------------------------- | --------------------------- |
| SEL (selector) parameter           | String infers as `@` (NSString), but the function expects `:` (SEL)    | `{ args: [":"] }`           |
| Integer parameter (NSInteger, int) | Number infers as `d` (double), but the function expects `q` or `i`     | `{ args: ["q"] }` or `"i"`  |
| Explicit Class (`#`) parameter     | Works fine with inferred `@` (Class is-an id), but `#` is more precise | Optional: `{ args: ["#"] }` |

## Type Encodings

Type encodings are the same Objective-C type encoding characters used elsewhere in the library:

| Encoding | Type                                 |
| -------- | ------------------------------------ |
| `v`      | void                                 |
| `@`      | id (NSObject, NSString, etc)         |
| `#`      | Class                                |
| `:`      | SEL (selector)                       |
| `B`      | BOOL                                 |
| `c`      | char                                 |
| `i`      | int                                  |
| `s`      | short                                |
| `l`      | long                                 |
| `q`      | long long / NSInteger                |
| `C`      | unsigned char                        |
| `I`      | unsigned int                         |
| `S`      | unsigned short                       |
| `L`      | unsigned long                        |
| `Q`      | unsigned long long / NSUInteger      |
| `f`      | float                                |
| `d`      | double / CGFloat                     |
| `*`      | char\* (C string)                    |
| `^v`     | void\* (pointer)                     |
| `{...}`  | struct (see [Structs](./structs.md)) |

## Error Handling

Errors are thrown as JavaScript exceptions in these cases:

```typescript
// Unknown function name
try {
  callFunction("NonExistentFunction");
} catch (e) {
  console.error(e.message); // "dlsym failed: symbol 'NonExistentFunction' not found"
}

// Wrong number of arguments
try {
  callFunction("NSHomeDirectory", { returns: "@" }, "extra");
} catch (e) {
  console.error(e.message); // argument count mismatch
}
```

## Framework Loading

The function must be exported by a framework that has been loaded into the process. Load the framework first using `NobjcLibrary`:

```typescript
import { NobjcLibrary, callFunction } from "objc-js";

// Load Foundation — this makes NSLog, NSHomeDirectory, etc. available
const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

// Now C functions from Foundation can be called
const home = callFunction("NSHomeDirectory", { returns: "@" });
```

If a function comes from a different framework (e.g., CoreGraphics), load that framework first.

## See Also

- [Basic Usage](./basic-usage.md)
- [Structs](./structs.md)
- [API Reference](./api-reference.md)
