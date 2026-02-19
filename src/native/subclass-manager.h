#ifndef SUBCLASS_MANAGER_H
#define SUBCLASS_MANAGER_H

/**
 * @file subclass-manager.h
 * @brief Singleton manager for subclass implementations.
 *
 * SubclassManager provides thread-safe access to subclass implementation storage.
 * It replaces the global g_subclasses map and g_subclasses_mutex with
 * an encapsulated singleton pattern.
 *
 * Usage:
 *   // Register a subclass implementation
 *   SubclassManager::Instance().Register(classPtr, std::move(impl));
 *
 *   // Find an implementation
 *   auto* impl = SubclassManager::Instance().Find(classPtr);
 *
 *   // Execute a callback with lock held
 *   SubclassManager::Instance().WithLock([](auto& map) {
 *     // ... work with map ...
 *   });
 */

#include "protocol-storage.h"
#include <functional>
#include <mutex>
#include <shared_mutex>
#include <optional>
#include <unordered_map>

namespace nobjc {

/**
 * @brief Thread-safe singleton manager for subclass implementations.
 *
 * Encapsulates storage and synchronization for JS-defined subclasses,
 * providing a clean API for registration, lookup, and iteration.
 */
class SubclassManager {
public:
  /**
   * @brief Get the singleton instance.
   * @return Reference to the singleton SubclassManager.
   */
  static SubclassManager& Instance() {
    static SubclassManager instance;
    return instance;
  }

  // Delete copy/move operations for singleton
  SubclassManager(const SubclassManager&) = delete;
  SubclassManager& operator=(const SubclassManager&) = delete;
  SubclassManager(SubclassManager&&) = delete;
  SubclassManager& operator=(SubclassManager&&) = delete;

  /**
   * @brief Find an implementation by class pointer.
   * @param classPtr The Objective-C Class pointer (bridged from Class).
   * @return Pointer to implementation if found, nullptr otherwise.
   * @note Caller must NOT hold the lock. This method acquires the lock.
   */
  SubclassImplementation* Find(void* classPtr) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    auto it = subclasses_.find(classPtr);
    if (it != subclasses_.end()) {
      return &it->second;
    }
    return nullptr;
  }

  /**
   * @brief Register a new subclass implementation.
   * @param classPtr The Objective-C Class pointer.
   * @param impl The implementation to register (moved).
   */
  void Register(void* classPtr, SubclassImplementation&& impl) {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    subclasses_.emplace(classPtr, std::move(impl));
  }

  /**
   * @brief Unregister a subclass implementation.
   * @param classPtr The Objective-C Class pointer.
   * @return true if the implementation was found and removed, false otherwise.
   */
  bool Unregister(void* classPtr) {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    return subclasses_.erase(classPtr) > 0;
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
      -> decltype(callback(std::declval<std::unordered_map<void*, SubclassImplementation>&>())) {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    return callback(subclasses_);
  }

  /**
   * @brief Execute a read-only callback with the lock held.
   * @param callback Function to call with const map reference.
   */
  template <typename Callback>
  auto WithLockConst(Callback&& callback) const
      -> decltype(callback(std::declval<const std::unordered_map<void*, SubclassImplementation>&>())) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    return callback(subclasses_);
  }

  /**
   * @brief Find superclass by walking the class hierarchy.
   * @param instanceClassPtr Starting class pointer.
   * @return Superclass pointer if found in registry, nullptr otherwise.
   *
   * Walks up the class hierarchy to find a registered subclass implementation
   * and returns its superclass pointer.
   */
  void* FindSuperClassInHierarchy(void* instanceClassPtr) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    
    // Walk up the class hierarchy to find our subclass implementation
    void* clsPtr = instanceClassPtr;
    while (clsPtr != nullptr) {
      auto it = subclasses_.find(clsPtr);
      if (it != subclasses_.end()) {
        return it->second.superClass;
      }
      // Get superclass - this requires Objective-C runtime, so we return nullptr
      // and let the caller handle walking the hierarchy with runtime calls
      return nullptr;
    }
    return nullptr;
  }

  /**
   * @brief Get the number of registered subclasses.
   * @return Count of subclasses.
   */
  size_t Size() const {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    return subclasses_.size();
  }

  /**
   * @brief Check if a subclass exists for the given pointer.
   * @param classPtr The Objective-C Class pointer.
   * @return true if registered, false otherwise.
   */
  bool Contains(void* classPtr) const {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    return subclasses_.find(classPtr) != subclasses_.end();
  }

private:
  SubclassManager() = default;
  ~SubclassManager() = default;

  mutable std::shared_mutex mutex_;
  std::unordered_map<void*, SubclassImplementation> subclasses_;
};

} // namespace nobjc

#endif // SUBCLASS_MANAGER_H
