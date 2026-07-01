// bin/main.dart
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:args/args.dart';
import 'package:mogen_unit_tests/mogen_unit_tests.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _version = '1.1.0';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'root',
      abbr: 'r',
      help: 'Project root directory (defaults to current directory).',
      defaultsTo: '.',
    )
    ..addFlag(
      'dry-run',
      abbr: 'd',
      negatable: false,
      help: 'Preview what would be generated without writing any files.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Print detailed progress while running.',
    )
    ..addFlag(
      'version',
      negatable: false,
      help: 'Print version and exit.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show this help message.',
    )
    ..addOption(
      'feature',
      abbr: 'f',
      help: 'Only generate tests for the given feature name.',
    );

  late final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr
      ..writeln('Error: ${e.message}')
      ..writeln();
    _printUsage(parser);
    exit(64);
  }

  if (args['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  if (args['version'] as bool) {
    print('mogen_unit_tests v$_version');
    exit(0);
  }

  // ── Resolve project root ─────────────────────────────────────────────────

  final root = p.absolute(args['root'] as String);

  if (!Directory(root).existsSync()) {
    stderr.writeln('Error: project root not found: $root');
    exit(1);
  }

  final packageName = _readPackageName(root);
  if (packageName == null) {
    stderr.writeln(
      'Error: could not read package name from $root/pubspec.yaml.\n'
      'Make sure you are running this from your Flutter project root, or '
      'pass --root <path>.',
    );
    exit(1);
  }

  final featuresDir = Directory(p.join(root, 'lib', 'features'));
  if (!featuresDir.existsSync()) {
    stderr.writeln(
      'Error: lib/features/ not found inside $root.\n'
      'Expected structure: lib/features/<featureName>/presentation/notifiers/',
    );
    exit(1);
  }

  // ── Run ──────────────────────────────────────────────────────────────────

  final dryRun = args['dry-run'] as bool;
  final verbose = args['verbose'] as bool;
  final feature = args['feature'] as String?;

  _printBanner();
  print('Package  : $packageName');
  print('Root     : $root');
  print('Features : ${featuresDir.path}');
  if (feature != null && feature.isNotEmpty) print('Feature  : $feature');
  print('Output   : ${p.join(root, 'test', 'features')}');
  if (dryRun) print('Mode     : dry-run (no files will be written)');
  print('');

  final orchestrator = TestOrchestrator(
    projectRoot: root,
    packageName: packageName,
    dryRun: dryRun,
    verbose: verbose,
    feature: feature,
  );

  final result = await orchestrator.run();

  // ── Summary ───────────────────────────────────────────────────────────────

  print('─' * 48);
  print('Features scanned : ${result.featuresScanned}');
  print('Tests written    : ${result.filesWritten}');
  if (result.filesSkipped > 0) {
    print('Files skipped    : ${result.filesSkipped}');
  }

  if (result.hasErrors) {
    print('');
    stderr.writeln('Completed with ${result.errors.length} error(s):');
    for (final e in result.errors) {
      stderr.writeln('  • $e');
    }
    exit(1);
  }

  print('');
  print('Done! Run `flutter test` to execute the generated tests.');
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Reads the `name:` field from pubspec.yaml at [projectRoot].
String? _readPackageName(String projectRoot) {
  final file = File(p.join(projectRoot, 'pubspec.yaml'));
  if (!file.existsSync()) return null;
  try {
    final doc = loadYaml(file.readAsStringSync());
    return (doc as YamlMap)['name'] as String?;
  } catch (_) {
    return null;
  }
}

void _printBanner() {
  print('''
╔══════════════════════════════════════════════╗
║         mogen_unit_tests  v$_version          ║
║   Auto-generate Mocktail unit tests for      ║
║   Riverpod AsyncNotifier classes             ║
╚══════════════════════════════════════════════╝
''');
}

void _printUsage(ArgParser parser) {
  print(
      'mogen_unit_tests — generate Mocktail unit tests for Riverpod notifiers');
  print('');
  print('Usage: dart run mogen_unit_tests [options]');
  print('');
  print(parser.usage);
  print('');
  print('Examples:');
  print('  dart run mogen_unit_tests');
  print('  dart run mogen_unit_tests --dry-run --verbose');
  print('  dart run mogen_unit_tests --root /path/to/my_app');
}
