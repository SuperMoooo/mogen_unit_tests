import 'dart:io';

import 'package:mogen_unit_tests/src/generators/bloc_test_generator.dart';
import 'package:mogen_unit_tests/src/models/notifier_info.dart';
import 'package:test/test.dart';

/// Writes [source] to a temp file and returns it, so the generator's
/// call-detection pass has real source to parse.
File _write(Directory dir, String name, String source) {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  file.writeAsStringSync(source);
  return file;
}

const _authState = StateInfo(
  className: 'AuthState',
  importPath: 'package:app/features/auth/presentation/bloc/auth_bloc.dart',
  // The conventional bloc layout: the state is a `part` of the bloc file.
  isPart: true,
  fields: [
    StateField(name: 'isLoading', type: 'bool'),
    StateField(name: 'error', type: 'String', isNullable: true),
    StateField(name: 'success', type: 'String', isNullable: true),
  ],
);

NotifierInfo _authBloc(String sourcePath) => NotifierInfo(
      className: 'AuthBloc',
      sourceFilePath: sourcePath,
      importPath: 'package:app/features/auth/presentation/bloc/auth_bloc.dart',
      packageName: 'app',
      stateType: 'AuthState',
      isAsync: false,
      kind: StateManagementKind.bloc,
      eventBaseType: 'AuthEvent',
      superclassSource: 'Bloc<AuthEvent, AuthState>',
      repositories: const [
        RepositoryDep(type: 'AuthRepository', name: '_authRepository'),
      ],
      constructorParams: const [
        ParamInfo(name: '_authRepository', type: 'AuthRepository'),
      ],
      events: const [
        EventInfo(
          type: 'LoginRequested',
          isAsync: true,
          handlerBodySource: '{ try { await _authRepository.login(); } '
              "catch (e) { emit(state.copyWith(error: e.toString())); } }",
        ),
      ],
      methods: const [],
      stateInfo: _authState,
    );

void main() {
  group('BlocTestGenerator', () {
    late BlocTestGenerator generator;

    setUp(() {
      generator = BlocTestGenerator(projectRoot: '.');
    });

    test(
        'drives a bloc with bloc_test: a blocTest per event, built from the '
        'mocked constructor dependencies and acted on by adding the event', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'auth_bloc.dart', '''
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._authRepository) : super(const AuthState()) {
    on<LoginRequested>((event, emit) async {
      try {
        await _authRepository.login(email: event.email);
      } catch (e) {
        emit(state.copyWith(error: e.toString()));
      }
    });
  }

  final AuthRepository _authRepository;
}
''');

        final output = generator.generate(_authBloc(file.path));

        // The generated file is a real bloc_test suite.
        expect(output, contains("import 'package:bloc_test/bloc_test.dart';"));
        expect(output, contains('blocTest<AuthBloc, AuthState>('));
        expect(output, contains("test('starts in a valid initial state'"));

        // Constructor injection is the DI seam: the mock is passed straight
        // into the class under test, with no container or provider override.
        expect(
            output,
            contains(
                'class MockAuthRepository extends Mock implements AuthRepository {}'));
        expect(
            output,
            contains(
                'AuthBloc buildAuthBloc() => AuthBloc(mockAuthRepository);'));
        expect(output, contains('build: buildAuthBloc,'));
        expect(output, isNot(contains('ProviderContainer')));
        expect(output, isNot(contains('overrideWith')));

        // A bloc is exercised by adding events, not by calling methods.
        expect(output, contains('act: (bloc) => bloc.add(LoginRequested('));
        expect(output, contains("group('LoginRequested'"));

        // The state lives in a `part` of the bloc file, so importing it
        // separately would not compile.
        expect(
            output,
            contains(
                "import 'package:app/features/auth/presentation/bloc/auth_bloc.dart';"));
        expect(
          'auth_bloc.dart'.allMatches(output).length,
          equals(1),
          reason: 'the part-file state must not be imported a second time',
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'stubs only the calls the event\'s own handler makes, keeping other '
        'handlers registered in the same constructor out of it', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'auth_bloc.dart', '''
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._authRepository) : super(const AuthState()) {
    on<LoginRequested>(_onLoginRequested);
    on<LogoutRequested>((event, emit) async {
      await _authRepository.logout();
    });
  }

  final AuthRepository _authRepository;

  Future<void> _onLoginRequested(LoginRequested event, Emitter<AuthState> emit) async {
    try {
      await _authRepository.login(email: event.email);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }
}
''');

        final bloc = _authBloc(file.path);
        final output = generator.generate(NotifierInfo(
          className: bloc.className,
          sourceFilePath: bloc.sourceFilePath,
          importPath: bloc.importPath,
          packageName: bloc.packageName,
          stateType: bloc.stateType,
          isAsync: false,
          kind: StateManagementKind.bloc,
          eventBaseType: bloc.eventBaseType,
          repositories: bloc.repositories,
          constructorParams: bloc.constructorParams,
          methods: const [],
          stateInfo: _authState,
          events: const [
            EventInfo(type: 'LoginRequested', isAsync: true),
            EventInfo(type: 'LogoutRequested', isAsync: true),
          ],
        ));

        final loginSection = output.substring(
          output.indexOf("group('LoginRequested'"),
          output.indexOf("group('LogoutRequested'"),
        );
        // The handler is a tear-off — its body still has to be found.
        expect(loginSection, contains('mockAuthRepository.login('));
        expect(loginSection, isNot(contains('mockAuthRepository.logout(')));

        final logoutSection =
            output.substring(output.indexOf("group('LogoutRequested'"));
        expect(logoutSection, contains('mockAuthRepository.logout('));
        expect(logoutSection, isNot(contains('mockAuthRepository.login(')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'hoists the calls the constructor itself makes into setUp(), and does '
        'not fail them in the error path — build() runs after a blocTest\'s '
        'setUp, so a throwing stub would break construction instead of the '
        'action', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'auth_bloc.dart', '''
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._authRepository) : super(const AuthState()) {
    _authRepository.restoreSession();
    on<LoginRequested>((event, emit) async {
      try {
        await _authRepository.login();
      } catch (e) {
        emit(state.copyWith(error: e.toString()));
      }
    });
  }

  final AuthRepository _authRepository;
}
''');

        final output = generator.generate(_authBloc(file.path));

        final setUpSection = output.substring(
          output.indexOf('setUp(() {'),
          output.indexOf("group('LoginRequested'"),
        );
        expect(setUpSection, contains('mockAuthRepository.restoreSession('));

        final errorTest = output
            .substring(output.indexOf('surfaces an error when a dependency'));
        expect(errorTest, contains('mockAuthRepository.login('));
        expect(errorTest, contains('thenThrow(AppException.test())'));
        expect(
          errorTest,
          isNot(contains('restoreSession()).thenThrow')),
          reason: 'failing a constructor call would break build:, not the act',
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'asserts bloc errors instead of state when the handler never catches '
        'the failure — an uncaught error escapes to the bloc error handler '
        'and never reaches the state', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'auth_bloc.dart', '''
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._authRepository) : super(const AuthState()) {
    on<LogoutRequested>((event, emit) async {
      await _authRepository.logout();
      emit(const AuthState());
    });
  }

  final AuthRepository _authRepository;
}
''');

        final bloc = _authBloc(file.path);
        final output = generator.generate(NotifierInfo(
          className: bloc.className,
          sourceFilePath: bloc.sourceFilePath,
          importPath: bloc.importPath,
          packageName: bloc.packageName,
          stateType: bloc.stateType,
          isAsync: false,
          kind: StateManagementKind.bloc,
          eventBaseType: bloc.eventBaseType,
          repositories: bloc.repositories,
          constructorParams: bloc.constructorParams,
          methods: const [],
          stateInfo: _authState,
          events: const [
            EventInfo(
              type: 'LogoutRequested',
              isAsync: true,
              handlerBodySource:
                  '{ await _authRepository.logout(); emit(const AuthState()); }',
            ),
          ],
        ));

        final errorTest = output
            .substring(output.indexOf('surfaces an error when a dependency'));
        expect(errorTest, contains('errors: () => [isA<AppException>()],'));
        expect(
            errorTest, isNot(contains('expect(bloc.state.error, isNotNull)')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('drives a cubit through its public methods instead of events', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'cart_cubit.dart', '''
class CartCubit extends Cubit<CartState> {
  CartCubit({required CartRepository cartRepository})
      : _cartRepository = cartRepository,
        super(const CartState());

  final CartRepository _cartRepository;

  Future<void> addItem({required String itemId}) async {
    try {
      await _cartRepository.addItem(itemId: itemId);
      emit(state.copyWith(success: 'added'));
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }
}
''');

        final output = generator.generate(NotifierInfo(
          className: 'CartCubit',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/cart/presentation/cubit/cart_cubit.dart',
          packageName: 'app',
          stateType: 'CartState',
          isAsync: false,
          kind: StateManagementKind.cubit,
          superclassSource: 'Cubit<CartState>',
          repositories: const [
            RepositoryDep(type: 'CartRepository', name: '_cartRepository'),
          ],
          constructorParams: const [
            ParamInfo(
                name: 'cartRepository', type: 'CartRepository', isNamed: true),
          ],
          methods: const [
            MethodInfo(
              name: 'addItem',
              returnType: 'Future<void>',
              isAsync: true,
              params: [
                ParamInfo(name: 'itemId', type: 'String', isNamed: true),
              ],
              bodySource: '{ try { await _cartRepository.addItem(itemId: '
                  "itemId); emit(state.copyWith(success: 'added')); } "
                  'catch (e) { emit(state.copyWith(error: e.toString())); } }',
            ),
          ],
          stateInfo: const StateInfo(
            className: 'CartState',
            importPath:
                'package:app/features/cart/presentation/cubit/cart_state.dart',
            fields: [
              StateField(name: 'error', type: 'String', isNullable: true),
              StateField(name: 'success', type: 'String', isNullable: true),
            ],
          ),
        ));

        expect(output, contains('blocTest<CartCubit, CartState>('));
        // A named constructor dependency keeps its label.
        expect(
          output,
          contains(
              'CartCubit buildCartCubit() => CartCubit(cartRepository: mockCartRepository);'),
        );
        expect(output, contains("act: (cubit) => cubit.addItem(itemId: '')"));
        expect(output, contains('verify: (cubit) {'));
        expect(output, contains("expect(cubit.state.success, isNotNull);"));
        expect(output, isNot(contains('.add(')));

        // A non-part state file still needs its own import.
        expect(
          output,
          contains(
              "import 'package:app/features/cart/presentation/cubit/cart_state.dart';"),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'mocks a bloc dependency with bloc_test\'s MockBloc and stubs its '
        'state — a bare Mock has no state stream to read', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'checkout_bloc.dart', '''
class CheckoutBloc extends Bloc<CheckoutEvent, CheckoutState> {
  CheckoutBloc(this._cartBloc) : super(const CheckoutState());

  final CartBloc _cartBloc;
}
''');

        final registryGenerator = BlocTestGenerator(
          projectRoot: '.',
          notifierIndex: const {
            'CartBloc':
                'package:app/features/cart/presentation/bloc/cart_bloc.dart',
          },
          notifierRegistry: const {
            'CartBloc': NotifierInfo(
              className: 'CartBloc',
              sourceFilePath: '/tmp/cart_bloc.dart',
              importPath:
                  'package:app/features/cart/presentation/bloc/cart_bloc.dart',
              packageName: 'app',
              stateType: 'CartState',
              isAsync: false,
              kind: StateManagementKind.bloc,
              eventBaseType: 'CartEvent',
              repositories: [],
              methods: [],
            ),
          },
        );

        final output = registryGenerator.generate(NotifierInfo(
          className: 'CheckoutBloc',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/checkout/presentation/bloc/checkout_bloc.dart',
          packageName: 'app',
          stateType: 'CheckoutState',
          isAsync: false,
          kind: StateManagementKind.bloc,
          eventBaseType: 'CheckoutEvent',
          repositories: const [
            RepositoryDep(type: 'CartBloc', name: '_cartBloc'),
          ],
          constructorParams: const [
            ParamInfo(name: '_cartBloc', type: 'CartBloc'),
          ],
          methods: const [],
          events: const [],
        ));

        expect(
          output,
          contains(
              'class MockCartBloc extends MockBloc<CartEvent, CartState> implements CartBloc {}'),
        );
        expect(output, contains('when(() => mockCartBloc.state)'));
        expect(output, contains('.thenReturn(CartState.empty());'));
        expect(
          output,
          contains(
              "import 'package:app/features/cart/presentation/bloc/cart_bloc.dart';"),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'builds the event with real constructor arguments resolved from the '
        'event registry, skipping named parameters that have a default', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'auth_bloc.dart', '''
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._authRepository) : super(const AuthState()) {
    on<LoginRequested>((event, emit) async {
      try {
        await _authRepository.login(email: event.email);
      } catch (e) {
        emit(state.copyWith(error: e.toString()));
      }
    });
  }

  final AuthRepository _authRepository;
}
''');

        final withEvents = BlocTestGenerator(
          projectRoot: '.',
          eventRegistry: const {
            'LoginRequested': EventClassInfo(
              className: 'LoginRequested',
              importPath:
                  'package:app/features/auth/presentation/bloc/auth_bloc.dart',
              isPart: true,
              params: [
                ParamInfo(name: 'email', type: 'String', isNamed: true),
                ParamInfo(name: 'password', type: 'String', isNamed: true),
                ParamInfo(
                  name: 'remember',
                  type: 'bool',
                  isNamed: true,
                  defaultValue: 'false',
                ),
              ],
            ),
          },
        );

        final output = withEvents.generate(_authBloc(file.path));

        expect(
          output,
          contains("bloc.add(LoginRequested(email: '', password: ''))"),
        );
        expect(output, isNot(contains('remember:')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'asserts a sealed state by the type the handler emits, and offers the '
        'real emit sequence as a ready-to-uncomment expect: list', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'search_bloc.dart', '''
class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc(this._searchRepository) : super(SearchInitial()) {
    on<QuerySubmitted>((event, emit) async {
      emit(SearchLoading());
      try {
        final results = await _searchRepository.search(event.query);
        emit(SearchSuccess(results));
      } catch (e) {
        emit(SearchFailure(e.toString()));
      }
    });
  }

  final SearchRepository _searchRepository;
}
''');

        final output = generator.generate(NotifierInfo(
          className: 'SearchBloc',
          sourceFilePath: file.path,
          importPath:
              'package:app/features/search/presentation/bloc/search_bloc.dart',
          packageName: 'app',
          stateType: 'SearchState',
          isAsync: false,
          kind: StateManagementKind.bloc,
          eventBaseType: 'SearchEvent',
          repositories: const [
            RepositoryDep(type: 'SearchRepository', name: '_searchRepository'),
          ],
          constructorParams: const [
            ParamInfo(name: '_searchRepository', type: 'SearchRepository'),
          ],
          methods: const [],
          events: const [EventInfo(type: 'QuerySubmitted', isAsync: true)],
          // A sealed hierarchy: the base class declares no fields to assert.
          stateInfo: const StateInfo(
            className: 'SearchState',
            importPath:
                'package:app/features/search/presentation/bloc/search_bloc.dart',
            isPart: true,
            fields: [],
          ),
        ));

        // The handler names the state it produces at every emit, so the
        // settled state is asserted for real instead of left as a TODO.
        expect(output, contains('expect(bloc.state, isA<SearchSuccess>());'));
        expect(output, contains('expect(bloc.state, isA<SearchFailure>());'));
        expect(output, isNot(contains('TODO(mogen_unit_tests)')));

        // The sequence stays commented — a guarded emit doesn't always run —
        // but it is the real one, not a placeholder.
        expect(
          output,
          contains(
              '// expect: () => [isA<SearchLoading>(), isA<SearchSuccess>()],'),
        );

        // An emit from inside the catch proves the handler converts the
        // failure into state, so the error test asserts state, not `errors:`.
        expect(output, isNot(contains('errors: () =>')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'still falls back to a TODO when nothing in the handler names a '
        'concrete state type', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_gen_');
      try {
        final file = _write(tempDir, 'auth_bloc.dart', '''
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._authRepository) : super(AuthInitial()) {
    on<LoginRequested>((event, emit) async {
      try {
        await _authRepository.login();
      } catch (e) {
        emit(AuthFailure(e.toString()));
      }
    });
  }

  final AuthRepository _authRepository;
}
''');

        final bloc = _authBloc(file.path);
        final output = generator.generate(NotifierInfo(
          className: bloc.className,
          sourceFilePath: bloc.sourceFilePath,
          importPath: bloc.importPath,
          packageName: bloc.packageName,
          stateType: bloc.stateType,
          isAsync: false,
          kind: StateManagementKind.bloc,
          eventBaseType: bloc.eventBaseType,
          repositories: bloc.repositories,
          constructorParams: bloc.constructorParams,
          methods: const [],
          events: bloc.events,
          // A sealed state hierarchy: the base class declares no fields.
          stateInfo: const StateInfo(
            className: 'AuthState',
            importPath:
                'package:app/features/auth/presentation/bloc/auth_bloc.dart',
            isPart: true,
            fields: [],
          ),
        ));

        expect(output,
            contains('TODO(mogen_unit_tests): assert the resulting state'));
        expect(output, contains('// expect(bloc.state, isA<AuthState>());'));
        expect(output, isNot(contains('bloc.state.error')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
