#ifndef PROTOCOL_MANAGER_H
#define PROTOCOL_MANAGER_H

/**
 * @file protocol-manager.h
 * @brief Singleton manager for protocol implementations.
 *
 * ProtocolManager provides thread-safe access to protocol implementation storage.
 * It replaces the global g_implementations map and g_implementations_mutex with
 * an encapsulated singleton pattern.
 *
 * Usage:
 *   // Register a protocol implementation
 *   ProtocolManager::Instance().Register(instancePtr, std::move(impl));
 *
 *   // Find an implementation
 *   auto* impl = ProtocolManager::Instance().Find(instancePtr);
 *
 *   // Execute a callback with lock held
 *   ProtocolManager::Instance().WithLock([](auto& map) {
 *     // ... work with map ...
 *   });
 */

#include "protocol-storage.h"
#include <functional>
#include <mutex>
#include <optional>
#include <unordered_map>

namespace nobjc {

/**
 * @brief Thread-safe singleton manager for protocol implementations.
 *
 * Encapsulates storage and synchronization for protocol implementations,
 * providing a clean API for registration, lookup, and unregistration.
 */
class ProtocolManager {
public:
  /**
   * @brief Get the singleton instance.
   * @return Reference to the singleton ProtocolManager.
   */
  static ProtocolManager& Instance() {
    static ProtocolManager instance;
    return instance;
  }

  // Delete copy/move operations for singleton
  ProtocolManager(const ProtocolManager&) = delete;
  ProtocolManager& operator=(const ProtocolManager&) = delete;
  ProtocolManager(ProtocolManager&&) = delete;
  ProtocolManager& operator=(ProtocolManager&&) = delete;

  /**
   * @brief Find an implementation by instance pointer.
   * @param instancePtr The Objective-C instance pointer (bridged from id).
   * @return Pointer to implementation if found, nullptr otherwise.
   * @note Caller must NOT hold the lock. This method acquires the lock.
   */
  ProtocolImplementation* Find(void* instancePtr) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = implementations_.find(instancePtr);
    if (it != implementations_.end()) {
      return &it->second;
    }
    return nullptr;
  }

  /**
   * @brief Register a new protocol implementation.
   * @param instancePtr The Objective-C instance pointer.
   * @param impl The implementation to register (moved).
   */
  void Register(void* instancePtr, ProtocolImplementation&& impl) {
    std::lock_guard<std::mutex> lock(mutex_);
    implementations_.emplace(instancePtr, std::move(impl));
  }

  /**
   * @brief Unregister a protocol implementation.
   * @param instancePtr The Objective-C instance pointer.
   * @return true if the implementation was found and removed, false otherwise.
   */
  bool Unregister(void* instancePtr) {
    std::lock_guard<std::mutex> lock(mutex_);
    return implementations_.erase(instancePtr) > 0;
  }

  /**
   * @brief Execute a callback with the lock held.
   * @param callback Function to call with the map reference.
   *
   * Use this for complex operations that need to access multiple map entries
   * or perform conditional logic while holding the lock.
   */
  template <typename Callback>
  auto WithLock(Callback&& callback)
      -> decltype(callback(std::declval<std::unordered_map<void*, ProtocolImplementation>&>())) {
    std::lock_guard<std::mutex> lock(mutex_);
    return callback(implementations_);
  }

  /**
   * @brief Execute a read-only callback with the lock held.
   * @param callback Function to call with const map reference.
   */
  template <typename Callback>
  auto WithLockConst(Callback&& callback) const
      -> decltype(callback(std::declval<const std::unordered_map<void*, ProtocolImplementation>&>())) {
    std::lock_guard<std::mutex> lock(mutex_);
    return callback(implementations_);
  }

  /**
   * @brief Get the number of registered implementations.
   * @return Count of implementations.
   */
  size_t Size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return implementations_.size();
  }

  /**
   * @brief Check if an implementation exists for the given pointer.
   * @param instancePtr The Objective-C instance pointer.
   * @return true if registered, false otherwise.
   */
  bool Contains(void* instancePtr) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return implementations_.find(instancePtr) != implementations_.end();
  }

private:
  ProtocolManager() = default;
  ~ProtocolManager() = default;

  mutable std::mutex mutex_;
  std::unordered_map<void*, ProtocolImplementation> implementations_;
};

} // namespace nobjc

#endif // PROTOCOL_MANAGER_H
