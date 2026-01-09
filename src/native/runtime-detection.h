#ifndef RUNTIME_DETECTION_H
#define RUNTIME_DETECTION_H

#include <napi.h>

/**
 * Detects if the code is running in an Electron environment.
 *
 * This is detected by checking for process.versions.electron.
 * In Electron, direct JS callback invocation may fail due to V8 context
 * issues, so we need to use ThreadSafeFunction for all callbacks.
 *
 * @param env The N-API environment
 * @return true if running in Electron, false otherwise
 */
inline bool IsElectronRuntime(Napi::Env env) {
  try {
    Napi::Object global = env.Global();
    if (global.Has("process")) {
      Napi::Object process = global.Get("process").As<Napi::Object>();
      if (process.Has("versions")) {
        Napi::Object versions = process.Get("versions").As<Napi::Object>();
        return versions.Has("electron");
      }
    }
  } catch (...) {
    // If detection fails, assume not Electron
  }
  return false;
}

/**
 * Detects if the code is running in Bun.
 *
 * @param env The N-API environment
 * @return true if running in Bun, false otherwise
 */
inline bool IsBunRuntime(Napi::Env env) {
  try {
    Napi::Object global = env.Global();
    if (global.Has("process")) {
      Napi::Object process = global.Get("process").As<Napi::Object>();
      if (process.Has("versions")) {
        Napi::Object versions = process.Get("versions").As<Napi::Object>();
        return versions.Has("bun");
      }
    }
  } catch (...) {
    // If detection fails, assume not Bun
  }
  return false;
}

#endif // RUNTIME_DETECTION_H
