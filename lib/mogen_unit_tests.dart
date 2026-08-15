/// CLI tool that scans a Flutter project's feature folders, parses its
/// state-management classes — Riverpod `Notifier`/`AsyncNotifier` as well as
/// `flutter_bloc` `Bloc`/`Cubit` — detects their dependencies, and generates
/// Mocktail-based unit tests with success and error cases for every action.
///
/// Riverpod notifiers get `ProviderContainer` tests; blocs and cubits get
/// `bloc_test` (`blocTest<B, S>(...)`) tests.
///
/// Run from your Flutter project root:
/// ```sh
/// dart run mogen_unit_tests
/// ```
library mogen_unit_tests;

export 'src/analyzers/event_parser.dart';
export 'src/analyzers/feature_scanner.dart';
export 'src/analyzers/notifier_parser.dart';
export 'src/analyzers/state_parser.dart';
export 'src/generators/bloc_test_generator.dart';
export 'src/generators/generator_support.dart';
export 'src/generators/test_generator.dart';
export 'src/generators/test_orchestrator.dart';
export 'src/models/notifier_info.dart';
export 'src/utils/mock_value_generator.dart';
