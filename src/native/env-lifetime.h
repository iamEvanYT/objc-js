#ifndef ENV_LIFETIME_H
#define ENV_LIFETIME_H

#include <memory>
#include <mutex>

/**
 * Tracks whether a Node-API environment can still be called into.
 *
 * When an environment is torn down (process exit, worker termination,
 * Electron quit), Node frees every ThreadSafeFunction it owns, even if
 * Objective-C still holds a block, protocol delegate, or subclass instance
 * that uses one. Touching a TSFN after that is a use-after-free, which shows
 * up as a crash or as a hang while locking the TSFN's freed mutex.
 *
 * An env cleanup hook flips `alive` to false before Node frees anything.
 * Code that uses a TSFN from a non-JS thread must hold `mutex` across the
 * `alive` check and the TSFN call, so teardown cannot happen in between.
 * Never call into JS while holding `mutex`.
 */
struct EnvLifetime {
  std::mutex mutex;
  bool alive = true;
  bool reportedIgnoredCall = false;

  // Whether to log a call ignored because the env is gone. Only the first is
  // logged, since teardown (e.g. an Electron app quitting) can cause many.
  // Hold `mutex`.
  bool ShouldReportIgnoredCall() {
    if (reportedIgnoredCall) return false;
    reportedIgnoredCall = true;
    return true;
  }
};

using EnvLifetimeRef = std::shared_ptr<EnvLifetime>;

#endif // ENV_LIFETIME_H
