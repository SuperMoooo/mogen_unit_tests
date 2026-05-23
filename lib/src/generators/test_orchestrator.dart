import 'dart:io';

import 'package:path/path.dart' as p;

import '../analyzers/feature_scanner.dart';
import '../analyzers/notifier_parser.dart';
import '../analyzers/state_parser.dart';
import '../models/notifier_info.dart';
import 'test_generator.dart';

/// Runs the feature scan and writes generated tests into `test/unit/features`.
class TestOrchestrator {
  /// Creates an orchestrator for the given project.
  TestOrchestrator({
    required this.projectRoot,
    required this.packageName,
    this.dryRun = false,
    this.verbose = false,
  });

  /// Absolute path to the project root.
  final String projectRoot;

  /// Package name used to build import paths.
  final String packageName;

  /// When `true`, generated files are not written to disk.
  final bool dryRun;

  /// When `true`, progress messages are emitted during execution.
  final bool verbose;

  /// Scans the project, parses notifiers and state models, and writes tests.
  Future<OrchestratorResult> run() async {
    final featuresRoot = p.join(projectRoot, 'lib', 'features');
    final testRoot = p.join(projectRoot, 'test', 'features');

    final scanner = FeatureScanner(featuresRoot: featuresRoot);
    final notifierParser =
        NotifierParser(projectRoot: projectRoot, packageName: packageName);
    final stateParser =
        StateParser(projectRoot: projectRoot, packageName: packageName);
    final generator = TestGenerator();

    final bundles = scanner.scan();
    _log('Found ${bundles.length} feature(s)\n');

    int written = 0;
    int skipped = 0;
    final errors = <String>[];

    for (final bundle in bundles) {
      _log('📁  ${bundle.featureName}');

      final states = stateParser.parseAll(bundle.stateFiles);
      _log('    states: ${states.length}');

      for (final notifierFile in bundle.notifierFiles) {
        try {
          final notifiers = notifierParser.parse(notifierFile);

          for (var notifier in notifiers) {
            final matched = _matchState(notifier, states);
            if (matched != null) {
              notifier = NotifierInfo(
                className: notifier.className,
                sourceFilePath: notifier.sourceFilePath,
                importPath: notifier.importPath,
                stateType: notifier.stateType,
                isAsync: notifier.isAsync,
                repositories: notifier.repositories,
                buildMethod: notifier.buildMethod,
                methods: notifier.methods,
                stateInfo: matched,
              );
              _log(
                  '    ✅  ${notifier.className} → state: ${matched.className}');
            } else {
              _log('    ✅  ${notifier.className} (no state matched)');
            }

            final content = generator.generate(notifier);
            final outPath = p.join(
              testRoot,
              'unit',
              'features',
              bundle.featureName,
              '${_snake(notifier.className)}_test.dart',
            );

            if (dryRun) {
              _log('    [dry-run] → $outPath');
              skipped++;
            } else {
              _write(outPath, content);
              _log('    📝  → $outPath');
              written++;
            }
          }
        } catch (e, st) {
          final msg = 'Error in $notifierFile: $e\n$st';
          errors.add(msg);
          stderr.writeln('⚠️   $msg');
        }
      }
      _log('');
    }

    return OrchestratorResult(
      featuresScanned: bundles.length,
      filesWritten: written,
      filesSkipped: skipped,
      errors: errors,
    );
  }

  StateInfo? _matchState(NotifierInfo n, List<StateInfo> states) {
    if (states.isEmpty) return null;

    if (n.stateType != null) {
      final match = states.firstWhere((s) => s.className == n.stateType,
          orElse: () => _none);
      if (!identical(match, _none)) return match;
    }

    final prefix =
        n.className.replaceAll(RegExp(r'(Notifier|Cubit|Bloc|ViewModel)$'), '');
    for (final s in states) {
      if (s.className.startsWith(prefix)) return s;
    }

    return null;
  }

  static const _none =
      StateInfo(className: '__none__', importPath: '', fields: []);

  void _write(String path, String content) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void _log(String msg) {
    if (verbose) stdout.writeln(msg);
  }

  String _snake(String name) => name
      .replaceAllMapped(
          RegExp(r'([A-Z])'), (m) => '_${m.group(0)!.toLowerCase()}')
      .replaceFirst(RegExp(r'^_'), '');
}

/// Summary of the results produced by a test generation run.
class OrchestratorResult {
  /// Number of features scanned.
  final int featuresScanned;

  /// Number of files successfully written.
  final int filesWritten;

  /// Number of files skipped because dry-run mode was active.
  final int filesSkipped;

  /// Errors encountered during generation.
  final List<String> errors;

  /// Creates a result summary.
  const OrchestratorResult({
    required this.featuresScanned,
    required this.filesWritten,
    required this.filesSkipped,
    required this.errors,
  });

  /// Returns `true` when the run produced one or more errors.
  bool get hasErrors => errors.isNotEmpty;
}
