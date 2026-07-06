import 'dart:io';

import 'package:mogen_unit_tests/src/analyzers/notifier_parser.dart';
import 'package:test/test.dart';

void main() {
  group('NotifierParser', () {
    test('resolves routerProvider to GoRouter, not the guessed Router type',
        () {
      final tempDir = Directory.systemTemp.createTempSync('mogen_parser_');
      try {
        final file = File(
            '${tempDir.path}${Platform.pathSeparator}auth_notifier.dart');
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
  });
}
