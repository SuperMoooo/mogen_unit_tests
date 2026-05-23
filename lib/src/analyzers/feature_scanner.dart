import 'dart:io';

import 'package:path/path.dart' as p;

/// Scans `lib/features` and groups notifier and state files by feature.
class FeatureScanner {
  /// Creates a scanner rooted at [featuresRoot].
  FeatureScanner({required this.featuresRoot});

  /// Absolute path to the `lib/features` directory.
  final String featuresRoot;

  /// Scans the configured features directory and returns discovered bundles.
  List<FeatureBundle> scan() {
    final dir = Directory(featuresRoot);
    if (!dir.existsSync()) {
      throw ArgumentError('Features directory not found: $featuresRoot');
    }

    final bundles = <FeatureBundle>[];

    for (final featureDir in dir.listSync().whereType<Directory>()) {
      final featureName = p.basename(featureDir.path);

      final notifiersDir =
          Directory(p.join(featureDir.path, 'presentation', 'notifiers'));
      final statesDir =
          Directory(p.join(featureDir.path, 'presentation', 'states'));

      if (!notifiersDir.existsSync()) continue;

      final notifierFiles = _dartFiles(notifiersDir);
      if (notifierFiles.isEmpty) continue;

      final stateFiles =
          statesDir.existsSync() ? _dartFiles(statesDir) : <String>[];

      bundles.add(FeatureBundle(
        featureName: featureName,
        featurePath: featureDir.path,
        notifierFiles: notifierFiles,
        stateFiles: stateFiles,
      ));
    }

    return bundles;
  }

  List<String> _dartFiles(Directory dir) => dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.path)
      .toList();
}

/// A discovered feature with its notifier and state source files.
class FeatureBundle {
  /// Creates a bundle for one feature.
  const FeatureBundle({
    required this.featureName,
    required this.featurePath,
    required this.notifierFiles,
    required this.stateFiles,
  });

  /// The feature directory name.
  final String featureName;

  /// The absolute path to the feature directory.
  final String featurePath;

  /// Source files that declare notifiers.
  final List<String> notifierFiles;

  /// Source files that declare state classes.
  final List<String> stateFiles;
}
