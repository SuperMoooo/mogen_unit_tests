// lib/src/analyzers/notifier_parser.dart

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../models/notifier_info.dart';
import '../utils/ast_helpers.dart';
import '../utils/mock_value_generator.dart';
import '../utils/provider_type_resolver.dart';

/// Parses a notifier, bloc or cubit source file and returns all
/// [NotifierInfo] found.
class NotifierParser {
  /// Creates a new [NotifierParser].
  const NotifierParser({
    required this.projectRoot,
    required this.packageName,
  });

  /// The root directory of the Flutter project.
  final String projectRoot;

  /// The package name of the project.
  final String packageName;

  /// Parse all [filePath] and return every [NotifierInfo] found.
  List<NotifierInfo> parse(String filePath) {
    final content = File(filePath).readAsStringSync();
    final result = parseString(content: content, path: filePath);

    final sourceImports = result.unit.directives
        .whereType<ImportDirective>()
        .map((d) => d.uri.stringValue)
        .whereType<String>()
        .toList();

    final visitor = _NotifierVisitor(
      filePath: filePath,
      importPath: _toPackagePath(filePath),
      packageName: packageName, // ← ADDED
      sourceImports: sourceImports,
    );
    result.unit.visitChildren(visitor);
    return visitor.notifiers;
  }

  String _toPackagePath(String filePath) {
    final libPath = p.join(projectRoot, 'lib');
    if (filePath.startsWith(libPath)) {
      final rel = p.relative(filePath, from: libPath).replaceAll(r'\', '/');
      return 'package:$packageName/$rel';
    }
    return filePath;
  }
}

// ─── Visitor ────────────────────────────────────────────────────────────────

class _NotifierVisitor extends RecursiveAstVisitor<void> {
  _NotifierVisitor({
    required this.filePath,
    required this.importPath,
    required this.packageName, // ← ADDED PARAMETER
    required this.sourceImports,
  });

  final String filePath;
  final String importPath;
  final String packageName; // ← ADDED FIELD
  final List<String> sourceImports;
  final List<NotifierInfo> notifiers = [];

  /// The exact Riverpod base classes this generator supports. Matching the
  /// base name exactly (instead of `contains('Notifier')`) keeps classes
  /// extending `ChangeNotifier`/`ValueNotifier` — which can legitimately
  /// live under `presentation/notifiers/` — from being scaffolded as
  /// Riverpod notifiers.
  static const _riverpodBases = {
    'Notifier',
    'AsyncNotifier',
    'AutoDisposeNotifier',
    'AutoDisposeAsyncNotifier',
    'FamilyNotifier',
    'FamilyAsyncNotifier',
    'AutoDisposeFamilyNotifier',
    'AutoDisposeFamilyAsyncNotifier',
  };

  /// `flutter_bloc` base classes are matched by suffix rather than by an
  /// exact name: a project-local base (`class AuthBloc extends BaseBloc<E, S>`,
  /// `HydratedBloc`, `ReplayCubit`, ...) is still a bloc, and anything whose
  /// superclass name ends in `Bloc`/`Cubit` is one by convention.
  static bool _isBlocBase(String baseName) => baseName.endsWith('Bloc');

  static bool _isCubitBase(String baseName) => baseName.endsWith('Cubit');

  /// Members inherited from `Bloc`/`Cubit` that a class may legitimately
  /// override but that are not actions worth generating a test group for.
  static const _blocLifecycleMembers = {
    'add',
    'emit',
    'close',
    'onChange',
    'onEvent',
    'onError',
    'onTransition',
    'fromJson',
    'toJson',
  };

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final superclassSource = node.extendsClause?.superclass.toSource() ?? '';
    final baseName = superclassSource.split('<').first.trim();

    if (_isBlocBase(baseName) || _isCubitBase(baseName)) {
      _visitBlocOrCubit(node, superclassSource, isBloc: _isBlocBase(baseName));
      return;
    }

    if (!_riverpodBases.contains(baseName)) return;

    final isAsync = baseName.contains('AsyncNotifier');
    final isFamily = baseName.contains('Family');

    final generics = _extractGenerics(superclassSource);
    final stateType = generics.isNotEmpty ? generics.first : null;
    final familyArgType = isFamily && generics.length > 1 ? generics[1] : null;

    final repoVisitor = _RepoRefVisitor();
    node.visitChildren(repoVisitor);
    final repos = repoVisitor.repos;

    for (final fr in _extractFieldRepos(node)) {
      if (!repos.any((r) => r.type == fr.type)) repos.add(fr);
    }

    final body = node.body;
    if (body is! BlockClassBody) return;

    MethodInfo? buildMethod;
    final methods = <MethodInfo>[];

    for (final member in body.members) {
      if (member is! MethodDeclaration) continue;

      // Getters, setters, statics and operators aren't callable the way the
      // generated `notifier.method(args)` scaffold expects — a getter would
      // be emitted as `.isReady()` and fail to compile.
      if (member.isGetter ||
          member.isSetter ||
          member.isStatic ||
          member.isOperator) {
        continue;
      }

      final memberName = member.name.lexeme;
      if (memberName.startsWith('_')) continue;
      if (memberName == 'toString' || memberName == 'noSuchMethod') continue;

      final info = MethodInfo(
        name: memberName,
        returnType: member.returnType?.toSource() ?? 'void',
        isAsync: _isAsync(member),
        params: _parseParams(member.parameters),
        isBuild: memberName == 'build',
        bodySource: member.body.toSource(),
      );

      if (memberName == 'build') {
        buildMethod = info;
      } else {
        methods.add(info);
      }
    }

    notifiers.add(NotifierInfo(
      className: node.namePart.typeName.lexeme,
      sourceFilePath: filePath,
      importPath: importPath,
      packageName: packageName, // ← ADDED
      stateType: stateType,
      isAsync: isAsync,
      isFamily: isFamily,
      familyArgType: familyArgType,
      superclassSource: superclassSource,
      repositories: repos,
      buildMethod: buildMethod,
      methods: methods,
      sourceImports: sourceImports,
    ));
  }

  // ─── flutter_bloc ─────────────────────────────────────────────────────────

  /// Records a `Bloc<Event, State>` or `Cubit<State>` declaration.
  ///
  /// Blocs and cubits get their dependencies through the constructor rather
  /// than through a `ref.read()` DI seam, so the constructor — not the class
  /// body alone — is what identifies the collaborators to mock, and its shape
  /// is kept so the generated test can instantiate the class with those mocks.
  void _visitBlocOrCubit(
    ClassDeclaration node,
    String superclassSource, {
    required bool isBloc,
  }) {
    final body = node.body;
    if (body is! BlockClassBody) return;

    final generics = _extractGenerics(superclassSource);
    final String? eventBaseType;
    final String? stateType;
    if (isBloc && generics.length >= 2) {
      eventBaseType = generics[0];
      stateType = generics[1];
    } else {
      eventBaseType = null;
      stateType = generics.isNotEmpty ? generics.first : null;
    }

    final fieldTypes = _fieldTypes(body);
    final constructor = _primaryConstructor(body);
    final constructorParams = _constructorParams(constructor, fieldTypes);

    final repos = _constructorDependencies(constructorParams, fieldTypes);
    for (final fr in _extractFieldRepos(node)) {
      if (!repos.any((r) => r.type == fr.type)) repos.add(fr);
    }
    // A bloc that still reaches for a service locator or a `ref` keeps those
    // dependencies too.
    final repoVisitor = _RepoRefVisitor();
    node.visitChildren(repoVisitor);
    for (final r in repoVisitor.repos) {
      if (!repos.any((existing) => existing.type == r.type)) repos.add(r);
    }

    final methods = <MethodInfo>[];
    for (final member in body.members) {
      if (member is! MethodDeclaration) continue;
      if (member.isGetter ||
          member.isSetter ||
          member.isStatic ||
          member.isOperator) {
        continue;
      }

      final memberName = member.name.lexeme;
      if (memberName.startsWith('_')) continue;
      if (_blocLifecycleMembers.contains(memberName)) continue;
      if (memberName == 'toString' || memberName == 'noSuchMethod') continue;

      methods.add(MethodInfo(
        name: memberName,
        returnType: member.returnType?.toSource() ?? 'void',
        isAsync: _isAsync(member),
        params: _parseParams(member.parameters),
        bodySource: member.body.toSource(),
      ));
    }

    notifiers.add(NotifierInfo(
      className: node.namePart.typeName.lexeme,
      sourceFilePath: filePath,
      importPath: importPath,
      packageName: packageName,
      stateType: stateType,
      // A bloc's state is a plain value, never an `AsyncValue` — there is no
      // `.future` to await and no `requireValue` to unwrap.
      isAsync: false,
      superclassSource: superclassSource,
      repositories: repos,
      methods: methods,
      sourceImports: sourceImports,
      kind: isBloc ? StateManagementKind.bloc : StateManagementKind.cubit,
      eventBaseType: eventBaseType,
      events: isBloc ? _extractEvents(node, body) : const [],
      constructorParams: constructorParams,
    ));
  }

  /// Declared field name → declared type, used to resolve `this.x`
  /// constructor parameters back to a real type.
  Map<String, String> _fieldTypes(BlockClassBody body) {
    final types = <String, String>{};
    for (final member in body.members) {
      if (member is! FieldDeclaration) continue;
      final type = member.fields.type?.toSource();
      if (type == null) continue;
      for (final v in member.fields.variables) {
        types[v.name.lexeme] = type;
      }
    }
    return types;
  }

  /// The constructor the generated test will call: the unnamed one when it
  /// exists, otherwise the first non-factory constructor declared.
  ConstructorDeclaration? _primaryConstructor(BlockClassBody body) {
    ConstructorDeclaration? fallback;
    for (final member in body.members) {
      if (member is! ConstructorDeclaration) continue;
      if (member.factoryKeyword != null) continue;
      if (member.name == null) return member;
      fallback ??= member;
    }
    return fallback;
  }

  List<ParamInfo> _constructorParams(
    ConstructorDeclaration? constructor,
    Map<String, String> fieldTypes,
  ) {
    final list = constructor?.parameters;
    if (list == null) return const [];

    final params = <ParamInfo>[];
    for (final param in list.parameters) {
      final source = param.toSource().trim();
      final name = param.name?.lexeme ?? _extractNameFromSource(source);
      if (name == null) continue;

      // `this.x` / `super.x` carry no type annotation of their own — the
      // matching field declaration does.
      var type = _extractTypeFromSource(source, name);
      if (type == 'dynamic') {
        type = fieldTypes[name] ?? fieldTypes['_$name'] ?? 'dynamic';
      }

      params.add(ParamInfo(
        name: name,
        type: type,
        isNamed: param.isNamed,
        isNullable: type.endsWith('?'),
        defaultValue: _extractDefaultValue(source),
      ));
    }
    return params;
  }

  /// Every constructor parameter that carries an injected collaborator.
  ///
  /// Constructor injection *is* the bloc DI seam, so any parameter whose type
  /// isn't a primitive, a collection or a callback is mocked — the same
  /// reasoning that makes every `ref.read()` dependency mockable on the
  /// Riverpod side, and what lets raw SDK types get mocked instead of running
  /// for real inside the generated test.
  List<RepositoryDep> _constructorDependencies(
    List<ParamInfo> params,
    Map<String, String> fieldTypes,
  ) {
    final deps = <RepositoryDep>[];
    for (final param in params) {
      final type = param.type.replaceAll('?', '').trim();
      if (!_isInjectableType(type)) continue;
      if (deps.any((d) => d.type == type)) continue;

      // Calls in the body go through the *field*, which is often a private
      // rename of the parameter (`AuthBloc(this._repo)` vs
      // `AuthBloc(AuthRepository repo) : _repo = repo`).
      final fieldName = fieldTypes.entries
          .where((e) => e.value.replaceAll('?', '').trim() == type)
          .map((e) => e.key)
          .firstOrNull;

      deps.add(RepositoryDep(type: type, name: fieldName ?? param.name));
    }
    return deps;
  }

  /// Whether a constructor parameter of [type] represents a collaborator
  /// worth mocking, as opposed to plain configuration data.
  bool _isInjectableType(String type) {
    if (type.isEmpty || type == 'dynamic' || type == 'Object') return false;
    if (MockValueGenerator.isPrimitive(type)) return false;
    if (type.contains('Function') || type.contains('(')) return false;
    final base = type.split('<').first.trim();
    const collections = {'List', 'Map', 'Set', 'Iterable', 'Stream', 'Future'};
    if (collections.contains(base)) return false;
    // The initial state of a cubit (`Cubit(SomeState.initial())`) is data the
    // test provides, not a collaborator it mocks.
    if (base.endsWith('State')) return false;
    return true;
  }

  /// Every event registered with `on<Event>(...)`, in declaration order.
  ///
  /// Both handler styles are supported: an inline `(event, emit) { ... }`
  /// closure and a tear-off (`on<LoginRequested>(_onLoginRequested)`), whose
  /// body is resolved from the matching method declaration.
  List<EventInfo> _extractEvents(ClassDeclaration node, BlockClassBody body) {
    final finder = _EventRegistrationFinder();
    node.visitChildren(finder);

    final methodBodies = <String, MethodDeclaration>{
      for (final m in body.members.whereType<MethodDeclaration>())
        m.name.lexeme: m,
    };

    final events = <EventInfo>[];
    for (final registration in finder.registrations) {
      if (events.any((e) => e.type == registration.type)) continue;

      var bodySource = registration.handlerBody;
      var isAsync = registration.isAsync;

      final handlerName = registration.handlerName;
      if (bodySource == null && handlerName != null) {
        final handler = methodBodies[handlerName];
        if (handler != null) {
          bodySource = handler.body.toSource();
          isAsync = AstHelpers.isAsyncBody(handler.body);
        }
      }

      events.add(EventInfo(
        type: registration.type,
        isAsync: isAsync,
        handlerBodySource: bodySource,
      ));
    }
    return events;
  }

  // ─── Shared ───────────────────────────────────────────────────────────────

  List<RepositoryDep> _extractFieldRepos(ClassDeclaration node) {
    final body = node.body;
    if (body is! BlockClassBody) return [];

    final deps = <RepositoryDep>[];
    for (final member in body.members) {
      if (member is! FieldDeclaration) continue;
      final type = member.fields.type?.toSource();
      if (type == null || !_looksLikeRepo(type)) continue;
      for (final v in member.fields.variables) {
        deps.add(RepositoryDep(
          type: type.replaceAll('?', '').trim(),
          name: v.name.lexeme,
        ));
      }
    }
    return deps;
  }

  bool _looksLikeRepo(String type) {
    final lower = type.toLowerCase();
    // Kept in sync with the generator's mockable-name heuristic — a
    // field-declared notifier/cubit dependency is just as mockable as a
    // repository one.
    return lower.contains('repository') ||
        lower.contains('service') ||
        lower.contains('datasource') ||
        lower.contains('client') ||
        lower.contains('api') ||
        lower.endsWith('notifier') ||
        lower.endsWith('cubit') ||
        lower.endsWith('bloc') ||
        lower.endsWith('viewmodel');
  }

  List<ParamInfo> _parseParams(FormalParameterList? list) {
    if (list == null) return [];
    return list.parameters.map(_resolveParam).whereType<ParamInfo>().toList();
  }

  ParamInfo? _resolveParam(FormalParameter param) {
    final source = param.toSource().trim();
    final isNamed = param.isNamed;
    final name = param.name?.lexeme ?? _extractNameFromSource(source);
    final type = _extractTypeFromSource(source, name);
    final defaultValue = _extractDefaultValue(source);

    if (name == null) return null;
    return ParamInfo(
      name: name,
      type: type,
      isNamed: isNamed,
      isNullable: type.endsWith('?'),
      defaultValue: defaultValue,
    );
  }

  String _extractTypeFromSource(String source, String? name) {
    String normalized = source.trim();
    if (normalized.contains('=')) {
      normalized = normalized.split('=').first.trim();
    }

    normalized = normalized.replaceFirst(
      RegExp(r'^(required|covariant|final|const|late|var)\s+'),
      '',
    );

    // Modifiers come first (`required this.email`), so the field-formal check
    // only holds once they're stripped — otherwise the type would resolve to
    // the literal string `this.`.
    if (normalized.startsWith('this.') || normalized.startsWith('super.')) {
      return 'dynamic';
    }

    if (name == null || !normalized.contains(name)) {
      return 'dynamic';
    }

    final type = normalized.substring(0, normalized.lastIndexOf(name)).trim();
    return type.isEmpty ? 'dynamic' : type;
  }

  String? _extractNameFromSource(String source) {
    String normalized = source.trim();
    if (normalized.contains('=')) {
      normalized = normalized.split('=').first.trim();
    }

    normalized = normalized.replaceFirst(
      RegExp(r'^(required|covariant|final|const|late|var)\s+'),
      '',
    );

    if (normalized.startsWith('this.') || normalized.startsWith('super.')) {
      final name = normalized.split('.').last.trim();
      return name.isEmpty ? null : name;
    }

    final token = normalized.split(RegExp(r'\s+')).lastOrNull;
    return token == null || token.isEmpty ? null : token;
  }

  String? _extractDefaultValue(String source) {
    if (!source.contains('=')) return null;
    return source.split('=').skip(1).join('=').trim();
  }

  /// Whether a call to [m] has to be awaited in the generated test.
  ///
  /// This is awaitability, not the `async` keyword. A method that hands back a
  /// `Future` from a plain block body is just as awaitable — the common
  /// `Future<void> login(...) { return runAction(...); }` shape delegates to a
  /// helper and never writes `async` itself. Treating that as synchronous
  /// leaves the call un-awaited, so the test asserts on the intermediate
  /// loading state while the action is still in flight.
  bool _isAsync(MethodDeclaration m) {
    final body = m.body;
    if (body.keyword?.lexeme == 'async') return true;
    return _returnsFuture(m.returnType?.toSource());
  }

  /// Whether [returnType] is a `Future`/`FutureOr`, ignoring type arguments,
  /// nullability and any library prefix (`async.Future<void>`).
  bool _returnsFuture(String? returnType) {
    if (returnType == null) return false;
    final base = returnType.split('<').first.trim().replaceAll('?', '');
    final name = base.split('.').last;
    return name == 'Future' || name == 'FutureOr';
  }

  /// Splits the generic arguments of [type] at top level, respecting nested
  /// generics: `FamilyAsyncNotifier<CartState, List<int>>` →
  /// `['CartState', 'List<int>']`.
  List<String> _extractGenerics(String type) {
    final raw = RegExp(r'<(.+)>').firstMatch(type)?.group(1);
    if (raw == null) return const [];

    final parts = <String>[];
    var depth = 0;
    final current = StringBuffer();
    for (final char in raw.split('')) {
      if (char == '<') depth++;
      if (char == '>') depth--;
      if (char == ',' && depth == 0) {
        parts.add(current.toString().trim());
        current.clear();
      } else {
        current.write(char);
      }
    }
    if (current.isNotEmpty) parts.add(current.toString().trim());
    return parts.where((p) => p.isNotEmpty).toList();
  }
}

// ─── Bloc `on<Event>(...)` registration finder ───────────────────────────────

/// One `on<Event>(handler)` registration found in a bloc's constructor.
class _EventRegistration {
  _EventRegistration({
    required this.type,
    this.handlerBody,
    this.handlerName,
    this.isAsync = false,
  });

  final String type;
  final String? handlerBody;
  final String? handlerName;
  final bool isAsync;
}

class _EventRegistrationFinder extends RecursiveAstVisitor<void> {
  final List<_EventRegistration> registrations = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    if (node.methodName.name != 'on') return;
    // `on` without a type argument isn't an event registration.
    final typeArgs = node.typeArguments?.arguments;
    if (typeArgs == null || typeArgs.isEmpty) return;

    final eventType = typeArgs.first.toSource();
    final handlerArg = AstHelpers.firstArgument(node.argumentList);
    if (handlerArg == null) {
      registrations.add(_EventRegistration(type: eventType));
      return;
    }

    final closure = AstHelpers.firstFunctionExpression(handlerArg);
    if (closure != null) {
      registrations.add(_EventRegistration(
        type: eventType,
        handlerBody: closure.body.toSource(),
        isAsync: AstHelpers.isAsyncBody(closure.body),
      ));
      return;
    }

    final source = handlerArg.toSource().trim();
    registrations.add(_EventRegistration(
      type: eventType,
      handlerName: AstHelpers.isIdentifier(source) ? source : null,
    ));
  }
}

// ─── Repo ref.read() Visitor ─────────────────────────────────────────────────

class _RepoRefVisitor extends RecursiveAstVisitor<void> {
  final List<RepositoryDep> repos = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    final target = node.target?.toSource();
    final method = node.methodName.name;

    if (target != 'ref' && target != '_ref') return;
    if (method != 'read' && method != 'watch') return;

    final args = node.argumentList.arguments;
    if (args.isEmpty) return;

    final providerExpr = args.first.toSource();
    final typeName = _providerToType(providerExpr);
    if (typeName == null) return;
    if (repos.any((r) => r.type == typeName)) return;

    repos.add(RepositoryDep(
      type: typeName,
      name: _typeToFieldName(typeName),
      providerExpression: providerExpr,
    ));
  }

  String? _providerToType(String providerExpr) =>
      ProviderTypeResolver.typeFromProviderExpression(providerExpr);

  String _typeToFieldName(String type) =>
      type[0].toLowerCase() + type.substring(1);
}
