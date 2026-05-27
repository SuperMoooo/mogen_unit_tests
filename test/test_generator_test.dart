// Import the generator and models
// Update these imports to match your actual package structure
import 'package:mogen_unit_tests/src/generators/test_generator.dart';
import 'package:mogen_unit_tests/src/models/notifier_info.dart';
import 'package:test/test.dart';

void main() {
  group('TestGenerator', () {
    late TestGenerator generator;

    setUp(() {
      generator = TestGenerator();
    });

    test('generates feature-scoped imports and omits non-feature repositories',
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

      // Should import only the auth feature's auth_repository
      expect(
        output,
        contains(
            "import 'package:app/features/auth/domain/repositories/auth_repository.dart';"),
      );

      // Should NOT import CartRepository (different feature)
      expect(output, isNot(contains('CartRepository')));
      expect(
        output,
        isNot(contains('cart_repository')),
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

      // Should generate assertions for state fields
      // FIX: success is now asserted for ANY async method (not just hardcoded names)
      expect(
          output, contains('expect(finalState.requireValue.isLoadingAction'));
      expect(output, contains('expect(finalState.requireValue.error'));
      expect(output, contains('expect(finalState.requireValue.success'));
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

    test('filters out repositories from different features', () {
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

      // Should NOT include PaymentRepository (different feature)
      expect(output, isNot(contains('class MockPaymentRepository')));
      expect(output, isNot(contains('paymentRepositoryProvider')));
    });

    test('does not include error handling test scaffolding', () {
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

      // Should NOT include error test patterns
      expect(output, isNot(contains("test('handles error from repository'")));
      expect(output, isNot(contains("test('throws exception when")));
      expect(output, isNot(contains('thenThrow')));
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
  });
}
