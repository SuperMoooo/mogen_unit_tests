import 'package:mogen_unit_tests/mogen_unit_tests.dart';
import 'package:test/test.dart';

void main() {
  test('generates feature-scoped imports and omits build/error scaffolding',
      () {
    const notifier = NotifierInfo(
      className: 'AuthNotifier',
      sourceFilePath: '/tmp/auth_notifier.dart',
      importPath:
          'package:app/features/localauth/presentation/notifiers/auth_notifier.dart',
      packageName: 'app',
      stateType: 'AuthState',
      isAsync: true,
      repositories: const [
        RepositoryDep(type: 'LocalAuth', name: 'localAuth'),
        RepositoryDep(type: 'CartRepository', name: 'cartRepository'),
      ],
      buildMethod: const MethodInfo(
        name: 'build',
        returnType: 'AuthState',
        isAsync: false,
        params: [],
        isBuild: true,
      ),
      methods: const [
        MethodInfo(
          name: 'refresh',
          returnType: 'Future<void>',
          isAsync: true,
          params: [],
        ),
      ],
    );

    final output = TestGenerator().generate(notifier);

    expect(
        output,
        contains(
            "import 'package:app/features/localauth/domain/repositories/local_auth.dart';"));
    expect(output, isNot(contains("CartRepository")));
    expect(output, isNot(contains("group('build'")));
    expect(output, isNot(contains("handles error from repository")));
    expect(output, contains('expect(finalState, isNotEqualTo(initialState));'));
  });
}
