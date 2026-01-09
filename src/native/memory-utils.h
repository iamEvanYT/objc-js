#ifndef MEMORY_UTILS_H
#define MEMORY_UTILS_H

#include "debug.h"
#include "protocol-storage.h"
#include <Foundation/Foundation.h>

// MARK: - InvocationDataGuard RAII Wrapper

/**
 * RAII wrapper for InvocationData to ensure proper cleanup.
 * 
 * This class manages the lifetime of InvocationData*, ensuring that:
 * 1. The NSInvocation is released
 * 2. The InvocationData is deleted
 * 3. Cleanup happens even when exceptions are thrown
 * 
 * Usage:
 *   auto data = new InvocationData();
 *   InvocationDataGuard guard(data);
 *   // ... use data ...
 *   guard.release();  // Transfer ownership on success
 * 
 * If release() is not called, cleanup happens in destructor.
 */
class InvocationDataGuard {
public:
  explicit InvocationDataGuard(InvocationData* data) : data_(data), released_(false) {
#if NOBJC_DEBUG
    if (data_) {
      NOBJC_LOG("InvocationDataGuard: acquired data=%p, selector=%s", 
                data_, data_->selectorName.c_str());
    }
#endif
  }
  
  // Non-copyable
  InvocationDataGuard(const InvocationDataGuard&) = delete;
  InvocationDataGuard& operator=(const InvocationDataGuard&) = delete;
  
  // Movable
  InvocationDataGuard(InvocationDataGuard&& other) noexcept 
      : data_(other.data_), released_(other.released_) {
    other.data_ = nullptr;
    other.released_ = true;
  }
  
  InvocationDataGuard& operator=(InvocationDataGuard&& other) noexcept {
    if (this != &other) {
      cleanup();
      data_ = other.data_;
      released_ = other.released_;
      other.data_ = nullptr;
      other.released_ = true;
    }
    return *this;
  }
  
  ~InvocationDataGuard() {
    cleanup();
  }
  
  /**
   * Release ownership of the data without cleanup.
   * Call this when you're transferring ownership elsewhere (e.g., to a callback).
   * @return The raw pointer (caller takes ownership)
   */
  InvocationData* release() {
    released_ = true;
    InvocationData* ptr = data_;
    data_ = nullptr;
#if NOBJC_DEBUG
    if (ptr) {
      NOBJC_LOG("InvocationDataGuard: released ownership of data=%p", ptr);
    }
#endif
    return ptr;
  }
  
  /**
   * Get the raw pointer without releasing ownership.
   */
  InvocationData* get() const { return data_; }
  
  /**
   * Check if the guard has valid data.
   */
  explicit operator bool() const { return data_ != nullptr && !released_; }
  
  /**
   * Arrow operator for convenient access.
   */
  InvocationData* operator->() const { return data_; }
  
private:
  void cleanup() {
    if (data_ && !released_) {
#if NOBJC_DEBUG
      NOBJC_LOG("InvocationDataGuard: cleaning up data=%p, selector=%s", 
                data_, data_->selectorName.c_str());
#endif
      // Release the NSInvocation if present
      if (data_->invocation) {
        [data_->invocation release];
        data_->invocation = nil;
      }
      
      // Delete the data
      delete data_;
      data_ = nullptr;
    }
  }
  
  InvocationData* data_;
  bool released_;
};

// MARK: - Cleanup Callback for CallJSCallback

/**
 * Helper function to clean up InvocationData after a JS callback completes.
 * This is called from CallJSCallback to ensure proper cleanup regardless of
 * success or failure.
 * 
 * @param data The InvocationData to clean up (takes ownership)
 */
inline void CleanupInvocationData(InvocationData* data) {
  if (!data) return;
  
#if NOBJC_DEBUG
  NOBJC_LOG("CleanupInvocationData: cleaning up selector=%s", 
            data->selectorName.c_str());
#endif
  
  // Signal completion if we have synchronization primitives
  SignalInvocationComplete(data);
  
  // Release the invocation
  if (data->invocation) {
    [data->invocation release];
    data->invocation = nil;
  }
  
  // Delete the data
  delete data;
}

// MARK: - ScopeGuard for Generic Cleanup

/**
 * Generic scope guard for executing cleanup code on scope exit.
 * 
 * Usage:
 *   auto guard = MakeScopeGuard([&] { cleanup_code(); });
 *   // ... do work ...
 *   guard.dismiss();  // Don't run cleanup on success
 */
template<typename Func>
class ScopeGuard {
public:
  explicit ScopeGuard(Func&& func) : func_(std::forward<Func>(func)), active_(true) {}
  
  ScopeGuard(ScopeGuard&& other) noexcept 
      : func_(std::move(other.func_)), active_(other.active_) {
    other.active_ = false;
  }
  
  ~ScopeGuard() {
    if (active_) {
      try {
        func_();
      } catch (...) {
        // Suppress exceptions in destructor
#if NOBJC_DEBUG
        NOBJC_ERROR("ScopeGuard: exception during cleanup (suppressed)");
#endif
      }
    }
  }
  
  void dismiss() { active_ = false; }
  
  // Non-copyable
  ScopeGuard(const ScopeGuard&) = delete;
  ScopeGuard& operator=(const ScopeGuard&) = delete;
  
private:
  Func func_;
  bool active_;
};

template<typename Func>
ScopeGuard<Func> MakeScopeGuard(Func&& func) {
  return ScopeGuard<Func>(std::forward<Func>(func));
}

#endif // MEMORY_UTILS_H
