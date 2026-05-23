// lib/src/models/notifier_info.dart

/// Everything the generator needs to know about one Riverpod notifier class.
class NotifierInfo {
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

  /// e.g. `CartNotifier`
  final String className;

  /// Absolute path to source file.
  final String sourceFilePath;

  /// `package:` import path.
  final String importPath;

  /// The generic type arg of `AsyncNotifier<T>` / `Notifier<T>`, e.g. `CartState`.
  final String? stateType;

  /// Whether it extends `AsyncNotifier` (true) or plain `Notifier` (false).
  final bool isAsync;

  /// Repository / service dependencies found in the notifier body.
  final List<RepositoryDep> repositories;

  /// The `build()` method signature.
  final MethodInfo? buildMethod;

  /// All public methods (excluding build).
  final List<MethodInfo> methods;

  /// Resolved state info from the `states/` folder.
  final StateInfo? stateInfo;
}

/// A repository or service dependency detected inside the notifier
/// (via `ref.read(...)`, `ref.watch(...)`, constructor param, or field).
class RepositoryDep {
  const RepositoryDep({
    required this.type,
    required this.name,
    this.providerExpression,
  });

  /// e.g. `CartRepository`
  final String type;

  /// e.g. `cartRepository`
  final String name;

  /// The provider expression, e.g. `cartRepositoryProvider`.
  final String? providerExpression;
}

/// A public method on the notifier that will receive generated test cases.
class MethodInfo {
  const MethodInfo({
    required this.name,
    required this.returnType,
    required this.isAsync,
    required this.params,
    this.isBuild = false,
  });

  final String name;
  final String returnType;
  final bool isAsync;
  final List<ParamInfo> params;

  /// `true` for the `build` method.
  final bool isBuild;
}

/// A single method or constructor parameter.
class ParamInfo {
  const ParamInfo({
    required this.name,
    required this.type,
    this.isNamed = false,
    this.isNullable = false,
    this.defaultValue,
  });

  final String name;
  final String type;
  final bool isNamed;
  final bool isNullable;
  final String? defaultValue;
}

/// Info about the matching state class found in the `states/` folder.
class StateInfo {
  const StateInfo({
    required this.className,
    required this.importPath,
    required this.fields,
  });

  final String className;
  final String importPath;
  final List<StateField> fields;
}

/// A single field declared on a state class.
class StateField {
  const StateField({
    required this.name,
    required this.type,
    this.isNullable = false,
    this.isList = false,
    this.listItemType,
  });

  final String name;
  final String type;
  final bool isNullable;
  final bool isList;

  /// The item type when [isList] is `true`, e.g. `CartItem` for `List<CartItem>`.
  final String? listItemType;
}
