// lib/src/utils/method_call_detector.dart
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

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
  const RepositoryMethodCall({
    required this.methodName,
    required this.argumentMatchers,
  });

  /// The repository method name being invoked.
  final String methodName;

  /// The generated matcher expression for each call argument.
  final List<String> argumentMatchers;

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
}

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

  /// Checks if this is a direct _repo.methodName() call
  bool _isDirectRepoCall(MethodInvocation node) {
    final target = node.target;

    if (target is SimpleIdentifier) {
      final varName = target.name;
      // Look for _repo, repo, _repository, repository patterns
      return varName == '_repo' ||
          varName == 'repo' ||
          varName == '_repository' ||
          varName == 'repository' ||
          _camelToTitle(varName) == repoType;
    }

    return false;
  }

  /// Checks if this is a ref.read(repositoryProvider).methodName() call
  bool _isRefReadCall(MethodInvocation node) {
    final target = node.target;

    if (target is MethodInvocation) {
      final targetMethod = target.methodName.name;

      // Check if it's ref.read() or ref.watch()
      if (targetMethod != 'read' && targetMethod != 'watch') {
        return false;
      }

      final refTarget = target.target?.toSource();
      if (refTarget != 'ref' && refTarget != '_ref') {
        return false;
      }

      // Get the provider expression argument
      final args = target.argumentList.arguments;
      if (args.isEmpty) return false;

      final providerExpr =
          args.first.toSource().replaceAll(RegExp(r'\.notifier\b'), '').trim();

      // Check if provider matches the repository type
      return _providerMatchesRepo(providerExpr);
    }

    return false;
  }

  /// Checks if this is a field/getter repository call like this.repository.methodName()
  bool _isFieldRepositoryCall(MethodInvocation node) {
    final target = node.target;

    if (target is PropertyAccess) {
      final propertyName = target.propertyName.name;

      // Check if the property is a repository-like name
      if (_isRepositoryVariable(propertyName, repoType)) {
        final object = target.target;

        // Check if it's accessed on 'this' or '_repo'
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

  /// Converts provider expression to repository type name
  /// e.g., "authRepositoryProvider" -> "AuthRepository"
  bool _providerMatchesRepo(String providerExpr) {
    final cleaned = providerExpr.replaceAll('Provider', '').trim();
    final typeFromProvider = _camelToTitle(cleaned);
    return typeFromProvider == repoType;
  }

  /// Checks if a variable name corresponds to the repository type
  /// e.g., "authRepository" matches "AuthRepository"
  bool _isRepositoryVariable(String varName, String repoType) {
    final typeName = _camelToTitle(varName);
    return typeName == repoType ||
        varName == _lcFirst(repoType) ||
        varName == '_${_lcFirst(repoType)}';
  }

  /// Converts camelCase to TitleCase
  /// e.g., "authRepository" -> "AuthRepository"
  String _camelToTitle(String camel) {
    if (camel.isEmpty) return camel;
    return camel[0].toUpperCase() + camel.substring(1);
  }

  /// Converts TitleCase to camelCase
  /// e.g., "AuthRepository" -> "authRepository"
  String _lcFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  List<String> _buildArgumentMatchers(NodeList<Expression> arguments) {
    return arguments.map((argument) {
      if (argument is NamedExpression) {
        final argName = argument.name.label.name;
        return '$argName: ${_anyMatcher(argName)}';
      }
      return _anyMatcher(null);
    }).toList();
  }

  String _anyMatcher(String? name) {
    if (name == null) return 'any()';
    return "any(named: '$name')";
  }
}
