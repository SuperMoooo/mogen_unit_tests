// lib/src/analyzers/notifier_parser.dart

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../models/notifier_info.dart';

/// Parses a notifier source file and returns all [NotifierInfo] found.
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

    final visitor = _NotifierVisitor(
      filePath: filePath,
      importPath: _toPackagePath(filePath),
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
  _NotifierVisitor({required this.filePath, required this.importPath});

  final String filePath;
  final String importPath;
  final List<NotifierInfo> notifiers = [];

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final superclassName = node.extendsClause?.superclass.toSource() ?? '';

    final isAsync = superclassName.contains('AsyncNotifier') ||
        superclassName.contains('AutoDisposeAsyncNotifier');
    final isNotifier = isAsync ||
        superclassName.contains('Notifier') ||
        superclassName.contains('AutoDisposeNotifier');

    if (!isNotifier) return;

    final stateType = _extractGeneric(superclassName);

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

      final memberName = member.name.lexeme;
      if (memberName.startsWith('_')) continue;

      final info = MethodInfo(
        name: memberName,
        returnType: member.returnType?.toSource() ?? 'void',
        isAsync: _isAsync(member),
        params: _parseParams(member.parameters),
        isBuild: memberName == 'build',
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
      stateType: stateType,
      isAsync: isAsync,
      repositories: repos,
      buildMethod: buildMethod,
      methods: methods,
    ));
  }

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
    return lower.contains('repository') ||
        lower.contains('service') ||
        lower.contains('datasource') ||
        lower.contains('client') ||
        lower.contains('api');
  }

  List<ParamInfo> _parseParams(FormalParameterList? list) {
    if (list == null) return [];
    return list.parameters.map(_resolveParam).whereType<ParamInfo>().toList();
  }

  ParamInfo? _resolveParam(FormalParameter param) {
    String? name;
    String type = 'dynamic';
    final isNamed = param.isNamed;
    String? defaultValue;

    if (param is SimpleFormalParameter) {
      name = param.name?.lexeme;
      type = param.type?.toSource() ?? 'dynamic';
    } else if (param is DefaultFormalParameter) {
      defaultValue = param.defaultValue?.toSource();
      final inner = param.parameter;
      if (inner is SimpleFormalParameter) {
        name = inner.name?.lexeme;
        type = inner.type?.toSource() ?? 'dynamic';
      }
    } else if (param is FieldFormalParameter) {
      name = param.name.lexeme;
      type = param.type?.toSource() ?? 'dynamic';
    } else if (param is SuperFormalParameter) {
      name = param.name.lexeme;
      type = param.type?.toSource() ?? 'dynamic';
    }

    if (name == null) return null;
    return ParamInfo(
      name: name,
      type: type,
      isNamed: isNamed,
      isNullable: type.endsWith('?'),
      defaultValue: defaultValue,
    );
  }

  bool _isAsync(MethodDeclaration m) {
    final body = m.body;
    if (body is BlockFunctionBody) {
      return body.keyword?.lexeme == 'async';
    }
    if (body is ExpressionFunctionBody) {
      return body.keyword?.lexeme == 'async';
    }
    return false;
  }

  String? _extractGeneric(String type) =>
      RegExp(r'<(.+)>').firstMatch(type)?.group(1);
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

  String? _providerToType(String providerExpr) {
    final cleaned = providerExpr.replaceAll(RegExp(r'\.notifier\b'), '').trim();
    final match = RegExp(r'^([a-z][a-zA-Z0-9]*)Provider').firstMatch(cleaned);
    if (match == null) return null;
    final camel = match.group(1)!;
    return camel[0].toUpperCase() + camel.substring(1);
  }

  String _typeToFieldName(String type) =>
      type[0].toLowerCase() + type.substring(1);
}
