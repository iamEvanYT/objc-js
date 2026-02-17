#ifndef FFI_UTILS_H
#define FFI_UTILS_H

#include <ffi.h>
#include <Foundation/Foundation.h>
#include <napi.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <vector>
#include <memory>
#include "debug.h"
#include "bridge.h"
#include "type-conversion.h"

// MARK: - FFITypeGuard RAII Wrapper

/**
 * RAII wrapper for managing dynamically allocated ffi_type structs.
 * 
 * FFI struct types require heap allocation for their elements arrays.
 * This class ensures proper cleanup when going out of scope, even if
 * exceptions are thrown.
 * 
 * Usage:
 *   FFITypeGuard guard;
 *   ffi_type* structType = ParseStructEncoding(encoding, &size, guard);
 *   // ... use structType ...
 *   // Cleanup happens automatically when guard goes out of scope
 */
class FFITypeGuard {
public:
  FFITypeGuard() = default;
  
  // Non-copyable
  FFITypeGuard(const FFITypeGuard&) = delete;
  FFITypeGuard& operator=(const FFITypeGuard&) = delete;
  
  // Movable
  FFITypeGuard(FFITypeGuard&& other) noexcept : allocatedTypes_(std::move(other.allocatedTypes_)) {
    other.allocatedTypes_.clear();
  }
  
  FFITypeGuard& operator=(FFITypeGuard&& other) noexcept {
    if (this != &other) {
      cleanup();
      allocatedTypes_ = std::move(other.allocatedTypes_);
      other.allocatedTypes_.clear();
    }
    return *this;
  }
  
  ~FFITypeGuard() {
    cleanup();
  }
  
  /**
   * Add a dynamically allocated ffi_type to be managed.
   * The guard takes ownership and will free it on destruction.
   */
  void add(ffi_type* type) {
    if (type) {
      allocatedTypes_.push_back(type);
#if NOBJC_DEBUG
      NOBJC_LOG("FFITypeGuard: added type=%p (total: %zu)", type, allocatedTypes_.size());
#endif
    }
  }
  
  /**
   * Get the underlying vector (for passing to legacy functions).
   */
  std::vector<ffi_type*>& types() { return allocatedTypes_; }
  
  /**
   * Release ownership of all types without cleanup.
   * Use when transferring ownership elsewhere.
   */
  std::vector<ffi_type*> release() {
    std::vector<ffi_type*> result = std::move(allocatedTypes_);
    allocatedTypes_.clear();
#if NOBJC_DEBUG
    NOBJC_LOG("FFITypeGuard: released ownership of %zu types", result.size());
#endif
    return result;
  }
  
  /**
   * Get number of managed types.
   */
  size_t size() const { return allocatedTypes_.size(); }
  
private:
  void cleanup() {
    if (!allocatedTypes_.empty()) {
#if NOBJC_DEBUG
      NOBJC_LOG("FFITypeGuard: cleaning up %zu types", allocatedTypes_.size());
#endif
      for (ffi_type* type : allocatedTypes_) {
        if (type && type->type == FFI_TYPE_STRUCT && type->elements) {
          delete[] type->elements;
        }
        delete type;
      }
      allocatedTypes_.clear();
    }
  }
  
  std::vector<ffi_type*> allocatedTypes_;
};

// MARK: - Type Size Calculation

inline size_t GetSizeForTypeEncoding(char typeCode) {
  switch (typeCode) {
    case 'c': return sizeof(char);
    case 'i': return sizeof(int);
    case 's': return sizeof(short);
    case 'l': return sizeof(long);
    case 'q': return sizeof(long long);
    case 'C': return sizeof(unsigned char);
    case 'I': return sizeof(unsigned int);
    case 'S': return sizeof(unsigned short);
    case 'L': return sizeof(unsigned long);
    case 'Q': return sizeof(unsigned long long);
    case 'f': return sizeof(float);
    case 'd': return sizeof(double);
    case 'B': return sizeof(bool);
    case '@':
    case '#':
    case ':':
    case '*':
    case '^':
      return sizeof(void*);
    case 'v':
      return 0;
    default:
      NOBJC_ERROR("GetSizeForTypeEncoding: Unknown type code '%c'", typeCode);
      return 0;
  }
}

// MARK: - FFI Type Mapping - Simple Types

inline ffi_type* GetFFITypeForSimpleEncoding(char typeCode) {
  switch (typeCode) {
    case 'c': return &ffi_type_sint8;
    case 'i': return &ffi_type_sint32;
    case 's': return &ffi_type_sint16;
    case 'l': return &ffi_type_slong;
    case 'q': return &ffi_type_sint64;
    case 'C': return &ffi_type_uint8;
    case 'I': return &ffi_type_uint32;
    case 'S': return &ffi_type_uint16;
    case 'L': return &ffi_type_ulong;
    case 'Q': return &ffi_type_uint64;
    case 'f': return &ffi_type_float;
    case 'd': return &ffi_type_double;
    case 'B': return &ffi_type_uint8;  // BOOL
    case '@':
    case '#':
    case ':':
    case '*':
    case '^':
      return &ffi_type_pointer;
    case 'v': return &ffi_type_void;
    default:
      NOBJC_ERROR("GetFFITypeForSimpleEncoding: Unknown type code '%c'", typeCode);
      return &ffi_type_void;
  }
}

// Forward declarations
inline ffi_type* GetFFITypeForEncoding(const char* encoding, size_t* outSize, 
                                      std::vector<ffi_type*>& allocatedTypes);

// Overload that works with FFITypeGuard (preferred)
inline ffi_type* GetFFITypeForEncoding(const char* encoding, size_t* outSize, 
                                      FFITypeGuard& guard) {
  return GetFFITypeForEncoding(encoding, outSize, guard.types());
}

// MARK: - Struct Type Parsing

inline ffi_type* ParseStructEncoding(const char* encoding, size_t* outSize, 
                                     std::vector<ffi_type*>& allocatedTypes) {
  NOBJC_LOG("ParseStructEncoding: parsing struct '%s'", encoding);
  
  auto header = ParseStructEncodingHeader(encoding);
  
  if (header.empty) {
    NOBJC_LOG("ParseStructEncoding: empty struct");
    return &ffi_type_void;
  }
  
  if (!header.fieldsStart) {
    NOBJC_ERROR("ParseStructEncoding: Invalid struct encoding '%s'", encoding);
    return nullptr;
  }
  
  const char* ptr = header.fieldsStart;
  
  // Parse field types
  std::vector<ffi_type*> fieldTypes;
  
  while (*ptr && *ptr != '}') {
    // Skip any qualifiers
    ptr = SimplifyTypeEncoding(ptr);
    
    if (*ptr == '}') break;
    
    std::string fieldEncoding = SkipOneFieldEncoding(ptr);
    NOBJC_LOG("ParseStructEncoding: parsing field '%s'", fieldEncoding.c_str());
    
    // Recursively get FFI type for this field
    ffi_type* fieldType = GetFFITypeForEncoding(fieldEncoding.c_str(), nullptr, allocatedTypes);
    if (!fieldType) {
      NOBJC_ERROR("ParseStructEncoding: Failed to parse field type");
      return nullptr;
    }
    
    fieldTypes.push_back(fieldType);
  }
  
  if (fieldTypes.empty()) {
    NOBJC_LOG("ParseStructEncoding: no fields found");
    return &ffi_type_void;
  }
  
  // Allocate ffi_type struct on heap
  ffi_type* structType = new ffi_type;
  structType->type = FFI_TYPE_STRUCT;
  structType->size = 0;
  structType->alignment = 0;
  
  // Allocate elements array (null-terminated)
  structType->elements = new ffi_type*[fieldTypes.size() + 1];
  for (size_t i = 0; i < fieldTypes.size(); i++) {
    structType->elements[i] = fieldTypes[i];
  }
  structType->elements[fieldTypes.size()] = nullptr;
  
  // Calculate size using NSGetSizeAndAlignment
  NSUInteger size, alignment;
  NSGetSizeAndAlignment(encoding, &size, &alignment);
  
  if (outSize) {
    *outSize = size;
  }
  
  NOBJC_LOG("ParseStructEncoding: struct has %zu fields, size=%zu", 
            fieldTypes.size(), (size_t)size);
  
  // Add to cleanup list
  allocatedTypes.push_back(structType);
  
  return structType;
}

// MARK: - Main FFI Type Function

inline ffi_type* GetFFITypeForEncoding(const char* encoding, size_t* outSize,
                                      std::vector<ffi_type*>& allocatedTypes) {
  if (!encoding || !*encoding) {
    NOBJC_ERROR("GetFFITypeForEncoding: null or empty encoding");
    return &ffi_type_void;
  }
  
  // Simplify encoding (remove qualifiers)
  SimplifiedTypeEncoding simplified(encoding);
  const char* simpleEncoding = simplified.c_str();
  
  char firstChar = simpleEncoding[0];
  
  // Handle structs and unions
  if (firstChar == '{') {
    return ParseStructEncoding(simpleEncoding, outSize, allocatedTypes);
  } else if (firstChar == '(') {
    // Unions are treated like structs for FFI purposes
    return ParseStructEncoding(simpleEncoding, outSize, allocatedTypes);
  }
  
  // Simple type
  ffi_type* type = GetFFITypeForSimpleEncoding(firstChar);
  
  if (outSize) {
    *outSize = GetSizeForTypeEncoding(firstChar);
  }
  
  return type;
}

// MARK: - Argument Extraction

inline void ExtractJSArgumentToBuffer(Napi::Env env, const Napi::Value& jsValue,
                                     const char* typeEncoding, void* buffer,
                                     const ObjcArgumentContext& context) {
  NOBJC_LOG("ExtractJSArgumentToBuffer: typeEncoding=%s, buffer=%p", typeEncoding, buffer);
  
  // Use existing AsObjCArgument to convert JS to ObjcType variant
  auto optType = AsObjCArgument(jsValue, typeEncoding, context);
  
  if (!optType.has_value()) {
    NOBJC_ERROR("ExtractJSArgumentToBuffer: AsObjCArgument returned nullopt");
    throw Napi::Error::New(env, "Failed to convert JS argument to ObjC type");
  }
  
  ObjcType objcType = optType.value();
  NOBJC_LOG("ExtractJSArgumentToBuffer: Got ObjcType variant, index=%zu", objcType.index());
  
  // Visit the outer variant
  std::visit([&](auto&& arg) {
    using T = std::decay_t<decltype(arg)>;
    
    if constexpr (std::is_same_v<T, BaseObjcType>) {
      NOBJC_LOG("ExtractJSArgumentToBuffer: Outer variant is BaseObjcType, visiting inner...");
      // It's a BaseObjcType directly - need to visit it to get the actual type
      std::visit([&](auto&& innerArg) {
        using InnerT = std::decay_t<decltype(innerArg)>;
        
        if constexpr (std::is_same_v<InnerT, std::monostate>) {
          NOBJC_LOG("ExtractJSArgumentToBuffer: Inner type is monostate (void)");
          // void - do nothing
        } else if constexpr (std::is_same_v<InnerT, std::string>) {
          NOBJC_LOG("ExtractJSArgumentToBuffer: Inner type is std::string");
          // String - store pointer
          const char* cstr = innerArg.c_str();
          *((const char**)buffer) = cstr;
          NOBJC_LOG("ExtractJSArgumentToBuffer: Stored string pointer: %p", cstr);
        } else if constexpr (std::is_same_v<InnerT, id>) {
          NOBJC_LOG("ExtractJSArgumentToBuffer: Inner type is id (object)");
          // Object - store pointer directly
          *((id*)buffer) = innerArg;
          NOBJC_LOG("ExtractJSArgumentToBuffer: Stored object pointer: %p", innerArg);
        } else if constexpr (std::is_same_v<InnerT, Class>) {
          NOBJC_LOG("ExtractJSArgumentToBuffer: Inner type is Class");
          // Class - store pointer directly
          *((Class*)buffer) = innerArg;
          NOBJC_LOG("ExtractJSArgumentToBuffer: Stored Class pointer: %p", innerArg);
        } else if constexpr (std::is_same_v<InnerT, SEL>) {
          NOBJC_LOG("ExtractJSArgumentToBuffer: Inner type is SEL");
          // SEL - store pointer directly
          *((SEL*)buffer) = innerArg;
          NOBJC_LOG("ExtractJSArgumentToBuffer: Stored SEL: %s", sel_getName(innerArg));
        } else if constexpr (std::is_same_v<InnerT, void*>) {
          NOBJC_LOG("ExtractJSArgumentToBuffer: Inner type is void*");
          // Generic pointer - store directly
          *((void**)buffer) = innerArg;
          NOBJC_LOG("ExtractJSArgumentToBuffer: Stored void pointer: %p", innerArg);
        } else {
          NOBJC_LOG("ExtractJSArgumentToBuffer: Inner type is primitive, size=%zu", sizeof(InnerT));
          // Primitive type - copy value
          *((InnerT*)buffer) = innerArg;
        }
      }, arg);
    } else if constexpr (std::is_same_v<T, BaseObjcType*>) {
      NOBJC_LOG("ExtractJSArgumentToBuffer: Type is BaseObjcType*");
      // Pointer to base type - dereference and copy
      std::visit([&](auto&& innerArg) {
        using InnerT = std::decay_t<decltype(innerArg)>;
        if constexpr (!std::is_same_v<InnerT, std::monostate>) {
          NOBJC_LOG("ExtractJSArgumentToBuffer: Copying inner type, size=%zu", sizeof(InnerT));
          *((InnerT*)buffer) = innerArg;
        }
      }, *arg);
    } else {
      NOBJC_ERROR("ExtractJSArgumentToBuffer: Unexpected outer variant type!");
    }
  }, objcType);
  
  NOBJC_LOG("ExtractJSArgumentToBuffer: Completed successfully");
}

// MARK: - Return Value Conversion

inline Napi::Value ConvertFFIReturnToJS(Napi::Env env, void* returnBuffer,
                                       const char* typeEncoding) {
  SimplifiedTypeEncoding simplified(typeEncoding);
  char typeCode = simplified[0];
  
  // Use existing ObjCToJS for most types
  return ObjCToJS(env, returnBuffer, typeCode);
}

// MARK: - Cleanup Helper

inline void CleanupAllocatedFFITypes(std::vector<ffi_type*>& allocatedTypes) {
  for (ffi_type* type : allocatedTypes) {
    if (type && type->type == FFI_TYPE_STRUCT && type->elements) {
      delete[] type->elements;
    }
    delete type;
  }
  allocatedTypes.clear();
}

#endif // FFI_UTILS_H
