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
        // Unknown / custom type used as a parameter — generate a Fake stub.
        return 'Fake$type()';
    }
  }

  /// Returns a literal expression suitable for use as a **repository stub
  /// return value** inside `thenAnswer` / `thenReturn`.
  ///
  /// Rules:
  ///   - `void` / `Future<void>` → `null`
  ///   - Primitives and collections → same literals as [forType]
  ///   - Nullable types → `null`
  ///   - Custom / entity classes → `ClassName.empty()`
  static String forReturnType(String rawType) {
    final nullable = rawType.trim().endsWith('?');
    final type = rawType.replaceAll('?', '').trim();

    // Unwrap Future<T> to operate on the inner type.
    final inner = type.startsWith('Future<') ? _generic(type) : type;
    final innerNullable = inner.trim().endsWith('?');
    final innerClean = inner.replaceAll('?', '').trim();

    // void / Future<void>
    if (innerClean == 'void' || innerClean.isEmpty) return 'null';

    // Explicitly nullable → null is the simplest valid value.
    if (nullable || innerNullable) return 'null';

    // Collections
    if (innerClean.startsWith('List<') || innerClean == 'List')
      return 'const []';
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
