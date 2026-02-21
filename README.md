# objc-js

**objc-js** is an Objective-C bridge for Node.js. This is a fork of [nobjc](https://github.com/nmggithub/nobjc) by [Noah Gregory](https://github.com/nmggithub).

## Installation

### Prerequisites

- Node.js / Bun
- Xcode Command Line Tools (Run `xcode-select --install` to install)
- `pkg-config` from Homebrew (Run `brew install pkgconf` to install)

> [!NOTE]
> **Why are these prerequisites required?**
>
> These are required to rebuild the native code for your system.

### Install using npm

```bash
npm install objc-js
```

### Install using bun

```bash
bun add objc-js
# and `bun pm trust -a` to run the rebuild if needed
```

## Documentation

The documentation is organized into several guides:

- **[Basic Usage](./docs/basic-usage.md)** - Getting started with loading frameworks and calling methods
- **[C Functions](./docs/c-functions.md)** - Calling C functions like NSLog, NSHomeDirectory, NSStringFromClass
- **[Structs](./docs/structs.md)** - Passing and receiving C structs (CGRect, NSRange, etc.)
- **[Subclassing Objective-C Classes](./docs/subclassing.md)** - Creating and subclassing Objective-C classes from JavaScript
- **[Blocks](./docs/blocks.md)** - Passing JavaScript functions as Objective-C blocks (closures)
- **[Protocol Implementation](./docs/protocol-implementation.md)** - Creating delegate objects that implement protocols
- **[API Reference](./docs/api-reference.md)** - Complete API documentation for all classes and functions

## Quick Start

```typescript
import { NobjcLibrary } from "objc-js";

// Load a framework
const foundation = new NobjcLibrary("/System/Library/Frameworks/Foundation.framework/Foundation");

// Get a class and call methods
const NSString = foundation["NSString"];
const str = NSString.stringWithUTF8String$("Hello, World!");
console.log(str.toString());
```

For more examples and detailed guides, see the [documentation](./docs/basic-usage.md).
