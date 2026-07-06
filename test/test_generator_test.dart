// Import the generator and models
// Update these imports to match your actual package structure
import 'dart:io';

import 'package:mogen_unit_tests/src/generators/test_generator.dart';
import 'package:mogen_unit_tests/src/models/notifier_info.dart';
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
      const notifier = NotifierInfo(
        className: 'FormNotifier',
        sourceFilePath: '/tmp/form_notifier.dart',
        importPath:
            'package:app/features/form/presentation/notifiers/form_notifier.dart',
        packageName: 'app',
        stateType: 'FormState',
        isAsync: true,
        repositories: const [],
        buildMethod: null,
        methods: const [
          MethodInfo(
            name: 'submit',
            returnType: 'Future<void>',
            isAsync: true,
            params: [],
          ),
        ],
        stateInfo: StateInfo(
          className: 'FormState',
          importPath:
              'package:app/features/form/presentation/states/form_state.dart',
          fields: const [
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
      expect(
          output, contains('expect(finalState.requireValue.error, isNull);'));
      expect(output,
          contains('expect(finalState.requireValue.success, isNotNull);'));

      // Error path should surface the error and clear any success message.
      expect(output,
          contains("test('submit shows an error when the repository fails'"));
      expect(output,
          contains('expect(finalState.requireValue.error, isNotNull);'));
      expect(
          output, contains('expect(finalState.requireValue.success, isNull);'));
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

    test('includes error handling test scaffolding for repository failures',
        () {
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

      // The generator should include an explicit failure-path test for each method.
      expect(output, contains("shows an error when the repository fails"));
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

      final errorTest = output.substring(
        output.indexOf("shows an error when the repository fails"),
      );
      expect(
        errorTest,
        isNot(contains('await container.read(counterNotifierProvider.notifier).increment')),
      );
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
  });
}
