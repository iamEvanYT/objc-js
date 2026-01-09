#ifndef TYPE_DISPATCH_H
#define TYPE_DISPATCH_H

#include <Foundation/Foundation.h>
#include <type_traits>

// MARK: - Type Code to C++ Type Mapping

/**
 * Maps Objective-C type encoding characters to C++ types.
 * 
 * Type codes:
 *   'c' = char           'C' = unsigned char
 *   'i' = int            'I' = unsigned int
 *   's' = short          'S' = unsigned short
 *   'l' = long           'L' = unsigned long
 *   'q' = long long      'Q' = unsigned long long
 *   'f' = float          'd' = double
 *   'B' = bool
 *   '*' = char*          '@' = id            '#' = Class
 *   ':' = SEL            '^' = pointer       'v' = void
 */

// Tag types for special ObjC types
struct ObjCIdTag {};
struct ObjCClassTag {};
struct ObjCSELTag {};
struct ObjCCStringTag {};
struct ObjCPointerTag {};
struct ObjCVoidTag {};

// Type trait to get C++ type from type code (compile-time)
template <char TypeCode> struct TypeCodeToType;

template <> struct TypeCodeToType<'c'> { using type = char; };
template <> struct TypeCodeToType<'i'> { using type = int; };
template <> struct TypeCodeToType<'s'> { using type = short; };
template <> struct TypeCodeToType<'l'> { using type = long; };
template <> struct TypeCodeToType<'q'> { using type = long long; };
template <> struct TypeCodeToType<'C'> { using type = unsigned char; };
template <> struct TypeCodeToType<'I'> { using type = unsigned int; };
template <> struct TypeCodeToType<'S'> { using type = unsigned short; };
template <> struct TypeCodeToType<'L'> { using type = unsigned long; };
template <> struct TypeCodeToType<'Q'> { using type = unsigned long long; };
template <> struct TypeCodeToType<'f'> { using type = float; };
template <> struct TypeCodeToType<'d'> { using type = double; };
template <> struct TypeCodeToType<'B'> { using type = bool; };
template <> struct TypeCodeToType<'*'> { using type = ObjCCStringTag; };
template <> struct TypeCodeToType<'@'> { using type = ObjCIdTag; };
template <> struct TypeCodeToType<'#'> { using type = ObjCClassTag; };
template <> struct TypeCodeToType<':'> { using type = ObjCSELTag; };
template <> struct TypeCodeToType<'^'> { using type = ObjCPointerTag; };
template <> struct TypeCodeToType<'v'> { using type = ObjCVoidTag; };

template <char TypeCode>
using TypeCodeToType_t = typename TypeCodeToType<TypeCode>::type;

// MARK: - Type Traits for Categories

template <typename T>
struct is_signed_integer : std::bool_constant<
    std::is_same_v<T, char> || std::is_same_v<T, short> ||
    std::is_same_v<T, int> || std::is_same_v<T, long> ||
    std::is_same_v<T, long long>> {};

template <typename T>
struct is_unsigned_integer : std::bool_constant<
    std::is_same_v<T, unsigned char> || std::is_same_v<T, unsigned short> ||
    std::is_same_v<T, unsigned int> || std::is_same_v<T, unsigned long> ||
    std::is_same_v<T, unsigned long long>> {};

template <typename T>
struct is_floating_point : std::bool_constant<
    std::is_same_v<T, float> || std::is_same_v<T, double>> {};

template <typename T>
inline constexpr bool is_signed_integer_v = is_signed_integer<T>::value;

template <typename T>
inline constexpr bool is_unsigned_integer_v = is_unsigned_integer<T>::value;

template <typename T>
inline constexpr bool is_floating_point_v = is_floating_point<T>::value;

template <typename T>
inline constexpr bool is_numeric_v = 
    is_signed_integer_v<T> || is_unsigned_integer_v<T> || 
    is_floating_point_v<T> || std::is_same_v<T, bool>;

// MARK: - Runtime Type Dispatch

/**
 * Dispatches to a visitor based on runtime type code.
 * 
 * The visitor must implement operator() for each type:
 *   - Numeric types: char, short, int, long, long long (signed/unsigned), float, double, bool
 *   - ObjC types: ObjCIdTag, ObjCClassTag, ObjCSELTag, ObjCCStringTag, ObjCPointerTag, ObjCVoidTag
 * 
 * Example:
 *   struct MyVisitor {
 *     template <typename T>
 *     auto operator()(std::type_identity<T>) { ... }
 *   };
 *   
 *   auto result = DispatchByTypeCode(typeCode, MyVisitor{});
 */
template <typename Visitor>
auto DispatchByTypeCode(char typeCode, Visitor&& visitor) 
    -> decltype(visitor(std::type_identity<int>{})) {
  switch (typeCode) {
    case 'c': return visitor(std::type_identity<char>{});
    case 'i': return visitor(std::type_identity<int>{});
    case 's': return visitor(std::type_identity<short>{});
    case 'l': return visitor(std::type_identity<long>{});
    case 'q': return visitor(std::type_identity<long long>{});
    case 'C': return visitor(std::type_identity<unsigned char>{});
    case 'I': return visitor(std::type_identity<unsigned int>{});
    case 'S': return visitor(std::type_identity<unsigned short>{});
    case 'L': return visitor(std::type_identity<unsigned long>{});
    case 'Q': return visitor(std::type_identity<unsigned long long>{});
    case 'f': return visitor(std::type_identity<float>{});
    case 'd': return visitor(std::type_identity<double>{});
    case 'B': return visitor(std::type_identity<bool>{});
    case '*': return visitor(std::type_identity<ObjCCStringTag>{});
    case '@': return visitor(std::type_identity<ObjCIdTag>{});
    case '#': return visitor(std::type_identity<ObjCClassTag>{});
    case ':': return visitor(std::type_identity<ObjCSELTag>{});
    case '^': return visitor(std::type_identity<ObjCPointerTag>{});
    case 'v': return visitor(std::type_identity<ObjCVoidTag>{});
    default:  return visitor(std::type_identity<ObjCVoidTag>{}); // Fallback
  }
}

/**
 * Dispatches only for numeric types (including bool).
 * Returns the default value if type is not numeric.
 */
template <typename Visitor, typename DefaultValue>
auto DispatchNumericType(char typeCode, Visitor&& visitor, DefaultValue&& defaultVal)
    -> decltype(visitor(std::type_identity<int>{})) {
  switch (typeCode) {
    case 'c': return visitor(std::type_identity<char>{});
    case 'i': return visitor(std::type_identity<int>{});
    case 's': return visitor(std::type_identity<short>{});
    case 'l': return visitor(std::type_identity<long>{});
    case 'q': return visitor(std::type_identity<long long>{});
    case 'C': return visitor(std::type_identity<unsigned char>{});
    case 'I': return visitor(std::type_identity<unsigned int>{});
    case 'S': return visitor(std::type_identity<unsigned short>{});
    case 'L': return visitor(std::type_identity<unsigned long>{});
    case 'Q': return visitor(std::type_identity<unsigned long long>{});
    case 'f': return visitor(std::type_identity<float>{});
    case 'd': return visitor(std::type_identity<double>{});
    case 'B': return visitor(std::type_identity<bool>{});
    default:  return std::forward<DefaultValue>(defaultVal);
  }
}

// MARK: - Size Lookup

/**
 * Returns the size of a type given its type code.
 */
inline size_t GetTypeSize(char typeCode) {
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
    case '*': return sizeof(char*);
    case '@': return sizeof(id);
    case '#': return sizeof(Class);
    case ':': return sizeof(SEL);
    case '^': return sizeof(void*);
    case 'v': return 0;
    default:  return 0;
  }
}

/**
 * Returns true if the type code represents a numeric type.
 */
inline bool IsNumericTypeCode(char typeCode) {
  switch (typeCode) {
    case 'c': case 'i': case 's': case 'l': case 'q':
    case 'C': case 'I': case 'S': case 'L': case 'Q':
    case 'f': case 'd': case 'B':
      return true;
    default:
      return false;
  }
}

/**
 * Returns true if the type code represents a signed integer.
 */
inline bool IsSignedIntegerTypeCode(char typeCode) {
  switch (typeCode) {
    case 'c': case 'i': case 's': case 'l': case 'q':
      return true;
    default:
      return false;
  }
}

/**
 * Returns true if the type code represents an unsigned integer.
 */
inline bool IsUnsignedIntegerTypeCode(char typeCode) {
  switch (typeCode) {
    case 'C': case 'I': case 'S': case 'L': case 'Q':
      return true;
    default:
      return false;
  }
}

/**
 * Returns true if the type code represents a floating point type.
 */
inline bool IsFloatingPointTypeCode(char typeCode) {
  return typeCode == 'f' || typeCode == 'd';
}

/**
 * Returns true if the type code represents an object type (@, #).
 */
inline bool IsObjectTypeCode(char typeCode) {
  return typeCode == '@' || typeCode == '#';
}

#endif // TYPE_DISPATCH_H
