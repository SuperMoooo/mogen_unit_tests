import 'dart:io';

import 'package:mogen_unit_tests/src/analyzers/notifier_parser.dart';
import 'package:test/test.dart';

void main() {
  group('NotifierParser', () {
    test('resolves routerProvider to GoRouter, not the guessed Router type',
        () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_parser_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
        file.writeAsStringSync('''
class AuthNotifier extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async => AuthState.empty();

  Future<void> login({required String email, required String password}) async {
    await ref.read(authRepositoryProvider).login(email: email, password: password);
    ref.read(routerProvider).push('/home');
  }
}
''');

        final parser =
            NotifierParser(projectRoot: tempDir.path, packageName: 'app');
        final notifiers = parser.parse(file.path);

        expect(notifiers, hasLength(1));
        final router = notifiers.first.repositories
            .firstWhere((r) => r.providerExpression == 'routerProvider');

        expect(router.type, equals('GoRouter'));
        expect(router.type, isNot(equals('Router')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'detects a family notifier: family flag, state type and argument '
        'type from the generics, and the full superclass source', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_parser_');
      try {
        final file =
            File('${tempDir.path}${Platform.pathSeparator}chat_notifier.dart');
        file.writeAsStringSync('''
class ChatNotifier extends FamilyAsyncNotifier<ChatState, String> {
  @override
  Future<ChatState> build(String roomId) async => ChatState.empty();

  Future<void> send(String text) async {
    await ref.read(chatRepositoryProvider).send(text);
  }
}
''');

        final parser =
            NotifierParser(projectRoot: tempDir.path, packageName: 'app');
        final notifiers = parser.parse(file.path);

        expect(notifiers, hasLength(1));
        final chat = notifiers.first;
        expect(chat.isFamily, isTrue);
        expect(chat.isAsync, isTrue);
        expect(chat.stateType, equals('ChatState'));
        expect(chat.familyArgType, equals('String'));
        expect(chat.superclassSource,
            equals('FamilyAsyncNotifier<ChatState, String>'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'ignores classes extending ChangeNotifier/ValueNotifier even when '
        'they live in the notifiers folder', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_parser_');
      try {
        final file = File(
            '${tempDir.path}${Platform.pathSeparator}legacy_controller.dart');
        file.writeAsStringSync('''
class LegacyController extends ChangeNotifier {
  void tick() {}
}

class SelectionHolder extends ValueNotifier<int> {
  SelectionHolder() : super(0);
}
''');

        final parser =
            NotifierParser(projectRoot: tempDir.path, packageName: 'app');
        final notifiers = parser.parse(file.path);

        expect(notifiers, isEmpty);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'skips getters, setters and static members — only real callable '
        'methods get test scaffolding', () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_parser_');
      try {
        final file = File(
            '${tempDir.path}${Platform.pathSeparator}counter_notifier.dart');
        file.writeAsStringSync('''
class CounterNotifier extends Notifier<int> {
  @override
  int build() => 0;

  bool get isReady => true;

  set threshold(int value) {}

  static int parse(String raw) => int.parse(raw);

  void increment() {}
}
''');

        final parser =
            NotifierParser(projectRoot: tempDir.path, packageName: 'app');
        final notifiers = parser.parse(file.path);

        expect(notifiers, hasLength(1));
        final names = notifiers.first.methods.map((m) => m.name).toList();
        expect(names, equals(['increment']));
        expect(notifiers.first.isAsync, isFalse);
        expect(notifiers.first.isFamily, isFalse);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
