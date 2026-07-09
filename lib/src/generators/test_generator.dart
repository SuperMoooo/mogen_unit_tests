// lib/src/generators/test_generator.dart

import 'dart:io';

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
/// first pass over every stubbed dependency call, resolves each method's
/// declared signature from its source, extracts the leaf custom types
/// (unwrapping Future<T>/FutureOr<T> and List<T>), locates the defining file
/// on disk (searching every feature's entity/model/state folders — a
/// dependency's types don't have to live in the consuming notifier's own
/// feature) and emits a targeted import.  Primitives and nullable types that
/// stub as `null` produce no import.
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
/// Riverpod notifier dependencies get special treatment: a bare
/// `extends Mock implements OtherNotifier` cannot satisfy the container's
/// library-private wiring (`_setElement`, ...) and dies with
/// `MissingStubError` the moment the provider is read. When the dependency
/// is a notifier the project scan parsed (available via [notifierRegistry]),
/// the mock instead *extends the real base class* and mixes `Mock` in:
///
///   class MockOtherNotifier extends AsyncNotifier<OtherState>
///       with Mock implements OtherNotifier {}
///
/// and its `build()` is stubbed in `setUp()`, so code under test that does
/// `await ref.read(otherNotifierProvider.future)` resolves instead of
/// crashing.
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
/// Synchronous methods are stubbed with `thenReturn(...)` — answering a
/// `Future` from a sync method is a runtime `TypeError`. `Future`-returning
/// methods use `thenAnswer((_) async => ...)`.
///
/// Error-path strategy
/// ───────────────────
/// The error test initialises the notifier first (while the success stubs
/// from `setUp()` are in effect, so `build()` never fails), then re-stubs
/// *every* dependency call the method makes with
/// `thenThrow(AppException.test())` — including calls `build()` shares —
/// and only then acts. A method that makes no dependency calls at all gets
/// no error test: there is no failure to simulate, and asserting an error
/// that can never occur would only ever fail.
///
/// Mocktail fallback values
/// ────────────────────────
/// `any()` on a non-nullable custom-typed parameter throws unless a
/// fallback instance was registered. The generator resolves the parameter
/// types of every stubbed method and emits the needed
/// `registerFallbackValue(...)` calls once in `setUpAll()`.
class TestGenerator {
  /// Creates a generator. [projectRoot] is needed to locate dependency
  /// source files for signature resolution. [notifierIndex] maps every
  /// notifier class name discovered in the project to its `package:` import
  /// path, and is used to resolve cross-notifier dependency imports.
  /// [notifierRegistry] carries the full parsed info of every project
  /// notifier so notifier dependencies can be mocked safely.
  TestGenerator({
    required this.projectRoot,
    this.notifierIndex = const {},
    this.notifierRegistry = const {},
  });

  /// Absolute path to the Flutter project root.
  final String projectRoot;

  /// Notifier class name → `package:` import path, for every notifier found
  /// in the project.
  final Map<String, String> notifierIndex;

  /// Notifier class name → full parsed info, for every notifier found in
  /// the project. Used to generate runtime-safe mocks (real base class +
  /// stubbed `build()`) and to resolve notifier dependency method
  /// signatures.
  final Map<String, NotifierInfo> notifierRegistry;

  final _fmt =
      DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);

  /// Generates a test file for the provided [notifier].
  String generate(NotifierInfo notifier) {
    final plan = _buildPlan(notifier);

    // The body is generated before the imports so we know whether any error
    // scaffold actually stubbed an `AppException.test()` throw — otherwise
    // the import would be unused.
    final bodyBuf = StringBuffer();
    _mocks(bodyBuf, notifier, plan);
    _mainBlock(bodyBuf, notifier, plan);
    final body = bodyBuf.toString();

    final buf = StringBuffer();
    _imports(
      buf,
      notifier,
      plan,
      needsAppException: body.contains('AppException.test()'),
    );
    buf.write(body);

    try {
      return _fmt.format(buf.toString());
    } catch (_) {
      return buf.toString();
    }
  }

  // ── Plan: one up-front analysis pass ─────────────────────────────────────

  /// Analyses the notifier once — every dependency call per method, resolved
  /// signatures, which stubs to hoist into `setUp()`, which fallback values
  /// mocktail needs, and which extra imports the stub values require.
  _Plan _buildPlan(NotifierInfo n) {
    final dependencies = _mockableDependencies(n);
    final publicMethods =
        n.methods.where((m) => !_isInternalHelper(m.name)).toList();

    final buildName = n.buildMethod?.name;
    final methodNames = [
      if (buildName != null) buildName,
      ...publicMethods.map((m) => m.name),
    ];

    final callsByMethod = <String, Map<String, List<RepositoryMethodCall>>>{};
    for (final name in methodNames) {
      final perDep = <String, List<RepositoryMethodCall>>{};
      for (final repo in dependencies) {
        perDep[repo.type] = MethodCallDetector.detectRepositoryMethodCalls(
          n.sourceFilePath,
          repo.type,
          methodName: name,
        );
      }
      callsByMethod[name] = perDep;
    }

    // Resolve each (dependency, call) signature exactly once.
    final returnTypes = <String, String?>{};
    final fallbackTypes = <String>[];
    final imports = <String>{};

    void addFallback(String rawType) {
      final type = rawType.trim();
      if (!_needsFallbackRegistration(type)) return;
      if (fallbackTypes.contains(type)) return;
      fallbackTypes.add(type);
      final base = type.split('<').first.trim();
      if (!MockValueGenerator.isPrimitive(base)) {
        imports.add(_typeImport(base, n));
      }
    }

    for (final methodName in methodNames) {
      for (final repo in dependencies) {
        for (final call in callsByMethod[methodName]![repo.type] ??
            const <RepositoryMethodCall>[]) {
          final key = '${repo.type}.${call.methodName}';
          if (returnTypes.containsKey(key)) continue;

          final sig = _resolveCallSignature(repo, call.methodName, n);
          returnTypes[key] = sig?.returnType;

          final returnType = sig?.returnType;
          if (returnType != null) {
            final customType = MockValueGenerator.extractCustomType(returnType);
            if (customType != null) {
              imports.add(_typeImport(customType, n));
            }
          }
          for (final paramType in sig?.paramTypes ?? const <String>[]) {
            addFallback(paramType);
          }
        }
      }
    }

    // Notifier dependencies: their build() is stubbed in setUp(), which
    // needs the state type imported (also referenced by the mock class's
    // `extends <Base<State>>`), and — for family notifiers — an any()
    // matcher whose argument type needs a registered fallback.
    for (final repo in dependencies) {
      final dep = notifierRegistry[repo.type];
      if (dep == null || dep.superclassSource == null) continue;

      final stateLeaf =
          MockValueGenerator.extractCustomType(dep.stateType ?? '');
      if (stateLeaf != null) {
        final stateImportPath = dep.stateInfo?.importPath;
        imports.add(stateImportPath != null
            ? "import '$stateImportPath';"
            : _typeImport(stateLeaf, n));
      }
      final argType = dep.familyArgType;
      if (dep.isFamily && argType != null) {
        addFallback(argType);
      }
    }

    // Family notifier under test: the family argument value may need an
    // import too.
    final familyArgType = n.familyArgType;
    if (n.isFamily && familyArgType != null) {
      final leaf = MockValueGenerator.extractCustomType(familyArgType);
      if (leaf != null) {
        imports.add(_typeImport(leaf, n));
      }
    }

    // Hoisted stubs: everything build() calls, plus calls shared by two or
    // more public methods — stubbed once at the end of setUp() instead of
    // being repeated identically inside every test.
    final buildCallNames = <String, Set<String>>{};
    final hoistedCalls = <String, List<RepositoryMethodCall>>{};
    for (final repo in dependencies) {
      final hoistedNames = <String>{};
      final hoisted = <RepositoryMethodCall>[];

      if (buildName != null) {
        for (final call in callsByMethod[buildName]![repo.type] ??
            const <RepositoryMethodCall>[]) {
          if (hoistedNames.add(call.methodName)) hoisted.add(call);
        }
      }
      buildCallNames[repo.type] = Set.of(hoistedNames);

      final usageCount = <String, int>{};
      final firstSeen = <String, RepositoryMethodCall>{};
      for (final method in publicMethods) {
        final seenInMethod = <String>{};
        for (final call in callsByMethod[method.name]![repo.type] ??
            const <RepositoryMethodCall>[]) {
          if (!seenInMethod.add(call.methodName)) continue;
          usageCount[call.methodName] =
              (usageCount[call.methodName] ?? 0) + 1;
          firstSeen.putIfAbsent(call.methodName, () => call);
        }
      }
      for (final entry in usageCount.entries) {
        if (entry.value >= 2 && hoistedNames.add(entry.key)) {
          hoisted.add(firstSeen[entry.key]!);
        }
      }

      if (hoisted.isNotEmpty) hoistedCalls[repo.type] = hoisted;
    }

    return _Plan(
      dependencies: dependencies,
      publicMethods: publicMethods,
      callsByMethod: callsByMethod,
      returnTypes: returnTypes,
      hoistedCalls: hoistedCalls,
      buildCallNames: buildCallNames,
      fallbackTypes: fallbackTypes,
      extraImports: imports,
    );
  }

  /// Resolves the declared signature of a dependency method: repository
  /// interfaces are parsed from their conventional source location, notifier
  /// dependencies come from the project-wide [notifierRegistry].
  MethodSignature? _resolveCallSignature(
      RepositoryDep repo, String callName, NotifierInfo n) {
    if (_isRepositorySuffix(repo.type)) {
      return MethodCallDetector.resolveMethodSignature(
        _repositoryInterfacePath(repo, n),
        callName,
      );
    }

    final dep = notifierRegistry[repo.type];
    if (dep != null) {
      MethodInfo? method;
      if (callName == 'build') {
        method = dep.buildMethod;
      } else {
        for (final m in dep.methods) {
          if (m.name == callName) {
            method = m;
            break;
          }
        }
      }
      if (method != null) {
        return MethodSignature(
          returnType: method.returnType,
          paramTypes: method.params.map((param) => param.type).toList(),
        );
      }
    }

    return null;
  }

  // ── Imports ──────────────────────────────────────────────────────────────

  void _imports(
    StringBuffer b,
    NotifierInfo n,
    _Plan plan, {
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

    // Deduplicated: the same file can be reached as the notifier's state,
    // a dependency's state, and a stub return type all at once.
    final lines = <String>{};

    // Notifier
    lines.add("import '${n.importPath}';");

    // State (if available)
    if (n.stateInfo != null) {
      lines.add("import '${n.stateInfo!.importPath}';");
    }

    // Dependency imports (repositories, services, clients, other notifiers, …)
    for (final repo in plan.dependencies) {
      lines.addAll(_resolveDependencyImports(repo, n));
    }

    // Entity / model / state imports derived from actual stub values.
    lines.addAll(plan.extraImports);

    for (final line in lines) {
      b.writeln(line);
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
        // and the impl file isn't guaranteed to re-export it. The feature
        // name is taken from the *resolved impl import* rather than the
        // notifier's own feature, since the dependency may well live in a
        // different feature than the notifier consuming it (e.g. an
        // `AuthNotifier` depending on a `UserRepository` that lives under
        // `features/user/`, not `features/auth/`).
        final featureName = _extractFeatureName(fromSource.uri);
        final snakeCase = _toSnakeCase(repo.type);
        return [
          "import 'package:${n.packageName}/features/$featureName/domain/repositories/$snakeCase.dart';",
          "import '${fromSource.uri}';",
        ];
      }
      return ["import '${fromSource.uri}';"];
    }

    if (_isRepositorySuffix(repo.type)) {
      final snakeCase = _toSnakeCase(repo.type);
      // Prefer the feature folder the repository interface actually lives
      // in on disk — a dependency doesn't necessarily belong to the
      // consuming notifier's own feature (e.g. an `AuthNotifier` reading a
      // `UserRepository` that lives under `features/user/`). Only fall back
      // to assuming the notifier's own feature when nothing is found (e.g.
      // in unit tests against a fabricated project root).
      final featureName = _findActualFeatureFolder(snakeCase) ??
          _extractFeatureName(n.importPath);
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

  /// Scans `lib/features/*/domain/repositories/` on disk for a file named
  /// `$repositoryFileName.dart` and returns the feature folder it was found
  /// in, or `null` if no such file exists anywhere in the project.
  String? _findActualFeatureFolder(String repositoryFileName) {
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

  /// Conventional folders a custom type's defining file can live in, in
  /// search-priority order.
  static const _typeFolders = [
    'domain/entities',
    'data/models',
    'domain/models',
    'presentation/states',
  ];

  /// Builds the import line for a custom [typeName]: first searches every
  /// feature's entity/model/state folders on disk (a type doesn't have to
  /// live in the consuming notifier's own feature), then falls back to a
  /// name-suffix guess inside the notifier's feature.
  String _typeImport(String typeName, NotifierInfo n) {
    final snakeFile = _toSnakeCase(typeName);

    final featuresDir = Directory(p.join(projectRoot, 'lib', 'features'));
    if (featuresDir.existsSync()) {
      for (final entry in featuresDir.listSync()) {
        if (entry is! Directory) continue;
        for (final sub in _typeFolders) {
          final candidate = File(
              p.joinAll([entry.path, ...sub.split('/'), '$snakeFile.dart']));
          if (candidate.existsSync()) {
            final featureName = p.basename(entry.path);
            return "import 'package:${n.packageName}/features/$featureName/$sub/$snakeFile.dart';";
          }
        }
      }
    }

    final featureName = _extractFeatureName(n.importPath);
    final subFolder = _entitySubfolder(typeName);
    return "import 'package:${n.packageName}/features/$featureName/$subFolder/$snakeFile.dart';";
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

  /// Looks for an import already declared in the notifier's own source file
  /// whose target file plausibly defines [type]. Reports whether the match
  /// was the `_impl` file specifically (as opposed to the bare interface),
  /// since that changes what else the caller needs to import.
  ({String uri, bool isImplOnly})? _findSourceImport(
      String type, NotifierInfo n) {
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
      final rel =
          p.relative(absoluteTarget, from: libPath).replaceAll(r'\', '/');
      return 'package:${n.packageName}/$rel';
    }

    return absoluteTarget.replaceAll(r'\', '/');
  }

  // ── Mock classes ─────────────────────────────────────────────────────────

  void _mocks(StringBuffer b, NotifierInfo n, _Plan plan) {
    if (plan.dependencies.isEmpty) return;

    b.writeln(
        '// ── Mocks ────────────────────────────────────────────────────');
    for (final repo in plan.dependencies) {
      final dep = notifierRegistry[repo.type];
      if (dep?.superclassSource != null) {
        // A Riverpod notifier can't be mocked with a bare
        // `extends Mock implements X` — the container wires notifiers
        // through library-private members only a real base class provides,
        // so that mock dies with MissingStubError as soon as the provider
        // is read. Extending the real base keeps the wiring real while
        // `with Mock` lets build() and the public methods be stubbed.
        b.writeln('class Mock${repo.type} extends ${dep!.superclassSource} '
            'with Mock implements ${repo.type} {}');
      } else {
        b.writeln(
            'class Mock${repo.type} extends Mock implements ${repo.type} {}');
      }
    }
    b.writeln();
  }

  // ── main() ───────────────────────────────────────────────────────────────

  void _mainBlock(StringBuffer b, NotifierInfo n, _Plan plan) {
    b.writeln('void main() {\n');
    b.write('TestWidgetsFlutterBinding.ensureInitialized();\n\n');
    _group(b, n, plan);
    b.writeln('}');
  }

  void _group(StringBuffer b, NotifierInfo n, _Plan plan) {
    b.writeln("  group('${n.className}', () {");

    for (final repo in plan.dependencies) {
      b.writeln('    late Mock${repo.type} mock${repo.type};');
    }
    b.writeln('    late ProviderContainer container;');

    if (n.isFamily) {
      b.writeln();
      b.writeln(
          '    // Family argument passed to every read of the provider under test.');
      final argType = n.familyArgType ?? 'dynamic';
      b.writeln(
          '    ${_inputDeclarationLine(ParamInfo(name: 'familyArg', type: argType))}');
    }
    b.writeln();

    _setUpAll(b, plan);
    _setUp(b, n, plan);
    _tearDown(b);

    for (final method in plan.publicMethods) {
      _methodTests(b, method, n, plan);
    }

    b.writeln('  });');
  }

  // ── setUpAll ─────────────────────────────────────────────────────────────

  void _setUpAll(StringBuffer b, _Plan plan) {
    if (plan.fallbackTypes.isEmpty) return;

    b.writeln('    setUpAll(() {');
    b.writeln(
        '      // Mocktail needs a fallback instance registered for every');
    b.writeln(
        '      // non-nullable custom type used with an any()/captureAny() matcher.');
    for (final type in plan.fallbackTypes) {
      b.writeln(
          '      registerFallbackValue(${MockValueGenerator.forType(type)});');
    }
    b.writeln('    });');
    b.writeln();
  }

  // ── setUp ────────────────────────────────────────────────────────────────

  void _setUp(StringBuffer b, NotifierInfo n, _Plan plan) {
    b.writeln('    setUp(() {');

    for (final repo in plan.dependencies) {
      b.writeln('      mock${repo.type} = Mock${repo.type}();');
    }

    b.writeln();
    b.writeln('      container = ProviderContainer(');

    if (plan.dependencies.isNotEmpty) {
      b.writeln('        overrides: [');
      for (final repo in plan.dependencies) {
        final rawProvider =
            repo.providerExpression ?? '${_lcFirst(repo.type)}Provider';
        // Overrides apply to the base provider — `.notifier`/`.future` are
        // read-time accessors and family call arguments are per-read
        // parameters, so both must be stripped from a captured expression
        // like `userNotifierProvider.future` or `chatProvider(roomId)`.
        final provider = _baseProviderExpression(rawProvider);
        b.writeln(
            '          // Override the provider so the notifier gets mock${repo.type}');
        if (_isNotifierType(repo.type)) {
          b.writeln(
              '          $provider.overrideWith(() => mock${repo.type}),');
        } else if (_hasCallArgs(rawProvider)) {
          // Family providers have no overrideWithValue — override the
          // factory instead, ignoring the per-read argument.
          b.writeln(
              '          $provider.overrideWith((ref, arg) => mock${repo.type}),');
        } else {
          b.writeln(
              '          $provider.overrideWithValue(mock${repo.type}),');
        }
      }
      b.writeln('        ],');
    }

    b.writeln('      );');

    // Riverpod calls build() on a mocked notifier dependency as soon as its
    // provider is read — a MissingStubError there would sink every test.
    final notifierDeps = plan.dependencies
        .where((r) => notifierRegistry[r.type]?.superclassSource != null)
        .toList();
    if (notifierDeps.isNotEmpty) {
      b.writeln();
      b.writeln(
          '      // Arrange: stub build() on mocked notifier dependencies so');
      b.writeln(
          '      // reading them (or awaiting their .future) resolves.');
      for (final repo in notifierDeps) {
        final dep = notifierRegistry[repo.type]!;
        final stateVal =
            MockValueGenerator.forReturnType(dep.stateType ?? 'dynamic');
        final buildArgs = dep.isFamily ? 'any()' : '';
        if (dep.isAsync) {
          b.writeln('      when(() => mock${repo.type}.build($buildArgs))');
          b.writeln('          .thenAnswer((_) async => $stateVal);');
        } else {
          b.writeln('      when(() => mock${repo.type}.build($buildArgs))');
          b.writeln('          .thenReturn($stateVal);');
        }
      }
    }

    if (plan.hoistedCalls.isNotEmpty) {
      b.writeln();
      b.writeln(
          '      // Arrange: stub dependencies used by build() and calls shared');
      b.writeln(
          '      // by multiple methods — once here instead of in every test.');
      for (final repo in plan.dependencies) {
        final calls = plan.hoistedCalls[repo.type];
        if (calls == null) continue;

        for (final call in calls) {
          _writeSuccessStub(
            b,
            '      ',
            'mock${repo.type}',
            call,
            plan.returnTypes['${repo.type}.${call.methodName}'],
          );
        }
      }
    }

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

  void _methodTests(
    StringBuffer b,
    MethodInfo method,
    NotifierInfo n,
    _Plan plan,
  ) {
    b.writeln(
        '    // ── ${method.name}() ──────────────────────────────────────');
    b.writeln("    group('${method.name}', () {");

    _methodSuccessTest(b, method, n, plan);

    final hasDependencyCalls = plan.dependencies.any((repo) =>
        (plan.callsByMethod[method.name]![repo.type] ??
                const <RepositoryMethodCall>[])
            .isNotEmpty);
    if (hasDependencyCalls) {
      _methodErrorTest(b, method, n, plan);
    } else {
      b.writeln(
          '      // No error-path test: ${method.name}() makes no dependency');
      b.writeln(
          '      // calls, so there is no repository failure to simulate.');
    }

    b.writeln('    });');
    b.writeln();
  }

  void _methodSuccessTest(
    StringBuffer b,
    MethodInfo method,
    NotifierInfo n,
    _Plan plan,
  ) {
    final awaitKw = method.isAsync ? 'await ' : '';
    final providerRead = _providerRead(n);

    b.writeln(
        "      test('${method.name} completes successfully', () async {");

    _stubSuccessCalls(b, method, n, plan);

    if (method.params.isNotEmpty) {
      b.writeln();
      b.writeln('        // Arrange: inputs');
      for (final param in method.params) {
        b.writeln('        ${_inputDeclarationLine(param)}');
      }
    }

    b.writeln();
    b.writeln('        // Ensure notifier is initialised');
    _initializeNotifier(b, n);

    b.writeln();
    b.writeln('        // Act');

    final args = _buildArgList(method.params);
    final call =
        '${awaitKw}container.read($providerRead.notifier).${method.name}($args)';

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
      b.writeln('        final finalState = container.read($providerRead);');
      _generateStateFieldAssertions(b, n, method, expectSuccess: true);
    } else {
      b.writeln('        // expect(container.read($providerRead), ...);');
    }

    b.writeln('      });');
    b.writeln();
  }

  void _methodErrorTest(
    StringBuffer b,
    MethodInfo method,
    NotifierInfo n,
    _Plan plan,
  ) {
    final awaitKw = method.isAsync ? 'await ' : '';
    final providerRead = _providerRead(n);

    b.writeln(
        "      test('${method.name} shows an error when the repository fails', () async {");

    if (method.params.isNotEmpty) {
      b.writeln('        // Arrange: inputs');
      for (final param in method.params) {
        b.writeln('        ${_inputDeclarationLine(param)}');
      }
      b.writeln();
    }

    // Initialise while setUp()'s success stubs are still in effect — build()
    // must succeed even when the method under test is about to fail.
    b.writeln('        // Ensure notifier is initialised');
    _initializeNotifier(b, n);

    b.writeln();
    b.writeln(
        '        // Arrange: make every dependency call this method performs fail.');
    b.writeln(
        '        // Re-stubbing overrides the success stubs from setUp().');
    for (final repo in plan.dependencies) {
      final calls = plan.callsByMethod[method.name]![repo.type] ??
          const <RepositoryMethodCall>[];
      for (final call in calls) {
        b.writeln(
            '        when(() => mock${repo.type}.${call.invocationSource})');
        b.writeln('            .thenThrow(AppException.test());');
      }
    }

    b.writeln();
    b.writeln('        // Act');

    final args = _buildArgList(method.params);
    b.writeln(
        '        ${awaitKw}container.read($providerRead.notifier).${method.name}($args);');

    b.writeln();
    b.writeln('        // Assert');

    if (n.stateType != null &&
        n.stateType != 'dynamic' &&
        n.stateInfo != null) {
      b.writeln('        final finalState = container.read($providerRead);');
      _generateStateFieldAssertions(b, n, method, expectSuccess: false);
    } else {
      b.writeln('        // expect(container.read($providerRead), ...);');
    }

    b.writeln('      });');
    b.writeln();
  }

  /// The expression used to read the provider under test — family notifiers
  /// must be read with their argument: `provider(familyArg)`.
  String _providerRead(NotifierInfo n) {
    final base = '${_lcFirst(n.className)}Provider';
    return n.isFamily ? '$base(familyArg)' : base;
  }

  /// Emits the notifier-initialisation line. `AsyncNotifier` providers expose
  /// `.future` and must be awaited before the state settles; plain
  /// `Notifier` providers build synchronously and have no `.future` getter,
  /// so simply reading the provider is enough to trigger `build()`.
  void _initializeNotifier(StringBuffer b, NotifierInfo n) {
    final providerRead = _providerRead(n);
    if (n.isAsync) {
      b.writeln('        await container.read($providerRead.future);');
    } else {
      b.writeln('        container.read($providerRead);');
    }
  }

  // ── Generate state field assertions ──────────────────────────────────────

  void _generateStateFieldAssertions(
    StringBuffer b,
    NotifierInfo n,
    MethodInfo method, {
    required bool expectSuccess,
  }) {
    if (n.stateInfo == null) return;

    final commonLoadingFields = ['isLoadingAction', 'isLoading', 'loading'];
    final commonErrorFields = ['error', 'errorMessage', 'errorMsg'];
    final commonSuccessFields = ['success', 'successMessage', 'message'];

    final stateFieldNames = n.stateInfo!.fields.map((f) => f.name).toSet();

    // A plain Notifier's provider exposes the state directly — AsyncValue's
    // `requireValue` only exists on async notifiers.
    final access = n.isAsync ? 'finalState.requireValue' : 'finalState';

    for (final field in commonLoadingFields) {
      if (stateFieldNames.contains(field)) {
        b.writeln('        expect($access.$field, isFalse);');
        break;
      }
    }

    for (final field in commonErrorFields) {
      if (stateFieldNames.contains(field)) {
        b.writeln(
            '        expect($access.$field, ${expectSuccess ? 'isNull' : 'isNotNull'});');
        break;
      }
    }

    for (final field in commonSuccessFields) {
      if (stateFieldNames.contains(field)) {
        // Only assert a success message appears when the method body
        // actually mentions the field — plenty of methods legitimately
        // never set one, and asserting isNotNull there always fails.
        // An unknown body (bodySource == null) gets the benefit of the
        // doubt to stay compatible with pre-parsed inputs.
        if (expectSuccess && !_methodMentions(method, field)) break;
        b.writeln(
            '        expect($access.$field, ${expectSuccess ? 'isNotNull' : 'isNull'});');
        break;
      }
    }
  }

  bool _methodMentions(MethodInfo method, String identifier) {
    final body = method.bodySource;
    if (body == null) return true;
    return body.contains(identifier);
  }

  // ── Success-path stubs for one method ────────────────────────────────────

  void _stubSuccessCalls(
    StringBuffer b,
    MethodInfo method,
    NotifierInfo n,
    _Plan plan,
  ) {
    if (plan.dependencies.isEmpty) return;

    b.writeln('        // Arrange: stub repositories');
    for (final repo in plan.dependencies) {
      final calls = plan.callsByMethod[method.name]![repo.type] ??
          const <RepositoryMethodCall>[];

      // Anything already stubbed at the end of setUp() (build()'s calls and
      // calls shared by several methods) isn't repeated here.
      final hoistedNames =
          (plan.hoistedCalls[repo.type] ?? const <RepositoryMethodCall>[])
              .map((c) => c.methodName)
              .toSet();
      final remaining =
          calls.where((c) => !hoistedNames.contains(c.methodName)).toList();

      if (calls.isEmpty) {
        b.writeln('        // No mocks needed for ${repo.type}');
      } else if (remaining.isEmpty) {
        final allFromBuild = calls.every((c) =>
            plan.buildCallNames[repo.type]?.contains(c.methodName) ?? false);
        b.writeln(allFromBuild
            ? '        // ${repo.type} already stubbed in setUp() for build()'
            : '        // ${repo.type} already stubbed in setUp()');
      } else {
        for (final call in remaining) {
          _writeSuccessStub(
            b,
            '        ',
            'mock${repo.type}',
            call,
            plan.returnTypes['${repo.type}.${call.methodName}'],
          );
        }
      }
    }
  }

  /// Writes one success `when(...)` stub, choosing `thenAnswer`/`thenReturn`
  /// from the resolved [returnType]: answering a `Future` from a
  /// synchronous method is a runtime `TypeError`, and vice versa a sync
  /// value can't satisfy an awaited `Future`.
  void _writeSuccessStub(
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

  /// Derives the absolute path to the domain repository interface file,
  /// searching every feature folder on disk first — the dependency doesn't
  /// have to live in the consuming notifier's own feature.
  String _repositoryInterfacePath(RepositoryDep repo, NotifierInfo n) {
    final snakeCase = _toSnakeCase(repo.type);
    final featureName = _findActualFeatureFolder(snakeCase) ??
        _extractFeatureName(n.importPath);
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

  /// Extracts the base provider identifier from a captured provider
  /// expression, dropping `.notifier`/`.future` accessors and family call
  /// arguments alike (`chatProvider(roomId).notifier` → `chatProvider`) —
  /// `overrideWith`/`overrideWithValue` must be called on the base provider.
  String _baseProviderExpression(String expr) {
    final match =
        RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*').firstMatch(expr.trim());
    if (match != null) return match.group(0)!;
    return expr.replaceAll(RegExp(r'\.(notifier|future)\b'), '').trim();
  }

  /// Whether a captured provider expression carries family call arguments,
  /// e.g. `chatProvider(roomId)`.
  bool _hasCallArgs(String expr) =>
      RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*\s*\(').hasMatch(expr.trim());

  /// Whether mocktail's `any()` matcher needs `registerFallbackValue` for a
  /// parameter of this type. Mocktail ships fallbacks for primitives and
  /// core collections; nullable types fall back to `null` on their own.
  bool _needsFallbackRegistration(String rawType) {
    final type = rawType.trim();
    if (type.isEmpty || type.endsWith('?')) return false;
    const builtIn = {
      'String', 'int', 'double', 'num', 'bool', 'dynamic', 'Object', 'void',
    };
    if (builtIn.contains(type)) return false;
    final base = type.split('<').first.trim();
    if (const {'List', 'Map', 'Set', 'Iterable'}.contains(base)) return false;
    if (type.contains('Function') || type.contains('(')) return false;
    return true;
  }

  /// Builds the `Arrange: inputs` declaration for one method parameter,
  /// using `const` instead of `final` whenever the generated literal is
  /// guaranteed to be a compile-time constant (satisfies
  /// `prefer_const_declarations`). Types like `DateTime`, `Uri`, `Future`,
  /// and custom `.empty()` factories aren't guaranteed const-constructible,
  /// so those stay `final`.
  String _inputDeclarationLine(ParamInfo param) {
    final val = MockValueGenerator.forType(param.type);
    if (!_isConstCompatible(param.type)) {
      return 'final ${param.name} = $val;';
    }
    // Avoid a redundant nested `const` (e.g. `const foo = const [];`).
    final cleanedVal =
        val.startsWith('const ') ? val.substring('const '.length) : val;
    return 'const ${param.name} = $cleanedVal;';
  }

  bool _isConstCompatible(String rawType) {
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
      .where(
          (r) => r.providerExpression != null || _looksLikeMockableName(r.type))
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

  bool _isRepositorySuffix(String type) =>
      type.toLowerCase().endsWith('repository');

  /// Riverpod `Notifier`/`AsyncNotifier` (and Bloc/Cubit) dependencies need
  /// their provider substituted via `overrideWith(() => instance)`, since
  /// their provider exposes the notifier's *state*, not the notifier
  /// instance itself — `overrideWithValue` would try to assign the mock as
  /// if it were a state value and fail to compile.
  bool _isNotifierType(String type) {
    if (notifierRegistry.containsKey(type)) return true;
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

  /// Converts a class name to its conventional snake_case file name,
  /// handling acronym runs correctly (`APIClient` → `api_client`,
  /// `UserAPI` → `user_api`), which a per-capital split would mangle into
  /// `a_p_i_client`.
  String _toSnakeCase(String name) => name
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

/// The result of the generator's single up-front analysis pass over one
/// notifier: which dependencies exist, what every method calls on them,
/// resolved signatures, what gets hoisted into `setUp()`, which mocktail
/// fallback values are needed, and which extra imports the stub values pull
/// in.
class _Plan {
  const _Plan({
    required this.dependencies,
    required this.publicMethods,
    required this.callsByMethod,
    required this.returnTypes,
    required this.hoistedCalls,
    required this.buildCallNames,
    required this.fallbackTypes,
    required this.extraImports,
  });

  /// Dependencies worth mocking.
  final List<RepositoryDep> dependencies;

  /// Public notifier methods that receive test groups (build excluded).
  final List<MethodInfo> publicMethods;

  /// notifier method name (including `build`) → dependency type → calls.
  final Map<String, Map<String, List<RepositoryMethodCall>>> callsByMethod;

  /// `'<DepType>.<callName>'` → resolved declared return type (or null).
  final Map<String, String?> returnTypes;

  /// Dependency type → calls stubbed once at the end of `setUp()`
  /// (build()'s calls + calls shared by ≥2 public methods).
  final Map<String, List<RepositoryMethodCall>> hoistedCalls;

  /// Dependency type → the subset of hoisted call names that came from
  /// `build()` (used to word the dedup comment precisely).
  final Map<String, Set<String>> buildCallNames;

  /// Custom types that need `registerFallbackValue` in `setUpAll()`.
  final List<String> fallbackTypes;

  /// Import lines required by stub values, fallback registrations, family
  /// arguments and mocked notifier dependency states.
  final Set<String> extraImports;
}
