import 'dart:io';

import 'package:path/path.dart' as p;

/// Scans `lib/features` and groups logic (notifier / bloc / cubit), state and
/// event files by feature.
class FeatureScanner {
  /// Creates a scanner rooted at [featuresRoot].
  FeatureScanner({required this.featuresRoot});

  /// Absolute path to the `lib/features` directory.
  final String featuresRoot;

  /// Folders (relative to a feature directory) that conventionally hold the
  /// state-management classes, covering both the Riverpod layout
  /// (`presentation/notifiers/`) and the common `flutter_bloc` ones
  /// (`presentation/bloc/`, `presentation/cubit/`, or a top-level `bloc/`
  /// folder). Each is scanned recursively, so a per-feature nesting like
  /// `presentation/bloc/login/login_bloc.dart` is picked up too.
  static const logicFolders = [
    'presentation/notifiers',
    'presentation/notifier',
    'presentation/bloc',
    'presentation/blocs',
    'presentation/cubit',
    'presentation/cubits',
    'presentation/logic',
    'bloc',
    'blocs',
    'cubit',
    'cubits',
  ];

  /// Folders (relative to a feature directory) that conventionally hold the
  /// state models. Bloc projects usually keep the state next to the bloc
  /// instead, which [scan] handles by also treating `*_state.dart` files
  /// inside [logicFolders] as state files.
  static const stateFolders = [
    'presentation/states',
    'presentation/state',
  ];

  /// Scans the configured features directory and returns discovered bundles.
  List<FeatureBundle> scan() {
    final dir = Directory(featuresRoot);
    if (!dir.existsSync()) {
      throw ArgumentError('Features directory not found: $featuresRoot');
    }

    final bundles = <FeatureBundle>[];

    for (final featureDir in dir.listSync().whereType<Directory>()) {
      final featureName = p.basename(featureDir.path);

      final logicFiles = <String>{};
      for (final folder in logicFolders) {
        logicFiles.addAll(_dartFiles(_subDir(featureDir.path, folder)));
      }
      if (logicFiles.isEmpty) continue;

      final stateFiles = <String>{};
      for (final folder in stateFolders) {
        stateFiles.addAll(_dartFiles(_subDir(featureDir.path, folder)));
      }
      // Bloc convention: `auth_state.dart` sits beside `auth_bloc.dart`,
      // usually as a `part` of it, rather than in a `states/` folder.
      stateFiles.addAll(
        logicFiles.where((f) => p.basename(f).endsWith('_state.dart')),
      );

      bundles.add(FeatureBundle(
        featureName: featureName,
        featurePath: featureDir.path,
        notifierFiles: logicFiles.toList(),
        stateFiles: stateFiles.toList(),
        // Event classes live either in a dedicated `*_event.dart` file or
        // inline in the bloc file itself, so every logic file is a candidate.
        eventFiles: logicFiles.toList(),
      ));
    }

    return bundles;
  }

  Directory _subDir(String featurePath, String relative) =>
      Directory(p.joinAll([featurePath, ...relative.split('/')]));

  List<String> _dartFiles(Directory dir) {
    if (!dir.existsSync()) return const [];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path)
        .toList();
  }
}

/// A discovered feature with its logic, state and event source files.
class FeatureBundle {
  /// Creates a bundle for one feature.
  const FeatureBundle({
    required this.featureName,
    required this.featurePath,
    required this.notifierFiles,
    required this.stateFiles,
    this.eventFiles = const [],
  });

  /// The feature directory name.
  final String featureName;

  /// The absolute path to the feature directory.
  final String featurePath;

  /// Source files that declare notifiers, blocs or cubits.
  final List<String> notifierFiles;

  /// Source files that declare state classes.
  final List<String> stateFiles;

  /// Source files that may declare bloc event classes.
  final List<String> eventFiles;
}
