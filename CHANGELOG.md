# [1.1.4]

## Fixes

- Router dependencies now resolve to `go_router`'s `GoRouter` instead of a guessed, non-existent `Router` type — both for the mock/import and for detecting method calls made on it.
- Error-path stubs now throw `AppException.test()` (imported from `core/errors/app_exception.dart`) instead of a generic `Exception`.
- Fixed a missing interface import when the notifier's own source only imports a dependency's `_impl` file — the mock class needs the bare interface too.
- Fixed cross-feature dependency imports resolving to the consuming notifier's own feature instead of the dependency's actual feature (e.g. an `AuthNotifier` depending on a `UserRepository` that lives under `features/user/`).
- Fixed `.notifier`/`.future` provider overrides emitting invalid Riverpod syntax (`xProvider.future.overrideWith(...)`) — overrides now always target the base provider.
- Compile-time-constant inputs (`String`, `int`, `double`, `bool`, `List`/`Map`/`Set`, `Duration`, ...) now use `const` instead of `final`.
- Fixed private underscore-prefixed field/getter calls (the common `_fieldName` convention) never being detected as a dependency call.
- `build()`'s dependency calls are now stubbed once in `setUp()`, after the provider overrides, instead of being duplicated identically inside every method's test.
