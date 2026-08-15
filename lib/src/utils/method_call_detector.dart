// lib/src/utils/method_call_detector.dart
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'ast_helpers.dart';
import 'provider_type_resolver.dart';

/// Detects method calls made on a specific repository type within source code.
///
/// This detector looks for patterns like:
///   - _repo.login(...)
///   - final auth = await _repo.login(...)
///   - ref.read(authRepositoryProvider).login(...)
class RepositoryMethodCall {
  /// Creates a repository method call matcher.
  ///
  /// [methodName] is the repository method name being invoked.
  /// [argumentMatchers] is the list of matcher expressions for the method call arguments.
  /// [returnType] is the declared return type resolved from the repository interface, if available.
  const RepositoryMethodCall({
    required this.methodName,
    required this.argumentMatchers,
    this.returnType,
  });

  /// The repository method name being invoked.
  final String methodName;

  /// The generated matcher expression for each call argument.
  final List<String> argumentMatchers;

  /// The declared return type of this repository method, e.g. `Future<UserEntity>`.
  /// Null when the return type could not be resolved.
  final String? returnType;

  /// Returns the matcher arguments joined into a single string.
  String get matcherArgs => argumentMatchers.join(', ');

  /// Returns the full invocation source for this repository method call.
  String get invocationSource => '$methodName($matcherArgs)';
}

/// Detects method calls to a specific repository type within a notifier source file.
class MethodCallDetector {
  /// Parse the notifier source file and extract method calls to a specific repository.
  ///
  /// If [methodName] is provided, only calls inside that notifier method are returned.
  ///
  /// [fieldName] is the actual declared field name for this dependency (as
  /// recorded by [NotifierParser]'s field scan), e.g. `_habitRepo` for a
  /// `HabitRepository _habitRepo` field. Passing it lets calls through
  /// descriptively-named fields be matched exactly, instead of relying on
  /// [ProviderTypeResolver]'s naive camelCase guess — which only works when
  /// the field is literally named after its type (`habitRepository`) and
  /// misses abbreviations, which are unavoidable once a notifier depends on
  /// more than one repository and `_repo` no longer disambiguates them.
  static List<RepositoryMethodCall> detectRepositoryMethodCalls(
    String notifierSourcePath,
    String repoType, {
    String? methodName,
    String? fieldName,
  }) {
    try {
      final content = File(notifierSourcePath).readAsStringSync();
      final parsed = parseString(content: content, path: notifierSourcePath);
      final visitor = _MethodCallVisitor(repoType, methodName, fieldName);
      parsed.unit.visitChildren(visitor);
      return visitor.methodCalls.values.toList();
    } catch (_) {
      return [];
    }
  }

  /// Parses a bloc source file and extracts the calls made to [repoType]
  /// inside the handler registered for [eventType].
  ///
  /// A bloc's work doesn't live in its own methods — it lives in the handler
  /// passed to `on<Event>(...)`, so scoping by method name (as the Riverpod
  /// path does) would find nothing. Both handler styles are supported: an
  /// inline `(event, emit) async { ... }` closure, and a tear-off
  /// (`on<LoginRequested>(_onLoginRequested)`) whose declaration is then
  /// scanned instead.
  static List<RepositoryMethodCall> detectEventHandlerCalls(
    String blocSourcePath,
    String repoType, {
    required String eventType,
    String? fieldName,
  }) {
    try {
      final content = File(blocSourcePath).readAsStringSync();
      final parsed = parseString(content: content, path: blocSourcePath);

      final finder = _EventHandlerFinder(eventType);
      parsed.unit.visitChildren(finder);

      final handler = finder.handler;
      if (handler == null) return [];

      final closure = AstHelpers.firstFunctionExpression(handler);
      if (closure != null) {
        final visitor = _MethodCallVisitor(repoType, null, fieldName);
        closure.body.visitChildren(visitor);
        return visitor.methodCalls.values.toList();
      }

      final source = handler.toSource().trim();
      if (!AstHelpers.isIdentifier(source)) return [];

      final visitor = _MethodCallVisitor(repoType, source, fieldName);
      parsed.unit.visitChildren(visitor);
      return visitor.methodCalls.values.toList();
    } catch (_) {
      return [];
    }
  }

  /// Parses a source file and extracts the calls to [repoType] made directly
  /// in a constructor body.
  ///
  /// This is the bloc/cubit analogue of a notifier's `build()`: work kicked
  /// off at construction time (a stream subscription, an initial load) runs
  /// for *every* test, so those stubs belong in `setUp()` rather than in each
  /// individual test. Closures are skipped, since an `on<Event>(...)` handler
  /// declared in the same constructor only runs when that event is added.
  static List<RepositoryMethodCall> detectConstructorCalls(
    String sourcePath,
    String repoType, {
    String? fieldName,
  }) {
    try {
      final content = File(sourcePath).readAsStringSync();
      final parsed = parseString(content: content, path: sourcePath);

      final finder = _ConstructorBodyFinder();
      parsed.unit.visitChildren(finder);
      if (finder.bodies.isEmpty) return [];

      final visitor = _MethodCallVisitor(
        repoType,
        null,
        fieldName,
        skipClosures: true,
      );
      for (final body in finder.bodies) {
        body.visitChildren(visitor);
      }
      return visitor.methodCalls.values.toList();
    } catch (_) {
      return [];
    }
  }

  /// Extracts the states a bloc/cubit action emits, in source order.
  ///
  /// A bloc names the state it produces right at the `emit(...)` call, so the
  /// generated test doesn't have to guess it: `emit(AuthSuccess(user))` in the
  /// happy path and `emit(AuthFailure(e))` inside the `catch` tell the
  /// generator exactly what to assert — which is what makes real assertions
  /// possible for sealed state hierarchies, whose base class declares no
  /// fields to check.
  ///
  /// Pass [eventType] for a bloc event handler, or [methodName] for a cubit
  /// method.
  static List<EmittedState> detectEmittedStates(
    String sourcePath, {
    String? eventType,
    String? methodName,
  }) {
    try {
      final content = File(sourcePath).readAsStringSync();
      final parsed = parseString(content: content, path: sourcePath);

      AstNode? root;
      if (eventType != null) {
        final finder = _EventHandlerFinder(eventType);
        parsed.unit.visitChildren(finder);

        final handler = finder.handler;
        if (handler == null) return [];

        final closure = AstHelpers.firstFunctionExpression(handler);
        if (closure != null) {
          root = closure.body;
        } else {
          final source = handler.toSource().trim();
          if (!AstHelpers.isIdentifier(source)) return [];
          root = _methodBody(parsed.unit, source);
        }
      } else if (methodName != null) {
        root = _methodBody(parsed.unit, methodName);
      }

      if (root == null) return [];

      final visitor = _EmitVisitor();
      root.visitChildren(visitor);
      return visitor.emits;
    } catch (_) {
      return [];
    }
  }

  static FunctionBody? _methodBody(CompilationUnit unit, String methodName) {
    final finder = _MethodBodyFinder(methodName);
    unit.visitChildren(finder);
    return finder.body;
  }

  /// Backwards-compatible helper for callers that only need method names.
  static List<String> detectRepositoryMethods(
    String notifierSourcePath,
    String repoType, {
    String? methodName,
  }) {
    return detectRepositoryMethodCalls(
      notifierSourcePath,
      repoType,
      methodName: methodName,
    ).map((call) => call.methodName).toList();
  }

  /// Resolves the declared return type of [methodName] by parsing the repository
  /// interface source file at [repoSourcePath].
  ///
  /// Returns `null` when the file cannot be read or the method is not found.
  static String? resolveReturnType(
    String repoSourcePath,
    String methodName,
  ) =>
      resolveMethodSignature(repoSourcePath, methodName)?.returnType;

  /// Resolves the full declared signature (return type + parameter types) of
  /// [methodName] by parsing the source file at [repoSourcePath].
  ///
  /// Returns `null` when the file cannot be read or the method is not found.
  static MethodSignature? resolveMethodSignature(
    String repoSourcePath,
    String methodName,
  ) {
    try {
      final content = File(repoSourcePath).readAsStringSync();
      final parsed = parseString(content: content, path: repoSourcePath);
      final visitor = _SignatureVisitor(methodName);
      parsed.unit.visitChildren(visitor);
      return visitor.signature;
    } catch (_) {
      return null;
    }
  }
}

/// The declared signature of a dependency method, resolved from its source.
class MethodSignature {
  /// Creates a resolved signature.
  const MethodSignature({this.returnType, this.paramTypes = const []});

  /// The declared return type, e.g. `Future<UserEntity>`. `null` when the
  /// declaration omits it.
  final String? returnType;

  /// The declared types of every parameter (positional and named alike).
  /// Parameters without an explicit type are omitted.
  final List<String> paramTypes;
}

// ─── Signature resolver ──────────────────────────────────────────────────────

class _SignatureVisitor extends RecursiveAstVisitor<void> {
  _SignatureVisitor(this.targetMethod);

  final String targetMethod;
  MethodSignature? signature;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme == targetMethod) {
      signature = MethodSignature(
        returnType: node.returnType?.toSource(),
        paramTypes: _paramTypes(node.parameters),
      );
    }
    super.visitMethodDeclaration(node);
  }

  List<String> _paramTypes(FormalParameterList? list) {
    if (list == null) return const [];
    final types = <String>[];
    for (final param in list.parameters) {
      final type = _declaredType(param);
      if (type != null) types.add(type.toSource());
    }
    return types;
  }

  /// Returns the explicit type annotation of [param], or `null` when the
  /// parameter declares none (`this.value`, `super.value`, bare `value`).
  ///
  /// This walks the AST for the first [TypeAnnotation] rather than matching on
  /// concrete parameter node classes: analyzer 13 folded the parameter class
  /// hierarchy together, so `SimpleFormalParameter` and friends only exist on
  /// older versions, while [TypeAnnotation] is stable across all of them.
  TypeAnnotation? _declaredType(FormalParameter param) {
    // Old-style function-typed parameters (`void cb(int x)`) lead with their
    // *return* type, which is not the parameter's type — skip them, as the
    // previous class-based implementation did.
    if (param.name?.next?.lexeme == '(') return null;

    final finder = _TypeAnnotationFinder();
    param.visitChildren(finder);
    return finder.type;
  }
}

/// Captures the first [TypeAnnotation] reachable from a node, in source order.
class _TypeAnnotationFinder extends GeneralizingAstVisitor<void> {
  TypeAnnotation? type;

  @override
  void visitNode(AstNode node) {
    if (type != null) return;
    if (node is TypeAnnotation) {
      // Stop here so the outermost annotation wins over its type arguments.
      type = node;
      return;
    }
    super.visitNode(node);
  }
}

/// One `emit(...)` call found inside a bloc handler or cubit method.
class EmittedState {
  /// Creates a record of one emitted state.
  const EmittedState({this.typeName, required this.inCatch});

  /// The state class being constructed, e.g. `AuthSuccess`.
  ///
  /// `null` when the emitted expression isn't a direct construction — the
  /// `emit(state.copyWith(...))` shape of a data-class state, or a local
  /// variable — in which case the state type is unchanged and the generator
  /// asserts fields rather than a type.
  final String? typeName;

  /// Whether this emit sits inside a `catch` clause, i.e. it is the state the
  /// action produces when its work fails.
  final bool inCatch;
}

// ─── Bloc handler / constructor finders ──────────────────────────────────────

/// Collects `emit(...)` calls in source order, tracking which ones are the
/// action's failure path.
class _EmitVisitor extends RecursiveAstVisitor<void> {
  final List<EmittedState> emits = [];
  bool _inCatch = false;

  @override
  void visitCatchClause(CatchClause node) {
    final wasInCatch = _inCatch;
    _inCatch = true;
    super.visitCatchClause(node);
    _inCatch = wasInCatch;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'emit') {
      final arg = AstHelpers.firstArgument(node.argumentList);
      if (arg != null) {
        // Recorded before descending so nested expressions can't reorder the
        // emit sequence, which the generated `expect:` scaffold mirrors.
        emits.add(EmittedState(
          typeName: _constructedTypeName(arg.toSource()),
          inCatch: _inCatch,
        ));
      }
    }
    super.visitMethodInvocation(node);
  }

  /// The class name an emitted expression constructs, or `null` when the
  /// expression isn't a construction at all.
  ///
  /// Parsed source is unresolved, so `AuthSuccess(user)` arrives as a method
  /// invocation and `const AuthFailure('x')` as an instance creation — a
  /// leading capitalised identifier is what both have in common.
  String? _constructedTypeName(String source) {
    var expression = source.trim();
    for (final keyword in const ['const ', 'new ']) {
      if (expression.startsWith(keyword)) {
        expression = expression.substring(keyword.length).trim();
      }
    }
    final match =
        RegExp(r'^([A-Z][A-Za-z0-9_]*)\s*[(.]').firstMatch(expression);
    return match?.group(1);
  }
}

/// Finds the body of the method declaration named [methodName].
class _MethodBodyFinder extends RecursiveAstVisitor<void> {
  _MethodBodyFinder(this.methodName);

  final String methodName;
  FunctionBody? body;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (body == null && node.name.lexeme == methodName) {
      body = node.body;
    }
    super.visitMethodDeclaration(node);
  }
}

/// Finds the handler argument of the `on<EventType>(...)` registration for a
/// specific event type.
class _EventHandlerFinder extends RecursiveAstVisitor<void> {
  _EventHandlerFinder(this.eventType);

  final String eventType;
  AstNode? handler;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    if (handler != null) return;
    if (node.methodName.name != 'on') return;

    final typeArgs = node.typeArguments?.arguments;
    if (typeArgs == null || typeArgs.isEmpty) return;
    if (typeArgs.first.toSource() != eventType) return;

    handler = AstHelpers.firstArgument(node.argumentList);
  }
}

/// Collects the body of every constructor declared in the compilation unit.
class _ConstructorBodyFinder extends RecursiveAstVisitor<void> {
  final List<FunctionBody> bodies = [];

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    bodies.add(node.body);
    super.visitConstructorDeclaration(node);
  }
}

// ─── Method-call visitor ─────────────────────────────────────────────────────

class _MethodCallVisitor extends RecursiveAstVisitor<void> {
  _MethodCallVisitor(
    this.repoType,
    this.methodName,
    this.fieldName, {
    this.skipClosures = false,
  });

  final String repoType;
  final String? methodName;
  final String? fieldName;

  /// When `true`, calls nested inside a closure are ignored — used to keep a
  /// bloc's `on<Event>(...)` handlers out of the constructor-time scan.
  final bool skipClosures;

  final Map<String, RepositoryMethodCall> methodCalls = {};

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (skipClosures) return;
    super.visitFunctionExpression(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (methodName == null) {
      super.visitMethodDeclaration(node);
      return;
    }

    if (node.name.lexeme == methodName) {
      node.body.visitChildren(this);
    }
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // A method-scoped scan must not pick up calls the constructor makes — a
    // bloc registers all of its `on<Event>(...)` handlers there, so without
    // this every event's calls would leak into every other event's stubs.
    if (methodName != null) return;
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    if (_isDirectRepoCall(node) ||
        _isRefReadCall(node) ||
        _isFieldRepositoryCall(node)) {
      final callName = node.methodName.name;
      methodCalls.putIfAbsent(
        callName,
        () => RepositoryMethodCall(
          methodName: callName,
          argumentMatchers: _buildArgumentMatchers(node.argumentList),
        ),
      );
    }
  }

  /// Checks if this is a direct _repo.methodName() call.
  bool _isDirectRepoCall(MethodInvocation node) {
    final target = node.target;

    if (target is SimpleIdentifier) {
      final varName = target.name;
      return varName == '_repo' ||
          varName == 'repo' ||
          varName == '_repository' ||
          varName == 'repository' ||
          varName == fieldName ||
          ProviderTypeResolver.resolve(varName) == repoType;
    }

    return false;
  }

  /// Checks if this is a ref.read(repositoryProvider).methodName() call.
  bool _isRefReadCall(MethodInvocation node) {
    final target = node.target;

    if (target is MethodInvocation) {
      final targetMethod = target.methodName.name;

      if (targetMethod != 'read' && targetMethod != 'watch') return false;

      final refTarget = target.target?.toSource();
      if (refTarget != 'ref' && refTarget != '_ref') return false;

      final args = target.argumentList.arguments;
      if (args.isEmpty) return false;

      final providerExpr =
          args.first.toSource().replaceAll(RegExp(r'\.notifier\b'), '').trim();

      return _providerMatchesRepo(providerExpr);
    }

    return false;
  }

  /// Checks if this is a field/getter repository call like this.repository.methodName().
  bool _isFieldRepositoryCall(MethodInvocation node) {
    final target = node.target;

    if (target is PropertyAccess) {
      final propertyName = target.propertyName.name;

      if (_isRepositoryVariable(propertyName, repoType)) {
        final object = target.target;

        if (object is SimpleIdentifier &&
            (object.name == 'this' ||
                object.name == '_repo' ||
                object.name == 'repo')) {
          return true;
        }
      }
    }

    return false;
  }

  bool _providerMatchesRepo(String providerExpr) {
    // Shared with the notifier parser so both derive the same type from a
    // provider expression — including family reads like `chatProvider(id)`,
    // where the call arguments must not leak into the derived type name.
    final typeFromProvider =
        ProviderTypeResolver.typeFromProviderExpression(providerExpr);
    return typeFromProvider == repoType;
  }

  bool _isRepositoryVariable(String varName, String repoType) {
    final typeName = ProviderTypeResolver.resolve(varName);
    return typeName == repoType ||
        varName == _lcFirst(repoType) ||
        varName == '_${_lcFirst(repoType)}' ||
        varName == fieldName;
  }

  String _lcFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  /// Builds argument matchers, emitting `any(named: 'x')` for named arguments
  /// and `any()` for positional ones.
  ///
  /// Takes the [ArgumentList] rather than its `arguments` because the element
  /// type of that list changed from `Expression` to `Argument` in analyzer 13.
  List<String> _buildArgumentMatchers(ArgumentList argumentList) {
    return argumentList.arguments.map((arg) {
      final label = _namedArgumentLabel(arg);
      return label == null ? 'any()' : "$label: any(named: '$label')";
    }).toList();
  }

  /// Returns the label of a named argument (`retries: 3` -> `retries`), or
  /// `null` when the argument is positional.
  ///
  /// Read off the token stream instead of the node type: analyzer 13 replaced
  /// `NamedExpression` with `NamedArgument` and reshaped `Label` to hold a
  /// token, so neither can be named in source that also builds on analyzer 10.
  /// Within an argument list, `identifier :` is unambiguously a named argument
  /// — a positional conditional such as `a ? b : c` leads with `?`.
  String? _namedArgumentLabel(AstNode arg) {
    final first = arg.beginToken;
    return first.next?.lexeme == ':' ? first.lexeme : null;
  }
}
