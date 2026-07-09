// lib/src/utils/mock_value_generator.dart

/// Maps a Dart type string to a sensible literal for generated test scaffolding.
class MockValueGenerator {
  MockValueGenerator._();

  /// Returns a literal expression suitable for use as a **method parameter**
  /// in test arrange blocks (e.g. `final url = '';`).
  static String forType(String rawType) {
    final type = rawType.replaceAll('?', '').trim();

    if (type.startsWith('List<') || type == 'List') return 'const []';
    if (type.startsWith('Map<') || type == 'Map') return 'const {}';
    if (type.startsWith('Set<') || type == 'Set') return 'const {}';
    if (type.startsWith('Future<')) {
      final inner = _generic(type);
      return 'Future.value(${forType(inner)})';
    }
    if (type.startsWith('Stream<')) return 'const Stream.empty()';

    switch (type) {
      case 'String':
        return "''";
      case 'int':
        return '0';
      case 'double':
        return '0.0';
      case 'num':
        return '0';
      case 'bool':
        return 'false';
      case 'dynamic':
      case 'Object':
        return 'null';
      case 'void':
        return '';
      case 'DateTime':
        return 'DateTime(2024)';
      case 'Duration':
        return 'Duration.zero';
      case 'Uri':
        return "Uri.parse('https://example.com')";
      default:
        // Unknown / custom type used as a parameter — construct a minimal
        // instance via the same `.empty()` convention used for repository
        // stub return values. A `Fake` from mocktail is only meant to be used
        // as an `any()`/`registerFallbackValue` matcher, not as a real value
        // fed into the notifier's own logic, and no `Fake$type` class is ever
        // generated, so using it here would produce a non-compiling test.
        return '$type.empty()';
    }
  }

  /// Returns a literal expression suitable for use as a **repository stub
  /// return value** inside `thenAnswer` / `thenReturn`.
  ///
  /// Rules:
  ///   - `void` / `Future<void>`           → `null`
  ///   - nullable types (`T?`)              → `null`
  ///   - primitives                         → literal (`''`, `0`, `false`, …)
  ///   - `List<CustomType>`                 → `[CustomType.empty()]`
  ///   - `List<primitive>`                  → `[]`
  ///   - custom / entity class              → `ClassName.empty()`
  static String forReturnType(String rawType) {
    final nullable = rawType.trim().endsWith('?');
    final type = rawType.replaceAll('?', '').trim();

    // Unwrap Future<T>/FutureOr<T> to operate on the inner type.
    final inner = _isFutureWrapped(type) ? _generic(type) : type;
    final innerNullable = inner.trim().endsWith('?');
    final innerClean = inner.replaceAll('?', '').trim();

    // void / Future<void>
    if (innerClean == 'void' || innerClean.isEmpty) return 'null';

    // Explicitly nullable → null is the simplest valid value.
    if (nullable || innerNullable) return 'null';

    // List<T> — check whether T is a custom type or a primitive.
    if (innerClean.startsWith('List<')) {
      final itemType = _generic(innerClean).replaceAll('?', '').trim();
      if (isPrimitive(itemType) || itemType == 'dynamic') return '[]';
      return '[${itemType}.empty()]';
    }

    if (innerClean.startsWith('Map<') || innerClean == 'Map') return 'const {}';
    if (innerClean.startsWith('Set<') || innerClean == 'Set') return 'const {}';

    // Primitives
    switch (innerClean) {
      case 'String':
        return "''";
      case 'int':
        return '0';
      case 'double':
        return '0.0';
      case 'num':
        return '0';
      case 'bool':
        return 'false';
      case 'dynamic':
      case 'Object':
        return 'null';
      case 'DateTime':
        return 'DateTime(2024)';
      case 'Duration':
        return 'Duration.zero';
      case 'Uri':
        return "Uri.parse('https://example.com')";
    }

    // Custom / entity class → use the `.empty()` named constructor.
    return '$innerClean.empty()';
  }

  /// Extracts the leaf custom type from a return type string, unwrapping
  /// `Future<T>` and `List<T>`. Returns `null` for primitives, void, and
  /// nullable types (which stub as `null` and need no import).
  ///
  /// Examples:
  ///   `Future<UserEntity>`       → `UserEntity`
  ///   `Future<List<UserEntity>>` → `UserEntity`
  ///   `Future<void>`             → `null`
  ///   `Future<String?>`          → `null`
  ///   `Future<String>`           → `null`
  static String? extractCustomType(String rawType) {
    final nullable = rawType.trim().endsWith('?');
    if (nullable) return null;

    final type = rawType.replaceAll('?', '').trim();

    // Unwrap Future<T>/FutureOr<T>
    final inner = _isFutureWrapped(type) ? _generic(type) : type;
    final innerNullable = inner.trim().endsWith('?');
    if (innerNullable) return null;

    final innerClean = inner.replaceAll('?', '').trim();

    if (innerClean == 'void' || innerClean.isEmpty) return null;

    // Unwrap List<T>
    final candidate =
        innerClean.startsWith('List<') ? _generic(innerClean) : innerClean;
    final candidateClean = candidate.replaceAll('?', '').trim();

    if (isPrimitive(candidateClean) || candidateClean == 'dynamic') return null;
    if (candidateClean.startsWith('Map<') || candidateClean.startsWith('Set<'))
      return null;

    return candidateClean;
  }

  /// Whether [type] is a `Future<T>`/`FutureOr<T>` wrapper whose inner type
  /// carries the actual stub value.
  static bool _isFutureWrapped(String type) =>
      type.startsWith('Future<') || type.startsWith('FutureOr<');

  static String _generic(String type) {
    final s = type.indexOf('<') + 1;
    final e = type.lastIndexOf('>');
    if (s > 0 && e > s) return type.substring(s, e).trim();
    return 'dynamic';
  }

  /// Returns `true` when [type] is one of the primitive literal types.
  static bool isPrimitive(String type) {
    const primitives = {
      'String',
      'int',
      'double',
      'bool',
      'num',
      'dynamic',
      'Object',
      'void',
      'DateTime',
      'Duration',
      'Uri',
    };
    return primitives.contains(type.replaceAll('?', ''));
  }
}
