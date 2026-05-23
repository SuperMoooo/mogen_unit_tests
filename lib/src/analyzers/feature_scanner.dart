// lib/src/analyzers/feature_scanner.dart

import 'dart:io';

import 'package:path/path.dart' as p;

/// Walks  lib/features/<featureName>/presentation/notifiers/
/// and    lib/features/<featureName>/presentation/states/   (optional)
/// returning grouped paths per feature.
class FeatureScanner {
  final String featuresRoot; // absolute path to lib/features

  FeatureScanner({required this.featuresRoot});

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

      if (!notifiersDir.existsSync()) continue; // not a presentation feature

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

class FeatureBundle {
  final String featureName;
  final String featurePath;
  final List<String> notifierFiles;
  final List<String> stateFiles;

  const FeatureBundle({
    required this.featureName,
    required this.featurePath,
    required this.notifierFiles,
    required this.stateFiles,
  });
}
