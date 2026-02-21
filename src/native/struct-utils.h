#ifndef STRUCT_UTILS_H
#define STRUCT_UTILS_H

/**
 * @file struct-utils.h
 * @brief Struct encoding parser and JS ↔ ObjC struct conversion utilities.
 *
 * Provides support for converting between JavaScript objects and Objective-C
 * structs (CGRect, CGPoint, CGSize, NSRange, etc.) in $msgSend calls.
 *
 * Type encodings with field names look like:
 *   {CGRect="origin"{CGPoint="x"d"y"d}"size"{CGSize="width"d"height"d}}
 *
 * Type encodings without field names look like:
 *   {CGRect={CGPoint=dd}{CGSize=dd}}
 *
 * Both formats are supported. When field names are present, JS objects use
 * named properties. When absent, fields are accessed by index from an array.
 */

#include "debug.h"
#include "ObjcObject.h"
#include "type-conversion.h"
#include <Foundation/Foundation.h>
#include <map>
#include <unordered_map>
#include <napi.h>
#include <objc/runtime.h>
#include <string>
#include <vector>

// MARK: - Well-Known Struct Field Names

/**
 * Maps ObjC struct names to their field names, since the runtime type
 * encodings typically don't include field names (only the compiler's
 * @encode() does). Without this mapping, fields would be named field0,
 * field1, etc.
 */
// clang-format off
static const std::unordered_map<std::string, std::vector<std::string>> KNOWN_STRUCT_FIELDS = {
  // CoreGraphics / AppKit geometry
  {"CGPoint",            {"x", "y"}},
  {"NSPoint",            {"x", "y"}},
  {"CGSize",             {"width", "height"}},
  {"NSSize",             {"width", "height"}},
  {"CGRect",             {"origin", "size"}},
  {"NSRect",             {"origin", "size"}},
  {"CGVector",           {"dx", "dy"}},
  // Foundation
  {"_NSRange",           {"location", "length"}},
  {"NSRange",            {"location", "length"}},
  // Edge insets
  {"NSEdgeInsets",       {"top", "left", "bottom", "right"}},
  {"NSDirectionalEdgeInsets", {"top", "leading", "bottom", "trailing"}},
  // Affine transforms
  {"CGAffineTransform",  {"a", "b", "c", "d", "tx", "ty"}},
};
// clang-format on

/**
 * Look up well-known field names for a struct by its name.
 * Returns nullptr if the struct name is not recognized.
 */
inline const std::vector<std::string> *
LookupKnownFieldNames(const std::string &structName) {
  auto it = KNOWN_STRUCT_FIELDS.find(structName);
  if (it != KNOWN_STRUCT_FIELDS.end()) {
    return &it->second;
  }
  return nullptr;
}

// MARK: - Data Structures

struct StructFieldInfo {
  std::string name;          // Field name (e.g., "origin", "x"), empty if unnamed
  std::string typeEncoding;  // Full type encoding for this field
  size_t offset;             // Byte offset within parent struct
  size_t size;               // Size in bytes
  size_t alignment;          // Alignment requirement
  bool isStruct;             // True if this field is a nested struct
  std::vector<StructFieldInfo> subfields; // Non-empty if isStruct
};

struct ParsedStructType {
  std::string name;                      // Struct name (e.g., "CGRect")
  std::vector<StructFieldInfo> fields;   // Top-level fields
  size_t totalSize;                      // Total struct size in bytes
  size_t alignment;                      // Struct alignment
};

// MARK: - Offset Computation

/**
 * Compute byte offsets for all fields (and recursively for subfields)
 * using alignment rules.
 */
inline void ComputeFieldOffsets(std::vector<StructFieldInfo> &fields) {
  size_t currentOffset = 0;
  for (auto &field : fields) {
    // Align to field's alignment requirement
    if (field.alignment > 0) {
      currentOffset =
          (currentOffset + field.alignment - 1) & ~(field.alignment - 1);
    }
    field.offset = currentOffset;
    currentOffset += field.size;

    // Recursively compute offsets for nested struct subfields
    if (field.isStruct && !field.subfields.empty()) {
      ComputeFieldOffsets(field.subfields);
    }
  }
}

// MARK: - Encoding Parser

// Forward declaration
inline bool ParseStructFields(const char *&ptr,
                              std::vector<StructFieldInfo> &fields);

/**
 * Parse struct fields from the encoding, handling both named and unnamed
 * formats.
 *
 * Named:   "fieldName"type"fieldName2"type2
 * Unnamed: type1type2
 *
 * ptr should point just past the '=' in {StructName=...}
 * Advances ptr to the closing '}'.
 */
inline bool ParseStructFields(const char *&ptr,
                              std::vector<StructFieldInfo> &fields) {
  int fieldIndex = 0;

  while (*ptr && *ptr != '}') {
    // Skip type qualifiers
    ptr = SimplifyTypeEncoding(ptr);

    if (*ptr == '}')
      break;

    StructFieldInfo field;

    // Check for quoted field name: "fieldName"
    if (*ptr == '"') {
      ptr++; // Skip opening quote
      const char *nameStart = ptr;
      while (*ptr && *ptr != '"') {
        ptr++;
      }
      field.name = std::string(nameStart, ptr - nameStart);
      if (*ptr == '"')
        ptr++; // Skip closing quote
    } else {
      // No field name — generate a positional name
      field.name = "field" + std::to_string(fieldIndex);
    }

    // Parse the field's type encoding
    field.typeEncoding = SkipOneTypeEncoding(ptr);
    field.isStruct = (!field.typeEncoding.empty() && field.typeEncoding[0] == '{');

    // If this is a nested struct, recursively parse its subfields
    if (field.isStruct) {
      auto subHeader = ParseStructEncodingHeader(field.typeEncoding.c_str());
      if (subHeader.fieldsStart) {
        const char *subPtr = subHeader.fieldsStart;
        ParseStructFields(subPtr, field.subfields);
      }
    }

    // Get size and alignment from the runtime
    NSUInteger nsSize, nsAlignment;
    NSGetSizeAndAlignment(field.typeEncoding.c_str(), &nsSize, &nsAlignment);
    field.size = nsSize;
    field.alignment = nsAlignment;

    fields.push_back(std::move(field));
    fieldIndex++;
  }

  return !fields.empty();
}

/**
 * Parse a complete struct type encoding into a ParsedStructType.
 *
 * Handles both named and unnamed field formats:
 *   {CGRect="origin"{CGPoint="x"d"y"d}"size"{CGSize="width"d"height"d}}
 *   {CGRect={CGPoint=dd}{CGSize=dd}}
 *
 * For unnamed fields, looks up the struct name in KNOWN_STRUCT_FIELDS
 * to apply proper field names (e.g., CGRect → origin, size).
 */
inline ParsedStructType ParseStructEncodingWithNames(const char *encoding) {
  ParsedStructType result;

  auto header = ParseStructEncodingHeader(encoding);

  if (!header.fieldsStart && !header.empty) {
    NOBJC_ERROR("ParseStructEncodingWithNames: Invalid struct encoding '%s'",
                encoding ? encoding : "(null)");
    return result;
  }

  result.name = header.name;

  if (header.empty) {
    result.totalSize = 0;
    result.alignment = 1;
    return result;
  }

  // Parse all fields
  const char *ptr = header.fieldsStart;
  ParseStructFields(ptr, result.fields);

  // Apply well-known field names if fields don't have names from the encoding
  // (i.e., they have generated names like "field0", "field1", etc.)
  if (!result.fields.empty() && result.fields[0].name.substr(0, 5) == "field") {
    const auto *knownNames = LookupKnownFieldNames(result.name);
    if (knownNames && knownNames->size() == result.fields.size()) {
      for (size_t i = 0; i < result.fields.size(); i++) {
        result.fields[i].name = (*knownNames)[i];
      }
      NOBJC_LOG("ParseStructEncodingWithNames: Applied known field names for "
                "'%s'",
                result.name.c_str());
    }
  }

  // Recursively apply known names to subfields of nested structs
  for (auto &field : result.fields) {
    if (field.isStruct && !field.subfields.empty() &&
        !field.subfields[0].name.empty() &&
        field.subfields[0].name.substr(0, 5) == "field") {
      // Extract the nested struct name from its type encoding
      std::string nestedName;
      if (field.typeEncoding.size() > 1 && field.typeEncoding[0] == '{') {
        const char *p = field.typeEncoding.c_str() + 1;
        const char *ns = p;
        while (*p && *p != '=' && *p != '}') {
          p++;
        }
        nestedName = std::string(ns, p - ns);
      }
      if (!nestedName.empty()) {
        const auto *nestedKnown = LookupKnownFieldNames(nestedName);
        if (nestedKnown && nestedKnown->size() == field.subfields.size()) {
          for (size_t i = 0; i < field.subfields.size(); i++) {
            field.subfields[i].name = (*nestedKnown)[i];
          }
        }
      }
    }
  }

  // Compute field offsets (recursively handles nested structs)
  ComputeFieldOffsets(result.fields);

  // Get total struct size and alignment from the runtime
  NSUInteger nsSize, nsAlignment;
  NSGetSizeAndAlignment(encoding, &nsSize, &nsAlignment);
  result.totalSize = nsSize;
  result.alignment = nsAlignment;

  NOBJC_LOG("ParseStructEncodingWithNames: '%s' has %zu fields, size=%zu, "
            "alignment=%zu",
            result.name.c_str(), result.fields.size(), result.totalSize,
            result.alignment);

  return result;
}

// MARK: - Cached Struct Encoding Lookup

/**
 * Return a cached ParsedStructType for the given encoding string.
 * Avoids re-parsing identical struct type encodings (CGRect, NSRange, etc.)
 * on every struct argument or return value.
 */
inline const ParsedStructType& GetOrParseStructEncoding(const char *encoding) {
  static std::unordered_map<std::string, ParsedStructType> cache;
  std::string key(encoding);
  auto it = cache.find(key);
  if (it != cache.end()) {
    return it->second;
  }
  auto [inserted_it, _] = cache.emplace(key, ParseStructEncodingWithNames(encoding));
  return inserted_it->second;
}

// MARK: - JS Object → Struct Buffer (for arguments)

/**
 * Visitor for writing a single primitive JS value into a struct buffer.
 * Used with DispatchByTypeCode to eliminate per-type switch boilerplate.
 */
struct WriteLeafToBufferVisitor {
  Napi::Env env;
  const Napi::Value &jsValue;
  uint8_t *dest;

  // Numeric types (excluding bool) — integers use Int64Value, floats use
  // DoubleValue
  template <typename T>
  auto operator()(std::type_identity<T>) const
      -> std::enable_if_t<is_numeric_v<T> && !std::is_same_v<T, bool>, void> {
    T val;
    if constexpr (is_floating_point_v<T>) {
      val = static_cast<T>(jsValue.As<Napi::Number>().DoubleValue());
    } else {
      val = static_cast<T>(jsValue.As<Napi::Number>().Int64Value());
    }
    memcpy(dest, &val, sizeof(val));
  }

  // Bool → uint8_t (ObjC BOOL is 1 byte)
  void operator()(std::type_identity<bool>) const {
    bool val = jsValue.ToBoolean().Value();
    uint8_t boolByte = val ? 1 : 0;
    memcpy(dest, &boolByte, sizeof(boolByte));
  }

  // id (@) — extract from ObjcObject wrapper
  void operator()(std::type_identity<ObjCIdTag>) const {
    id objcObj = nil;
    if (!jsValue.IsNull() && !jsValue.IsUndefined() && jsValue.IsObject()) {
      ObjcObject *wrapper = ObjcObject::Unwrap(jsValue.As<Napi::Object>());
      if (wrapper) {
        objcObj = wrapper->objcObject;
      }
    }
    memcpy(dest, &objcObj, sizeof(objcObj));
  }

  // Class (#) — not typically used in struct fields
  void operator()(std::type_identity<ObjCClassTag>) const {
    Class cls = nil;
    memcpy(dest, &cls, sizeof(cls));
  }

  // SEL (:)
  void operator()(std::type_identity<ObjCSELTag>) const {
    SEL sel = nullptr;
    if (jsValue.IsString()) {
      std::string selName = jsValue.As<Napi::String>().Utf8Value();
      sel = sel_registerName(selName.c_str());
    }
    memcpy(dest, &sel, sizeof(sel));
  }

  // C string (*) — can't safely handle lifetime, set to nullptr
  void operator()(std::type_identity<ObjCCStringTag>) const {
    const char *val = nullptr;
    memcpy(dest, &val, sizeof(val));
  }

  // Pointer (^)
  void operator()(std::type_identity<ObjCPointerTag>) const {
    void *val = nullptr;
    if (!jsValue.IsNull() && !jsValue.IsUndefined() && jsValue.IsBuffer()) {
      Napi::Buffer<uint8_t> buf = jsValue.As<Napi::Buffer<uint8_t>>();
      val = buf.Data();
    }
    memcpy(dest, &val, sizeof(val));
  }

  // Void — should not appear in struct fields
  void operator()(std::type_identity<ObjCVoidTag>) const {
    NOBJC_ERROR("WriteLeafToBufferVisitor: void type in struct field");
  }
};

/**
 * Write a single primitive JS value into a buffer at the given offset,
 * according to the type encoding character.
 */
inline void WriteLeafValueToBuffer(Napi::Env env, const Napi::Value &jsValue,
                                   const char *typeEncoding, uint8_t *buffer,
                                   size_t offset) {
  const char *simplified = SimplifyTypeEncoding(typeEncoding);
  DispatchByTypeCode(simplified[0],
                     WriteLeafToBufferVisitor{env, jsValue, buffer + offset});
}

/**
 * Recursively pack a JS object/array into a struct byte buffer.
 *
 * For named fields, reads JS object properties by name.
 * Falls back to iterating JS object properties in order if names don't match.
 * Arrays are indexed positionally.
 */
inline void PackJSValueToStructBuffer(Napi::Env env,
                                      const Napi::Value &jsValue,
                                      const std::vector<StructFieldInfo> &fields,
                                      uint8_t *buffer, size_t baseOffset) {
  bool isArray = jsValue.IsArray();
  bool isObject = jsValue.IsObject() && !isArray;

  if (!isArray && !isObject) {
    throw Napi::TypeError::New(
        env, "Struct argument must be an object or array");
  }

  Napi::Object jsObj = jsValue.As<Napi::Object>();

  // Check if the JS object has the expected field names
  bool namesMatch = false;
  if (isObject && !fields.empty()) {
    namesMatch = jsObj.Has(fields[0].name);
  }

  // If names don't match and it's an object, get property names to iterate
  // in order
  Napi::Array propNames;
  if (isObject && !namesMatch) {
    propNames = jsObj.GetPropertyNames();
    if (propNames.Length() < fields.size()) {
      throw Napi::Error::New(
          env,
          std::string("Object has ") + std::to_string(propNames.Length()) +
              " properties but struct expects " +
              std::to_string(fields.size()) + " fields");
    }
  }

  for (size_t i = 0; i < fields.size(); i++) {
    const StructFieldInfo &field = fields[i];
    Napi::Value fieldValue;

    if (isArray) {
      Napi::Array arr = jsValue.As<Napi::Array>();
      if (i < arr.Length()) {
        fieldValue = arr.Get(static_cast<uint32_t>(i));
      } else {
        throw Napi::Error::New(
            env,
            std::string("Struct array too short: expected at least ") +
                std::to_string(fields.size()) + " elements, got " +
                std::to_string(arr.Length()));
      }
    } else if (namesMatch) {
      // Object with matching field names — look up by name
      fieldValue = jsObj.Get(field.name);
    } else {
      // Object without matching names — use property order
      Napi::Value key = propNames.Get(static_cast<uint32_t>(i));
      fieldValue = jsObj.Get(key.As<Napi::String>());
    }

    if (field.isStruct && !field.subfields.empty()) {
      // Nested struct — recurse
      PackJSValueToStructBuffer(env, fieldValue, field.subfields, buffer,
                                baseOffset + field.offset);
    } else {
      // Leaf field — write the value
      WriteLeafValueToBuffer(env, fieldValue, field.typeEncoding.c_str(),
                             buffer, baseOffset + field.offset);
    }
  }
}

// MARK: - Struct Buffer → JS Object (for return values)

/**
 * Read a single primitive value from a buffer and convert to JS.
 * Delegates to ObjCToJS from type-conversion.h.
 */
inline Napi::Value ReadLeafValueFromBuffer(Napi::Env env,
                                           const char *typeEncoding,
                                           const uint8_t *buffer,
                                           size_t offset) {
  const char *simplified = SimplifyTypeEncoding(typeEncoding);
  return ObjCToJS(env, const_cast<uint8_t *>(buffer) + offset, simplified[0]);
}

/**
 * Recursively unpack a struct byte buffer into a JS object with named fields.
 */
inline Napi::Value
UnpackStructBufferToJSObject(Napi::Env env,
                             const std::vector<StructFieldInfo> &fields,
                             const uint8_t *buffer, size_t baseOffset) {
  Napi::Object result = Napi::Object::New(env);

  for (const auto &field : fields) {
    Napi::Value fieldValue;

    if (field.isStruct && !field.subfields.empty()) {
      // Nested struct — recurse
      fieldValue = UnpackStructBufferToJSObject(env, field.subfields, buffer,
                                                baseOffset + field.offset);
    } else {
      // Leaf field — read the value
      fieldValue = ReadLeafValueFromBuffer(env, field.typeEncoding.c_str(),
                                           buffer, baseOffset + field.offset);
    }

    result.Set(field.name, fieldValue);
  }

  return result;
}

// MARK: - High-Level API

/**
 * Check if a type encoding represents a struct type.
 * Handles leading type qualifiers.
 */
inline bool IsStructTypeEncoding(const char *typeEncoding) {
  if (!typeEncoding)
    return false;
  return *SimplifyTypeEncoding(typeEncoding) == '{';
}

// MARK: - Fast Path: Specialized Struct Pack/Unpack (H3)

/**
 * Extract struct name from a type encoding string.
 * E.g., "{CGRect=...}" → "CGRect", "{_NSRange=QQ}" → "_NSRange"
 * Returns empty string_view if encoding is malformed.
 */
inline std::string_view ExtractStructName(const char *encoding) {
  if (!encoding || *encoding != '{') return {};
  const char *start = encoding + 1;
  const char *end = start;
  while (*end && *end != '=' && *end != '}') end++;
  return {start, static_cast<size_t>(end - start)};
}

/**
 * Fast-path pack for CGPoint / NSPoint: { double x, y }
 * Reads jsValue.x and jsValue.y directly into buffer.
 * Returns true if handled, false to fall through to generic path.
 */
inline bool TryPackCGPoint(Napi::Env env, const Napi::Value &jsValue,
                           uint8_t *buffer) {
  if (!jsValue.IsObject() || jsValue.IsArray()) return false;
  Napi::Object obj = jsValue.As<Napi::Object>();
  double x = obj.Get("x").As<Napi::Number>().DoubleValue();
  double y = obj.Get("y").As<Napi::Number>().DoubleValue();
  memcpy(buffer, &x, sizeof(double));
  memcpy(buffer + sizeof(double), &y, sizeof(double));
  return true;
}

/**
 * Fast-path unpack for CGPoint / NSPoint: { double x, y }
 */
inline Napi::Value TryUnpackCGPoint(Napi::Env env, const uint8_t *buffer) {
  double x, y;
  memcpy(&x, buffer, sizeof(double));
  memcpy(&y, buffer + sizeof(double), sizeof(double));
  Napi::Object result = Napi::Object::New(env);
  result.Set("x", Napi::Number::New(env, x));
  result.Set("y", Napi::Number::New(env, y));
  return result;
}

/**
 * Fast-path pack for CGSize / NSSize: { double width, height }
 */
inline bool TryPackCGSize(Napi::Env env, const Napi::Value &jsValue,
                          uint8_t *buffer) {
  if (!jsValue.IsObject() || jsValue.IsArray()) return false;
  Napi::Object obj = jsValue.As<Napi::Object>();
  double w = obj.Get("width").As<Napi::Number>().DoubleValue();
  double h = obj.Get("height").As<Napi::Number>().DoubleValue();
  memcpy(buffer, &w, sizeof(double));
  memcpy(buffer + sizeof(double), &h, sizeof(double));
  return true;
}

/**
 * Fast-path unpack for CGSize / NSSize: { double width, height }
 */
inline Napi::Value TryUnpackCGSize(Napi::Env env, const uint8_t *buffer) {
  double w, h;
  memcpy(&w, buffer, sizeof(double));
  memcpy(&h, buffer + sizeof(double), sizeof(double));
  Napi::Object result = Napi::Object::New(env);
  result.Set("width", Napi::Number::New(env, w));
  result.Set("height", Napi::Number::New(env, h));
  return result;
}

/**
 * Fast-path pack for CGRect / NSRect: { CGPoint origin, CGSize size }
 * Memory layout: [origin.x, origin.y, size.width, size.height] — 4 doubles
 */
inline bool TryPackCGRect(Napi::Env env, const Napi::Value &jsValue,
                          uint8_t *buffer) {
  if (!jsValue.IsObject() || jsValue.IsArray()) return false;
  Napi::Object obj = jsValue.As<Napi::Object>();
  Napi::Object origin = obj.Get("origin").As<Napi::Object>();
  Napi::Object size = obj.Get("size").As<Napi::Object>();
  double vals[4];
  vals[0] = origin.Get("x").As<Napi::Number>().DoubleValue();
  vals[1] = origin.Get("y").As<Napi::Number>().DoubleValue();
  vals[2] = size.Get("width").As<Napi::Number>().DoubleValue();
  vals[3] = size.Get("height").As<Napi::Number>().DoubleValue();
  memcpy(buffer, vals, sizeof(vals));
  return true;
}

/**
 * Fast-path unpack for CGRect / NSRect.
 */
inline Napi::Value TryUnpackCGRect(Napi::Env env, const uint8_t *buffer) {
  double vals[4];
  memcpy(vals, buffer, sizeof(vals));

  Napi::Object origin = Napi::Object::New(env);
  origin.Set("x", Napi::Number::New(env, vals[0]));
  origin.Set("y", Napi::Number::New(env, vals[1]));

  Napi::Object size = Napi::Object::New(env);
  size.Set("width", Napi::Number::New(env, vals[2]));
  size.Set("height", Napi::Number::New(env, vals[3]));

  Napi::Object result = Napi::Object::New(env);
  result.Set("origin", origin);
  result.Set("size", size);
  return result;
}

/**
 * Fast-path pack for NSRange / _NSRange: { NSUInteger location, length }
 * On 64-bit, NSUInteger = unsigned long long = 8 bytes.
 */
inline bool TryPackNSRange(Napi::Env env, const Napi::Value &jsValue,
                           uint8_t *buffer) {
  if (!jsValue.IsObject() || jsValue.IsArray()) return false;
  Napi::Object obj = jsValue.As<Napi::Object>();
  uint64_t location = static_cast<uint64_t>(
      obj.Get("location").As<Napi::Number>().Int64Value());
  uint64_t length = static_cast<uint64_t>(
      obj.Get("length").As<Napi::Number>().Int64Value());
  memcpy(buffer, &location, sizeof(uint64_t));
  memcpy(buffer + sizeof(uint64_t), &length, sizeof(uint64_t));
  return true;
}

/**
 * Fast-path unpack for NSRange / _NSRange.
 */
inline Napi::Value TryUnpackNSRange(Napi::Env env, const uint8_t *buffer) {
  uint64_t location, length;
  memcpy(&location, buffer, sizeof(uint64_t));
  memcpy(&length, buffer + sizeof(uint64_t), sizeof(uint64_t));
  Napi::Object result = Napi::Object::New(env);
  result.Set("location", Napi::Number::New(env, static_cast<double>(location)));
  result.Set("length", Napi::Number::New(env, static_cast<double>(length)));
  return result;
}

/**
 * Pack a JS value into a newly allocated struct buffer.
 * Returns a vector<uint8_t> that must be kept alive until after the
 * NSInvocation is invoked.
 *
 * Tries specialized fast paths for CGRect/CGPoint/CGSize/NSRange first,
 * falling through to the generic parser for other struct types.
 */
inline std::vector<uint8_t>
PackJSValueAsStruct(Napi::Env env, const Napi::Value &jsValue,
                    const char *typeEncoding) {
  // Fast path: check struct name for well-known types
  auto name = ExtractStructName(typeEncoding);
  if (!name.empty()) {
    if (name == "CGRect" || name == "NSRect") {
      std::vector<uint8_t> buffer(4 * sizeof(double), 0);
      if (TryPackCGRect(env, jsValue, buffer.data())) return buffer;
    } else if (name == "CGPoint" || name == "NSPoint") {
      std::vector<uint8_t> buffer(2 * sizeof(double), 0);
      if (TryPackCGPoint(env, jsValue, buffer.data())) return buffer;
    } else if (name == "CGSize" || name == "NSSize") {
      std::vector<uint8_t> buffer(2 * sizeof(double), 0);
      if (TryPackCGSize(env, jsValue, buffer.data())) return buffer;
    } else if (name == "_NSRange" || name == "NSRange") {
      std::vector<uint8_t> buffer(2 * sizeof(uint64_t), 0);
      if (TryPackNSRange(env, jsValue, buffer.data())) return buffer;
    }
  }

  // Generic path: parse encoding and pack recursively
  const ParsedStructType &parsed = GetOrParseStructEncoding(typeEncoding);

  if (parsed.fields.empty()) {
    throw Napi::Error::New(
        env, std::string("Failed to parse struct encoding: ") + typeEncoding);
  }

  std::vector<uint8_t> buffer(parsed.totalSize, 0);
  PackJSValueToStructBuffer(env, jsValue, parsed.fields, buffer.data(), 0);
  return buffer;
}

/**
 * Unpack a struct byte buffer into a JS object.
 *
 * Tries specialized fast paths for CGRect/CGPoint/CGSize/NSRange first,
 * falling through to the generic parser for other struct types.
 */
inline Napi::Value UnpackStructToJSValue(Napi::Env env,
                                          const uint8_t *buffer,
                                          const char *typeEncoding) {
  // Fast path: check struct name for well-known types
  auto name = ExtractStructName(typeEncoding);
  if (!name.empty()) {
    if (name == "CGRect" || name == "NSRect") {
      return TryUnpackCGRect(env, buffer);
    } else if (name == "CGPoint" || name == "NSPoint") {
      return TryUnpackCGPoint(env, buffer);
    } else if (name == "CGSize" || name == "NSSize") {
      return TryUnpackCGSize(env, buffer);
    } else if (name == "_NSRange" || name == "NSRange") {
      return TryUnpackNSRange(env, buffer);
    }
  }

  // Generic path
  const ParsedStructType &parsed = GetOrParseStructEncoding(typeEncoding);

  if (parsed.fields.empty()) {
    NOBJC_ERROR("UnpackStructToJSValue: Failed to parse struct encoding '%s'",
                typeEncoding);
    return env.Undefined();
  }

  return UnpackStructBufferToJSObject(env, parsed.fields, buffer, 0);
}

#endif // STRUCT_UTILS_H
