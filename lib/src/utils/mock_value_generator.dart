// lib/src/utils/mock_value_generator.dart

/// Maps a Dart type string → a sensible literal for test scaffolding.
class MockValueGenerator {
  MockValueGenerator._();

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
        // Complex type → emit a Fake() call
        return 'Fake$type()';
    }
  }

  static String _generic(String type) {
    final s = type.indexOf('<') + 1;
    final e = type.lastIndexOf('>');
    if (s > 0 && e > s) return type.substring(s, e).trim();
    return 'dynamic';
  }

  static bool isPrimitive(String type) {
    const p = {
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
    return p.contains(type.replaceAll('?', ''));
  }
}
