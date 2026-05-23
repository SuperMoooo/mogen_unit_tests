// lib/src/models/notifier_info.dart

/// Everything the generator needs to know about one Riverpod notifier class.
class NotifierInfo {
  /// e.g. `CartNotifier`
  final String className;

  /// Absolute path to source file
  final String sourceFilePath;

  /// package: import path
  final String importPath;

  /// The generic type arg of AsyncNotifier<T> / Notifier<T>, e.g. `CartState`
  final String? stateType;

  /// Whether it extends AsyncNotifier (true) or plain Notifier (false)
  final bool isAsync;

  /// Repository / service dependencies found in the notifier body
  final List<RepositoryDep> repositories;

  /// The `build()` method signature
  final MethodInfo? buildMethod;

  /// All public methods (excluding build)
  final List<MethodInfo> methods;

  /// Resolved state info from the states/ folder
  final StateInfo? stateInfo;

  const NotifierInfo({
    required this.className,
    required this.sourceFilePath,
    required this.importPath,
    this.stateType,
    required this.isAsync,
    required this.repositories,
    this.buildMethod,
    required this.methods,
    this.stateInfo,
  });
}

/// A repository / service dependency detected inside the notifier
/// (via `ref.read(...)`, constructor param, or field declaration).
class RepositoryDep {
  /// e.g. `CartRepository`
  final String type;

  /// e.g. `cartRepository`
  final String name;

  /// The provider expression, e.g. `cartRepositoryProvider`
  final String? providerExpression;

  const RepositoryDep({
    required this.type,
    required this.name,
    this.providerExpression,
  });
}

class MethodInfo {
  final String name;
  final String returnType;
  final bool isAsync;
  final List<ParamInfo> params;

  /// true for the `build` method
  final bool isBuild;

  const MethodInfo({
    required this.name,
    required this.returnType,
    required this.isAsync,
    required this.params,
    this.isBuild = false,
  });
}

class ParamInfo {
  final String name;
  final String type;
  final bool isNamed;
  final bool isNullable;
  final String? defaultValue;

  const ParamInfo({
    required this.name,
    required this.type,
    this.isNamed = false,
    this.isNullable = false,
    this.defaultValue,
  });
}

/// Info about the matching State class from the states/ folder
class StateInfo {
  final String className;
  final String importPath;
  final List<StateField> fields;

  const StateInfo({
    required this.className,
    required this.importPath,
    required this.fields,
  });
}

class StateField {
  final String name;
  final String type;
  final bool isNullable;
  final bool isList;
  final String? listItemType;

  const StateField({
    required this.name,
    required this.type,
    this.isNullable = false,
    this.isList = false,
    this.listItemType,
  });
}
