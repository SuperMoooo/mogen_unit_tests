import 'dart:io';

import 'package:mogen_unit_tests/src/analyzers/event_parser.dart';
import 'package:mogen_unit_tests/src/analyzers/feature_scanner.dart';
import 'package:mogen_unit_tests/src/analyzers/notifier_parser.dart';
import 'package:mogen_unit_tests/src/models/notifier_info.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('FeatureScanner', () {
    test(
        'discovers bloc and cubit folders alongside the Riverpod notifiers '
        'folder, and treats a state file sitting beside a bloc as a state file',
        () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_scan_');
      try {
        void write(List<String> parts, String content) {
          final file = File(p.joinAll([tempDir.path, ...parts]));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(content);
        }

        write(['auth', 'presentation', 'bloc', 'auth_bloc.dart'], '');
        write(['auth', 'presentation', 'bloc', 'auth_state.dart'], '');
        write(['auth', 'presentation', 'bloc', 'auth_event.dart'], '');
        write(['cart', 'presentation', 'cubit', 'cart_cubit.dart'], '');
        write(['user', 'presentation', 'notifiers', 'user_notifier.dart'], '');
        write(['user', 'presentation', 'states', 'user_state.dart'], '');

        final bundles = FeatureScanner(featuresRoot: tempDir.path).scan()
          ..sort((a, b) => a.featureName.compareTo(b.featureName));

        expect(bundles.map((b) => b.featureName),
            equals(['auth', 'cart', 'user']));

        final auth = bundles.first;
        expect(auth.notifierFiles.map(p.basename),
            containsAll(['auth_bloc.dart', 'auth_event.dart']));
        // Bloc projects keep the state next to the bloc, not in `states/`.
        expect(auth.stateFiles.map(p.basename), contains('auth_state.dart'));
        expect(auth.eventFiles.map(p.basename), contains('auth_event.dart'));

        final user = bundles.last;
        expect(
            user.notifierFiles.map(p.basename), equals(['user_notifier.dart']));
        expect(user.stateFiles.map(p.basename), equals(['user_state.dart']));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('NotifierParser — flutter_bloc', () {
    test(
        'detects a Bloc: kind, event base type, state type, registered events '
        'and its constructor-injected dependencies', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_bloc.dart');
        file.writeAsStringSync('''
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._authRepository) : super(const AuthState()) {
    on<LoginRequested>(_onLoginRequested);
    on<LogoutRequested>((event, emit) async {
      await _authRepository.logout();
    });
  }

  final AuthRepository _authRepository;

  Future<void> _onLoginRequested(LoginRequested event, Emitter<AuthState> emit) async {
    await _authRepository.login(email: event.email, password: event.password);
  }
}
''');

        final parser =
            NotifierParser(projectRoot: tempDir.path, packageName: 'app');
        final blocs = parser.parse(file.path);

        expect(blocs, hasLength(1));
        final bloc = blocs.first;

        expect(bloc.kind, equals(StateManagementKind.bloc));
        expect(bloc.isBloc, isTrue);
        expect(bloc.eventBaseType, equals('AuthEvent'));
        expect(bloc.stateType, equals('AuthState'));
        // A bloc's state is a plain value — never an AsyncValue.
        expect(bloc.isAsync, isFalse);

        expect(
          bloc.events.map((e) => e.type),
          equals(['LoginRequested', 'LogoutRequested']),
        );

        // Constructor injection is the bloc DI seam.
        expect(bloc.repositories, hasLength(1));
        expect(bloc.repositories.first.type, equals('AuthRepository'));
        // The call site uses the private field, not the parameter name.
        expect(bloc.repositories.first.name, equals('_authRepository'));

        expect(bloc.constructorParams, hasLength(1));
        expect(bloc.constructorParams.first.type, equals('AuthRepository'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'detects a Cubit: its public methods are the actions, and named '
        'constructor dependencies keep their parameter name', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}cart_cubit.dart');
        file.writeAsStringSync('''
class CartCubit extends Cubit<CartState> {
  CartCubit({required CartRepository cartRepository, this.pageSize = 20})
      : _cartRepository = cartRepository,
        super(const CartState());

  final CartRepository _cartRepository;
  final int pageSize;

  Future<void> loadCart() async {
    await _cartRepository.fetchItems();
  }

  @override
  Future<void> close() {
    return super.close();
  }
}
''');

        final parser =
            NotifierParser(projectRoot: tempDir.path, packageName: 'app');
        final cubits = parser.parse(file.path);

        expect(cubits, hasLength(1));
        final cubit = cubits.first;

        expect(cubit.kind, equals(StateManagementKind.cubit));
        expect(cubit.isCubit, isTrue);
        expect(cubit.stateType, equals('CartState'));
        expect(cubit.eventBaseType, isNull);
        expect(cubit.events, isEmpty);

        // `close()` is inherited lifecycle, not an action worth testing.
        expect(cubit.methods.map((m) => m.name), equals(['loadCart']));

        // `int pageSize` is configuration, not a collaborator.
        expect(
            cubit.repositories.map((r) => r.type), equals(['CartRepository']));
        expect(cubit.constructorParams.map((p) => p.name),
            equals(['cartRepository', 'pageSize']));
        expect(cubit.constructorParams.first.isNamed, isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('leaves Riverpod notifiers on the Riverpod path', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_bloc_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
        file.writeAsStringSync('''
class AuthNotifier extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async => AuthState.empty();
}
''');

        final parser =
            NotifierParser(projectRoot: tempDir.path, packageName: 'app');
        final notifiers = parser.parse(file.path);

        expect(notifiers.single.kind, equals(StateManagementKind.riverpod));
        expect(notifiers.single.isRiverpod, isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('EventParser', () {
    test(
        'resolves `required this.x` constructor parameters back to their '
        'declared field types, and flags part files', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_event_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_event.dart');
        file.writeAsStringSync('''
part of 'auth_bloc.dart';

class LoginRequested extends AuthEvent {
  const LoginRequested({required this.email, this.remember = false});

  final String email;
  final bool remember;
}
''');

        final events =
            EventParser(projectRoot: tempDir.path, packageName: 'app')
                .parseAll([file.path]);

        final login = events.firstWhere((e) => e.className == 'LoginRequested');
        // A part file can never be imported directly.
        expect(login.isPart, isTrue);

        final email = login.params.firstWhere((p) => p.name == 'email');
        expect(email.type, equals('String'));
        expect(email.isNamed, isTrue);
        expect(email.defaultValue, isNull);

        final remember = login.params.firstWhere((p) => p.name == 'remember');
        expect(remember.type, equals('bool'));
        expect(remember.defaultValue, equals('false'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
