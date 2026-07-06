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
  static String resolve(String camelCasePrefix) {
    final override = _knownOverrides[camelCasePrefix];
    if (override != null) return override;
    if (camelCasePrefix.isEmpty) return camelCasePrefix;
    return camelCasePrefix[0].toUpperCase() + camelCasePrefix.substring(1);
  }
}
