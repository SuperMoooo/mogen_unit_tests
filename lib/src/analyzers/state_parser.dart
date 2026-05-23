// lib/src/analyzers/state_parser.dart

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../models/notifier_info.dart';

class StateParser {
  final String projectRoot;
  final String packageName;

  StateParser({required this.projectRoot, required this.packageName});

  List<StateInfo> parseAll(List<String> filePaths) {
    final result = <StateInfo>[];
    for (final path in filePaths) {
      try {
        result.addAll(_parse(path));
      } catch (_) {}
    }
    return result;
  }

  List<StateInfo> _parse(String filePath) {
    final content = File(filePath).readAsStringSync();
    final parsed = parseString(
      content: content,
      featureSet: FeatureSet.latestLanguageVersion(),
      path: filePath,
    );

    final importPath = _toPackagePath(filePath);
    final visitor = _StateVisitor(importPath: importPath);
    parsed.unit.visitChildren(visitor);
    return visitor.states;
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

class _StateVisitor extends RecursiveAstVisitor<void> {
  final String importPath;
  final List<StateInfo> states = [];

  _StateVisitor({required this.importPath});

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final name = node.name.lexeme;
    // Accept anything that looks state-like
    if (!_isState(name)) return;

    final fields = <StateField>[];

    for (final member in node.members) {
      if (member is! FieldDeclaration) continue;
      final rawType = member.fields.type?.toSource();
      if (rawType == null) continue;

      final isNullable = rawType.endsWith('?');
      final clean =
          isNullable ? rawType.substring(0, rawType.length - 1) : rawType;
      final (isList, itemType) = _listInfo(clean);

      for (final v in member.fields.variables) {
        fields.add(StateField(
          name: v.name.lexeme,
          type: clean,
          isNullable: isNullable,
          isList: isList,
          listItemType: itemType,
        ));
      }
    }

    // Also check constructor params (for Freezed / data classes)
    for (final member in node.members) {
      if (member is! ConstructorDeclaration) continue;
      for (final param in member.parameters.parameters) {
        _addParamAsField(param, fields);
      }
    }

    states.add(StateInfo(
      className: name,
      importPath: importPath,
      fields: fields,
    ));
  }

  void _addParamAsField(FormalParameter param, List<StateField> fields) {
    String? name;
    String? rawType;

    if (param is SimpleFormalParameter) {
      name = param.name?.lexeme;
      rawType = param.type?.toSource();
    } else if (param is DefaultFormalParameter) {
      final inner = param.parameter;
      if (inner is SimpleFormalParameter) {
        name = inner.name?.lexeme;
        rawType = inner.type?.toSource();
      }
    } else if (param is FieldFormalParameter) {
      name = param.name.lexeme;
      rawType = param.type?.toSource();
    }

    if (name == null || rawType == null) return;
    if (fields.any((f) => f.name == name)) return; // already added

    final isNullable = rawType.endsWith('?');
    final clean =
        isNullable ? rawType.substring(0, rawType.length - 1) : rawType;
    final (isList, itemType) = _listInfo(clean);

    fields.add(StateField(
      name: name,
      type: clean,
      isNullable: isNullable,
      isList: isList,
      listItemType: itemType,
    ));
  }

  bool _isState(String name) {
    final lower = name.toLowerCase();
    return lower.contains('state') ||
        lower.endsWith('model') ||
        lower.endsWith('data') ||
        lower.endsWith('entity');
  }

  (bool, String?) _listInfo(String type) {
    final m = RegExp(r'^List<(.+)>$').firstMatch(type);
    if (m != null) return (true, m.group(1));
    return (false, null);
  }
}
