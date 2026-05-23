// lib/src/models/notifier_info.dart

/// Everything the generator needs to know about one Riverpod notifier class.
class NotifierInfo {
  /// Creates metadata for a notifier discovered in the source tree.
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

  /// e.g. `CartNotifier`.
  final String className;

  /// Absolute path to the source file that declares the notifier.
  final String sourceFilePath;

  /// The `package:` import path for the notifier source.
  final String importPath;

  /// The generic type argument of `AsyncNotifier<T>` or `Notifier<T>`, for example `CartState`.
  final String? stateType;

  /// Whether the notifier extends `AsyncNotifier`.
  final bool isAsync;

  /// Repository or service dependencies found in the notifier body.
  final List<RepositoryDep> repositories;

  /// The `build()` method signature, if present.
  final MethodInfo? buildMethod;

  /// All public methods on the notifier, excluding `build()`.
  final List<MethodInfo> methods;

  /// Resolved state info from the matching `states/` file, if available.
  final StateInfo? stateInfo;
}

/// A repository or service dependency detected inside the notifier.
class RepositoryDep {
  /// Creates a dependency record for a repository or service.
  const RepositoryDep({
    required this.type,
    required this.name,
    this.providerExpression,
  });

  /// The dependency type, for example `CartRepository`.
  final String type;

  /// The generated field name for the dependency, for example `cartRepository`.
  final String name;

  /// The provider expression used to resolve the dependency, if known.
  final String? providerExpression;
}

/// A public method on the notifier that will receive generated test cases.
class MethodInfo {
  /// Creates metadata for one notifier method.
  const MethodInfo({
    required this.name,
    required this.returnType,
    required this.isAsync,
    required this.params,
    this.isBuild = false,
  });

  /// The method name, for example `loadCart`.
  final String name;

  /// The declared return type of the method.
  final String returnType;

  /// Whether the method is declared `async`.
  final bool isAsync;

  /// The method parameters discovered from the signature.
  final List<ParamInfo> params;

  /// `true` when this metadata describes the `build` method.
  final bool isBuild;
}

/// A single method or constructor parameter.
class ParamInfo {
  /// Creates metadata for one parameter.
  const ParamInfo({
    required this.name,
    required this.type,
    this.isNamed = false,
    this.isNullable = false,
    this.defaultValue,
  });

  /// The parameter name.
  final String name;

  /// The declared parameter type.
  final String type;

  /// Whether the parameter is named.
  final bool isNamed;

  /// Whether the parameter is nullable.
  final bool isNullable;

  /// The default value expression when one is provided.
  final String? defaultValue;
}

/// Information about the matching state class found in the `states/` folder.
class StateInfo {
  /// Creates state metadata for a discovered model.
  const StateInfo({
    required this.className,
    required this.importPath,
    required this.fields,
  });

  /// The state class name.
  final String className;

  /// The `package:` import path for the state file.
  final String importPath;

  /// The fields discovered on the state model.
  final List<StateField> fields;
}

/// A single field declared on a state class.
class StateField {
  /// Creates metadata for one state field.
  const StateField({
    required this.name,
    required this.type,
    this.isNullable = false,
    this.isList = false,
    this.listItemType,
  });

  /// The field name.
  final String name;

  /// The raw field type, without trailing `?`.
  final String type;

  /// Whether the field is nullable.
  final bool isNullable;

  /// Whether the field is a `List<T>`.
  final bool isList;

  /// The item type when [isList] is `true`, for example `CartItem`.
  final String? listItemType;
}
