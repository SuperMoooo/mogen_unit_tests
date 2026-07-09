# mogen_unit_tests

`mogen_unit_tests` scans your Flutter feature folders, parses Riverpod notifiers, and generates **Mocktail-based unit test scaffolding** for each discovered notifier.

It is designed for projects that keep their notifier and state files under `lib/features/**/presentation/` and want a fast starting point for repeatable unit tests.

---

## What it generates

For every notifier it finds, the package creates a ready-to-run test file with:

- `Mock<Type>` classes for every dependency reached via `ref.read(...)`/`ref.watch(...)` — repositories, services, clients, and other notifiers alike
- **notifier dependencies mocked safely**: another notifier is never mocked with a bare `extends Mock implements X` (Riverpod's internal wiring makes that crash with `MissingStubError` at first read) — instead the mock extends the real base class (`class MockX extends AsyncNotifier<S> with Mock implements X {}`) and its `build()` is stubbed in `setUp`, so code that does `await ref.read(otherNotifierProvider.future)` resolves
- a `ProviderContainer` with dependency overrides in `setUp`
- `registerFallbackValue(...)` calls in `setUpAll` for every non-nullable custom type used inside an `any()` matcher (resolved from the dependency's declared parameter types) — without them mocktail throws at stub time
- any dependency calls made from `build()` — plus any call shared by two or more methods — stubbed once at the bottom of `setUp` (after the overrides), so initializing the notifier never throws `MissingStubError` and identical stubs aren't repeated inside every method's test
- `container.dispose()` in `tearDown`
- two tests per public notifier method: one exercising the success path, one where the dependency throws `AppException.test()` to exercise the error path. The error test first initialises the notifier (while `setUp`'s success stubs are in effect, so `build()` still succeeds), then re-stubs **every** call the method makes — including ones `build()` shares — with `thenThrow`. Methods that make no dependency calls get no error test: there is nothing that can fail
- stubs that match the dependency's declared signature: `Future`-returning methods use `thenAnswer((_) async => ...)`, synchronous ones use `thenReturn(...)` (answering a `Future` from a sync method is a runtime `TypeError`)
- `ClassName.empty()` used for custom-type parameters and stub return values (no `Fake` classes)
- optional state field assertions when `stateInfo` is available — the `success` message is only asserted when the method body actually mentions the field
- **family support**: `FamilyAsyncNotifier`/`FamilyNotifier` (and their `AutoDispose` variants) are read as `provider(familyArg)` everywhere, with the argument declared once from the family's argument type; family *dependencies* have their captured call arguments stripped and are overridden on the base provider

### Conventions this generator assumes

The generated tests lean on a few conventions rather than guessing blindly. If your project doesn't follow them, the generated file will need manual edits to compile:

- **Errors**: `lib/core/errors/app_exception.dart` defines `AppException` with a `factory AppException.test()` constructor — this is what error-path stubs throw.
- **Repositories**: interfaces live at `lib/features/<feature>/domain/repositories/<name>.dart`, with an implementation at `lib/features/<feature>/data/repositories/<name>_impl.dart`. A dependency doesn't have to belong to the *consuming* notifier's own feature — the generator scans the whole project to find where it actually lives (both for imports and for resolving method signatures/return types).
- **Entities/models**: any custom type used as a parameter or stub return value exposes a `ClassName.empty()` factory constructor. Their files are located by searching every feature's `domain/entities`, `data/models`, `domain/models` and `presentation/states` folders on disk before falling back to a name-suffix guess.
- **Router**: a `routerProvider` dependency is assumed to expose `go_router`'s `GoRouter`, not Flutter's own `Router` class.

---

## Project layout

The CLI expects this layout inside your Flutter app:

```text
lib/
└── features/
    └── cart/
        └── presentation/
            ├── notifiers/
            │   └── cart_notifier.dart
            └── states/
                └── cart_state.dart
```

---

## Installation

Add the package to your Flutter app's `dev_dependencies`:

```yaml
dev_dependencies:
    mogen_unit_tests:
```

Install it:

```bash
dart pub get
```

---

## Usage

Run the generator from the root of your Flutter app:

```bash
dart run mogen_unit_tests
```

### CLI options

| Flag        | Short | Default | Description                                                                             |
| ----------- | ----- | ------- | --------------------------------------------------------------------------------------- |
| `--root`    | `-r`  | `.`     | Project root directory                                                                  |
| `--dry-run` | `-d`  | `false` | Preview generated files without writing them                                            |
| `--verbose` | `-v`  | `false` | Print progress details while scanning and generating                                    |
| `--feature` | `-f`  |         | Only generate tests for the given feature name                                          |
| `--force`   |       | `false` | Overwrite existing test files that look hand-maintained (missing the generated marker)  |
| `--version` |       |         | Print the package version and exit                                                      |
| `--help`    | `-h`  |         | Show the CLI help text                                                                  |

> **Overwrite protection:** a test file that exists but no longer starts with the
> `GENERATED BY mogen_unit_tests` marker is treated as hand-maintained and skipped
> (with a warning). Pass `--force` to overwrite it anyway.

### Examples

```bash
# Generate tests from the current directory
dart run mogen_unit_tests

# Preview the output without writing files
dart run mogen_unit_tests --dry-run --verbose

# Run against a different Flutter project
dart run mogen_unit_tests --root /path/to/my_flutter_app
```

---

## Example

### Input notifier

```dart
class CartNotifier extends AsyncNotifier<CartState> {
  @override
  Future<CartState> build() async {
    return ref.read(cartRepositoryProvider).fetchCart();
  }

  Future<void> addItem(CartItem item) async {
    await ref.read(cartRepositoryProvider).addItem(item);
    state = AsyncData(state.requireValue.copyWith(success: 'added'));
  }

  Future<void> removeItem(String itemId) async {
    await ref.read(cartRepositoryProvider).removeItem(itemId);
    state = AsyncData(state.requireValue.copyWith(success: 'removed'));
  }
}
```

### Input repository interface

```dart
abstract class CartRepository {
  Future<CartEntity> fetchCart();
  Future<void> addItem(CartItem item);
  Future<void> removeItem(String itemId);
}
```

### Input state

```dart
class CartState {
  final bool isLoadingAction;
  final String? error;
  final String? success;

  const CartState({this.isLoadingAction = false, this.error, this.success});
}
```

### Generated output

**Note: the generator creates test groups for public notifier methods only — `build()` is not scaffolded as its own test group, but any dependency call it makes is stubbed once in `setUp` so initialization doesn't throw.**

```dart
// GENERATED BY mogen_unit_tests — YOU CAN REMOVE THIS COMMENT

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:my_app/core/errors/app_exception.dart';

import 'package:my_app/features/cart/presentation/notifiers/cart_notifier.dart';
import 'package:my_app/features/cart/presentation/states/cart_state.dart';
import 'package:my_app/features/cart/domain/repositories/cart_repository.dart';
import 'package:my_app/features/cart/data/repositories/cart_repository_impl.dart';
import 'package:my_app/features/cart/domain/entities/cart_entity.dart';
import 'package:my_app/features/cart/domain/entities/cart_item.dart';

// ── Mocks ────────────────────────────────────────────────────
class MockCartRepository extends Mock implements CartRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CartNotifier', () {
    late MockCartRepository mockCartRepository;
    late ProviderContainer container;

    setUpAll(() {
      // Mocktail needs a fallback instance registered for every
      // non-nullable custom type used with an any()/captureAny() matcher.
      registerFallbackValue(CartItem.empty());
    });

    setUp(() {
      mockCartRepository = MockCartRepository();

      container = ProviderContainer(
        overrides: [
          // Override the provider so the notifier gets mockCartRepository
          cartRepositoryProvider.overrideWithValue(mockCartRepository),
        ],
      );

      // Arrange: stub dependencies used by build() and calls shared
      // by multiple methods — once here instead of in every test.
      when(
        () => mockCartRepository.fetchCart(),
      ).thenAnswer((_) async => CartEntity.empty());
    });

    tearDown(() {
      container.dispose();
    });

    // ── addItem() ──────────────────────────────────────
    group('addItem', () {
      test('addItem completes successfully', () async {
        // Arrange: stub repositories
        when(
          () => mockCartRepository.addItem(any()),
        ).thenAnswer((_) async => null);

        // Arrange: inputs
        final item = CartItem.empty();

        // Ensure notifier is initialised
        await container.read(cartNotifierProvider.future);

        // Act
        await container.read(cartNotifierProvider.notifier).addItem(item);

        // Assert
        final finalState = container.read(cartNotifierProvider);
        expect(finalState.requireValue.isLoadingAction, isFalse);
        expect(finalState.requireValue.error, isNull);
        expect(finalState.requireValue.success, isNotNull);
      });

      test('addItem shows an error when the repository fails', () async {
        // Arrange: inputs
        final item = CartItem.empty();

        // Ensure notifier is initialised
        await container.read(cartNotifierProvider.future);

        // Arrange: make every dependency call this method performs fail.
        // Re-stubbing overrides the success stubs from setUp().
        when(
          () => mockCartRepository.addItem(any()),
        ).thenThrow(AppException.test());

        // Act
        await container.read(cartNotifierProvider.notifier).addItem(item);

        // Assert
        final finalState = container.read(cartNotifierProvider);
        expect(finalState.requireValue.isLoadingAction, isFalse);
        expect(finalState.requireValue.error, isNotNull);
        expect(finalState.requireValue.success, isNull);
      });
    });

    // ── removeItem() ──────────────────────────────────────
    group('removeItem', () {
      test('removeItem completes successfully', () async {
        // Arrange: stub repositories
        when(
          () => mockCartRepository.removeItem(any()),
        ).thenAnswer((_) async => null);

        // Arrange: inputs
        const itemId = '';

        // Ensure notifier is initialised
        await container.read(cartNotifierProvider.future);

        // Act
        await container.read(cartNotifierProvider.notifier).removeItem(itemId);

        // Assert
        final finalState = container.read(cartNotifierProvider);
        expect(finalState.requireValue.isLoadingAction, isFalse);
        expect(finalState.requireValue.error, isNull);
        expect(finalState.requireValue.success, isNotNull);
      });

      test('removeItem shows an error when the repository fails', () async {
        // Arrange: inputs
        const itemId = '';

        // Ensure notifier is initialised
        await container.read(cartNotifierProvider.future);

        // Arrange: make every dependency call this method performs fail.
        // Re-stubbing overrides the success stubs from setUp().
        when(
          () => mockCartRepository.removeItem(any()),
        ).thenThrow(AppException.test());

        // Act
        await container.read(cartNotifierProvider.notifier).removeItem(itemId);

        // Assert
        final finalState = container.read(cartNotifierProvider);
        expect(finalState.requireValue.isLoadingAction, isFalse);
        expect(finalState.requireValue.error, isNotNull);
        expect(finalState.requireValue.success, isNull);
      });
    });
  });
}
```

---

## What you still need to fill in

The generator creates dependency method stubs automatically. If a method returns a non-null value, update the generated `thenAnswer(...)` call to return a realistic object instead of the auto-generated `ClassName.empty()`/literal placeholder.

Everything else is generated for you.

---

## Supported notifier types

| Class                                     | Supported |
| ----------------------------------------- | --------- |
| `AsyncNotifier<T>`                        | ✅        |
| `AutoDisposeAsyncNotifier<T>`             | ✅        |
| `Notifier<T>`                             | ✅        |
| `AutoDisposeNotifier<T>`                  | ✅        |
| `FamilyAsyncNotifier<T, Arg>`             | ✅        |
| `AutoDisposeFamilyAsyncNotifier<T, Arg>`  | ✅        |
| `FamilyNotifier<T, Arg>`                  | ✅        |
| `AutoDisposeFamilyNotifier<T, Arg>`       | ✅        |

Family notifiers are read with a generated `familyArg` (built from the family's argument type) at every `provider(familyArg)` read.

Classes extending `ChangeNotifier`/`ValueNotifier` are deliberately skipped even when they live under `presentation/notifiers/` — they aren't Riverpod notifiers.

Dependencies of any kind — repositories, services, clients, other notifiers — are detected from `ref.read(...)` and `ref.watch(...)` calls inside the notifier implementation.

---

## Limitations

- Generates **unit tests only** — no widget or integration tests
- Dependency stubs are autogenerated and may require manual return-value adjustments
- Only notifiers under `presentation/notifiers/` are scanned
- Assumes `AppException.test()` exists (see [Conventions this generator assumes](#conventions-this-generator-assumes)) — projects without it will need to adjust the error-path stubs manually
- Notifier dependencies get a runtime-safe mock only when their source was found by the project scan; a notifier dependency the scan never saw falls back to a plain `Mock`, which Riverpod cannot wire — replace it with a hand-written stub subclass in that case
- The success-path state assertion for the `success` field relies on a textual check of the method body — a method that sets it through a helper the generator can't see loses that one assertion

---

## Dependencies

| Package      | Purpose                                  |
| ------------ | ---------------------------------------- |
| `analyzer`   | AST parsing of notifier source files     |
| `dart_style` | Formatting generated Dart output         |
| `args`       | CLI flag parsing                         |
| `glob`       | Discovering feature folders              |
| `path`       | Cross-platform path handling             |
| `yaml`       | Reading package name from `pubspec.yaml` |

---

## Project health notes

- This package is a CLI tool, not a Flutter app. Running `dart run mogen_unit_tests` from this repository itself will not produce output unless you point it at a consuming Flutter app with `lib/features/...`.
- The current output destination is `test/unit/features/...`, which is now reflected in the examples above.
