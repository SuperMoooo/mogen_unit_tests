// lib/src/generators/test_generator.dart

import 'package:dart_style/dart_style.dart';

import '../models/notifier_info.dart';
import '../utils/method_call_detector.dart';
import '../utils/mock_value_generator.dart';
import 'bloc_test_generator.dart';
import 'generator_support.dart';

/// Generates a complete Mocktail + Riverpod test file for one [NotifierInfo].
///
/// Import strategy
/// ───────────────
/// Rather than importing a hard-coded entity file, the generator does a
/// first pass over every stubbed dependency call, resolves each method's
/// declared signature from its source, extracts the leaf custom types
/// (unwrapping `Future<T>`/`FutureOr<T>` and `List<T>`), locates the
/// defining file on disk (searching every feature's entity/model/state
/// folders — a dependency's types don't have to live in the consuming
/// notifier's own feature) and emits a targeted import.  Primitives and
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
/// Riverpod notifier dependencies get special treatment: a bare
/// `extends Mock implements OtherNotifier` cannot satisfy the container's
/// library-private wiring (`_setElement`, ...) and dies with
/// `MissingStubError` the moment the provider is read. When the dependency
/// is a notifier the project scan parsed (available via [notifierRegistry]),
/// the mock instead *extends the real base class* and mixes `Mock` in:
///
/// ```dart
/// class MockOtherNotifier extends AsyncNotifier<OtherState>
///     with Mock implements OtherNotifier {}
/// ```
///
/// and its `build()` is stubbed in `setUp()`, so code under test that does
/// `await ref.read(otherNotifierProvider.future)` resolves instead of
/// crashing.
///
/// Stub return value strategy
/// ──────────────────────────
/// ```
/// void / Future<void>       → null
/// nullable T?               → null
/// primitive                 → literal  ('', 0, false, …)
/// List<CustomType>          → [CustomType.empty()]
/// List<primitive>           → []
/// CustomType                → CustomType.empty()
/// ```
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
    this.eventRegistry = const {},
  })  : _importResolver = ImportResolver(
          projectRoot: projectRoot,
          notifierIndex: notifierIndex,
        ),
        _blocGenerator = BlocTestGenerator(
          projectRoot: projectRoot,
          notifierIndex: notifierIndex,
          notifierRegistry: notifierRegistry,
          eventRegistry: eventRegistry,
        );

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

  /// Event class name → parsed event class, for every bloc event found in the
  /// project. Only used when delegating a bloc to [BlocTestGenerator].
  final Map<String, EventClassInfo> eventRegistry;

  final ImportResolver _importResolver;
  final BlocTestGenerator _blocGenerator;

  final _fmt =
      DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);

  /// Generates a test file for the provided [notifier].
  ///
  /// `flutter_bloc` blocs and cubits are handed to [BlocTestGenerator], which
  /// emits `bloc_test` scaffolding instead of Riverpod `ProviderContainer`
  /// scaffolding.
  String generate(NotifierInfo notifier) {
    if (!notifier.isRiverpod) return _blocGenerator.generate(notifier);

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
          fieldName: repo.name,
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
          usageCount[call.methodName] = (usageCount[call.methodName] ?? 0) + 1;
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

  List<String> _resolveDependencyImports(RepositoryDep repo, NotifierInfo n) =>
      _importResolver.dependencyImports(repo, n);

  String _typeImport(String typeName, NotifierInfo n) =>
      _importResolver.typeImport(typeName, n);

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
          b.writeln('          $provider.overrideWithValue(mock${repo.type}),');
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
      b.writeln('      // reading them (or awaiting their .future) resolves.');
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

    b.writeln("      test('${method.name} completes successfully', () async {");

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

  void _writeSuccessStub(
    StringBuffer b,
    String indent,
    String mockName,
    RepositoryMethodCall call,
    String? returnType,
  ) =>
      StubWriter.writeSuccessStub(b, indent, mockName, call, returnType);

  String _repositoryInterfacePath(RepositoryDep repo, NotifierInfo n) =>
      _importResolver.repositoryInterfacePath(repo, n);

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
    final match = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*').firstMatch(expr.trim());
    if (match != null) return match.group(0)!;
    return expr.replaceAll(RegExp(r'\.(notifier|future)\b'), '').trim();
  }

  /// Whether a captured provider expression carries family call arguments,
  /// e.g. `chatProvider(roomId)`.
  bool _hasCallArgs(String expr) =>
      RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*\s*\(').hasMatch(expr.trim());

  bool _needsFallbackRegistration(String rawType) =>
      StubWriter.needsFallbackRegistration(rawType);

  String _inputDeclarationLine(ParamInfo param) =>
      StubWriter.inputDeclarationLine(param);

  List<RepositoryDep> _mockableDependencies(NotifierInfo n) =>
      DependencySelector.mockable(n);

  bool _isRepositorySuffix(String type) =>
      ImportResolver.isRepositorySuffix(type);

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
