// lib/src/generators/test_orchestrator.dart

import 'dart:io';

import 'package:path/path.dart' as p;

import '../analyzers/feature_scanner.dart';
import '../analyzers/notifier_parser.dart';
import '../analyzers/state_parser.dart';
import '../models/notifier_info.dart';
import 'test_generator.dart';

/// Runs the feature scan and writes generated tests into `test/features`.
class TestOrchestrator {
  /// Creates an orchestrator for the given project.
  TestOrchestrator({
    required this.projectRoot,
    required this.packageName,
    this.dryRun = false,
    this.verbose = false,
    this.feature,
  });

  /// Absolute path to the project root.
  final String projectRoot;

  /// Package name used to build import paths.
  final String packageName;

  /// When `true`, generated files are not written to disk.
  final bool dryRun;

  /// When `true`, progress messages are emitted during execution.
  final bool verbose;

  /// If non-null, only generate tests for this feature name.
  final String? feature;

  /// Scans the project, parses notifiers and state models, and writes tests.
  Future<OrchestratorResult> run() async {
    final featuresRoot = p.join(projectRoot, 'lib', 'features');
    final testRoot = p.join(projectRoot, 'test');

    final scanner = FeatureScanner(featuresRoot: featuresRoot);
    final notifierParser =
        NotifierParser(projectRoot: projectRoot, packageName: packageName);
    final stateParser =
        StateParser(projectRoot: projectRoot, packageName: packageName);

    var bundles = scanner.scan();
    if (feature != null && feature!.isNotEmpty) {
      bundles = bundles.where((b) => b.featureName == feature).toList();
    }
    _log('Found ${bundles.length} feature(s)\n');

    final errors = <String>[];

    // ── First pass: parse every notifier and state file up front so we can
    //    build a project-wide index of notifier class → import path. This
    //    lets the generator resolve accurate imports for cross-notifier
    //    dependencies (ref.read(otherNotifierProvider)) even when the other
    //    notifier lives in a different feature.
    final parsedByBundle = <FeatureBundle, List<NotifierInfo>>{};
    final statesByBundle = <FeatureBundle, List<StateInfo>>{};
    final notifierIndex = <String, String>{};

    for (final bundle in bundles) {
      final states = stateParser.parseAll(bundle.stateFiles);
      statesByBundle[bundle] = states;

      final notifiers = <NotifierInfo>[];
      for (final notifierFile in bundle.notifierFiles) {
        try {
          final parsed = notifierParser.parse(notifierFile);
          notifiers.addAll(parsed);
          for (final n in parsed) {
            notifierIndex[n.className] = n.importPath;
          }
        } catch (e, st) {
          final msg = 'Error in $notifierFile: $e\n$st';
          errors.add(msg);
          stderr.writeln('⚠️   $msg');
        }
      }
      parsedByBundle[bundle] = notifiers;
    }

    // Pass projectRoot so the generator can locate repository interface files
    // for return-type resolution, and notifierIndex for cross-notifier ones.
    final generator = TestGenerator(
      projectRoot: projectRoot,
      notifierIndex: notifierIndex,
    );

    int written = 0;
    int skipped = 0;

    // ── Second pass: match state models and generate test files.
    for (final bundle in bundles) {
      _log('📁  ${bundle.featureName}');

      final states = statesByBundle[bundle] ?? const [];
      _log('    states: ${states.length}');

      for (var notifier in parsedByBundle[bundle] ?? const <NotifierInfo>[]) {
        final matched = _matchState(notifier, states);
        if (matched != null) {
          notifier = NotifierInfo(
            className: notifier.className,
            sourceFilePath: notifier.sourceFilePath,
            importPath: notifier.importPath,
            packageName: packageName,
            stateType: notifier.stateType,
            isAsync: notifier.isAsync,
            repositories: notifier.repositories,
            buildMethod: notifier.buildMethod,
            methods: notifier.methods,
            stateInfo: matched,
            sourceImports: notifier.sourceImports,
          );
          _log('    ✅  ${notifier.className} → state: ${matched.className}');
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

    // Prefer the exact `${prefix}State` match before falling back to a
    // prefix search, whose result would otherwise depend on filesystem
    // enumeration order when multiple states share the same prefix
    // (e.g. `CartState` and `CartSummaryState` both matching `CartNotifier`).
    final exact = states.firstWhere((s) => s.className == '${prefix}State',
        orElse: () => _none);
    if (!identical(exact, _none)) return exact;

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
