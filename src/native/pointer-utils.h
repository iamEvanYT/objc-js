#ifndef POINTER_UTILS_H
#define POINTER_UTILS_H

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <napi.h>

// MARK: - Pointer Conversion Utilities

/**
 * Write a pointer value to a buffer in little-endian format.
 * The buffer must be at least sizeof(void*) bytes.
 */
inline void WritePointerToBuffer(const void *ptr, uint8_t *buffer) {
  uintptr_t ptrValue = reinterpret_cast<uintptr_t>(ptr);
  for (size_t i = 0; i < sizeof(void *); ++i) {
    buffer[i] = static_cast<uint8_t>((ptrValue >> (i * 8)) & 0xFF);
  }
}

/**
 * Read a pointer value from a buffer in little-endian format.
 * The buffer must be at least sizeof(void*) bytes.
 */
inline void *ReadPointerFromBuffer(const uint8_t *buffer) {
  uintptr_t ptrValue = 0;
  for (size_t i = 0; i < sizeof(void *); ++i) {
    ptrValue |= static_cast<uintptr_t>(buffer[i]) << (i * 8);
  }
  return reinterpret_cast<void *>(ptrValue);
}

/**
 * Create a N-API BigInt from a pointer value.
 */
inline Napi::BigInt PointerToBigInt(Napi::Env env, const void *ptr) {
  return Napi::BigInt::New(env, reinterpret_cast<uint64_t>(ptr));
}

/**
 * Extract a pointer value from a N-API BigInt.
 * Throws if the value is out of range.
 */
inline void *BigIntToPointer(Napi::Env env, const Napi::BigInt &bigint) {
  bool lossless;
  uint64_t value = bigint.Uint64Value(&lossless);
  if (!lossless) {
    throw Napi::RangeError::New(env, "BigInt value out of range for pointer");
  }
  return reinterpret_cast<void *>(value);
}

/**
 * Create a N-API Buffer containing a pointer value (little-endian).
 */
inline Napi::Buffer<uint8_t> PointerToBuffer(Napi::Env env, const void *ptr) {
  Napi::Buffer<uint8_t> buffer = Napi::Buffer<uint8_t>::New(env, sizeof(void *));
  WritePointerToBuffer(ptr, buffer.Data());
  return buffer;
}

#endif // POINTER_UTILS_H
