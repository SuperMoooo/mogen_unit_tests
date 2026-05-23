## [1.0.0]

### Added

- Initial release
- Basic Mocktail mock and test generation
- CLI entry point with `--help` and `--version` flags
- Riverpod `AsyncNotifier` and `AutoDisposeAsyncNotifier` support
- `ProviderContainer` with repository provider overrides in generated `setUp`
- Detects repository dependencies via `ref.read()` and `ref.watch()` calls
- Generates `Fake<Type>` classes and `registerFallbackValue` for complex parameter types
- Matches state classes from `presentation/states/` to enrich generated tests
- `--dry-run` flag to preview output without writing files
- `--verbose` flag for detailed progress logging
- `--root` flag to run from outside the project directory
- Validates project structure before running and exits with clear error messages

### Changed

- Rewrote scanner to target `lib/features/**/presentation/notifiers/` specifically
- Output now mirrors source structure under `test/features/`
- Repository stubs scaffolded as comments to avoid broken code on first run
