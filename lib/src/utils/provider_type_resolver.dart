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
}
