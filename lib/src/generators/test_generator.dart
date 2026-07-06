// lib/src/generators/test_generator.dart

import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;

import '../models/notifier_info.dart';
import '../utils/method_call_detector.dart';
import '../utils/mock_value_generator.dart';

/// Generates a complete Mocktail + Riverpod test file for one [NotifierInfo].
///
/// Import strategy
/// ───────────────
/// Rather than importing a hard-coded entity file, the generator does a
/// first pass over every stubbed repository call, resolves each method's
/// declared return type from the repository interface source, extracts the
/// leaf custom type (unwrapping Future<T> and List<T>), converts it to a
/// snake_case file path and emits a targeted import.  Primitives and
/// nullable types that stub as `null` produce no import.
///
/// Dependency mocking strategy
/// ────────────────────────────
/// Any dependency read via `ref.read()`/`ref.watch()` is a deliberate
/// Riverpod DI seam, so it is always mocked and overridden regardless of
/// its type name — this is what lets raw SDK dependencies (a directly
/// injected `FlutterSecureStorage`, `FirebaseAuth`, a `Dio` client, or
/// another feature's notifier) get mocked instead of running for real
/// inside the generated test. Dependencies discovered only as a class
/// field (no provider expression) still rely on a name heuristic
/// (Repository/Service/Client/DataSource/Api/Notifier/Cubit/Bloc/ViewModel)
/// to avoid flagging unrelated fields.
///
/// Import resolution for a mocked dependency is attempted in order:
///   1. a well-known SDK package mapping (e.g. `GoRouter` → `go_router`)
///   2. the project-wide notifier index (exact match for cross-notifier deps)
///   3. an import the notifier's own source file already declares (if that
///      import only resolves the `_impl` file, the bare interface import is
///      added alongside it, since the impl file isn't guaranteed to
///      re-export the interface `implements` needs)
///   4. the conventional Clean-Architecture repository folder layout
///      (only for `...Repository`-named types)
///   5. otherwise a `// TODO` comment is emitted instead of a guessed,
///      possibly-wrong import path.
///
/// Stub return value strategy
/// ──────────────────────────
///   void / Future<void>       → null
///   nullable T?               → null
///   primitive                 → literal  ('', 0, false, …)
///   List<CustomType>          → [CustomType.empty()]
///   List<primitive>           → []
///   CustomType                → CustomType.empty()
///
/// Error-path stubs throw `AppException.test()` (imported from
/// `core/errors/app_exception.dart`) rather than a bare `Exception`, since
/// that's the concrete failure type the app's own error handling expects.
class TestGenerator {
  /// Creates a generator. [projectRoot] is needed to locate repository
  /// interface files for return-type resolution. [notifierIndex] maps every
  /// notifier class name discovered in the project to its `package:` import
  /// path, and is used to resolve cross-notifier dependency imports.
  TestGenerator({required this.projectRoot, this.notifierIndex = const {}});

  /// Absolute path to the Flutter project root.
  final String projectRoot;

  /// Notifier class name → `package:` import path, for every notifier found
  /// in the project.
  final Map<String, String> notifierIndex;

  final _fmt =
      DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);

  /// Generates a test file for the provided [notifier].
  String generate(NotifierInfo notifier) {
    // ── First pass: resolve all stub return types so we know which custom
    //    entity types need to be imported before we write anything.
    final customTypeImports = _collectCustomTypeImports(notifier);

    // The body is generated before the imports so we know whether any error
    // scaffold actually stubbed an `AppException.test()` throw — otherwise
    // the import would be unused.
    final bodyBuf = StringBuffer();
    _mocks(bodyBuf, notifier);
    _mainBlock(bodyBuf, notifier);
    final body = bodyBuf.toString();

    final buf = StringBuffer();
    _imports(
      buf,
      notifier,
      customTypeImports,
      needsAppException: body.contains('AppException.test()'),
    );
    buf.write(body);

    try {
      return _fmt.format(buf.toString());
    } catch (_) {
      return buf.toString();
    }
  }

  // ── First pass: collect entity imports ──────────────────────────────────

  /// Walks every public method × every repository dependency, resolves each
  /// repository method's return type, extracts the custom leaf type, and
  /// returns the set of `package:` import strings that are needed.
  ///
  /// Restricted to `...Repository`-named dependencies, since only those
  /// follow the folder convention needed to locate and parse the interface
  /// source for return-type resolution.
  Set<String> _collectCustomTypeImports(NotifierInfo n) {
    final repositoryDeps =
        _mockableDependencies(n).where((r) => _isRepositorySuffix(r.type));

    final imports = <String>{};
    final featureName = _extractFeatureName(n.importPath);
    final publicMethods = n.methods.where((m) => !_isInternalHelper(m.name));

    for (final method in publicMethods) {
      for (final repo in repositoryDeps) {
        final calls = MethodCallDetector.detectRepositoryMethodCalls(
          n.sourceFilePath,
          repo.type,
          methodName: method.name,
        );

        final repoInterfacePath = _repositoryInterfacePath(repo, n);

        for (final call in calls) {
          final returnType = MethodCallDetector.resolveReturnType(
            repoInterfacePath,
            call.methodName,
          );
          if (returnType == null) continue;

          final customType = MockValueGenerator.extractCustomType(returnType);
          if (customType == null) continue;

          // Convert the class name to the expected snake_case file path.
          // e.g. UserEntity → user_entity, ContactModel → contact_model
          final snakeFile = _toSnakeCase(customType);
          // Heuristic: if the type name ends with Entity, Model, or Data,
          // place it in domain/entities; otherwise try the same folder.
          final subFolder = _entitySubfolder(customType);
          imports.add(
            "import 'package:${n.packageName}/features/$featureName/$subFolder/$snakeFile.dart';",
          );
        }
      }
    }

    return imports;
  }

  /// Returns the `lib/features/<feature>/` sub-path where a custom type
  /// class file is likely to live based on its name suffix.
  String _entitySubfolder(String typeName) {
    final lower = typeName.toLowerCase();
    if (lower.endsWith('entity')) return 'domain/entities';
    if (lower.endsWith('model')) return 'data/models';
    if (lower.endsWith('data')) return 'data/models';
    // Default — most custom return types in Clean Architecture are entities.
    return 'domain/entities';
  }

  // ── Imports ──────────────────────────────────────────────────────────────

  void _imports(
    StringBuffer b,
    NotifierInfo n,
    Set<String> customTypeImports, {
    required bool needsAppException,
  }) {
    b.writeln('// GENERATED BY mogen_unit_tests — YOU CAN REMOVE THIS COMMENT');
    b.writeln();
    b.writeln("import 'package:flutter_riverpod/flutter_riverpod.dart';");
    b.writeln("import 'package:flutter_test/flutter_test.dart';");
    b.writeln("import 'package:mocktail/mocktail.dart';");
    if (needsAppException) {
      b.writeln(
          "import 'package:${n.packageName}/core/errors/app_exception.dart';");
    }
    b.writeln();

    // Notifier
    b.writeln("import '${n.importPath}';");

    // State (if available)
    if (n.stateInfo != null) {
      b.writeln("import '${n.stateInfo!.importPath}';");
    }

    // Dependency imports (repositories, services, clients, other notifiers, …)
    for (final repo in _mockableDependencies(n)) {
      for (final line in _resolveDependencyImports(repo, n)) {
        b.writeln(line);
      }
    }

    // Entity / model imports derived from actual stub return types
    for (final import in customTypeImports) {
      b.writeln(import);
    }

    b.writeln();
  }

  /// Types whose mock class needs an import from a well-known pub package
  /// rather than anything discoverable inside the project itself.
  static const _wellKnownPackageImports = {
    'GoRouter': 'package:go_router/go_router.dart',
  };

  /// Resolves the import(s) needed for [repo]'s mock class to compile, trying
  /// (in order) well-known SDK packages, the project-wide notifier index,
  /// the notifier's own source imports, and the Clean-Architecture
  /// repository convention. Emits a `// TODO` comment instead of a guess when
  /// nothing resolves.
  List<String> _resolveDependencyImports(RepositoryDep repo, NotifierInfo n) {
    final wellKnown = _wellKnownPackageImports[repo.type];
    if (wellKnown != null) return ["import '$wellKnown';"];

    final indexed = notifierIndex[repo.type];
    if (indexed != null) return ["import '$indexed';"];

    final fromSource = _findSourceImport(repo.type, n);
    if (fromSource != null) {
      if (fromSource.isImplOnly && _isRepositorySuffix(repo.type)) {
        // The notifier's own source only imports the `_impl` file (likely
        // where the provider itself is declared) — the mock class still
        // needs the bare interface type for `implements $Type` to compile,
        // and the impl file isn't guaranteed to re-export it.
        final featureName = _extractFeatureName(n.importPath);
        final snakeCase = _toSnakeCase(repo.type);
        return [
          "import 'package:${n.packageName}/features/$featureName/domain/repositories/$snakeCase.dart';",
          "import '${fromSource.uri}';",
        ];
      }
      return ["import '${fromSource.uri}';"];
    }

    if (_isRepositorySuffix(repo.type)) {
      final featureName = _extractFeatureName(n.importPath);
      final snakeCase = _toSnakeCase(repo.type);
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

  /// Looks for an import already declared in the notifier's own source file
  /// whose target file plausibly defines [type]. Reports whether the match
  /// was the `_impl` file specifically (as opposed to the bare interface),
  /// since that changes what else the caller needs to import.
  ({String uri, bool isImplOnly})? _findSourceImport(String type, NotifierInfo n) {
    final snake = _toSnakeCase(type);
    for (final uri in n.sourceImports) {
      final base = p.basenameWithoutExtension(uri);
      if (base == snake) {
        return (uri: _toPortableImport(uri, n), isImplOnly: false);
      }
      if (base == '${snake}_impl') {
        return (uri: _toPortableImport(uri, n), isImplOnly: true);
      }
    }
    return null;
  }

  /// Converts a possibly-relative import URI (valid from the notifier's own
  /// source file) into a `package:` import valid from anywhere, since the
  /// generated test lives in a different directory than the notifier.
  String _toPortableImport(String uri, NotifierInfo n) {
    if (uri.startsWith('package:') || uri.startsWith('dart:')) return uri;

    final sourceDir = p.dirname(n.sourceFilePath);
    final absoluteTarget = p.normalize(p.join(sourceDir, uri));
    final libPath = p.join(projectRoot, 'lib');

    if (p.isWithin(libPath, absoluteTarget)) {
      final rel = p.relative(absoluteTarget, from: libPath).replaceAll(r'\', '/');
      return 'package:${n.packageName}/$rel';
    }

    return absoluteTarget.replaceAll(r'\', '/');
  }

  // ── Mock classes ─────────────────────────────────────────────────────────

  void _mocks(StringBuffer b, NotifierInfo n) {
    final dependencies = _mockableDependencies(n);

    if (dependencies.isEmpty) return;

    b.writeln(
        '// ── Mocks ────────────────────────────────────────────────────');
    for (final repo in dependencies) {
      b.writeln(
          'class Mock${repo.type} extends Mock implements ${repo.type} {}');
    }
    b.writeln();
  }

  // ── main() ───────────────────────────────────────────────────────────────

  void _mainBlock(StringBuffer b, NotifierInfo n) {
    b.writeln('void main() {\n');
    b.write('TestWidgetsFlutterBinding.ensureInitialized();\n\n');
    _group(b, n);
    b.writeln('}');
  }

  void _group(StringBuffer b, NotifierInfo n) {
    final dependencies = _mockableDependencies(n);

    b.writeln("  group('${n.className}', () {");

    for (final repo in dependencies) {
      b.writeln('    late Mock${repo.type} mock${repo.type};');
    }
    b.writeln('    late ProviderContainer container;');
    b.writeln();

    _setUp(b, n, dependencies);
    _tearDown(b);

    final publicMethods =
        n.methods.where((m) => !_isInternalHelper(m.name)).toList();

    for (final method in publicMethods) {
      _methodTests(b, method, n, dependencies);
    }

    b.writeln('  });');
  }

  // ── setUp ────────────────────────────────────────────────────────────────

  void _setUp(
      StringBuffer b, NotifierInfo n, List<RepositoryDep> dependencies) {
    b.writeln('    setUp(() {');

    for (final repo in dependencies) {
      b.writeln('      mock${repo.type} = Mock${repo.type}();');
    }

    b.writeln();
    b.writeln('      container = ProviderContainer(');

    if (dependencies.isNotEmpty) {
      b.writeln('        overrides: [');
      for (final repo in dependencies) {
        final provider =
            repo.providerExpression ?? '${_lcFirst(repo.type)}Provider';
        b.writeln(
            '          // Override the provider so the notifier gets mock${repo.type}');
        if (_isNotifierType(repo.type)) {
          b.writeln(
              '          $provider.overrideWith(() => mock${repo.type}),');
        } else {
          b.writeln(
              '          $provider.overrideWithValue(mock${repo.type}),');
        }
      }
      b.writeln('        ],');
    }

    b.writeln('      );');
    b.writeln('    });');
    b.writeln();
  }

  // ── tearDown ─────────────────────────────────────────────────────────────

  void _tearDown(StringBuffer b) {
    b.writeln('    tearDown(() {');
    b.writeln('      container.dispose();');
    b.writeln('    });');
    b.writeln();
  }

  // ── per-method tests ─────────────────────────────────────────────────────

  void _methodTests(StringBuffer b, MethodInfo method, NotifierInfo n,
      List<RepositoryDep> dependencies) {
    b.writeln(
        '    // ── ${method.name}() ──────────────────────────────────────');
    b.writeln("    group('${method.name}', () {");

    _methodSuccessTest(b, method, n, dependencies);
    _methodErrorTest(b, method, n, dependencies);

    b.writeln('    });');
    b.writeln();
  }

  void _methodSuccessTest(StringBuffer b, MethodInfo method, NotifierInfo n,
      List<RepositoryDep> dependencies) {
    final awaitKw = method.isAsync ? 'await ' : '';
    final notifierProvider = '${_lcFirst(n.className)}Provider';

    b.writeln("      test('${method.name} completes successfully', () async {");

    _stubOnlyCalledMethods(b, method, n, dependencies);

    if (method.params.isNotEmpty) {
      b.writeln();
      b.writeln('        // Arrange: inputs');
      for (final param in method.params) {
        final val = MockValueGenerator.forType(param.type);
        b.writeln('        final ${param.name} = $val;');
      }
    }

    b.writeln();
    b.writeln('        // Ensure notifier is initialised');
    _initializeNotifier(b, n, notifierProvider);

    b.writeln();
    b.writeln('        // Act');

    final args = _buildArgList(method.params);
    final call =
        '${awaitKw}container.read($notifierProvider.notifier).${method.name}($args)';

    if (method.returnType != 'void' && method.returnType != 'Future<void>') {
      b.writeln('        final result = $call;');
    } else {
      b.writeln('        $call;');
    }

    b.writeln();
    b.writeln('        // Assert');

    if (n.stateType != null &&
        n.stateType != 'dynamic' &&
        n.stateInfo != null) {
      b.writeln(
          '        final finalState = container.read($notifierProvider);');
      _generateStateFieldAssertions(b, n, expectSuccess: true);
    } else {
      b.writeln('        // expect(container.read($notifierProvider), ...);');
    }

    b.writeln('      });');
    b.writeln();
  }

  void _methodErrorTest(StringBuffer b, MethodInfo method, NotifierInfo n,
      List<RepositoryDep> dependencies) {
    final awaitKw = method.isAsync ? 'await ' : '';
    final notifierProvider = '${_lcFirst(n.className)}Provider';

    b.writeln(
        "      test('${method.name} shows an error when the repository fails', () async {");

    _stubOnlyCalledMethods(b, method, n, dependencies, shouldThrow: true);

    if (method.params.isNotEmpty) {
      b.writeln();
      b.writeln('        // Arrange: inputs');
      for (final param in method.params) {
        final val = MockValueGenerator.forType(param.type);
        b.writeln('        final ${param.name} = $val;');
      }
    }

    b.writeln();
    b.writeln('        // Ensure notifier is initialised');
    _initializeNotifier(b, n, notifierProvider);

    b.writeln();
    b.writeln('        // Act');

    final args = _buildArgList(method.params);
    final call =
        '        ${awaitKw}container.read($notifierProvider.notifier).${method.name}($args);';
    b.writeln(call);

    b.writeln();
    b.writeln('        // Assert');

    if (n.stateType != null &&
        n.stateType != 'dynamic' &&
        n.stateInfo != null) {
      b.writeln(
          '        final finalState = container.read($notifierProvider);');
      _generateStateFieldAssertions(b, n, expectSuccess: false);
    } else {
      b.writeln('        // expect(container.read($notifierProvider), ...);');
    }

    b.writeln('      });');
    b.writeln();
  }

  /// Emits the notifier-initialisation line. `AsyncNotifier` providers expose
  /// `.future` and must be awaited before the state settles; plain
  /// `Notifier` providers build synchronously and have no `.future` getter,
  /// so simply reading the provider is enough to trigger `build()`.
  void _initializeNotifier(
      StringBuffer b, NotifierInfo n, String notifierProvider) {
    if (n.isAsync) {
      b.writeln('        await container.read($notifierProvider.future);');
    } else {
      b.writeln('        container.read($notifierProvider);');
    }
  }

  // ── Generate state field assertions ──────────────────────────────────────

  void _generateStateFieldAssertions(
    StringBuffer b,
    NotifierInfo n, {
    required bool expectSuccess,
  }) {
    if (n.stateInfo == null) return;

    final commonLoadingFields = ['isLoadingAction', 'isLoading', 'loading'];
    final commonErrorFields = ['error', 'errorMessage', 'errorMsg'];
    final commonSuccessFields = ['success', 'successMessage', 'message'];

    final stateFieldNames = n.stateInfo!.fields.map((f) => f.name).toSet();

    for (final field in commonLoadingFields) {
      if (stateFieldNames.contains(field)) {
        b.writeln('        expect(finalState.requireValue.$field, isFalse);');
        break;
      }
    }

    for (final field in commonErrorFields) {
      if (stateFieldNames.contains(field)) {
        b.writeln(
            '        expect(finalState.requireValue.$field, ${expectSuccess ? 'isNull' : 'isNotNull'});');
        break;
      }
    }

    for (final field in commonSuccessFields) {
      if (stateFieldNames.contains(field)) {
        b.writeln(
            '        expect(finalState.requireValue.$field, ${expectSuccess ? 'isNotNull' : 'isNull'});');
        break;
      }
    }
  }

  // ── Stub only methods actually called ────────────────────────────────────

  void _stubOnlyCalledMethods(
    StringBuffer b,
    MethodInfo method,
    NotifierInfo n,
    List<RepositoryDep> dependencies, {
    bool shouldThrow = false,
  }) {
    if (dependencies.isEmpty) return;

    b.writeln('        // Arrange: stub repositories');
    for (final repo in dependencies) {
      final calls = MethodCallDetector.detectRepositoryMethodCalls(
        n.sourceFilePath,
        repo.type,
        methodName: method.name,
      );

      if (calls.isEmpty) {
        b.writeln('        // No mocks needed for ${repo.type}');
      } else {
        // Only Repository-suffixed types follow the folder convention we can
        // use to resolve a real return type; everything else stubs `null`.
        final repoInterfacePath =
            _isRepositorySuffix(repo.type) ? _repositoryInterfacePath(repo, n) : null;

        for (final call in calls) {
          b.writeln(
              '        when(() => mock${repo.type}.${call.invocationSource})');

          if (shouldThrow) {
            b.writeln('            .thenThrow(AppException.test());');
          } else {
            final returnType = repoInterfacePath == null
                ? null
                : MethodCallDetector.resolveReturnType(
                    repoInterfacePath, call.methodName);
            final returnVal = _stubReturnValue(returnType);
            b.writeln('            .thenAnswer((_) async => $returnVal);');
          }
        }
      }
    }
  }

  // ── Stub return value ─────────────────────────────────────────────────────

  String _stubReturnValue(String? returnType) {
    if (returnType == null) return 'null';
    return MockValueGenerator.forReturnType(returnType);
  }

  /// Derives the absolute path to the domain repository interface file.
  String _repositoryInterfacePath(RepositoryDep repo, NotifierInfo n) {
    final featureName = _extractFeatureName(n.importPath);
    final snakeCase = _toSnakeCase(repo.type);
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

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _buildArgList(List<ParamInfo> params) => params.map((p) {
        if (p.isNamed) return '${p.name}: ${p.name}';
        return p.name;
      }).join(', ');

  String _lcFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  String _extractFeatureName(String importPath) {
    final parts = importPath.split('/');
    final featuresIdx = parts.indexOf('features');
    if (featuresIdx >= 0 && featuresIdx + 1 < parts.length) {
      return parts[featuresIdx + 1];
    }
    return '';
  }

  /// Every dependency worth mocking for [n]. A dependency reached via
  /// `ref.read()`/`ref.watch()` is always mocked, since that call is itself
  /// the DI seam the app relies on to substitute a fake in tests — this is
  /// what covers raw SDK types (`FlutterSecureStorage`, `FirebaseAuth`, a
  /// `Dio` client, ...) and other notifiers alike, regardless of their type
  /// name. Dependencies found only as a plain class field (no provider
  /// expression) fall back to a name-suffix heuristic.
  List<RepositoryDep> _mockableDependencies(NotifierInfo n) => n.repositories
      .where((r) => r.providerExpression != null || _looksLikeMockableName(r.type))
      .toList();

  bool _looksLikeMockableName(String type) {
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

  bool _isRepositorySuffix(String type) => type.toLowerCase().endsWith('repository');

  /// Riverpod `Notifier`/`AsyncNotifier` (and Bloc/Cubit) dependencies need
  /// their provider substituted via `overrideWith(() => instance)`, since
  /// their provider exposes the notifier's *state*, not the notifier
  /// instance itself — `overrideWithValue` would try to assign the mock as
  /// if it were a state value and fail to compile.
  bool _isNotifierType(String type) {
    final lower = type.toLowerCase();
    return lower.endsWith('notifier') ||
        lower.endsWith('cubit') ||
        lower.endsWith('bloc') ||
        lower.endsWith('viewmodel');
  }

  /// Matches internal helper methods following the `pXxx` naming convention
  /// (e.g. `pOnSuccess`, `pOnError`) without excluding real public methods
  /// that merely start with a lowercase `p` (`parse`, `publish`, `pay`, ...).
  bool _isInternalHelper(String name) => RegExp(r'^p[A-Z]').hasMatch(name);

  String _toSnakeCase(String name) => name
      .replaceAllMapped(
        RegExp(r'([A-Z])'),
        (m) => '_${m.group(0)!.toLowerCase()}',
      )
      .replaceFirst(RegExp(r'^_'), '');
}
