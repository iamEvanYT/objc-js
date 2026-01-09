#pragma once

// ============================================================================
// constants.h - Named Constants for nobjc
// ============================================================================
//
// This header centralizes magic numbers and configuration values used
// throughout the codebase for better maintainability and documentation.
//

#include <cstddef>
#include <CoreFoundation/CoreFoundation.h>

namespace nobjc {

// MARK: - RunLoop Configuration

/// Time interval (in seconds) for each CFRunLoop iteration when waiting for
/// JS callback completion. Smaller values = more responsive but higher CPU.
constexpr CFTimeInterval kRunLoopPumpInterval = 0.001;  // 1ms

/// Number of runloop iterations between debug log messages when waiting.
/// Set to 1000 = log every ~1 second at kRunLoopPumpInterval of 1ms.
constexpr int kRunLoopDebugLogInterval = 1000;

// MARK: - Buffer Sizes

/// Minimum size for return value buffers (handles pointer-sized returns).
constexpr size_t kMinReturnBufferSize = 16;

/// Buffer size for type encoding strings (stack allocation).
constexpr size_t kTypeEncodingBufferSize = 64;

// MARK: - FFI Configuration

/// Default buffer size for FFI argument storage when type size is unknown.
constexpr size_t kDefaultArgBufferSize = sizeof(void*);

/// Size of pointer storage for out-parameters (e.g., NSError**).
constexpr size_t kOutParamPointerSize = sizeof(void*);

}  // namespace nobjc
