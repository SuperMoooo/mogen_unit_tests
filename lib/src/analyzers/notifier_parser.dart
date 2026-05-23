// lib/src/analyzers/notifier_parser.dart

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../models/notifier_info.dart';

class NotifierParser {
  final String projectRoot;
  final String packageName;

  NotifierParser({required this.projectRoot, required this.packageName});

  List<NotifierInfo> parse(String filePath) {
    final content = File(filePath).readAsStringSync();
    final result = parseString(
      content: content,
      featureSet: FeatureSet.latestLanguageVersion(),
      path: filePath,
    );

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
  final String filePath;
  final String importPath;

  final List<NotifierInfo> notifiers = [];

  _NotifierVisitor({required this.filePath, required this.importPath});

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final superclassName = node.extendsClause?.superclass.toSource() ?? '';

    // Match AsyncNotifier<T>, Notifier<T>, FamilyAsyncNotifier<T,A> etc.
    final isAsync = superclassName.contains('AsyncNotifier') ||
        superclassName.contains('AutoDisposeAsyncNotifier');
    final isNotifier = isAsync ||
        superclassName.contains('Notifier') ||
        superclassName.contains('AutoDisposeNotifier');

    if (!isNotifier) return;

    // Extract <T> from AsyncNotifier<T>
    final stateType = _extractGeneric(superclassName);

    // Collect repositories from ref.read() calls inside the class
    final repoVisitor = _RepoRefVisitor();
    node.visitChildren(repoVisitor);
    final repos = repoVisitor.repos;

    // Also check field declarations for injected repos
    final fieldRepos = _extractFieldRepos(node);
    for (final fr in fieldRepos) {
      if (!repos.any((r) => r.type == fr.type)) repos.add(fr);
    }

    // Parse methods
    MethodInfo? buildMethod;
    final methods = <MethodInfo>[];

    for (final member in node.members) {
      if (member is! MethodDeclaration) continue;
      final name = member.name.lexeme;
      if (name.startsWith('_')) continue;

      final returnType = member.returnType?.toSource() ?? 'void';
      final isAsync = _isAsync(member);
      final params = _parseParams(member.parameters);

      final info = MethodInfo(
        name: name,
        returnType: returnType,
        isAsync: isAsync,
        params: params,
        isBuild: name == 'build',
      );

      if (name == 'build') {
        buildMethod = info;
      } else {
        methods.add(info);
      }
    }

    notifiers.add(NotifierInfo(
      className: node.name.lexeme,
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
    final deps = <RepositoryDep>[];
    for (final member in node.members) {
      if (member is! FieldDeclaration) continue;
      final type = member.fields.type?.toSource();
      if (type == null) continue;
      if (!_looksLikeRepo(type)) continue;
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
    final result = <ParamInfo>[];
    for (final param in list.parameters) {
      String? name;
      String type = 'dynamic';
      bool isNamed = param.isNamed;
      bool isNullable = false;
      String? defaultValue;

      if (param is SimpleFormalParameter) {
        name = param.name?.lexeme;
        type = param.type?.toSource() ?? 'dynamic';
        isNullable = type.endsWith('?');
      } else if (param is DefaultFormalParameter) {
        defaultValue = param.defaultValue?.toSource();
        final inner = param.parameter;
        if (inner is SimpleFormalParameter) {
          name = inner.name?.lexeme;
          type = inner.type?.toSource() ?? 'dynamic';
          isNullable = type.endsWith('?');
        }
      } else if (param is FieldFormalParameter) {
        name = param.name.lexeme;
        type = param.type?.toSource() ?? 'dynamic';
      }

      if (name != null) {
        result.add(ParamInfo(
          name: name,
          type: type,
          isNamed: isNamed,
          isNullable: isNullable,
          defaultValue: defaultValue,
        ));
      }
    }
    return result;
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

  String? _extractGeneric(String type) {
    final match = RegExp(r'<(.+)>').firstMatch(type);
    return match?.group(1);
  }
}

// ─── Repo ref.read() Visitor ─────────────────────────────────────────────────

class _RepoRefVisitor extends RecursiveAstVisitor<void> {
  final List<RepositoryDep> repos = [];

  // Matches: ref.read(cartRepositoryProvider)
  // Matches: ref.watch(cartRepositoryProvider)
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
    // Try to infer type from provider name convention:
    // cartRepositoryProvider → CartRepository
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
    // cartRepositoryProvider → CartRepository
    // authServiceProvider    → AuthService
    final cleaned = providerExpr.replaceAll(RegExp(r'\.notifier\b'), '').trim();
    final match = RegExp(r'^([a-z][a-zA-Z0-9]*)Provider').firstMatch(cleaned);
    if (match == null) return null;
    final camel = match.group(1)!;
    return camel[0].toUpperCase() + camel.substring(1);
  }

  String _typeToFieldName(String type) =>
      type[0].toLowerCase() + type.substring(1);
}
