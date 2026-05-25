// lib/src/utils/method_call_detector.dart

import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Detects method calls made on a specific repository type within source code.
class MethodCallDetector {
  /// Parse the notifier source file and extract method calls to a specific repository.
  static List<String> detectRepositoryMethods(
    String notifierSourcePath,
    String repoType,
  ) {
    try {
      final content = File(notifierSourcePath).readAsStringSync();
      final parsed = parseString(content: content, path: notifierSourcePath);

      final visitor = _MethodCallVisitor(repoType);
      parsed.unit.visitChildren(visitor);

      return visitor.methodCalls.toList();
    } catch (_) {
      return [];
    }
  }
}

class _MethodCallVisitor extends RecursiveAstVisitor<void> {
  _MethodCallVisitor(this.repoType);

  final String repoType;
  final Set<String> methodCalls = {};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    // Check if this is a call on ref.read(repositoryProvider)
    final target = node.target;
    if (target is MethodInvocation) {
      final targetMethod = target.methodName.name;
      if (targetMethod == 'read' || targetMethod == 'watch') {
        final refTarget = target.target?.toSource();
        if (refTarget == 'ref' || refTarget == '_ref') {
          final providerExpr = target.argumentList.arguments.firstOrNull
              ?.toSource()
              .replaceAll(RegExp(r'\.notifier\b'), '');

          if (providerExpr != null && _providerMatchesRepo(providerExpr)) {
            methodCalls.add(node.methodName.name);
          }
        }
      }
    }

    // Also check for direct field calls like this.repository.method()
    if (target is SimpleIdentifier) {
      final varName = target.name;
      if (_isRepositoryVariable(varName, repoType)) {
        methodCalls.add(node.methodName.name);
      }
    }
  }

  bool _providerMatchesRepo(String providerExpr) {
    // Convert provider expression to type name
    // e.g., "authRepositoryProvider" -> "AuthRepository"
    final cleaned = providerExpr.replaceAll('Provider', '').trim();
    final typeFromProvider = _camelToTitle(cleaned);
    return typeFromProvider == repoType;
  }

  bool _isRepositoryVariable(String varName, String repoType) {
    // Check if variable name matches repository type
    final typeName = _camelToTitle(varName);
    return typeName == repoType || varName == _lcFirst(repoType);
  }

  String _camelToTitle(String camel) {
    if (camel.isEmpty) return camel;
    return camel[0].toUpperCase() + camel.substring(1);
  }

  String _lcFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
}
