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

      // Should generate input variables
      expect(output, contains("final query = '';"));
      expect(output, contains('final limit = 0;'));

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
        expect(output,
            contains("thenThrow(Exception('Simulated login failure'))"));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
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
      expect(
        output,
        contains(
            'cartNotifierProvider.notifier.overrideWith(() => mockCartNotifier)'),
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
  });
}
