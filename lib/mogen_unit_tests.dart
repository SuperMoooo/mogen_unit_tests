/// CLI tool that scans `lib/features/**/presentation/notifiers/`, parses
/// Riverpod `AsyncNotifier` classes, detects repository dependencies via
/// `ref.read()`, and generates Mocktail-based unit tests with success and
/// error cases for every method.
///
/// Run from your Flutter project root:
/// ```sh
/// dart run mogen_unit_tests
/// ```
library mogen_unit_tests;

export 'src/analyzers/feature_scanner.dart';
export 'src/analyzers/notifier_parser.dart';
export 'src/analyzers/state_parser.dart';
export 'src/generators/test_generator.dart';
export 'src/generators/test_orchestrator.dart';
export 'src/models/notifier_info.dart';
export 'src/utils/mock_value_generator.dart';
