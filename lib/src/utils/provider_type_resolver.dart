// lib/src/utils/provider_type_resolver.dart

/// Resolves the type name implied by a Riverpod provider's camelCase prefix
/// (e.g. the `router` in `routerProvider`), or by a camelCase field/variable
/// name. Used by both the notifier parser (to label a discovered dependency)
/// and the method-call detector (to match calls back to that same
/// dependency) — kept in one place so the two can never derive different
/// answers for the same name.
///
/// Most names just need their first letter capitalized (`authRepository` →
/// `AuthRepository`), but a few provider names don't follow that rule
/// because the DI convention names the *variable* generically while the
/// concrete type is a specific SDK class — most notably `routerProvider`,
/// which conventionally exposes a `go_router` `GoRouter` instance, not
/// Flutter's own `Router` class (which isn't a concrete, mockable
/// navigation type).
class ProviderTypeResolver {
  ProviderTypeResolver._();

  static const _knownOverrides = {
    'router': 'GoRouter',
  };

  /// Converts a camelCase prefix to its PascalCase type name, applying known
  /// overrides where naive capitalization would guess wrong.
  ///
  /// Leading underscores are stripped first, since Dart's usual private
  /// field/getter convention (`_authRepository`) would otherwise capitalize
  /// to `_authRepository` (the underscore has no uppercase form) instead of
  /// `AuthRepository`, silently failing to match the type it's the private
  /// backing field for.
  static String resolve(String camelCasePrefix) {
    final normalized = camelCasePrefix.replaceFirst(RegExp(r'^_+'), '');
    final override = _knownOverrides[normalized];
    if (override != null) return override;
    if (normalized.isEmpty) return normalized;
    return normalized[0].toUpperCase() + normalized.substring(1);
  }

  /// Extracts the camelCase prefix of the provider identifier at the start
  /// of a full provider *expression* — tolerating `.notifier`/`.future`
  /// accessors and family call arguments alike:
  ///
  ///   `authRepositoryProvider`          → `authRepository`
  ///   `userNotifierProvider.notifier`   → `userNotifier`
  ///   `userNotifierProvider.future`     → `userNotifier`
  ///   `chatProvider(roomId).notifier`   → `chat`
  ///
  /// Returns `null` when the expression doesn't start with a
  /// `...Provider`-named identifier.
  static String? providerPrefix(String providerExpression) {
    final match = RegExp(r'^([a-z_][a-zA-Z0-9_]*)Provider\b')
        .firstMatch(providerExpression.trim());
    return match?.group(1);
  }

  /// Resolves the dependency type implied by a full provider expression, or
  /// `null` when the expression doesn't look like a provider read. This is
  /// [providerPrefix] + [resolve] in one step, shared by the notifier parser
  /// and the method-call detector so they can never disagree.
  static String? typeFromProviderExpression(String providerExpression) {
    final prefix = providerPrefix(providerExpression);
    if (prefix == null) return null;
    return resolve(prefix);
  }
}
