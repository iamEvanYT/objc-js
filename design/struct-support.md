# Struct Support Design Document

**Date:** 2026-02-17
**Status:** IMPLEMENTED

---

## Problem Statement

Many Objective-C APIs use C structs for geometry, ranges, and other compound values. Before this change, `$msgSend` could not handle struct arguments or struct return values — any method with a struct parameter (like `initWithContentRect:styleMask:backing:defer:` which takes a `CGRect`) would throw `Unsupported argument type {CGRect={CGPoint=dd}{CGSize=dd}}`.

### Motivating Example

```typescript
// This failed before the change:
const window = NSWindow.alloc().initWithContentRect$styleMask$backing$defer$(
  { origin: { x: 100, y: 100 }, size: { width: 800, height: 600 } },
  15,
  2,
  false
);
```

### Scope

- Struct arguments: JS objects/arrays → packed byte buffers → `[invocation setArgument:atIndex:]`
- Struct return values: `[invocation getReturnValue:]` → byte buffer → JS objects with named fields
- Nested structs (e.g., CGRect contains CGPoint and CGSize)
- Well-known field name mapping (the runtime doesn't provide field names)

---

## Background: Why This Is Non-Trivial

### The ObjcType Variant Cannot Represent Structs

The existing argument pipeline works like this:

```
JS value → AsObjCArgument() → ObjcType variant → SetObjCArgumentVisitor → invocation
```

`ObjcType` is a `std::variant` covering primitives, `id`, `SEL`, `char*`, etc. Structs are variable-size blobs of bytes — they don't fit into a fixed variant. Extending `ObjcType` to support arbitrary structs would require something like `std::vector<uint8_t>` variant members with struct-specific visitors, adding complexity for a case that's better handled separately.

### The Runtime Doesn't Provide Field Names

The Objective-C runtime's `NSMethodSignature` returns type encodings like:

```
{CGRect={CGPoint=dd}{CGSize=dd}}
{_NSRange=QQ}
```

These encodings contain the struct name and field types, but **not the field names**. The compiler's `@encode()` does include quoted names (e.g., `{CGRect="origin"{CGPoint="x"d"y"d}"size"{CGSize="width"d"height"d}}`), but the runtime strips them.

This means we can't generically know that `{CGPoint=dd}` has fields named `x` and `y` just from the encoding. We need a lookup table.

### NSInvocation Handles stret Internally

On ARM64, struct returns larger than 16 bytes use the "stret" calling convention (struct is returned via a hidden pointer parameter). `NSInvocation` handles this transparently — we don't need to use `objc_msgSend_stret` or worry about the calling convention. We just call `[invocation getReturnValue:buffer]` and get the struct bytes.

---

## Design

### Architecture

Struct handling bypasses the existing `ObjcType` pipeline entirely. In the `$MsgSend` argument loop, struct types are detected early by checking if the type encoding starts with `{`, then routed to a separate code path:

```
JS value
  │
  ├── Struct type encoding (starts with '{')
  │   → IsStructTypeEncoding()
  │   → PackJSValueAsStruct() → byte buffer → [invocation setArgument:buffer atIndex:]
  │   → buffer stored in structBuffers vector (kept alive until after invoke)
  │
  └── Non-struct type encoding
      → AsObjCArgument() → ObjcType → SetObjCArgumentVisitor → invocation
```

For return values:

```
[invocation invoke]
  │
  ├── Struct return type (starts with '{')
  │   → [invocation getReturnValue:buffer]
  │   → UnpackStructToJSValue() → JS object with named fields
  │
  └── Non-struct return type
      → ConvertReturnValueToJSValue() (existing path)
```

### Well-Known Field Name Mapping

A static map (`KNOWN_STRUCT_FIELDS`) provides field names for common structs. This is necessary because the runtime's type encodings don't include field names.

```cpp
static const std::map<std::string, std::vector<std::string>> KNOWN_STRUCT_FIELDS = {
  {"CGPoint",            {"x", "y"}},
  {"CGSize",             {"width", "height"}},
  {"CGRect",             {"origin", "size"}},
  {"_NSRange",           {"location", "length"}},
  {"NSEdgeInsets",       {"top", "left", "bottom", "right"}},
  {"CGAffineTransform",  {"a", "b", "c", "d", "tx", "ty"}},
  // ...
};
```

For structs not in this table, fields are named `field0`, `field1`, etc.

### Encoding Parser

`ParseStructEncodingWithNames()` takes a type encoding string and produces a `ParsedStructType`:

```cpp
struct StructFieldInfo {
  std::string name;          // "origin", "x", "field0", etc.
  std::string typeEncoding;  // "d", "{CGPoint=dd}", etc.
  size_t offset;             // Byte offset within parent struct
  size_t size;               // From NSGetSizeAndAlignment
  size_t alignment;          // From NSGetSizeAndAlignment
  bool isStruct;             // True if nested struct
  std::vector<StructFieldInfo> subfields;
};

struct ParsedStructType {
  std::string name;                     // "CGRect"
  std::vector<StructFieldInfo> fields;  // Top-level fields
  size_t totalSize;                     // From NSGetSizeAndAlignment
  size_t alignment;
};
```

The parser:

1. Extracts the struct name from the encoding
2. Recursively parses field type encodings (handling nested structs)
3. Gets size/alignment for each field via `NSGetSizeAndAlignment()`
4. Applies well-known field names from `KNOWN_STRUCT_FIELDS`
5. Recursively computes byte offsets for all fields and subfields
6. Cross-checks total size with `NSGetSizeAndAlignment()` on the full encoding

### Packing: JS → Struct Bytes

`PackJSValueToStructBuffer()` recursively walks the parsed field structure and the JS value (object or array) in parallel:

- For **named objects**: reads `jsObj.Get(field.name)` for each field
- For **arrays**: reads `arr.Get(i)` positionally
- For **objects without matching names**: iterates property names in insertion order
- For **nested structs**: recurses with the sub-object and subfields
- For **leaf fields**: `WriteLeafValueToBuffer()` reads the JS number/bool and writes the correct C type (`memcpy` to the buffer at the computed offset)

### Unpacking: Struct Bytes → JS

`UnpackStructBufferToJSObject()` does the reverse — walks the parsed fields and reads values from the byte buffer:

- Creates a `Napi::Object` for each struct level
- For nested structs: recurses and sets the result as a property
- For leaf fields: `ReadLeafValueFromBuffer()` reads the C type from the buffer and creates a `Napi::Number`/`Napi::Boolean`/etc.

### Buffer Lifetime

Struct argument buffers must remain valid until after `[invocation invoke]` completes. They are stored in a `std::vector<std::vector<uint8_t>> structBuffers` that lives alongside `storedArgs` in `$MsgSend` and goes out of scope after `invoke`.

---

## Key Implementation Details

### Files Modified

- **`src/native/ObjcObject.mm`** — `$MsgSend` function:
  - Return type validation relaxed to allow `{` (struct types)
  - Argument loop: detect struct types via `IsStructTypeEncoding()`, pack with `PackJSValueAsStruct()`, set on invocation directly
  - Return path: detect struct return via `isStructReturn` flag, read bytes via `getReturnValue:`, convert with `UnpackStructToJSValue()`

### Files Created

- **`src/native/struct-utils.h`** — All struct support logic:
  - `KNOWN_STRUCT_FIELDS` — well-known field name lookup table
  - `ParseStructEncodingWithNames()` — encoding parser
  - `ComputeFieldOffsets()` — recursive offset computation
  - `PackJSValueAsStruct()` / `PackJSValueToStructBuffer()` — JS → bytes
  - `UnpackStructToJSValue()` / `UnpackStructBufferToJSObject()` — bytes → JS
  - `WriteLeafValueToBuffer()` / `ReadLeafValueFromBuffer()` — primitive type I/O
  - `IsStructTypeEncoding()` — type encoding check

### Integration Points in $MsgSend

```cpp
// In the argument loop (ObjcObject.mm):
if (IsStructTypeEncoding(typeEncoding)) {
    auto buffer = PackJSValueAsStruct(env, info[i], typeEncoding);
    [invocation setArgument:buffer.data() atIndex:i + 1];
    structBuffers.push_back(std::move(buffer));
    storedArgs.push_back(BaseObjcType{std::monostate{}}); // placeholder
    continue;
}

// After invoke, for struct returns:
if (isStructReturn) {
    NSUInteger returnLength = [methodSignature methodReturnLength];
    std::vector<uint8_t> returnBuffer(returnLength, 0);
    [invocation getReturnValue:returnBuffer.data()];
    return UnpackStructToJSValue(env, returnBuffer.data(), returnType);
}
```

---

## Bug Fix: Uninitialized Subfield Offsets

### The Bug

The initial implementation computed byte offsets only for top-level fields in `ParseStructEncodingWithNames()`. Subfield offsets for nested structs (e.g., `CGPoint.x` and `CGPoint.y` inside `CGRect`) were left uninitialized, causing writes to random memory locations and a SIGBUS crash.

For `{CGRect={CGPoint=dd}{CGSize=dd}}`:

- Top-level fields `origin` (offset=0) and `size` (offset=16) were computed correctly
- But `origin.x` (should be 0), `origin.y` (should be 8), `size.width` (should be 0), `size.height` (should be 8) had indeterminate offset values

### The Fix

Extracted offset computation into a recursive `ComputeFieldOffsets()` function that walks all nesting levels:

```cpp
inline void ComputeFieldOffsets(std::vector<StructFieldInfo> &fields) {
  size_t currentOffset = 0;
  for (auto &field : fields) {
    if (field.alignment > 0) {
      currentOffset = (currentOffset + field.alignment - 1) & ~(field.alignment - 1);
    }
    field.offset = currentOffset;
    currentOffset += field.size;
    if (field.isStruct && !field.subfields.empty()) {
      ComputeFieldOffsets(field.subfields); // recurse into nested structs
    }
  }
}
```

---

## Design Decisions

### Why Bypass ObjcType Instead of Extending It?

Extending the `ObjcType` variant to handle structs would require:

1. A new variant member (e.g., `std::vector<uint8_t>`) for arbitrary-size data
2. A new `SetObjCArgumentVisitor` case that knows the buffer size
3. Thread-through of the type encoding to the visitor for size info

This adds complexity to the general argument path for a special case. The struct path is simpler: detect early, pack directly, set on invocation. The two paths share no logic since struct packing is fundamentally different from scalar argument conversion.

### Why a Static Field Name Table Instead of Parsing @encode() Output?

Options considered:

1. **Runtime introspection**: The runtime strips field names from type encodings. Not available.
2. **Header parsing**: Parse Objective-C headers at build time. Too complex, fragile.
3. **Static lookup table**: Map well-known struct names to their field names. Simple, correct, extensible.

The static table covers all commonly used Apple framework structs. Unknown structs fall back to positional names (`field0`, `field1`), which still work — the user just needs to know the field order.

### Why Objects With Named Fields Instead of Flat Arrays?

Both are supported as input, but named objects are the default for output. Reasons:

- `{ origin: { x: 100, y: 100 }, size: { width: 800, height: 600 } }` is self-documenting
- Nested structs (CGRect) are natural as nested objects, awkward as flat arrays
- Matches how other ObjC bridges (PyObjC, RubyCocoa) represent structs
- Arrays are still accepted as input for convenience

### Why NSGetSizeAndAlignment Instead of Manual Size Calculation?

`NSGetSizeAndAlignment()` is the runtime's own function for computing struct layout. Using it ensures our size/alignment calculations match what `NSInvocation` expects, avoiding subtle platform-specific discrepancies (e.g., different padding rules on ARM64 vs x86_64).

---

## Limitations

1. **Unknown structs lack field names**: Structs not in `KNOWN_STRUCT_FIELDS` get positional names (`field0`, `field1`). Adding new structs requires updating the table.

2. **No struct support in super calls**: `CallSuper` (via libffi) does not yet use the struct packing logic. Super calls with struct arguments would need separate integration.

3. **No struct support in subclass method forwarding**: When an overridden method receives a struct argument from ObjC, the forwarding path doesn't unpack it into a JS object. The JS callback receives raw data.

4. **C string fields in structs**: `char*` fields inside structs are set to `nullptr` when packing (lifetime of pointed-to data is unclear). Reading `char*` fields from return structs works if the pointer is valid.

---

## Testing

15 tests in `tests/test-struct-support.test.ts` covering:

| Category             | Tests                                                                                                                                                            |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Struct arguments     | NSRange (named object), NSRange (array), CGRect (NSWindow), CGPoint (NSValue), CGSize (NSValue)                                                                  |
| Struct return values | NSRange from `rangeOfString:`, NSRange not-found case, CGPoint from `pointValue`, CGSize from `sizeValue`, CGRect from `rectValue`, CGRect from `NSWindow.frame` |
| Roundtrip            | CGRect through NSValue, CGPoint through NSValue, CGSize through NSValue, NSRange through NSValue                                                                 |

All 15 struct tests pass. All pre-existing tests (90+) continue to pass.
