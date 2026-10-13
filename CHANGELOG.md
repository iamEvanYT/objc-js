# Changelog

## [1.6.0] - 2026-10-13

- feat: add `dispose()` to release an Objective-C object immediately instead of when its wrapper is garbage collected; using the object afterwards throws instead of silently passing `nil` (based on #1)
- fix: blocks, protocol delegates and subclass instances that outlive their JS environment (worker termination, Electron quit) no longer crash or hang the process on exit; calls into a torn-down environment now return zero/`nil` (reported in #1)
- fix: link Foundation, CoreFoundation and libobjc so the addon loads in plain Node.js/Bun on macOS 27 (previously failed with `symbol not found in flat namespace '_NSDefaultRunLoopMode'` unless Foundation was already loaded)
- fix: `BOOL` values are now JS booleans on Intel Macs (previously returned as `1`/`0`, and passing `true`/`false` to `BOOL` arguments threw)
- fix: negative `char`/`short` arguments were passed incorrectly (e.g. `-5` arrived as `251`)
- fix: blocks without explicit types (no `typedBlock`) sometimes received short `NSString`s, small `NSNumber`s and other tagged pointer objects as plain numbers on Intel Macs, depending on a random per-process value
- fix: integer return values from `NobjcClass.super()` calls without arguments were read at the wrong width, which could corrupt negative values
- build: build libffi from source and link it statically for prebuilds (minimum macOS 13.3), replacing Homebrew bottles that are no longer available
- chore: update dependencies (`node-addon-api` 8.9.2)
- test: fix RunLoop timer test on macOS 27

## [1.5.0] - 2026-04-06

- feat: add typedBlock API for explicit Objective-C block signatures

## [1.4.0] - 2026-03-24

- feat: add RunLoop APIs
- feat: cleanup blocks when finished

## [1.3.1] - 2026-02-22

- fix: custom inspect symbol not being set on native objects
- speculative fix: retain ObjC objects in JS wrappers to prevent use-after-free
- fix: `then` method erroring

## [1.3.0] - 2026-02-21

- feat: add block support
- feat: add testing for node with vitest

## [1.2.1] - 2026-02-21

- feat: add calling C functions like NSLog, NSHomeDirectory, NSStringFromClass
- refactor: improve performance

## [1.1.0] - 2026-02-17

- feat: added support for structs

## [1.0.4] - 2026-01-14

- fix: prebuilds not being detected by `@electron/rebuild`

## [1.0.3] - 2026-01-14

- fix: native.js not loading correctly

## [1.0.2] - 2026-01-14

- feat: Static linking of libffi

## [1.0.1] - 2026-01-14

- Added prebuilds for native code
