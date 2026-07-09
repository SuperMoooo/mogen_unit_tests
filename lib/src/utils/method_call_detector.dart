// lib/src/utils/method_call_detector.dart
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

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
  static List<RepositoryMethodCall> detectRepositoryMethodCalls(
    String notifierSourcePath,
    String repoType, {
    String? methodName,
  }) {
    try {
      final content = File(notifierSourcePath).readAsStringSync();
      final parsed = parseString(content: content, path: notifierSourcePath);
      final visitor = _MethodCallVisitor(repoType, methodName);
      parsed.unit.visitChildren(visitor);
      return visitor.methodCalls.values.toList();
    } catch (_) {
      return [];
    }
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
    for (var param in list.parameters) {
      if (param is DefaultFormalParameter) param = param.parameter;
      if (param is SimpleFormalParameter) {
        final type = param.type?.toSource();
        if (type != null) types.add(type);
      }
    }
    return types;
  }
}

// ─── Method-call visitor ─────────────────────────────────────────────────────

class _MethodCallVisitor extends RecursiveAstVisitor<void> {
  _MethodCallVisitor(this.repoType, this.methodName);

  final String repoType;
  final String? methodName;
  final Map<String, RepositoryMethodCall> methodCalls = {};

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
          argumentMatchers: _buildArgumentMatchers(node.argumentList.arguments),
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
        varName == '_${_lcFirst(repoType)}';
  }

  String _lcFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  /// Builds argument matchers, emitting `any(named: 'x')` for named arguments
  /// and `any()` for positional ones.
  List<String> _buildArgumentMatchers(NodeList<Expression> arguments) {
    return arguments.map((arg) {
      if (arg is NamedExpression) {
        return "${arg.name.label.name}: any(named: '${arg.name.label.name}')";
      }
      return 'any()';
    }).toList();
  }
}
