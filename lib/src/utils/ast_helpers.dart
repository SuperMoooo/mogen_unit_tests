// lib/src/utils/ast_helpers.dart

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Small AST utilities shared by the parsers and detectors.
///
/// Everything here is written structurally rather than against concrete node
/// classes, because the analyzer's argument-list model changed between the
/// versions this package supports (`Expression` became `Argument` in
/// analyzer 13). Walking with a [GeneralizingAstVisitor] keeps one
/// implementation valid across all of them.
class AstHelpers {
  AstHelpers._();

  /// Returns the first argument of [list] as a plain [AstNode], or `null`
  /// when the list is empty.
  ///
  /// The static element type of `ArgumentList.arguments` differs per analyzer
  /// version, so the result is deliberately widened to [AstNode] — the one
  /// supertype every version agrees on.
  static AstNode? firstArgument(ArgumentList list) {
    final args = list.arguments;
    return args.isEmpty ? null : args.first;
  }

  /// Returns the first [FunctionExpression] reachable from [node] (including
  /// [node] itself), or `null` when there is none.
  ///
  /// Used to pull the `(event, emit) { ... }` closure out of an
  /// `on<Event>(...)` registration regardless of how the argument node is
  /// wrapped.
  static FunctionExpression? firstFunctionExpression(AstNode node) {
    final finder = _FunctionExpressionFinder();
    node.accept(finder);
    return finder.found;
  }

  /// Whether [source] is a bare identifier (e.g. a tear-off handler such as
  /// `_onLoginRequested` passed to `on<LoginRequested>(...)`).
  static bool isIdentifier(String source) =>
      RegExp(r'^[_a-zA-Z][a-zA-Z0-9_]*$').hasMatch(source.trim());

  /// Whether the function [body] is declared `async` / `async*`.
  static bool isAsyncBody(FunctionBody body) => body.keyword?.lexeme == 'async';
}

class _FunctionExpressionFinder extends GeneralizingAstVisitor<void> {
  FunctionExpression? found;

  @override
  void visitNode(AstNode node) {
    if (found != null) return;
    if (node is FunctionExpression) {
      found = node;
      return;
    }
    super.visitNode(node);
  }
}
