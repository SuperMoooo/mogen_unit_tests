// lib/src/analyzers/event_parser.dart

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../models/notifier_info.dart';

/// Parses bloc event classes so the generator can construct a real event
/// instance inside `act:` (`bloc.add(LoginRequested(email: '', ...))`).
///
/// Events have no naming convention to key off — `LoginRequested` looks like
/// any other class — so every class declaration in the scanned files is
/// recorded and looked up later by the exact name the bloc registered with
/// `on<Event>(...)`.
class EventParser {
  /// Creates a new [EventParser].
  const EventParser({
    required this.projectRoot,
    required this.packageName,
  });

  /// The root directory of the Flutter project.
  final String projectRoot;

  /// The package name of the project.
  final String packageName;

  /// Parses all [filePaths] and returns every class found, keyed by name.
  List<EventClassInfo> parseAll(List<String> filePaths) {
    final result = <EventClassInfo>[];
    for (final path in filePaths) {
      try {
        result.addAll(_parse(path));
      } catch (_) {
        // Skip files that cannot be parsed.
      }
    }
    return result;
  }

  List<EventClassInfo> _parse(String filePath) {
    final content = File(filePath).readAsStringSync();
    final parsed = parseString(content: content, path: filePath);
    final visitor = _EventVisitor(
      importPath: _toPackagePath(filePath),
      isPart: parsed.unit.directives.whereType<PartOfDirective>().isNotEmpty,
    );
    parsed.unit.visitChildren(visitor);
    return visitor.events;
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

class _EventVisitor extends RecursiveAstVisitor<void> {
  _EventVisitor({required this.importPath, this.isPart = false});

  final String importPath;
  final bool isPart;
  final List<EventClassInfo> events = [];

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final body = node.body;
    if (body is! BlockClassBody) return;

    final fieldTypes = <String, String>{};
    for (final member in body.members) {
      if (member is! FieldDeclaration) continue;
      final type = member.fields.type?.toSource();
      if (type == null) continue;
      for (final v in member.fields.variables) {
        fieldTypes[v.name.lexeme] = type;
      }
    }

    events.add(EventClassInfo(
      className: node.namePart.typeName.lexeme,
      importPath: importPath,
      isPart: isPart,
      params: _params(_primaryConstructor(body), fieldTypes),
    ));
  }

  /// The constructor a test would call: the unnamed generative one when it
  /// exists, otherwise the first declared — including factories, which is how
  /// `freezed`-generated events expose their fields.
  ConstructorDeclaration? _primaryConstructor(BlockClassBody body) {
    ConstructorDeclaration? fallback;
    for (final member in body.members) {
      if (member is! ConstructorDeclaration) continue;
      if (member.name == null && member.factoryKeyword == null) return member;
      fallback ??= member;
    }
    return fallback;
  }

  List<ParamInfo> _params(
    ConstructorDeclaration? constructor,
    Map<String, String> fieldTypes,
  ) {
    final list = constructor?.parameters;
    if (list == null) return const [];

    final params = <ParamInfo>[];
    for (final param in list.parameters) {
      final source = param.toSource().trim();
      final name = param.name?.lexeme ?? _nameFromSource(source);
      if (name == null) continue;

      var type = _typeFromSource(source, name);
      if (type == 'dynamic') {
        type = fieldTypes[name] ?? fieldTypes['_$name'] ?? 'dynamic';
      }

      params.add(ParamInfo(
        name: name,
        type: type,
        isNamed: param.isNamed,
        isNullable: type.endsWith('?'),
        defaultValue: _defaultValue(source),
      ));
    }
    return params;
  }

  String _typeFromSource(String source, String? name) {
    var normalized = source.trim();
    if (normalized.contains('=')) {
      normalized = normalized.split('=').first.trim();
    }
    // Modifiers come first (`required this.email`), so they have to be
    // stripped before the field-formal check — otherwise the type resolves to
    // the literal string `this.`.
    normalized = normalized.replaceFirst(
      RegExp(r'^(required|covariant|final|const|late|var)\s+'),
      '',
    );
    if (normalized.startsWith('this.') || normalized.startsWith('super.')) {
      return 'dynamic';
    }

    if (name == null || !normalized.contains(name)) return 'dynamic';
    final type = normalized.substring(0, normalized.lastIndexOf(name)).trim();
    return type.isEmpty ? 'dynamic' : type;
  }

  String? _nameFromSource(String source) {
    var normalized = source.trim();
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

  String? _defaultValue(String source) {
    if (!source.contains('=')) return null;
    return source.split('=').skip(1).join('=').trim();
  }
}
