// lib/src/generators/bloc_test_generator.dart

import 'package:dart_style/dart_style.dart';

import '../models/notifier_info.dart';
import '../utils/method_call_detector.dart';
import '../utils/mock_value_generator.dart';
import 'generator_support.dart';

/// Generates a complete `bloc_test` + Mocktail test file for one
/// `flutter_bloc` [NotifierInfo] — a `Bloc<Event, State>` or a
/// `Cubit<State>`.
///
/// What drives a test
/// ──────────────────
/// A bloc is exercised by *adding events*, not by calling methods, so every
/// `on<Event>(...)` registration the parser found becomes a test group whose
/// `act:` adds a real instance of that event. A cubit has no events, so its
/// public methods play that role instead.
///
/// Dependency mocking strategy
/// ───────────────────────────
/// Constructor injection is the bloc DI seam, so every collaborator the
/// constructor takes is mocked and passed into `build:`:
///
/// ```dart
/// AuthBloc buildAuthBloc() => AuthBloc(mockAuthRepository);
/// ```
///
/// A dependency that is itself a bloc or cubit gets `bloc_test`'s own
/// `MockBloc`/`MockCubit` base rather than a bare `Mock`: a plain mock has no
/// state stream, so the first `state` read or `stream` listen inside the class
/// under test would blow up.
///
/// Assertion strategy
/// ──────────────────
/// What the action does to the state is read off its own `emit(...)` calls:
///
/// - a state class with the conventional fields (`isLoading`, `error`,
///   `success`) is asserted field by field, exactly as on the Riverpod side;
/// - a sealed state hierarchy has no such fields on its base class, so the
///   settled state is asserted *by type* instead — `emit(AuthSuccess(...))`
///   becomes `expect(bloc.state, isA<AuthSuccess>())`, and the emit inside the
///   handler's `catch` becomes the error test's assertion.
///
/// Only the state *sequence* stays commented out: emits guarded by an `if`, or
/// made in a loop, don't run as many times as they appear in source, and a
/// wrong `expect:` list fails every run. The comment is still the real
/// sequence, ready to uncomment once the guards are checked.
class BlocTestGenerator {
  /// Creates a generator. [projectRoot] is needed to locate dependency source
  /// files for signature resolution, [notifierIndex] maps every logic class in
  /// the project to its import path, [notifierRegistry] carries their parsed
  /// info (so a bloc dependency can be mocked with `MockBloc`), and
  /// [eventRegistry] carries the event classes so `act:` can construct one.
  BlocTestGenerator({
    required this.projectRoot,
    this.notifierIndex = const {},
    this.notifierRegistry = const {},
    this.eventRegistry = const {},
  }) : _resolver = ImportResolver(
          projectRoot: projectRoot,
          notifierIndex: notifierIndex,
        );

  /// Absolute path to the Flutter project root.
  final String projectRoot;

  /// Logic class name → `package:` import path.
  final Map<String, String> notifierIndex;

  /// Logic class name → full parsed info.
  final Map<String, NotifierInfo> notifierRegistry;

  /// Event class name → parsed event class.
  final Map<String, EventClassInfo> eventRegistry;

  final ImportResolver _resolver;

  final _fmt =
      DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);

  /// Generates a `bloc_test` file for the provided bloc or cubit.
  String generate(NotifierInfo n) {
    final plan = _buildPlan(n);

    // The body is generated first so the import block knows whether the error
    // scaffold actually used `AppException.test()`.
    final bodyBuf = StringBuffer();
    _mocks(bodyBuf, n, plan);
    _mainBlock(bodyBuf, n, plan);
    final body = bodyBuf.toString();

    final buf = StringBuffer();
    _imports(
      buf,
      n,
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

  // ── Plan ─────────────────────────────────────────────────────────────────

  _BlocPlan _buildPlan(NotifierInfo n) {
    final dependencies = DependencySelector.mockable(n);
    final actions = _actions(n);

    final callsByAction = <String, Map<String, List<RepositoryMethodCall>>>{};
    for (final action in actions) {
      final perDep = <String, List<RepositoryMethodCall>>{};
      for (final dep in dependencies) {
        perDep[dep.type] = action.isEvent
            ? MethodCallDetector.detectEventHandlerCalls(
                n.sourceFilePath,
                dep.type,
                eventType: action.name,
                fieldName: dep.name,
              )
            : MethodCallDetector.detectRepositoryMethodCalls(
                n.sourceFilePath,
                dep.type,
                methodName: action.name,
                fieldName: dep.name,
              );
      }
      callsByAction[action.name] = perDep;
    }

    // Work started in the constructor runs for every test, so it is stubbed
    // once in setUp() instead of in each blocTest's own setUp:.
    final constructorCalls = <String, List<RepositoryMethodCall>>{};
    for (final dep in dependencies) {
      final calls = MethodCallDetector.detectConstructorCalls(
        n.sourceFilePath,
        dep.type,
        fieldName: dep.name,
      );
      if (calls.isNotEmpty) constructorCalls[dep.type] = calls;
    }

    final returnTypes = <String, String?>{};
    final fallbackTypes = <String>[];
    final imports = <String>{};

    void addFallback(String rawType) {
      final type = rawType.trim();
      if (!StubWriter.needsFallbackRegistration(type)) return;
      if (fallbackTypes.contains(type)) return;
      fallbackTypes.add(type);
      final base = type.split('<').first.trim();
      if (!MockValueGenerator.isPrimitive(base)) {
        imports.add(_resolver.typeImport(base, n));
      }
    }

    void resolveCall(RepositoryDep dep, RepositoryMethodCall call) {
      final key = '${dep.type}.${call.methodName}';
      if (returnTypes.containsKey(key)) return;

      final sig = _resolveCallSignature(dep, call.methodName, n);
      returnTypes[key] = sig?.returnType;

      final returnType = sig?.returnType;
      if (returnType != null) {
        final customType = MockValueGenerator.extractCustomType(returnType);
        if (customType != null) {
          imports.add(_resolver.typeImport(customType, n));
        }
      }
      for (final paramType in sig?.paramTypes ?? const <String>[]) {
        addFallback(paramType);
      }
    }

    for (final action in actions) {
      for (final dep in dependencies) {
        for (final call in callsByAction[action.name]![dep.type] ??
            const <RepositoryMethodCall>[]) {
          resolveCall(dep, call);
        }
      }
      // Event arguments and cubit method parameters may need imports too.
      for (final param in action.params) {
        final leaf = MockValueGenerator.extractCustomType(param.type);
        if (leaf != null) imports.add(_resolver.typeImport(leaf, n));
      }

      // A state class asserted by type (`isA<AuthSuccess>()`) has to be in
      // scope. Sealed state subclasses usually live in the bloc's own library,
      // which the bloc import already covers — the registry says which.
      for (final type in [
        _successStateType(action, n),
        _errorStateType(action, n),
      ]) {
        if (type == null) continue;
        final declared = eventRegistry[type];
        if (declared == null || declared.isPart) continue;
        if (declared.importPath == n.importPath) continue;
        imports.add("import '${declared.importPath}';");
      }
    }
    for (final dep in dependencies) {
      for (final call
          in constructorCalls[dep.type] ?? const <RepositoryMethodCall>[]) {
        resolveCall(dep, call);
      }
    }

    // A mocked bloc/cubit dependency needs its `state` stubbed, which pulls
    // in that bloc's state type.
    for (final dep in dependencies) {
      final depInfo = notifierRegistry[dep.type];
      if (depInfo == null || depInfo.isRiverpod) continue;
      final leaf =
          MockValueGenerator.extractCustomType(depInfo.stateType ?? '');
      if (leaf == null) continue;
      final stateImport = depInfo.stateInfo;
      imports.add(stateImport != null && !stateImport.isPart
          ? "import '${stateImport.importPath}';"
          : _resolver.typeImport(leaf, n));
    }

    // Constructor arguments that aren't mocks (plain configuration values,
    // an injected initial state, ...) still have to be constructed.
    for (final param in n.constructorParams) {
      if (dependencies.any((d) => d.type == param.type.replaceAll('?', ''))) {
        continue;
      }
      final leaf = MockValueGenerator.extractCustomType(param.type);
      if (leaf != null) imports.add(_resolver.typeImport(leaf, n));
    }

    return _BlocPlan(
      dependencies: dependencies,
      actions: actions,
      callsByAction: callsByAction,
      constructorCalls: constructorCalls,
      returnTypes: returnTypes,
      fallbackTypes: fallbackTypes,
      extraImports: imports,
    );
  }

  /// The things a generated test drives: a bloc's registered events, or a
  /// cubit's public methods.
  List<_BlocAction> _actions(NotifierInfo n) {
    if (n.isBloc) {
      return n.events
          .map((e) => _BlocAction(
                name: e.type,
                isEvent: true,
                bodySource: e.handlerBodySource,
                params: eventRegistry[e.type]?.params ?? const [],
                emits: MethodCallDetector.detectEmittedStates(
                  n.sourceFilePath,
                  eventType: e.type,
                ),
              ))
          .toList();
    }

    return n.methods
        .where((m) => !_isInternalHelper(m.name))
        .map((m) => _BlocAction(
              name: m.name,
              isEvent: false,
              bodySource: m.bodySource,
              params: m.params,
              method: m,
              emits: MethodCallDetector.detectEmittedStates(
                n.sourceFilePath,
                methodName: m.name,
              ),
            ))
        .toList();
  }

  /// The state class the action emits on its happy path, when that class is
  /// something more specific than the declared state type — the sealed-state
  /// shape (`emit(AuthSuccess(...))`), where asserting the base type would be
  /// trivially true.
  String? _successStateType(_BlocAction action, NotifierInfo n) =>
      _lastEmittedType(action, n, inCatch: false);

  /// The state class the action emits from its `catch` block.
  String? _errorStateType(_BlocAction action, NotifierInfo n) =>
      _lastEmittedType(action, n, inCatch: true);

  String? _lastEmittedType(
    _BlocAction action,
    NotifierInfo n, {
    required bool inCatch,
  }) {
    String? found;
    for (final emit in action.emits) {
      if (emit.inCatch != inCatch) continue;
      final type = emit.typeName;
      if (type == null || type == n.stateType) continue;
      // The settled state is whatever was emitted last on that path.
      found = type;
    }
    return found;
  }

  /// Resolves the declared signature of a dependency method. Repository
  /// interfaces are parsed from their conventional source location; a bloc or
  /// cubit dependency comes from the project-wide registry.
  MethodSignature? _resolveCallSignature(
      RepositoryDep dep, String callName, NotifierInfo n) {
    if (ImportResolver.isRepositorySuffix(dep.type)) {
      return MethodCallDetector.resolveMethodSignature(
        _resolver.repositoryInterfacePath(dep, n),
        callName,
      );
    }

    final depInfo = notifierRegistry[dep.type];
    if (depInfo != null) {
      for (final m in depInfo.methods) {
        if (m.name != callName) continue;
        return MethodSignature(
          returnType: m.returnType,
          paramTypes: m.params.map((param) => param.type).toList(),
        );
      }
    }

    return null;
  }

  // ── Imports ──────────────────────────────────────────────────────────────

  void _imports(
    StringBuffer b,
    NotifierInfo n,
    _BlocPlan plan, {
    required bool needsAppException,
  }) {
    b.writeln('// GENERATED BY mogen_unit_tests — YOU CAN REMOVE THIS COMMENT');
    b.writeln();
    b.writeln("import 'package:bloc_test/bloc_test.dart';");
    b.writeln("import 'package:flutter_test/flutter_test.dart';");
    b.writeln("import 'package:mocktail/mocktail.dart';");
    if (needsAppException) {
      b.writeln(
          "import 'package:${n.packageName}/core/errors/app_exception.dart';");
    }
    b.writeln();

    final lines = <String>{};

    // The bloc/cubit itself. In the conventional bloc layout the state and
    // the events are `part`s of this same file, so this single import already
    // brings them in.
    lines.add("import '${n.importPath}';");

    final stateInfo = n.stateInfo;
    if (stateInfo != null &&
        !stateInfo.isPart &&
        stateInfo.importPath != n.importPath) {
      lines.add("import '${stateInfo.importPath}';");
    }

    for (final action in plan.actions.where((a) => a.isEvent)) {
      final event = eventRegistry[action.name];
      if (event == null || event.isPart) continue;
      if (event.importPath == n.importPath) continue;
      lines.add("import '${event.importPath}';");
    }

    for (final dep in plan.dependencies) {
      lines.addAll(_resolver.dependencyImports(dep, n));
    }

    lines.addAll(plan.extraImports);

    for (final line in lines) {
      b.writeln(line);
    }
    b.writeln();
  }

  // ── Mock classes ─────────────────────────────────────────────────────────

  void _mocks(StringBuffer b, NotifierInfo n, _BlocPlan plan) {
    if (plan.dependencies.isEmpty) return;

    b.writeln(
        '// ── Mocks ────────────────────────────────────────────────────');
    for (final dep in plan.dependencies) {
      final depInfo = notifierRegistry[dep.type];

      // bloc_test ships mock bases that keep the state stream alive; a bare
      // `Mock` has none, so the first `state` read inside the class under
      // test would throw instead of returning a state.
      if (depInfo != null && depInfo.isBloc) {
        final event = depInfo.eventBaseType ?? 'dynamic';
        final state = depInfo.stateType ?? 'dynamic';
        b.writeln('class Mock${dep.type} extends MockBloc<$event, $state> '
            'implements ${dep.type} {}');
      } else if (depInfo != null && depInfo.isCubit) {
        final state = depInfo.stateType ?? 'dynamic';
        b.writeln('class Mock${dep.type} extends MockCubit<$state> '
            'implements ${dep.type} {}');
      } else {
        b.writeln(
            'class Mock${dep.type} extends Mock implements ${dep.type} {}');
      }
    }
    b.writeln();
  }

  // ── main() ───────────────────────────────────────────────────────────────

  void _mainBlock(StringBuffer b, NotifierInfo n, _BlocPlan plan) {
    b.writeln('void main() {\n');
    b.write('TestWidgetsFlutterBinding.ensureInitialized();\n\n');
    _group(b, n, plan);
    b.writeln('}');
  }

  void _group(StringBuffer b, NotifierInfo n, _BlocPlan plan) {
    b.writeln("  group('${n.className}', () {");

    for (final dep in plan.dependencies) {
      b.writeln('    late Mock${dep.type} mock${dep.type};');
    }
    b.writeln();

    _setUpAll(b, plan);
    _setUp(b, n, plan);
    _buildHelper(b, n, plan);
    _initialStateTest(b, n);

    for (final action in plan.actions) {
      _actionTests(b, action, n, plan);
    }

    b.writeln('  });');
  }

  void _setUpAll(StringBuffer b, _BlocPlan plan) {
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

  void _setUp(StringBuffer b, NotifierInfo n, _BlocPlan plan) {
    b.writeln('    setUp(() {');

    for (final dep in plan.dependencies) {
      b.writeln('      mock${dep.type} = Mock${dep.type}();');
    }

    final blocDeps = plan.dependencies
        .where((d) => notifierRegistry[d.type]?.isRiverpod == false)
        .toList();
    if (blocDeps.isNotEmpty) {
      b.writeln();
      b.writeln('      // Arrange: a mocked bloc/cubit starts with no state —');
      b.writeln('      // stub it so reading it from the class under test');
      b.writeln('      // returns a real value.');
      for (final dep in blocDeps) {
        final depInfo = notifierRegistry[dep.type]!;
        final stateVal =
            MockValueGenerator.forReturnType(depInfo.stateType ?? 'dynamic');
        b.writeln('      when(() => mock${dep.type}.state)');
        b.writeln('          .thenReturn($stateVal);');
      }
    }

    if (plan.constructorCalls.isNotEmpty) {
      b.writeln();
      b.writeln(
          '      // Arrange: stub the dependency calls ${n.className}\'s own');
      b.writeln(
          '      // constructor makes — they run in every test, not just one.');
      for (final dep in plan.dependencies) {
        final calls = plan.constructorCalls[dep.type];
        if (calls == null) continue;
        for (final call in calls) {
          StubWriter.writeSuccessStub(
            b,
            '      ',
            'mock${dep.type}',
            call,
            plan.returnTypes['${dep.type}.${call.methodName}'],
          );
        }
      }
    }

    b.writeln('    });');
    b.writeln();
  }

  /// Emits the factory every `blocTest` passes as `build:`.
  void _buildHelper(StringBuffer b, NotifierInfo n, _BlocPlan plan) {
    b.writeln(
        '    // The class under test, wired with the mocked dependencies.');
    b.writeln(
        '    ${n.className} ${_buildFnName(n)}() => ${n.className}(${_constructorArgs(n, plan)});');
    b.writeln();
  }

  String _buildFnName(NotifierInfo n) => 'build${n.className}';

  /// Builds the constructor call for the class under test, substituting a
  /// mock for every injected collaborator and a generated literal for the
  /// remaining plain-data parameters.
  String _constructorArgs(NotifierInfo n, _BlocPlan plan) {
    final args = <String>[];
    for (final param in n.constructorParams) {
      final type = param.type.replaceAll('?', '').trim();
      final isMocked = plan.dependencies.any((d) => d.type == type);
      final value = isMocked ? 'mock$type' : MockValueGenerator.forType(type);
      // A private field-formal (`this._repo`) can only ever be positional.
      args.add(param.isNamed ? '${param.name}: $value' : value);
    }
    return args.join(', ');
  }

  void _initialStateTest(StringBuffer b, NotifierInfo n) {
    final stateType = n.stateType;
    if (stateType == null || stateType == 'dynamic') return;

    final sut = _actParam(n);
    // `super(SearchInitial())` names the starting state, which makes this a
    // real assertion instead of the tautology `isA<SearchState>()` would be.
    final initial =
        MethodCallDetector.detectInitialState(n.sourceFilePath) ?? stateType;

    b.writeln("    test('starts in a valid initial state', () async {");
    b.writeln('      final $sut = ${_buildFnName(n)}();');
    b.writeln('      expect($sut.state, isA<$initial>());');
    b.writeln('      await $sut.close();');
    b.writeln('    });');
    b.writeln();
  }

  // ── per-action tests ─────────────────────────────────────────────────────

  void _actionTests(
    StringBuffer b,
    _BlocAction action,
    NotifierInfo n,
    _BlocPlan plan,
  ) {
    b.writeln(
        '    // ── ${action.name} ──────────────────────────────────────');
    b.writeln("    group('${action.name}', () {");

    _successTest(b, action, n, plan);

    final hasDependencyCalls = plan.dependencies.any((dep) =>
        (plan.callsByAction[action.name]![dep.type] ??
                const <RepositoryMethodCall>[])
            .isNotEmpty);

    if (_actionOwnCalls(action, plan).isNotEmpty) {
      _errorTest(b, action, n, plan);
    } else if (hasDependencyCalls) {
      // Every call this action makes is also made by the constructor, and
      // `build:` runs after `setUp:` — a throwing stub would blow up while
      // constructing the bloc rather than while handling the action.
      b.writeln('      // No error-path test: every dependency call '
          '${action.name} makes is');
      b.writeln('      // also made by the constructor, so failing it would '
          'break build()');
      b.writeln('      // instead of the action itself.');
    } else {
      b.writeln(
          '      // No error-path test: ${action.name} makes no dependency');
      b.writeln('      // calls, so there is no failure to simulate.');
    }

    b.writeln('    });');
    b.writeln();
  }

  void _successTest(
    StringBuffer b,
    _BlocAction action,
    NotifierInfo n,
    _BlocPlan plan,
  ) {
    b.writeln('      blocTest<${n.className}, ${n.stateType ?? 'dynamic'}>(');
    b.writeln("        '${action.name} completes successfully',");

    _writeStubSetUp(b, action, n, plan, throwing: false);

    b.writeln('        build: ${_buildFnName(n)},');
    b.writeln(
        '        act: (${_actParam(n)}) => ${_actExpression(action, n)},');
    _writeExpectScaffold(b, action, n);
    b.writeln('        verify: (${_actParam(n)}) {');
    _writeCallVerifications(b, action, plan);
    _writeStateAssertions(b, n, action, expectSuccess: true);
    b.writeln('        },');
    b.writeln('      );');
    b.writeln();
  }

  void _errorTest(
    StringBuffer b,
    _BlocAction action,
    NotifierInfo n,
    _BlocPlan plan,
  ) {
    b.writeln('      blocTest<${n.className}, ${n.stateType ?? 'dynamic'}>(');
    b.writeln(
        "        '${action.name} surfaces an error when a dependency fails',");

    _writeStubSetUp(b, action, n, plan, throwing: true);

    b.writeln('        build: ${_buildFnName(n)},');
    b.writeln(
        '        act: (${_actParam(n)}) => ${_actExpression(action, n)},');

    if (_catchesErrors(action)) {
      b.writeln('        verify: (${_actParam(n)}) {');
      _writeStateAssertions(b, n, action, expectSuccess: false);
      b.writeln('        },');
    } else {
      // Nothing catches the failure, so it never becomes state — it escapes
      // the handler and bloc reports it through `addError`. Asserting a state
      // field here would fail every run; `errors:` is what actually holds.
      b.writeln(
          '        // ${action.name} does not catch the failure, so it escapes to');
      b.writeln(
          '        // the bloc\'s error handler instead of becoming state.');
      b.writeln('        errors: () => [isA<AppException>()],');
    }

    b.writeln('      );');
    b.writeln();
  }

  /// Whether the action's body converts a thrown error into state.
  ///
  /// An unknown body (nothing captured) gets the benefit of the doubt, the
  /// same convention the Riverpod generator uses for its heuristics.
  bool _catchesErrors(_BlocAction action) {
    // An emit from inside a `catch` is proof, not a guess.
    if (action.emits.any((e) => e.inCatch)) return true;
    final body = action.bodySource;
    if (body == null) return true;
    return body.contains('catch') || body.contains('onError');
  }

  /// Writes the commented `expect:` scaffold for the success path.
  ///
  /// When the handler's emits name concrete state classes, the comment is the
  /// real sequence, ready to uncomment. It stays commented on purpose: emits
  /// guarded by an `if`, or made in a loop, don't happen the number of times
  /// they appear in source, and a wrong `expect:` list fails every single run
  /// — whereas the settled-state assertion in `verify:` holds either way.
  void _writeExpectScaffold(
    StringBuffer b,
    _BlocAction action,
    NotifierInfo n,
  ) {
    final sequence = action.emits
        .where((e) => !e.inCatch)
        .map((e) => e.typeName ?? n.stateType ?? 'Object')
        .toList();
    final namesAConcreteType = action.emits
        .any((e) => e.typeName != null && e.typeName != n.stateType);

    b.writeln(
        '        // Uncomment to assert the exact sequence of emitted states');
    b.writeln(
        '        // (check the guards first — a conditional emit doesn\'t '
        'always run):');
    if (sequence.isEmpty || !namesAConcreteType) {
      b.writeln('        // expect: () => [isA<'
          '${n.stateType ?? 'Object'}>()],');
      return;
    }
    final matchers = sequence.map((type) => 'isA<$type>()').join(', ');
    b.writeln('        // expect: () => [$matchers],');
  }

  /// The calls an action makes that the constructor doesn't already make.
  ///
  /// Constructor calls are stubbed once in `setUp()`, and — crucially for the
  /// error path — re-stubbing them to throw would fail inside `build:`, since
  /// `blocTest` builds the bloc *after* running its `setUp:`.
  List<(RepositoryDep, RepositoryMethodCall)> _actionOwnCalls(
    _BlocAction action,
    _BlocPlan plan,
  ) {
    final entries = <(RepositoryDep, RepositoryMethodCall)>[];
    for (final dep in plan.dependencies) {
      final calls = plan.callsByAction[action.name]![dep.type] ??
          const <RepositoryMethodCall>[];
      final fromConstructor =
          (plan.constructorCalls[dep.type] ?? const <RepositoryMethodCall>[])
              .map((c) => c.methodName)
              .toSet();
      for (final call in calls) {
        if (fromConstructor.contains(call.methodName)) continue;
        entries.add((dep, call));
      }
    }
    return entries;
  }

  /// Writes the `setUp:` closure of one `blocTest`, stubbing every dependency
  /// call the action performs — with a success value, or with a throw for the
  /// error path.
  void _writeStubSetUp(
    StringBuffer b,
    _BlocAction action,
    NotifierInfo n,
    _BlocPlan plan, {
    required bool throwing,
  }) {
    final entries = _actionOwnCalls(action, plan);
    if (entries.isEmpty) return;

    b.writeln('        setUp: () {');
    if (throwing) {
      b.writeln('          // Make every dependency call this action performs');
      b.writeln('          // fail, replacing the stubs from setUp().');
    }
    for (final (dep, call) in entries) {
      if (throwing) {
        b.writeln(
            '          when(() => mock${dep.type}.${call.invocationSource})');
        b.writeln('              .thenThrow(AppException.test());');
      } else {
        StubWriter.writeSuccessStub(
          b,
          '          ',
          'mock${dep.type}',
          call,
          plan.returnTypes['${dep.type}.${call.methodName}'],
        );
      }
    }
    b.writeln('        },');
  }

  void _writeCallVerifications(
    StringBuffer b,
    _BlocAction action,
    _BlocPlan plan,
  ) {
    for (final dep in plan.dependencies) {
      final calls = plan.callsByAction[action.name]![dep.type] ??
          const <RepositoryMethodCall>[];
      for (final call in calls) {
        // `called(1)` would fail for a call made inside a loop or a retry, so
        // the assertion is only that the collaborator was reached at all.
        b.writeln(
            '          verify(() => mock${dep.type}.${call.invocationSource})');
        b.writeln('              .called(greaterThanOrEqualTo(1));');
      }
    }
  }

  /// Asserts the settled state.
  ///
  /// Both state shapes are handled, and they are not alternatives — a project
  /// can use either, or both at once:
  ///
  /// - **subtype**: the action emits a dedicated class (`emit(AuthSuccess(…))`,
  ///   `emit(AuthFailure(…))`), asserted as
  ///   `expect(bloc.state, isA&lt;AuthSuccess&gt;())`;
  /// - **fields**: the state is one class carrying `isLoading`/`error`/
  ///   `success`, asserted field by field, exactly as on the Riverpod side.
  ///
  /// A state that does both — a sealed base declaring shared fields, with the
  /// action emitting a subtype — gets both assertions. Only fields declared on
  /// the *matched* state class are read, since `bloc.state.error` doesn't
  /// compile when `error` only exists on one subclass.
  void _writeStateAssertions(
    StringBuffer b,
    NotifierInfo n,
    _BlocAction action, {
    required bool expectSuccess,
  }) {
    final sut = _actParam(n);

    // The shape first: which state class the action settled on.
    final emittedType = expectSuccess
        ? _successStateType(action, n)
        : _errorStateType(action, n);
    if (emittedType != null) {
      b.writeln('          expect($sut.state, isA<$emittedType>());');
    }

    final stateInfo = _fieldBearingState(n);
    if (stateInfo == null) {
      if (emittedType == null) {
        _writeStateTodo(b, n, sut);
      }
      return;
    }

    const loadingFields = ['isLoadingAction', 'isLoading', 'loading'];
    const errorFields = ['error', 'errorMessage', 'errorMsg'];
    const successFields = ['success', 'successMessage', 'message'];

    final names = stateInfo.fields.map((f) => f.name).toSet();
    var asserted = emittedType != null;

    for (final field in loadingFields) {
      if (!names.contains(field)) continue;
      b.writeln('          expect($sut.state.$field, isFalse);');
      asserted = true;
      break;
    }

    for (final field in errorFields) {
      if (!names.contains(field)) continue;
      b.writeln(
          '          expect($sut.state.$field, ${expectSuccess ? 'isNull' : 'isNotNull'});');
      asserted = true;
      break;
    }

    for (final field in successFields) {
      if (!names.contains(field)) continue;
      // Only assert a success message appears when the handler body actually
      // mentions the field — plenty of actions legitimately never set one.
      if (expectSuccess && !_mentions(action, field)) break;
      b.writeln(
          '          expect($sut.state.$field, ${expectSuccess ? 'isNotNull' : 'isNull'});');
      asserted = true;
      break;
    }

    if (!asserted) {
      _writeStateTodo(b, n, sut);
    }
  }

  /// The matched state class, but only when its fields can be read off
  /// `bloc.state` — that is, when it really is the bloc's declared state type.
  ///
  /// State matching falls back to a name-prefix search, which in a sealed
  /// hierarchy can land on a *subclass* (`AuthSuccessState` for an `AuthBloc`).
  /// Its fields belong to that subclass alone, so asserting them on
  /// `bloc.state` — statically the base type — would not compile.
  StateInfo? _fieldBearingState(NotifierInfo n) {
    final stateInfo = n.stateInfo;
    if (stateInfo == null || stateInfo.fields.isEmpty) return null;
    if (n.stateType != null && stateInfo.className != n.stateType) return null;
    return stateInfo;
  }

  void _writeStateTodo(StringBuffer b, NotifierInfo n, String sut) {
    b.writeln(
        '          // TODO(mogen_unit_tests): assert the resulting state, e.g.');
    b.writeln(
        '          // expect($sut.state, isA<${n.stateType ?? 'Object'}>());');
  }

  bool _mentions(_BlocAction action, String identifier) {
    final body = action.bodySource;
    if (body == null) return true;
    return body.contains(identifier);
  }

  // ── act ──────────────────────────────────────────────────────────────────

  String _actParam(NotifierInfo n) => n.isBloc ? 'bloc' : 'cubit';

  /// The expression a `blocTest` acts with: adding the event for a bloc, or
  /// calling the method for a cubit.
  String _actExpression(_BlocAction action, NotifierInfo n) {
    if (action.isEvent) {
      return 'bloc.add(${action.name}(${_eventArgs(action)}))';
    }
    final args = action.params
        .map((p) => p.isNamed
            ? '${p.name}: ${MockValueGenerator.forType(p.type)}'
            : MockValueGenerator.forType(p.type))
        .join(', ');
    return 'cubit.${action.name}($args)';
  }

  /// Builds the argument list for an event constructor, skipping named
  /// parameters that already declare a default.
  String _eventArgs(_BlocAction action) => action.params
      .where((p) => !(p.isNamed && p.defaultValue != null))
      .map((p) => p.isNamed
          ? '${p.name}: ${MockValueGenerator.forType(p.type)}'
          : MockValueGenerator.forType(p.type))
      .join(', ');

  /// Matches internal helper methods following the `pXxx` naming convention
  /// (e.g. `pOnSuccess`), without excluding real public methods that merely
  /// start with a lowercase `p` (`parse`, `publish`, `pay`, ...).
  bool _isInternalHelper(String name) => RegExp(r'^p[A-Z]').hasMatch(name);
}

/// One thing a generated bloc test drives: an event added to a bloc, or a
/// public method called on a cubit.
class _BlocAction {
  const _BlocAction({
    required this.name,
    required this.isEvent,
    this.bodySource,
    this.params = const [],
    this.method,
    this.emits = const [],
  });

  /// The event class name, or the cubit method name.
  final String name;

  /// Whether this action is a bloc event (as opposed to a cubit method).
  final bool isEvent;

  /// The handler / method body source, when captured.
  final String? bodySource;

  /// The event constructor parameters, or the cubit method parameters.
  final List<ParamInfo> params;

  /// The cubit method behind this action, when [isEvent] is `false`.
  final MethodInfo? method;

  /// The states this action emits, in source order.
  final List<EmittedState> emits;
}

/// The result of the generator's up-front analysis pass over one bloc/cubit.
class _BlocPlan {
  const _BlocPlan({
    required this.dependencies,
    required this.actions,
    required this.callsByAction,
    required this.constructorCalls,
    required this.returnTypes,
    required this.fallbackTypes,
    required this.extraImports,
  });

  /// Dependencies worth mocking.
  final List<RepositoryDep> dependencies;

  /// Events (bloc) or public methods (cubit) that receive test groups.
  final List<_BlocAction> actions;

  /// action name → dependency type → detected calls.
  final Map<String, Map<String, List<RepositoryMethodCall>>> callsByAction;

  /// Dependency type → calls made directly by the constructor, stubbed once
  /// in `setUp()`.
  final Map<String, List<RepositoryMethodCall>> constructorCalls;

  /// `'<DepType>.<callName>'` → resolved declared return type (or null).
  final Map<String, String?> returnTypes;

  /// Custom types that need `registerFallbackValue` in `setUpAll()`.
  final List<String> fallbackTypes;

  /// Import lines required by stub values, fallback registrations and mocked
  /// bloc dependency states.
  final Set<String> extraImports;
}
