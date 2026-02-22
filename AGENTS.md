# AGENTS.md

Guidelines for AI agents working in the objc-js codebase.

## Project Overview

objc-js is an Objective-C bridge for Node.js, Bun, and Electron (macOS only). It uses a native N-API addon (C++/Objective-C++) to expose Objective-C runtime objects, methods, protocols, blocks, subclassing, and C function calling to JavaScript. Bun is used as the package manager.

## Build Commands

| Command                | Description                                       |
| ---------------------- | ------------------------------------------------- |
| `bun run build`        | Full build: native addon + scripts + TypeScript   |
| `bun run build-source` | Build TypeScript only (fast, no native recompile) |
| `bun run build-native` | Build native C++ addon only (`node-gyp build`)    |

**Important**: Native builds must NOT be done inside a sandbox. They will fail due to sandbox restrictions. If you only changed `.ts` files, use `bun run build-source` to skip the native build.

The `pretest` script runs a full build automatically, so `bun test` always builds first.

## Test Commands

| Command                                    | Description                             |
| ------------------------------------------ | --------------------------------------- |
| `bun test`                                 | Run all tests with Bun (primary runner) |
| `bun test tests/test-<name>.test.ts`       | Run a single test file on Bun           |
| `npx vitest run`                           | Run all tests with Node.js/Vitest       |
| `npx vitest run tests/test-<name>.test.ts` | Run a single test file on Node.js       |

Both runtimes must pass. Tests import from compiled output (`../dist/index.js`), so always build before running tests.

## Formatting

Prettier is the sole formatter. No ESLint or other linter is configured.

```
bun run format
```

Prettier config (`.prettierrc`):

- **Double quotes** (no single quotes)
- **Semicolons**: always
- **Indentation**: 2 spaces
- **Trailing commas**: none
- **Print width**: 120 characters

## Project Structure

```
src/ts/           TypeScript source (index.ts, native.ts)
src/native/       C++/Objective-C++ native addon
tests/            Test files (test-*.test.ts + test-utils.ts)
types/native/     TypeScript declarations for the native addon
dist/             Compiled JS output (generated)
docs/             Documentation
```

## TypeScript Style

### Imports

- Named imports: `import { NobjcLibrary, RunLoop } from "./index.js";`
- Always use `.js` extensions in import paths (required by NodeNext resolution)
- Use `node:` protocol for Node builtins: `import { createRequire } from "node:module";`

### Types

- `interface` for object shapes and constructor types; `type` for unions/aliases
- `any` is acceptable for ObjC interop where types are inherently dynamic
- Cast ObjC classes with `as unknown as _Constructor` pattern
- Strict mode is enabled (`strict: true` in tsconfig)

### Naming

- Classes/constructors: `PascalCase` (`NobjcLibrary`, `NobjcObject`)
- Functions/methods/variables: `camelCase` (`getPointer`, `callFunction`)
- Module-level constants: `UPPER_SNAKE_CASE` (`NATIVE_OBJC_OBJECT`, `BUILT_IN_PROPS`)
- ObjC selector mapping: `$` replaces `:` in method names (`stringWithUTF8String$` -> `stringWithUTF8String:`)

### Error Handling

- `throw new Error(...)` for general errors
- `throw new TypeError(...)` for type mismatches
- `try/catch` around ObjC interop that may fail
- Native side uses `Napi::TypeError::New()` / `Napi::Error::New()`

### Comments

- JSDoc `/** */` for public API documentation with `@param`, `@returns`
- Line comments `//` for inline explanations
- Focus on "why" not "what", especially for ObjC runtime behavior and performance decisions

## Test Conventions

### File Structure

- File naming: `tests/test-<feature>.test.ts` (kebab-case, `test-` prefix)
- Import from the cross-runtime shim: `import { test, expect, describe } from "./test-utils.js";`
- Import project API from compiled output: `import { NobjcLibrary, RunLoop } from "../dist/index.js";`
- Use `test()`, not `it()`
- No hooks (`beforeEach`, `afterEach`, etc.) -- each test is self-contained
- No mocks

### Type Declarations

Define local interfaces for ObjC classes at the top of each test file, prefixed with `_`:

```typescript
interface _NSString extends NobjcObject {
  UTF8String(): string;
  length(): number;
}
interface _NSStringConstructor {
  stringWithUTF8String$(str: string): _NSString;
}
```

### Loading Frameworks

```typescript
const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");
const NSString = foundation["NSString"] as unknown as _NSStringConstructor;
```

### Patterns

- `describe()` blocks for grouping, can be nested
- `test.skip()` for known limitations
- Async tests use `async/await` with `new Promise()` wrappers
- Assertions: `.toBe()`, `.toEqual()`, `.toBeDefined()`, `.toThrow()`, `.not.toThrow()`, etc.

## Native Code (C++/Objective-C++)

- C++20, Objective-C++ (`.mm` files, `.h` headers)
- N-API via `node-addon-api` wrappers (`Napi::Value`, `Napi::ObjectWrap`)
- ARC enabled for ObjC (`-fobjc-arc`); manual retain/release in C++ contexts
- `@autoreleasepool` blocks around ObjC code in N-API functions
- `#ifndef` include guards (not `#pragma once`)
- `PascalCase` for classes, functions, and exported symbols
- `camelCase` for local variables
- macOS deployment target: 13.3

## Key Architecture Notes

- `NobjcLibrary` returns a `Proxy` that lazily loads frameworks on first class access via `LoadLibrary()`
- `NobjcObject` wraps native `ObjcObject` in a `Proxy` for dynamic method dispatch
- Method calls go through `$prepareSend` + `$msgSendPrepared` (cached selector + signature)
- `RunLoop` pumps the macOS run loop via NSRunLoop proxy objects (not raw `$msgSend` or `CFRunLoopRunInMode`, which crash Bun)
- Blocks bridge JS functions to ObjC blocks with automatic type inference from method signatures
- `WeakMap` is used for O(1) proxy-to-native-object unwrapping

## Common Pitfalls

- Always build before testing (`bun run build-source` for TS-only changes)
- `RunLoop` must use proxy-wrapped objects (`wrapObjCObjectIfNeeded`), not raw `GetClassObject` + `$msgSend` -- the raw path crashes Bun
- `NobjcLibrary` lazy-loads frameworks; `GetClassObject` may return undefined if the framework hasn't been loaded yet
- The `PumpRunLoop` native function exists but is unused by the TS `RunLoop` object (kept for backward compatibility)
- Test files import from `../dist/index.js`, not `../src/ts/index.ts`
