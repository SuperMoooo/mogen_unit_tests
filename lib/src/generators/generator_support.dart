// lib/src/generators/generator_support.dart

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/notifier_info.dart';
import '../utils/method_call_detector.dart';
import '../utils/mock_value_generator.dart';

/// Resolves the `import` lines a generated test needs for the types it
/// mentions: dependencies, entities, models and states.
///
/// Shared by the Riverpod and `bloc_test` generators so both resolve the same
/// path for the same type — the rules are about the project's folder layout,
/// not about which state-management framework produced the test.
class ImportResolver {
  /// Creates a resolver for the project at [projectRoot]. [notifierIndex]
  /// maps every notifier/bloc/cubit class name discovered in the project to
  /// its `package:` import path.
  const ImportResolver({
    required this.projectRoot,
    this.notifierIndex = const {},
  });

  /// Absolute path to the Flutter project root.
  final String projectRoot;

  /// Logic class name → `package:` import path, for every notifier, bloc and
  /// cubit found in the project.
  final Map<String, String> notifierIndex;

  /// Types whose mock class needs an import from a well-known pub package
  /// rather than anything discoverable inside the project itself.
  static const wellKnownPackageImports = {
    'GoRouter': 'package:go_router/go_router.dart',
  };

  /// Conventional folders a custom type's defining file can live in, in
  /// search-priority order.
  static const typeFolders = [
    'domain/entities',
    'data/models',
    'domain/models',
    'presentation/states',
  ];

  /// Resolves the import(s) needed for [repo]'s mock class to compile, trying
  /// (in order) well-known SDK packages, the project-wide notifier index,
  /// the source file's own imports, and the Clean-Architecture repository
  /// convention. Emits a `// TODO` comment instead of a guess when nothing
  /// resolves.
  List<String> dependencyImports(RepositoryDep repo, NotifierInfo n) {
    final wellKnown = wellKnownPackageImports[repo.type];
    if (wellKnown != null) return ["import '$wellKnown';"];

    final indexed = notifierIndex[repo.type];
    if (indexed != null) return ["import '$indexed';"];

    final fromSource = _findSourceImport(repo.type, n);
    if (fromSource != null) {
      if (fromSource.isImplOnly && isRepositorySuffix(repo.type)) {
        // The source only imports the `_impl` file (likely where the provider
        // itself is declared) — the mock class still needs the bare interface
        // type for `implements $Type` to compile, and the impl file isn't
        // guaranteed to re-export it. The feature name is taken from the
        // *resolved impl import* rather than the consuming class's own
        // feature, since the dependency may well live elsewhere (e.g. an
        // `AuthNotifier` depending on a `UserRepository` under
        // `features/user/`).
        final featureName = extractFeatureName(fromSource.uri);
        final snakeCase = toSnakeCase(repo.type);
        return [
          "import 'package:${n.packageName}/features/$featureName/domain/repositories/$snakeCase.dart';",
          "import '${fromSource.uri}';",
        ];
      }
      return ["import '${fromSource.uri}';"];
    }

    if (isRepositorySuffix(repo.type)) {
      final snakeCase = toSnakeCase(repo.type);
      // Prefer the feature folder the repository interface actually lives in
      // on disk — a dependency doesn't necessarily belong to the consuming
      // class's own feature. Only fall back to assuming it when nothing is
      // found (e.g. in unit tests against a fabricated project root).
      final featureName = findActualFeatureFolder(snakeCase) ??
          extractFeatureName(n.importPath);
      return [
        "import 'package:${n.packageName}/features/$featureName/domain/repositories/$snakeCase.dart';",
        "import 'package:${n.packageName}/features/$featureName/data/repositories/${snakeCase}_impl.dart';",
      ];
    }

    return [
      '// TODO(mogen_unit_tests): could not resolve an import for '
          "'${repo.type}' — add the correct import manually so "
          'Mock${repo.type} compiles.',
    ];
  }

  /// Builds the import line for a custom [typeName]: first searches every
  /// feature's entity/model/state folders on disk (a type doesn't have to
  /// live in the consuming class's own feature), then falls back to a
  /// name-suffix guess inside that feature.
  String typeImport(String typeName, NotifierInfo n) {
    final snakeFile = toSnakeCase(typeName);

    final featuresDir = Directory(p.join(projectRoot, 'lib', 'features'));
    if (featuresDir.existsSync()) {
      for (final entry in featuresDir.listSync()) {
        if (entry is! Directory) continue;
        for (final sub in typeFolders) {
          final candidate = File(
              p.joinAll([entry.path, ...sub.split('/'), '$snakeFile.dart']));
          if (candidate.existsSync()) {
            final featureName = p.basename(entry.path);
            return "import 'package:${n.packageName}/features/$featureName/$sub/$snakeFile.dart';";
          }
        }
      }
    }

    final featureName = extractFeatureName(n.importPath);
    final subFolder = _entitySubfolder(typeName);
    return "import 'package:${n.packageName}/features/$featureName/$subFolder/$snakeFile.dart';";
  }

  /// Derives the absolute path to the domain repository interface file,
  /// searching every feature folder on disk first — the dependency doesn't
  /// have to live in the consuming class's own feature.
  String repositoryInterfacePath(RepositoryDep repo, NotifierInfo n) {
    final snakeCase = toSnakeCase(repo.type);
    final featureName =
        findActualFeatureFolder(snakeCase) ?? extractFeatureName(n.importPath);
    return p.join(
      projectRoot,
      'lib',
      'features',
      featureName,
      'domain',
      'repositories',
      '$snakeCase.dart',
    );
  }

  /// Scans `lib/features/*/domain/repositories/` on disk for a file named
  /// `$repositoryFileName.dart` and returns the feature folder it was found
  /// in, or `null` if no such file exists anywhere in the project.
  String? findActualFeatureFolder(String repositoryFileName) {
    final featuresDir = Directory(p.join(projectRoot, 'lib', 'features'));
    if (!featuresDir.existsSync()) return null;

    for (final entry in featuresDir.listSync()) {
      if (entry is! Directory) continue;
      final candidate = File(p.join(
          entry.path, 'domain', 'repositories', '$repositoryFileName.dart'));
      if (candidate.existsSync()) {
        return p.basename(entry.path);
      }
    }
    return null;
  }

  /// Returns the `lib/features/<feature>/` sub-path where a custom type
  /// class file is likely to live based on its name suffix.
  String _entitySubfolder(String typeName) {
    final lower = typeName.toLowerCase();
    if (lower.endsWith('entity')) return 'domain/entities';
    if (lower.endsWith('model')) return 'data/models';
    if (lower.endsWith('data')) return 'data/models';
    if (lower.endsWith('state')) return 'presentation/states';
    // Default — most custom return types in Clean Architecture are entities.
    return 'domain/entities';
  }

  /// Looks for an import already declared in the source file whose target
  /// plausibly defines [type]. Reports whether the match was the `_impl` file
  /// specifically (as opposed to the bare interface), since that changes what
  /// else the caller needs to import.
  ({String uri, bool isImplOnly})? _findSourceImport(
      String type, NotifierInfo n) {
    final snake = toSnakeCase(type);
    for (final uri in n.sourceImports) {
      final base = p.basenameWithoutExtension(uri);
      if (base == snake) {
        return (uri: toPortableImport(uri, n), isImplOnly: false);
      }
      if (base == '${snake}_impl') {
        return (uri: toPortableImport(uri, n), isImplOnly: true);
      }
    }
    return null;
  }

  /// Converts a possibly-relative import URI (valid from the scanned source
  /// file) into a `package:` import valid from anywhere, since the generated
  /// test lives in a different directory than the class under test.
  String toPortableImport(String uri, NotifierInfo n) {
    if (uri.startsWith('package:') || uri.startsWith('dart:')) return uri;

    final sourceDir = p.dirname(n.sourceFilePath);
    final absoluteTarget = p.normalize(p.join(sourceDir, uri));
    final libPath = p.join(projectRoot, 'lib');

    if (p.isWithin(libPath, absoluteTarget)) {
      final rel =
          p.relative(absoluteTarget, from: libPath).replaceAll(r'\', '/');
      return 'package:${n.packageName}/$rel';
    }

    return absoluteTarget.replaceAll(r'\', '/');
  }

  /// Whether [type] follows the repository naming convention, which is what
  /// unlocks the `domain/repositories` + `data/repositories` layout guesses.
  static bool isRepositorySuffix(String type) =>
      type.toLowerCase().endsWith('repository');

  /// Extracts the feature folder name out of a `package:` import path.
  static String extractFeatureName(String importPath) {
    final parts = importPath.split('/');
    final featuresIdx = parts.indexOf('features');
    if (featuresIdx >= 0 && featuresIdx + 1 < parts.length) {
      return parts[featuresIdx + 1];
    }
    return '';
  }

  /// Converts a class name to its conventional snake_case file name,
  /// handling acronym runs correctly (`APIClient` → `api_client`,
  /// `UserAPI` → `user_api`), which a per-capital split would mangle into
  /// `a_p_i_client`.
  static String toSnakeCase(String name) => name
      .replaceAllMapped(
        RegExp(r'([A-Z]+)([A-Z][a-z])'),
        (m) => '${m.group(1)}_${m.group(2)}',
      )
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (m) => '${m.group(1)}_${m.group(2)}',
      )
      .toLowerCase();
}

/// Writes the `when(...)` stubs, fallback registrations and input
/// declarations that both generators emit identically.
class StubWriter {
  StubWriter._();

  /// Writes one success `when(...)` stub, choosing `thenAnswer`/`thenReturn`
  /// from the resolved [returnType]: answering a `Future` from a synchronous
  /// method is a runtime `TypeError`, and vice versa a sync value can't
  /// satisfy an awaited `Future`.
  static void writeSuccessStub(
    StringBuffer b,
    String indent,
    String mockName,
    RepositoryMethodCall call,
    String? returnType,
  ) {
    b.writeln('${indent}when(() => $mockName.${call.invocationSource})');

    final type = returnType?.trim();
    if (type == null) {
      // Unresolvable — assume the overwhelmingly common async case.
      b.writeln('$indent    .thenAnswer((_) async => null);');
    } else if (type.startsWith('Future<') ||
        type.startsWith('FutureOr<') ||
        type == 'Future' ||
        type == 'FutureOr') {
      b.writeln(
          '$indent    .thenAnswer((_) async => ${MockValueGenerator.forReturnType(type)});');
    } else if (type == 'void') {
      b.writeln('$indent    .thenAnswer((_) {});');
    } else if (type.startsWith('Stream<') || type == 'Stream') {
      b.writeln('$indent    .thenAnswer((_) => const Stream.empty());');
    } else {
      b.writeln(
          '$indent    .thenReturn(${MockValueGenerator.forReturnType(type)});');
    }
  }

  /// Whether mocktail's `any()` matcher needs `registerFallbackValue` for a
  /// parameter of this type. Mocktail ships fallbacks for primitives and
  /// core collections; nullable types fall back to `null` on their own.
  static bool needsFallbackRegistration(String rawType) {
    final type = rawType.trim();
    if (type.isEmpty || type.endsWith('?')) return false;
    const builtIn = {
      'String',
      'int',
      'double',
      'num',
      'bool',
      'dynamic',
      'Object',
      'void',
    };
    if (builtIn.contains(type)) return false;
    final base = type.split('<').first.trim();
    if (const {'List', 'Map', 'Set', 'Iterable'}.contains(base)) return false;
    if (type.contains('Function') || type.contains('(')) return false;
    return true;
  }

  /// Builds the `Arrange: inputs` declaration for one parameter, using
  /// `const` instead of `final` whenever the generated literal is guaranteed
  /// to be a compile-time constant (satisfies `prefer_const_declarations`).
  /// Types like `DateTime`, `Uri`, `Future`, and custom `.empty()` factories
  /// aren't guaranteed const-constructible, so those stay `final`.
  static String inputDeclarationLine(ParamInfo param) {
    final val = MockValueGenerator.forType(param.type);
    if (!isConstCompatible(param.type)) {
      return 'final ${param.name} = $val;';
    }
    // Avoid a redundant nested `const` (e.g. `const foo = const [];`).
    final cleanedVal =
        val.startsWith('const ') ? val.substring('const '.length) : val;
    return 'const ${param.name} = $cleanedVal;';
  }

  /// Whether a value generated for [rawType] is a compile-time constant.
  static bool isConstCompatible(String rawType) {
    final type = rawType.replaceAll('?', '').trim();
    if (type.startsWith('List<') || type == 'List') return true;
    if (type.startsWith('Map<') || type == 'Map') return true;
    if (type.startsWith('Set<') || type == 'Set') return true;
    switch (type) {
      case 'String':
      case 'int':
      case 'double':
      case 'num':
      case 'bool':
      case 'Duration':
      case 'dynamic':
      case 'Object':
        return true;
      default:
        return false;
    }
  }
}

/// Decides which of a class's discovered dependencies are worth mocking.
class DependencySelector {
  DependencySelector._();

  /// Every dependency worth mocking for [n].
  ///
  /// For a Riverpod notifier, a dependency reached via `ref.read()`/
  /// `ref.watch()` is always mocked, since that call is itself the DI seam
  /// the app relies on to substitute a fake in tests — this covers raw SDK
  /// types (`FlutterSecureStorage`, `FirebaseAuth`, a `Dio` client, ...) and
  /// other notifiers alike, regardless of their type name. Dependencies found
  /// only as a plain class field (no provider expression) fall back to a
  /// name-suffix heuristic.
  ///
  /// For a bloc or cubit the constructor *is* the seam: every collaborator
  /// the parser kept made it through the constructor already, so all of them
  /// are mocked.
  static List<RepositoryDep> mockable(NotifierInfo n) {
    if (!n.isRiverpod) return n.repositories;
    return n.repositories
        .where((r) =>
            r.providerExpression != null || looksLikeMockableName(r.type))
        .toList();
  }

  /// Whether a bare type name (no provider expression to vouch for it) reads
  /// as an injectable collaborator.
  static bool looksLikeMockableName(String type) {
    final lower = type.toLowerCase();
    return lower.endsWith('repository') ||
        lower.endsWith('service') ||
        lower.endsWith('datasource') ||
        lower.endsWith('client') ||
        lower.endsWith('api') ||
        lower.endsWith('notifier') ||
        lower.endsWith('cubit') ||
        lower.endsWith('bloc') ||
        lower.endsWith('viewmodel');
  }
}
