# Changelog

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
