// Import the generator and models
// Update these imports to match your actual package structure
import 'dart:io';

import 'package:mogen_unit_tests/src/generators/test_generator.dart';
import 'package:mogen_unit_tests/src/models/notifier_info.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('TestGenerator', () {
    late TestGenerator generator;

    setUp(() {
      generator = TestGenerator(projectRoot: ".");
    });

    test(
        'generates imports for every repository dependency, including ones '
        'from other features, and omits the build method', () {
      const notifier = NotifierInfo(
        className: 'AuthNotifier',
        sourceFilePath: '/tmp/auth_notifier.dart',
        importPath:
            'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
        packageName: 'app',
        stateType: 'AuthState',
        isAsync: true,
        repositories: const [
          RepositoryDep(type: 'AuthRepository', name: 'authRepository'),
          RepositoryDep(type: 'CartRepository', name: 'cartRepository'),
        ],
        buildMethod: MethodInfo(
          name: 'build',
          returnType: 'FutureOr<AuthState>',
          isAsync: true,
          params: const [],
          isBuild: true,
        ),
        methods: const [
          MethodInfo(
            name: 'login',
            returnType: 'Future<void>',
            isAsync: true,
            params: [
              ParamInfo(
                name: 'email',
                type: 'String',
                isNamed: true,
              ),
              ParamInfo(
                name: 'password',
                type: 'String',
                isNamed: true,
              ),
            ],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Should import the auth feature's own repository.
      expect(
        output,
        contains(
            "import 'package:app/features/auth/domain/repositories/auth_repository.dart';"),
      );

      // A dependency isn't skipped just because it doesn't belong to this
      // notifier's own feature — every dependency the notifier actually
      // touches should be mocked, otherwise the real implementation runs
      // inside what's supposed to be an isolated unit test.
      expect(output, contains('class MockCartRepository extends Mock'));
      expect(
        output,
        contains(
            "import 'package:app/features/auth/domain/repositories/cart_repository.dart';"),
      );

      // Should NOT generate test for build method
      expect(output, isNot(contains("group('build'")));
    });

    test('filters out service/non-repository types (LocalAuth)', () {
      const notifier = NotifierInfo(
        className: 'AuthNotifier',
        sourceFilePath: '/tmp/auth_notifier.dart',
        importPath:
            'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
        packageName: 'app',
        stateType: 'AuthState',
        isAsync: true,
        repositories: const [
          RepositoryDep(type: 'AuthRepository', name: 'authRepository'),
          RepositoryDep(type: 'LocalAuth', name: 'localAuth'),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'login',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Should include AuthRepository mock
      expect(output, contains('class MockAuthRepository extends Mock'));

      // Should NOT include LocalAuth mock (it's a service, not a repository)
      expect(output, isNot(contains('class MockLocalAuth extends Mock')));
      expect(
        output,
        isNot(contains('localAuthProvider')),
      );
    });

    test('omits build method from test groups', () {
      const notifier = NotifierInfo(
        className: 'UserNotifier',
        sourceFilePath: '/tmp/user_notifier.dart',
        importPath:
            'package:app/features/user/presentation/notifiers/user_notifier.dart',
        packageName: 'app',
        stateType: 'UserState',
        isAsync: true,
        repositories: const [],
        buildMethod: MethodInfo(
          name: 'build',
          returnType: 'FutureOr<UserState>',
          isAsync: true,
          params: const [],
          isBuild: true,
        ),
        methods: const [
          MethodInfo(
            name: 'loadUser',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Should NOT have test group for 'build'
      expect(output, isNot(contains("group('build'")));

      // Should have test group for 'loadUser'
      expect(output, contains("group('loadUser'"));
    });

    test('skips internal helper methods starting with p', () {
      const notifier = NotifierInfo(
        className: 'DataNotifier',
        sourceFilePath: '/tmp/data_notifier.dart',
        importPath:
            'package:app/features/data/presentation/notifiers/data_notifier.dart',
        packageName: 'app',
        stateType: 'DataState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'loadData',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
          MethodInfo(
            name: 'pOnSuccess',
            returnType: 'void',
            isAsync: false,
            params: [],
          ),
          MethodInfo(
            name: 'pOnError',
            returnType: 'void',
            isAsync: false,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Should generate test for 'loadData'
      expect(output, contains("group('loadData'"));

      // Should NOT generate tests for 'pOnSuccess' and 'pOnError'
      expect(output, isNot(contains("group('pOnSuccess'")));
      expect(output, isNot(contains("group('pOnError'")));
    });

    test('generates state field assertions for known patterns', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}form_notifier.dart');
        file.writeAsStringSync('''
class FormNotifier extends AsyncNotifier<FormState> {
  Future<void> submit() async {
    await ref.read(formRepositoryProvider).submit();
    state = AsyncData(state.requireValue.copyWith(success: 'ok'));
  }
}
''');

        final notifier = NotifierInfo(
          className: 'FormNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/form/presentation/notifiers/form_notifier.dart',
          packageName: 'app',
          stateType: 'FormState',
          isAsync: true,
          repositories: const [
            RepositoryDep(
              type: 'FormRepository',
              name: 'formRepository',
              providerExpression: 'formRepositoryProvider',
            ),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'submit',
              returnType: 'Future<void>',
              isAsync: true,
              params: [],
            ),
          ],
          stateInfo: const StateInfo(
            className: 'FormState',
            importPath:
                'package:app/features/form/presentation/states/form_state.dart',
            fields: [
              StateField(
                name: 'isLoadingAction',
                type: 'bool',
                isNullable: false,
              ),
              StateField(
                name: 'error',
                type: 'String',
                isNullable: true,
              ),
              StateField(
                name: 'success',
                type: 'String',
                isNullable: true,
              ),
            ],
          ),
        );

        final output = generator.generate(notifier);

        // Success path should clear the error and surface the success message.
        expect(output,
            contains('expect(finalState.requireValue.error, isNull);'));
        expect(output,
            contains('expect(finalState.requireValue.success, isNotNull);'));

        // Error path should surface the error and clear any success message.
        expect(
            output,
            contains(
                "test('submit shows an error when the repository fails'"));
        expect(output,
            contains('expect(finalState.requireValue.error, isNotNull);'));
        expect(output,
            contains('expect(finalState.requireValue.success, isNull);'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('generates proper async/await syntax for async methods', () {
      const notifier = NotifierInfo(
        className: 'AsyncNotifier',
        sourceFilePath: '/tmp/async_notifier.dart',
        importPath:
            'package:app/features/async/presentation/notifiers/async_notifier.dart',
        packageName: 'app',
        stateType: 'AsyncState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'fetchData',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
          MethodInfo(
            name: 'syncData',
            returnType: 'void',
            isAsync: false,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Async method should use await
      expect(output, contains('await container.read'));

      // Both methods should appear in tests
      expect(output, contains("group('fetchData'"));
      expect(output, contains("group('syncData'"));
    });

    test('generates method input variables from parameters', () {
      const notifier = NotifierInfo(
        className: 'SearchNotifier',
        sourceFilePath: '/tmp/search_notifier.dart',
        importPath:
            'package:app/features/search/presentation/notifiers/search_notifier.dart',
        packageName: 'app',
        stateType: 'SearchState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'search',
            returnType: 'Future<void>',
            isAsync: true,
            params: [
              ParamInfo(
                name: 'query',
                type: 'String',
                isNamed: true,
              ),
              ParamInfo(
                name: 'limit',
                type: 'int',
                isNamed: true,
              ),
            ],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Should generate input variables — `const` since both are
      // compile-time-constant-compatible primitive literals.
      expect(output, contains("const query = '';"));
      expect(output, contains('const limit = 0;'));

      // Should use these in the method call
      expect(output, contains('query: query'));
      expect(output, contains('limit: limit'));
    });

    test('does not generate fake classes for primitive types', () {
      const notifier = NotifierInfo(
        className: 'SimpleNotifier',
        sourceFilePath: '/tmp/simple_notifier.dart',
        importPath:
            'package:app/features/simple/presentation/notifiers/simple_notifier.dart',
        packageName: 'app',
        stateType: 'SimpleState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'update',
            returnType: 'Future<void>',
            isAsync: true,
            params: [
              ParamInfo(name: 'value', type: 'String', isNamed: true),
              ParamInfo(name: 'count', type: 'int', isNamed: true),
              ParamInfo(name: 'enabled', type: 'bool', isNamed: true),
            ],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Should NOT generate Fake classes for primitives
      expect(output, isNot(contains('class FakeString')));
      expect(output, isNot(contains('class FakeInt')));
      expect(output, isNot(contains('class FakeBool')));

      // Should NOT have a "Fakes" section at all
      expect(output, isNot(contains('// ── Fakes')));
    });

    test('imports state file when stateInfo is provided', () {
      const notifier = NotifierInfo(
        className: 'CartNotifier',
        sourceFilePath: '/tmp/cart_notifier.dart',
        importPath:
            'package:app/features/cart/presentation/notifiers/cart_notifier.dart',
        packageName: 'app',
        stateType: 'CartState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [],
        stateInfo: StateInfo(
          className: 'CartState',
          importPath:
              'package:app/features/cart/presentation/states/cart_state.dart',
          fields: const [],
        ),
      );

      final output = generator.generate(notifier);

      // Should import the state file
      expect(
          output,
          contains(
              "import 'package:app/features/cart/presentation/states/cart_state.dart';"));
    });

    test('handles notifiers with multiple repositories from same feature', () {
      const notifier = NotifierInfo(
        className: 'OrderNotifier',
        sourceFilePath: '/tmp/order_notifier.dart',
        importPath:
            'package:app/features/order/presentation/notifiers/order_notifier.dart',
        packageName: 'app',
        stateType: 'OrderState',
        isAsync: true,
        repositories: const [
          RepositoryDep(type: 'OrderRepository', name: 'orderRepository'),
          RepositoryDep(
              type: 'OrderItemRepository', name: 'orderItemRepository'),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'placeOrder',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Both repositories should be mocked (same feature - order)
      expect(output, contains('class MockOrderRepository'));
      expect(output, contains('class MockOrderItemRepository'));

      // Both should have overrides
      expect(output, contains('orderRepositoryProvider'));
      expect(output, contains('orderItemRepositoryProvider'));
    });

    test('mocks repository dependencies from other features too', () {
      const notifier = NotifierInfo(
        className: 'OrderNotifier',
        sourceFilePath: '/tmp/order_notifier.dart',
        importPath:
            'package:app/features/order/presentation/notifiers/order_notifier.dart',
        packageName: 'app',
        stateType: 'OrderState',
        isAsync: true,
        repositories: const [
          RepositoryDep(type: 'OrderRepository', name: 'orderRepository'),
          RepositoryDep(type: 'PaymentRepository', name: 'paymentRepository'),
        ],
        buildMethod: null,
        methods: const [],
      );

      final output = generator.generate(notifier);

      // Should include OrderRepository (same feature)
      expect(output, contains('class MockOrderRepository'));

      // A repository from another feature is still a real dependency this
      // notifier relies on, and must be overridden too so the test doesn't
      // exercise the real PaymentRepository implementation.
      expect(output, contains('class MockPaymentRepository'));
      expect(output, contains('paymentRepositoryProvider'));
    });

    test('scopes repository stubs to the current method group only', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
        file.writeAsStringSync('''
class AuthNotifier {
  final AuthRepository authRepository;

  AuthNotifier(this.authRepository);

  Future<void> login() async {
    await authRepository.login();
  }

  Future<void> logout() async {
    await authRepository.logout();
  }
}
''');

        final notifier = NotifierInfo(
          className: 'AuthNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
          packageName: 'app',
          stateType: 'AuthState',
          isAsync: true,
          repositories: const [
            RepositoryDep(type: 'AuthRepository', name: 'authRepository'),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'login',
              returnType: 'Future<void>',
              isAsync: true,
              params: [],
            ),
            MethodInfo(
              name: 'logout',
              returnType: 'Future<void>',
              isAsync: true,
              params: [],
            ),
          ],
        );

        final output = generator.generate(notifier);

        final loginSection = output.substring(
          output.indexOf("group('login'"),
          output.indexOf("group('logout'"),
        );

        expect(loginSection, contains('mockAuthRepository.login()'));
        expect(loginSection, isNot(contains('mockAuthRepository.logout()')));

        final logoutSection = output.substring(
          output.indexOf("group('logout'"),
          output.length,
        );

        expect(logoutSection, contains('mockAuthRepository.logout()'));
        expect(logoutSection, isNot(contains('mockAuthRepository.login()')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('uses repository call named arguments when stubbing', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
        file.writeAsStringSync('''
class AuthNotifier {
  final AuthRepository authRepository;

  AuthNotifier(this.authRepository);

  Future<void> login({required String email, required String password}) async {
    await authRepository.login(email: email, password: password);
  }
}
''');

        final notifier = NotifierInfo(
          className: 'AuthNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
          packageName: 'app',
          stateType: 'AuthState',
          isAsync: true,
          repositories: const [
            RepositoryDep(type: 'AuthRepository', name: 'authRepository'),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'login',
              returnType: 'Future<void>',
              isAsync: true,
              params: [
                ParamInfo(name: 'email', type: 'String', isNamed: true),
                ParamInfo(name: 'password', type: 'String', isNamed: true),
              ],
            ),
          ],
        );

        final output = generator.generate(notifier);

        expect(output, contains('when('));
        expect(output, contains('mockAuthRepository.login('));
        expect(output, contains("email: any(named: 'email')"));
        expect(output, contains("password: any(named: 'password')"));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'omits the error-path test when the method makes no dependency '
        'calls — there is no failure to simulate, so the test could never '
        'pass', () {
      const notifier = NotifierInfo(
        className: 'RiskyNotifier',
        sourceFilePath: '/tmp/risky_notifier.dart',
        importPath:
            'package:app/features/risky/presentation/notifiers/risky_notifier.dart',
        packageName: 'app',
        stateType: 'RiskyState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'doSomethingRisky',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // No dependencies → nothing can throw → an error test asserting a
      // non-null error would be guaranteed to fail.
      expect(output, isNot(contains('shows an error when the repository fails')));
      expect(output, contains('No error-path test'));
      // The success test is still generated.
      expect(output,
          contains("test('doSomethingRisky completes successfully'"));
    });

    test('throws in the error-path scaffold when a repository call exists', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_error_test_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
        file.writeAsStringSync('''
class AuthNotifier {
  final AuthRepository authRepository;

  AuthNotifier(this.authRepository);

  Future<void> login() async {
    await authRepository.login();
  }
}
''');

        final notifier = NotifierInfo(
          className: 'AuthNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
          packageName: 'app',
          stateType: 'AuthState',
          isAsync: true,
          repositories: const [
            RepositoryDep(type: 'AuthRepository', name: 'authRepository'),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'login',
              returnType: 'Future<void>',
              isAsync: true,
              params: [],
            ),
          ],
        );

        final output = generator.generate(notifier);

        expect(output,
            contains("test('login shows an error when the repository fails'"));
        expect(output, contains('when(() => mockAuthRepository.login())'));
        expect(output, contains('thenThrow(AppException.test())'));

        // The AppException import should only be emitted because it's
        // actually used in the error-path scaffold above.
        expect(
          output,
          contains("import 'package:app/core/errors/app_exception.dart';"),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('does not import AppException when no error stub needs it', () {
      const notifier = NotifierInfo(
        className: 'SimpleNotifier',
        sourceFilePath: '/tmp/simple_notifier.dart',
        importPath:
            'package:app/features/simple/presentation/notifiers/simple_notifier.dart',
        packageName: 'app',
        stateType: 'SimpleState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'doNothing',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      expect(output, isNot(contains('AppException')));
      expect(output, isNot(contains('app_exception.dart')));
    });

    test('generates only success test case per method', () {
      const notifier = NotifierInfo(
        className: 'SimpleNotifier',
        sourceFilePath: '/tmp/simple_notifier.dart',
        importPath:
            'package:app/features/simple/presentation/notifiers/simple_notifier.dart',
        packageName: 'app',
        stateType: 'SimpleState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'action1',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
          MethodInfo(
            name: 'action2',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Should have exactly one test per method
      expect(output, contains("test('action1 completes successfully'"));
      expect(output, contains("test('action2 completes successfully'"));

      // Count occurrences - should be 1 per method
      final count1 = 'action1 completes successfully'.allMatches(output).length;
      final count2 = 'action2 completes successfully'.allMatches(output).length;

      expect(count1, equals(1));
      expect(count2, equals(1));
    });

    test(
        'mocks a cross-notifier dependency and resolves its import via the '
        'project-wide notifier index', () {
      final indexedGenerator = TestGenerator(
        projectRoot: '.',
        notifierIndex: const {
          'CartNotifier':
              'package:app/features/cart/presentation/notifiers/cart_notifier.dart',
        },
      );

      const notifier = NotifierInfo(
        className: 'CheckoutNotifier',
        sourceFilePath: '/tmp/checkout_notifier.dart',
        importPath:
            'package:app/features/checkout/presentation/notifiers/checkout_notifier.dart',
        packageName: 'app',
        stateType: 'CheckoutState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'CartNotifier',
            name: 'cartNotifier',
            providerExpression: 'cartNotifierProvider.notifier',
          ),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'checkout',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = indexedGenerator.generate(notifier);

      // The other notifier is a real dependency and must be mocked, not left
      // to run for real inside this notifier's test.
      expect(output, contains('class MockCartNotifier extends Mock'));
      expect(
        output,
        contains(
            "import 'package:app/features/cart/presentation/notifiers/cart_notifier.dart';"),
      );

      // Notifier-shaped dependencies override the provider's *implementation*
      // (overrideWith), not its exposed state value (overrideWithValue).
      // The override applies to the *base* provider — `.notifier` is just a
      // read-time accessor, not a separately overridable provider, so the
      // captured `cartNotifierProvider.notifier` expression must have that
      // suffix stripped here even though it's kept as-is anywhere else the
      // captured expression is used verbatim.
      expect(
        output,
        contains('cartNotifierProvider.overrideWith(() => mockCartNotifier)'),
      );
      expect(
        output,
        isNot(contains('cartNotifierProvider.notifier.overrideWith')),
      );
    });

    test(
        'mocks a raw SDK dependency reached via ref.read even though its '
        'type name matches no repository-style suffix', () {
      const notifier = NotifierInfo(
        className: 'AuthNotifier',
        sourceFilePath: '/tmp/auth_notifier.dart',
        importPath:
            'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
        packageName: 'app',
        stateType: 'AuthState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'FlutterSecureStorage',
            name: 'secureStorage',
            providerExpression: 'secureStorageProvider',
          ),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'login',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Reached via ref.read(...) — that's the DI seam, so it must be mocked
      // regardless of its type name not looking like a repository/service.
      expect(
          output, contains('class MockFlutterSecureStorage extends Mock'));
      expect(
          output, contains('secureStorageProvider.overrideWithValue'));

      // The import location can't be resolved from a bare NotifierInfo (no
      // source imports, no index entry), so a visible TODO should be emitted
      // instead of a silently wrong guessed path.
      expect(output, contains('TODO(mogen_unit_tests)'));
    });

    test('resolves a dependency import from the notifier\'s own source file',
        () {
      const notifier = NotifierInfo(
        className: 'AuthNotifier',
        sourceFilePath: '/tmp/auth_notifier.dart',
        importPath:
            'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
        packageName: 'app',
        stateType: 'AuthState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'ApiClient',
            name: 'apiClient',
            providerExpression: 'apiClientProvider',
          ),
        ],
        buildMethod: null,
        methods: const [],
        sourceImports: [
          'package:app/core/network/api_client.dart',
        ],
      );

      final output = generator.generate(notifier);

      expect(
        output,
        contains("import 'package:app/core/network/api_client.dart';"),
      );
      expect(output, isNot(contains('TODO(mogen_unit_tests)')));
    });

    test('does not emit .future for a plain (synchronous) Notifier', () {
      const notifier = NotifierInfo(
        className: 'CounterNotifier',
        sourceFilePath: '/tmp/counter_notifier.dart',
        importPath:
            'package:app/features/counter/presentation/notifiers/counter_notifier.dart',
        packageName: 'app',
        stateType: 'CounterState',
        isAsync: false,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'increment',
            returnType: 'void',
            isAsync: false,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // A plain NotifierProvider has no `.future` getter.
      expect(output, isNot(contains('.future')));
      expect(output, contains('container.read(counterNotifierProvider);'));
    });

    test('does not force await on the error-path call for a sync method', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file = File(
            '${tempDir.path}${Platform.pathSeparator}counter_notifier.dart');
        file.writeAsStringSync('''
class CounterNotifier extends Notifier<CounterState> {
  void increment() {
    ref.read(analyticsServiceProvider).track();
  }
}
''');

        final notifier = NotifierInfo(
          className: 'CounterNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/counter/presentation/notifiers/counter_notifier.dart',
          packageName: 'app',
          stateType: 'CounterState',
          isAsync: false,
          repositories: const [
            RepositoryDep(
              type: 'AnalyticsService',
              name: 'analyticsService',
              providerExpression: 'analyticsServiceProvider',
            ),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'increment',
              returnType: 'void',
              isAsync: false,
              params: [],
            ),
          ],
        );

        final output = generator.generate(notifier);

        final errorTest = output.substring(
          output.indexOf('shows an error when the repository fails'),
        );
        expect(errorTest, contains('thenThrow(AppException.test())'));
        expect(
          errorTest,
          isNot(contains(
              'await container.read(counterNotifierProvider.notifier).increment')),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('uses .empty() instead of an undefined Fake class for custom-type '
        'method parameters', () {
      const notifier = NotifierInfo(
        className: 'CartNotifier',
        sourceFilePath: '/tmp/cart_notifier.dart',
        importPath:
            'package:app/features/cart/presentation/notifiers/cart_notifier.dart',
        packageName: 'app',
        stateType: 'CartState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'addItem',
            returnType: 'Future<void>',
            isAsync: true,
            params: [
              ParamInfo(name: 'item', type: 'CartItem'),
            ],
          ),
        ],
      );

      final output = generator.generate(notifier);

      expect(output, contains('final item = CartItem.empty();'));
      expect(output, isNot(contains('FakeCartItem')));
      expect(output, isNot(contains('class Fake')));
    });

    test('treats a public method starting with lowercase p as a real method',
        () {
      const notifier = NotifierInfo(
        className: 'PublishingNotifier',
        sourceFilePath: '/tmp/publishing_notifier.dart',
        importPath:
            'package:app/features/publishing/presentation/notifiers/publishing_notifier.dart',
        packageName: 'app',
        stateType: 'PublishingState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'publish',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
          MethodInfo(
            name: 'pOnSuccess',
            returnType: 'void',
            isAsync: false,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // `publish` is a real method (lowercase p followed by a lowercase
      // letter) and must not be treated as an internal `pXxx` helper.
      expect(output, contains("group('publish'"));
      // `pOnSuccess` still matches the internal-helper convention.
      expect(output, isNot(contains("group('pOnSuccess'")));
    });

    test('mocks a router dependency as GoRouter from go_router', () {
      const notifier = NotifierInfo(
        className: 'AuthNotifier',
        sourceFilePath: '/tmp/auth_notifier.dart',
        importPath:
            'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
        packageName: 'app',
        stateType: 'AuthState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'GoRouter',
            name: 'router',
            providerExpression: 'routerProvider',
          ),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'login',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // The provider name heuristic would naively guess `Router`, which
      // isn't a concrete, mockable navigation type — these apps always
      // store a `GoRouter` behind `routerProvider`.
      expect(output, contains('class MockGoRouter extends Mock implements GoRouter {}'));
      expect(
        output,
        contains("import 'package:go_router/go_router.dart';"),
      );
      expect(output, isNot(contains('TODO(mogen_unit_tests)')));
      expect(output, isNot(contains('implements Router')));
    });

    test(
        'adds the interface import alongside a source-discovered impl-only '
        'import for a Repository dependency', () {
      const notifier = NotifierInfo(
        className: 'AuthNotifier',
        sourceFilePath: '/tmp/auth_notifier.dart',
        importPath:
            'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
        packageName: 'app',
        stateType: 'AuthState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'AuthRepository',
            name: 'authRepository',
            providerExpression: 'authRepositoryProvider',
          ),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'login',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
        // The notifier's own source only imports the impl file (e.g.
        // because that's where `authRepositoryProvider` is declared) —
        // it never imports the bare interface file directly.
        sourceImports: [
          'package:app/features/auth/data/repositories/auth_repository_impl.dart',
        ],
      );

      final output = generator.generate(notifier);

      // `implements AuthRepository` needs the interface import even though
      // the notifier's own source never imports it directly.
      expect(
        output,
        contains(
            "import 'package:app/features/auth/domain/repositories/auth_repository.dart';"),
      );
      expect(
        output,
        contains(
            "import 'package:app/features/auth/data/repositories/auth_repository_impl.dart';"),
      );
      expect(output, isNot(contains('TODO(mogen_unit_tests)')));
    });

    test(
        'resolves the interface import from the dependency\'s own feature, '
        'not the consuming notifier\'s feature', () {
      const notifier = NotifierInfo(
        className: 'AuthNotifier',
        sourceFilePath: '/tmp/auth_notifier.dart',
        importPath:
            'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
        packageName: 'app',
        stateType: 'AuthState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'UserRepository',
            name: 'userRepository',
            providerExpression: 'userRepositoryProvider',
          ),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'login',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
        // AuthNotifier only ever imports the impl file, and that impl file
        // lives under the `user` feature — not `auth`.
        sourceImports: [
          'package:app/features/user/data/repositories/user_repository_impl.dart',
        ],
      );

      final output = generator.generate(notifier);

      // The interface import must use the repository's own feature (`user`)
      // rather than the notifier's feature (`auth`).
      expect(
        output,
        contains(
            "import 'package:app/features/user/domain/repositories/user_repository.dart';"),
      );
      expect(
        output,
        isNot(contains('features/auth/domain/repositories/user_repository.dart')),
      );
    });

    test(
        'strips .future from a captured provider expression before using it '
        'in overrideWith, since Riverpod overrides apply to the base '
        'provider', () {
      const notifier = NotifierInfo(
        className: 'AuthNotifier',
        sourceFilePath: '/tmp/auth_notifier.dart',
        importPath:
            'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
        packageName: 'app',
        stateType: 'AuthState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'UserNotifier',
            name: 'userNotifier',
            // Captured verbatim from a source call like
            // `ref.read(userNotifierProvider.future)`.
            providerExpression: 'userNotifierProvider.future',
          ),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'login',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      expect(
        output,
        contains('userNotifierProvider.overrideWith(() => mockUserNotifier)'),
      );
      expect(
        output,
        isNot(contains('userNotifierProvider.future.overrideWith')),
      );
    });

    test('uses const instead of final for compile-time-constant inputs', () {
      const notifier = NotifierInfo(
        className: 'SearchNotifier',
        sourceFilePath: '/tmp/search_notifier.dart',
        importPath:
            'package:app/features/search/presentation/notifiers/search_notifier.dart',
        packageName: 'app',
        stateType: 'SearchState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'search',
            returnType: 'Future<void>',
            isAsync: true,
            params: [
              ParamInfo(name: 'query', type: 'String', isNamed: true),
              ParamInfo(name: 'limit', type: 'int', isNamed: true),
              ParamInfo(name: 'tags', type: 'List<String>', isNamed: true),
              ParamInfo(name: 'startedAt', type: 'DateTime', isNamed: true),
            ],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Compile-time-constant-compatible types use `const`.
      expect(output, contains("const query = '';"));
      expect(output, contains('const limit = 0;'));
      expect(output, contains('const tags = [];'));
      expect(output, isNot(contains('const tags = const [];')));

      // `DateTime` isn't const-constructible — must stay `final`.
      expect(output, contains('final startedAt = DateTime(2024);'));
    });

    test(
        'detects a direct call through a private underscore-prefixed field '
        '(the common Dart convention), not just a public one', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
        file.writeAsStringSync('''
class AuthNotifier {
  final AuthRepository _authRepository;

  AuthNotifier(this._authRepository);

  Future<void> login() async {
    await _authRepository.login();
  }
}
''');

        final notifier = NotifierInfo(
          className: 'AuthNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
          packageName: 'app',
          stateType: 'AuthState',
          isAsync: true,
          repositories: const [
            RepositoryDep(type: 'AuthRepository', name: 'authRepository'),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'login',
              returnType: 'Future<void>',
              isAsync: true,
              params: [],
            ),
          ],
        );

        final output = generator.generate(notifier);

        expect(output, contains('mockAuthRepository.login()'));
        expect(output, isNot(contains('No mocks needed for AuthRepository')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'does not stub a method on dependencies that method never actually '
        'calls, even when several dependencies share the same method name '
        'across different notifier methods', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
        file.writeAsStringSync('''
class AuthNotifier extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async {
    // Touched only in build() — must not leak into login()/logout().
    ref.read(routerProvider).push('/splash');
    ref.read(userNotifierProvider.notifier);
    return AuthState.empty();
  }

  Future<void> login({required String email, required String password}) async {
    await ref.read(authRepositoryProvider).login(email: email, password: password);
    await ref.read(localAuthProvider).login(email: email, password: password);
  }

  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    ref.read(routerProvider).go('/login');
  }
}
''');

        final notifier = NotifierInfo(
          className: 'AuthNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
          packageName: 'app',
          stateType: 'AuthState',
          isAsync: true,
          repositories: const [
            RepositoryDep(
              type: 'GoRouter',
              name: 'goRouter',
              providerExpression: 'routerProvider',
            ),
            RepositoryDep(
              type: 'UserNotifier',
              name: 'userNotifier',
              providerExpression: 'userNotifierProvider.notifier',
            ),
            RepositoryDep(
              type: 'AuthRepository',
              name: 'authRepository',
              providerExpression: 'authRepositoryProvider',
            ),
            RepositoryDep(
              type: 'LocalAuth',
              name: 'localAuth',
              providerExpression: 'localAuthProvider',
            ),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'login',
              returnType: 'Future<void>',
              isAsync: true,
              params: [
                ParamInfo(name: 'email', type: 'String', isNamed: true),
                ParamInfo(name: 'password', type: 'String', isNamed: true),
              ],
            ),
            MethodInfo(
              name: 'logout',
              returnType: 'Future<void>',
              isAsync: true,
              params: [],
            ),
          ],
        );

        final output = generator.generate(notifier);

        final loginSection = output.substring(
          output.indexOf("group('login'"),
          output.indexOf("group('logout'"),
        );

        // login() only calls authRepository.login and localAuth.login — the
        // router and userNotifier must not be stubbed with `.login(...)`
        // just because they're mocked dependencies of the notifier overall.
        expect(loginSection, contains('mockAuthRepository.login('));
        expect(loginSection, contains('mockLocalAuth.login('));
        expect(loginSection, isNot(contains('mockGoRouter.login(')));
        expect(loginSection, isNot(contains('mockUserNotifier.login(')));
        expect(loginSection, contains('// No mocks needed for GoRouter'));
        expect(loginSection, contains('// No mocks needed for UserNotifier'));

        final logoutSection =
            output.substring(output.indexOf("group('logout'"));
        expect(logoutSection, contains('mockAuthRepository.logout('));
        expect(logoutSection, contains('mockGoRouter.go('));
        expect(logoutSection, isNot(contains('mockLocalAuth.logout(')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'stubs build()\'s dependency calls once in setUp(), after the '
        'overrides, instead of repeating them inside every method test', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
        file.writeAsStringSync('''
class AuthNotifier extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async {
    ref.read(routerProvider).push('/splash');
    await ref.read(userNotifierProvider.notifier).refreshProfile();
    await ref.read(userRepositoryProvider).syncSession();
    return AuthState.empty();
  }

  Future<void> login({required String email, required String password}) async {
    await ref.read(authRepositoryProvider).login(email: email, password: password);
    // Also navigates — same `push` call build() already stubs in setUp(),
    // so login()'s own arrange block shouldn't re-declare it.
    ref.read(routerProvider).push('/home');
  }
}
''');

        final notifier = NotifierInfo(
          className: 'AuthNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/auth/presentation/notifiers/auth_notifier.dart',
          packageName: 'app',
          stateType: 'AuthState',
          isAsync: true,
          repositories: const [
            RepositoryDep(
              type: 'GoRouter',
              name: 'goRouter',
              providerExpression: 'routerProvider',
            ),
            RepositoryDep(
              type: 'UserNotifier',
              name: 'userNotifier',
              providerExpression: 'userNotifierProvider.notifier',
            ),
            RepositoryDep(
              type: 'UserRepository',
              name: 'userRepository',
              providerExpression: 'userRepositoryProvider',
            ),
            RepositoryDep(
              type: 'AuthRepository',
              name: 'authRepository',
              providerExpression: 'authRepositoryProvider',
            ),
          ],
          buildMethod: const MethodInfo(
            name: 'build',
            returnType: 'FutureOr<AuthState>',
            isAsync: true,
            params: [],
            isBuild: true,
          ),
          methods: const [
            MethodInfo(
              name: 'login',
              returnType: 'Future<void>',
              isAsync: true,
              params: [
                ParamInfo(name: 'email', type: 'String', isNamed: true),
                ParamInfo(name: 'password', type: 'String', isNamed: true),
              ],
            ),
          ],
        );

        final output = generator.generate(notifier);

        // build()'s calls are stubbed once in setUp(), positioned after the
        // ProviderContainer overrides.
        final setUpSection = output.substring(
          output.indexOf('setUp('),
          output.indexOf("group('login'"),
        );
        expect(setUpSection, contains('// Arrange: stub dependencies used by build()'));
        expect(setUpSection, contains('mockGoRouter.push('));
        expect(setUpSection, contains('mockUserNotifier.refreshProfile('));
        expect(setUpSection, contains('mockUserRepository.syncSession('));
        expect(
          setUpSection.indexOf('overrides: ['),
          lessThan(setUpSection.indexOf('mockGoRouter.push(')),
        );

        // login()'s own tests only stub what login() itself calls — build()'s
        // dependencies are already covered by setUp() and must not repeat.
        final loginSection = output.substring(output.indexOf("group('login'"));
        expect(loginSection, contains('mockAuthRepository.login('));
        expect(loginSection, contains('// No mocks needed for UserNotifier'));
        expect(loginSection, contains('// No mocks needed for UserRepository'));
        expect(
          loginSection,
          isNot(contains('mockUserNotifier.refreshProfile(')),
        );
        expect(
          loginSection,
          isNot(contains('mockUserRepository.syncSession(')),
        );

        // login() *also* calls `router.push(...)` itself — the same call
        // build() already stubs in setUp() — so the *success* test must
        // deduplicate it rather than redeclare an identical `when()`.
        final successTest = loginSection.substring(
          loginSection.indexOf("test('login completes successfully'"),
          loginSection.indexOf("test('login shows an error"),
        );
        expect(successTest, isNot(contains('mockGoRouter.push(')));
        expect(
          successTest,
          contains('// GoRouter already stubbed in setUp() for build()'),
        );

        // The *error* test is different: setUp()'s stub answers success, so
        // skipping the call there would leave nothing throwing and the test
        // could never pass. It must re-stub every call the method makes —
        // including the build()-shared one — with thenThrow, and only after
        // the notifier has been initialised (so build() itself still
        // succeeds).
        final errorTest =
            loginSection.substring(loginSection.indexOf("test('login shows an error"));
        expect(errorTest, contains('mockGoRouter.push('));
        expect(errorTest, contains('mockAuthRepository.login('));
        expect(errorTest, contains('thenThrow(AppException.test())'));
        expect(
          errorTest.indexOf('container.read(authNotifierProvider.future)'),
          lessThan(errorTest.indexOf('thenThrow(AppException.test())')),
          reason: 'the notifier must initialise with the success stubs still '
              'in effect, before the failure stubs replace them',
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'registers mocktail fallback values in setUpAll for custom-typed '
        'parameters, and stubs synchronous methods with thenReturn instead '
        'of an async answer', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        // Real repository interface on disk so the generator can resolve
        // both parameter types and the sync return type.
        final repoFile = File(p.joinAll([
          tempDir.path,
          'lib',
          'features',
          'cart',
          'domain',
          'repositories',
          'cart_repository.dart',
        ]));
        repoFile.parent.createSync(recursive: true);
        repoFile.writeAsStringSync('''
abstract class CartRepository {
  Future<void> addItem(CartItem item);
  String getToken();
}
''');

        final notifierFile =
            File('${tempDir.path}${Platform.pathSeparator}cart_notifier.dart');
        notifierFile.writeAsStringSync('''
class CartNotifier extends AsyncNotifier<CartState> {
  Future<void> addItem(CartItem item) async {
    await ref.read(cartRepositoryProvider).addItem(item);
  }

  void cacheToken() {
    ref.read(cartRepositoryProvider).getToken();
  }
}
''');

        final diskGenerator = TestGenerator(projectRoot: tempDir.path);
        final notifier = NotifierInfo(
          className: 'CartNotifier',
          sourceFilePath: notifierFile.path,
          importPath:
              'package:app/features/cart/presentation/notifiers/cart_notifier.dart',
          packageName: 'app',
          stateType: 'CartState',
          isAsync: true,
          repositories: const [
            RepositoryDep(
              type: 'CartRepository',
              name: 'cartRepository',
              providerExpression: 'cartRepositoryProvider',
            ),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'addItem',
              returnType: 'Future<void>',
              isAsync: true,
              params: [ParamInfo(name: 'item', type: 'CartItem')],
            ),
            MethodInfo(
              name: 'cacheToken',
              returnType: 'void',
              isAsync: false,
              params: [],
            ),
          ],
        );

        final output = diskGenerator.generate(notifier);

        // `any()` on a non-nullable custom type throws at runtime unless a
        // fallback instance is registered.
        expect(output, contains('setUpAll('));
        expect(output, contains('registerFallbackValue(CartItem.empty());'));
        // ... and the registered type needs an import to compile.
        expect(
          output,
          contains(
              "import 'package:app/features/cart/domain/entities/cart_item.dart';"),
        );

        // `String getToken()` is synchronous — answering a Future there is a
        // runtime TypeError.
        expect(output, contains(".thenReturn('')"));
        expect(output, isNot(contains("getToken()).thenAnswer")));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'mocks a notifier dependency from the registry by extending its real '
        'base class and stubbing build() in setUp, instead of a bare Mock '
        'that Riverpod cannot wire', () {
      final registryGenerator = TestGenerator(
        projectRoot: '.',
        notifierIndex: const {
          'UserNotifier':
              'package:app/features/user/presentation/notifiers/user_notifier.dart',
        },
        notifierRegistry: const {
          'UserNotifier': NotifierInfo(
            className: 'UserNotifier',
            sourceFilePath: '/tmp/user_notifier.dart',
            importPath:
                'package:app/features/user/presentation/notifiers/user_notifier.dart',
            packageName: 'app',
            stateType: 'UserState',
            isAsync: true,
            superclassSource: 'AsyncNotifier<UserState>',
            repositories: [],
            methods: [],
            stateInfo: StateInfo(
              className: 'UserState',
              importPath:
                  'package:app/features/user/presentation/states/user_state.dart',
              fields: [],
            ),
          ),
        },
      );

      const notifier = NotifierInfo(
        className: 'CheckoutNotifier',
        sourceFilePath: '/tmp/checkout_notifier.dart',
        importPath:
            'package:app/features/checkout/presentation/notifiers/checkout_notifier.dart',
        packageName: 'app',
        stateType: 'CheckoutState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'UserNotifier',
            name: 'userNotifier',
            // Captured from `await ref.read(userNotifierProvider.future)`.
            providerExpression: 'userNotifierProvider.future',
          ),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'checkout',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = registryGenerator.generate(notifier);

      // The mock keeps Riverpod's private wiring real by extending the real
      // base class, mixing Mock in only for stubbing. (dart_style may wrap
      // the clause across lines, so match the pieces individually.)
      expect(
          output, contains('class MockUserNotifier extends AsyncNotifier<UserState>'));
      expect(output, contains('with Mock'));
      expect(output, contains('implements UserNotifier {}'));
      expect(output, isNot(contains('class MockUserNotifier extends Mock ')));

      // Riverpod calls build() on the mock as soon as the provider is read
      // (`.future` awaits it) — it must be stubbed or every test dies with
      // MissingStubError.
      expect(output, contains('mockUserNotifier.build()'));
      expect(output, contains('UserState.empty()'));

      // The state type appears in the mock's `extends` clause and the build
      // stub, so its import is required.
      expect(
        output,
        contains(
            "import 'package:app/features/user/presentation/states/user_state.dart';"),
      );
    });

    test(
        'reads a family notifier with its argument everywhere: declaration, '
        '.future initialisation, .notifier calls and state reads', () {
      const notifier = NotifierInfo(
        className: 'ChatNotifier',
        sourceFilePath: '/tmp/chat_notifier.dart',
        importPath:
            'package:app/features/chat/presentation/notifiers/chat_notifier.dart',
        packageName: 'app',
        stateType: 'ChatState',
        isAsync: true,
        isFamily: true,
        familyArgType: 'String',
        superclassSource: 'FamilyAsyncNotifier<ChatState, String>',
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'send',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      expect(output, contains("const familyArg = '';"));
      expect(output,
          contains('await container.read(chatNotifierProvider(familyArg).future);'));
      expect(
        output,
        contains('container.read(chatNotifierProvider(familyArg).notifier).send()'),
      );
      // A family provider read without its argument doesn't compile.
      expect(output, isNot(contains('chatNotifierProvider.future')));
      expect(output, isNot(contains('chatNotifierProvider.notifier')));
    });

    test(
        'strips family call arguments from a captured dependency provider '
        'expression and overrides the family factory', () {
      const notifier = NotifierInfo(
        className: 'ProfileNotifier',
        sourceFilePath: '/tmp/profile_notifier.dart',
        importPath:
            'package:app/features/profile/presentation/notifiers/profile_notifier.dart',
        packageName: 'app',
        stateType: 'ProfileState',
        isAsync: true,
        repositories: const [
          RepositoryDep(
            type: 'Session',
            name: 'session',
            // Captured from `ref.read(sessionProvider(userId))` — `userId`
            // only exists inside the notifier, not in the generated test.
            providerExpression: 'sessionProvider(userId)',
          ),
        ],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'refresh',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
      );

      final output = generator.generate(notifier);

      // Family providers have no overrideWithValue; the captured call
      // argument must not leak into the test.
      expect(output,
          contains('sessionProvider.overrideWith((ref, arg) => mockSession)'));
      expect(output, isNot(contains('sessionProvider(userId)')));
    });

    test(
        'hoists a stub shared by two or more methods to the end of setUp() '
        'instead of repeating it in every success test', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}sync_notifier.dart');
        file.writeAsStringSync('''
class SyncNotifier extends AsyncNotifier<SyncState> {
  Future<void> refreshA() async {
    await ref.read(dataRepositoryProvider).sync();
  }

  Future<void> refreshB() async {
    await ref.read(dataRepositoryProvider).sync();
  }
}
''');

        final notifier = NotifierInfo(
          className: 'SyncNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/sync/presentation/notifiers/sync_notifier.dart',
          packageName: 'app',
          stateType: 'SyncState',
          isAsync: true,
          repositories: const [
            RepositoryDep(
              type: 'DataRepository',
              name: 'dataRepository',
              providerExpression: 'dataRepositoryProvider',
            ),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'refreshA',
              returnType: 'Future<void>',
              isAsync: true,
              params: [],
            ),
            MethodInfo(
              name: 'refreshB',
              returnType: 'Future<void>',
              isAsync: true,
              params: [],
            ),
          ],
        );

        final output = generator.generate(notifier);

        // The shared call is stubbed once in setUp()...
        final setUpSection = output.substring(
          output.indexOf('setUp('),
          output.indexOf("group('refreshA'"),
        );
        expect(setUpSection, contains('mockDataRepository.sync('));

        // ...and the success tests reference it instead of re-declaring it.
        final successA = output.substring(
          output.indexOf("test('refreshA completes successfully'"),
          output.indexOf("test('refreshA shows an error"),
        );
        expect(successA, isNot(contains('when(() => mockDataRepository.sync(')));
        expect(successA, contains('already stubbed in setUp()'));

        // Error tests still re-stub it with thenThrow, or nothing would fail.
        final errorA = output.substring(
          output.indexOf("test('refreshA shows an error"),
          output.indexOf("group('refreshB'"),
        );
        expect(errorA, contains('mockDataRepository.sync('));
        expect(errorA, contains('thenThrow(AppException.test())'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'asserts state fields directly (no requireValue) for a synchronous '
        'Notifier, whose provider exposes the state itself', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_test_');
      try {
        final file = File(
            '${tempDir.path}${Platform.pathSeparator}counter_notifier.dart');
        file.writeAsStringSync('''
class CounterNotifier extends Notifier<CounterState> {
  void increment() {
    ref.read(analyticsServiceProvider).track();
    state = state.copyWith(success: 'incremented');
  }
}
''');

        final notifier = NotifierInfo(
          className: 'CounterNotifier',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/counter/presentation/notifiers/counter_notifier.dart',
          packageName: 'app',
          stateType: 'CounterState',
          isAsync: false,
          repositories: const [
            RepositoryDep(
              type: 'AnalyticsService',
              name: 'analyticsService',
              providerExpression: 'analyticsServiceProvider',
            ),
          ],
          buildMethod: null,
          methods: const [
            MethodInfo(
              name: 'increment',
              returnType: 'void',
              isAsync: false,
              params: [],
            ),
          ],
          stateInfo: const StateInfo(
            className: 'CounterState',
            importPath:
                'package:app/features/counter/presentation/states/counter_state.dart',
            fields: [
              StateField(name: 'error', type: 'String', isNullable: true),
              StateField(name: 'success', type: 'String', isNullable: true),
            ],
          ),
        );

        final output = generator.generate(notifier);

        // `container.read(provider)` on a plain Notifier returns the state
        // directly — `.requireValue` only exists on AsyncValue.
        expect(output, contains('expect(finalState.error, isNull);'));
        expect(output, contains('expect(finalState.success, isNotNull);'));
        expect(output, isNot(contains('requireValue')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'skips the success-message assertion when the method body provably '
        'never sets one', () {
      const notifier = NotifierInfo(
        className: 'ToggleNotifier',
        sourceFilePath: '/tmp/toggle_notifier.dart',
        importPath:
            'package:app/features/toggle/presentation/notifiers/toggle_notifier.dart',
        packageName: 'app',
        stateType: 'ToggleState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'toggle',
            returnType: 'void',
            isAsync: false,
            params: [],
            // The parsed body never mentions the state's `success` field —
            // asserting isNotNull would be guaranteed to fail.
            bodySource:
                '{ state = AsyncData(state.requireValue.copyWith(enabled: true)); }',
          ),
        ],
        stateInfo: StateInfo(
          className: 'ToggleState',
          importPath:
              'package:app/features/toggle/presentation/states/toggle_state.dart',
          fields: const [
            StateField(name: 'error', type: 'String', isNullable: true),
            StateField(name: 'success', type: 'String', isNullable: true),
          ],
        ),
      );

      final output = generator.generate(notifier);

      expect(output, contains('expect(finalState.requireValue.error, isNull);'));
      expect(
        output,
        isNot(contains('expect(finalState.requireValue.success, isNotNull);')),
      );
    });
  });
}
