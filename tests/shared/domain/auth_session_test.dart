import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:receipt_master/ui/account.dart';
import 'package:receipt_master/ui/app_theme.dart';
import 'package:receipt_master/data/store.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/auth_session.dart';
import 'package:receipt_master/data/backend_defaults.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final vault = <String, String>{};
  AuthSession makeSession(http.Client client) => AuthSession(
    client,
    loadDefaults: () async => const BackendDefaults('https://example.test'),
  );
  setUp(() {
    vault.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final key = call.arguments['key'] as String;
            if (call.method == 'write') vault[key] = call.arguments['value'];
            if (call.method == 'delete') vault.remove(key);
            return call.method == 'read' ? vault[key] : null;
          },
        );
  });
  Map<String, dynamic> session(String token, {bool change = true}) => {
    'access_token': token,
    'refresh_token': '$token-refresh',
    'expires_in': 900,
    'user': {
      'user_id': 'alice',
      'username': 'alice',
      'is_admin': false,
      'must_change_password': change,
    },
  };
  test(
    'mobile stores only the rotating refresh credential in its vault',
    () async {
      final auth = makeSession(
        MockClient((request) async {
          expect(request.headers['X-Receipt-Client'], 'mobile');
          return http.Response(jsonEncode(session('jwt')), 200);
        }),
      );
      await auth.login('https://example.test', 'alice', 'temporary-pass');
      expect(auth.user!['must_change_password'], true);
      expect(vault['refresh_token'], 'jwt-refresh');
      expect(vault.containsKey('access_token'), false);
      expect((await auth.connection()).key, 'jwt');
    },
  );
  test(
    'network outages retain refresh credentials, revocation clears them',
    () async {
      bool offline = true;
      final auth = makeSession(
        MockClient((request) async {
          if (offline) throw http.ClientException('offline');
          return http.Response(
            jsonEncode({
              'error': {'message': 'revoked'},
            }),
            401,
          );
        }),
      );
      auth.endpoint = 'https://example.test';
      await auth.accept(session('jwt'));
      auth.expiresAt = 0;
      await expectLater(
        auth.connection(),
        throwsA(isA<http.ClientException>()),
      );
      expect(vault['refresh_token'], 'jwt-refresh');
      expect(auth.user, isNotNull);
      offline = false;
      await expectLater(auth.connection(), throwsA(isA<AuthenticationError>()));
      expect(auth.user, isNull);
      expect(vault.containsKey('refresh_token'), false);
    },
  );
  test('a late refresh cannot restore an explicitly cleared account', () async {
    final reply = Completer<http.Response>();
    final requested = Completer<void>();
    final auth = makeSession(
      MockClient((request) {
        requested.complete();
        return reply.future;
      }),
    );
    auth.endpoint = 'https://example.test';
    await auth.accept(session('old'));
    final refresh = auth.refresh();
    await requested.future;
    await auth.clear();
    reply.complete(http.Response(jsonEncode(session('late')), 200));
    await expectLater(refresh, throwsA(isA<Exception>()));
    expect(auth.user, isNull);
    expect(vault.containsKey('refresh_token'), false);
  });
  testWidgets('mobile forced-password gate hides business screens', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('auth-gate');
    addTearDown(() => root.deleteSync(recursive: true));
    final client = MockClient((request) async => http.Response('{}', 500));
    final auth = makeSession(client)..endpoint = 'https://example.test';
    await auth.accept(session('gate'));
    await tester.pumpWidget(
      MaterialApp(
        home: AccountGate(
          store: AppStore(
            root.path,
            client: client,
            configuration: auth.connection,
          ),
          zone: 'UTC',
          appearance: Appearance(root.path),
          session: auth,
        ),
      ),
    );
    expect(find.byType(PasswordPage), findsOneWidget);
    expect(find.text('首次登录或管理员重置后，必须修改密码才能使用。'), findsOneWidget);
    expect(find.text('收据'), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    await auth.clear();
    await tester.pump();
    expect(find.byType(LoginPage), findsOneWidget);
    final loginFields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(loginFields[0].controller!.text, 'https://example.test');
    expect(loginFields[1].controller!.text, isEmpty);
    expect(loginFields[2].controller!.text, isEmpty);
  });
  testWidgets(
    'password autofill groups the account and commits only after a successful change',
    (tester) async {
      bool fail = true;
      final auth = makeSession(
        MockClient((request) async {
          expect(request.url.path, '/api/auth/change-password');
          final body = jsonDecode(request.body);
          expect(body['current_password'], 'old-password-123');
          expect(body['new_password'], 'generated-password-123');
          return fail
              ? http.Response(
                  jsonEncode({
                    'error': {'message': 'temporary failure'},
                  }),
                  503,
                )
              : http.Response(
                  jsonEncode(session('updated', change: false)),
                  200,
                );
        }),
      )..endpoint = 'https://example.test';
      await auth.accept(session('existing'));
      await tester.pumpWidget(
        MaterialApp(home: PasswordPage(session: auth, requiredChange: true)),
      );
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields, hasLength(4));
      expect(fields[0].controller!.text, 'alice');
      expect(fields[0].readOnly, true);
      expect(fields.map((field) => field.autofillHints!.single), [
        AutofillHints.username,
        AutofillHints.password,
        AutofillHints.newPassword,
        AutofillHints.newPassword,
      ]);
      expect(find.byType(AutofillGroup), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), 'old-password-123');
      await tester.enterText(
        find.byType(TextField).at(2),
        'generated-password-123',
      );
      await tester.enterText(
        find.byType(TextField).at(3),
        'generated-password-123',
      );
      final submit = find.widgetWithText(FilledButton, '修改密码');
      await tester.ensureVisible(submit);
      tester.testTextInput.log.clear();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      bool saved() => tester.testTextInput.log.any(
        (call) =>
            call.method == 'TextInput.finishAutofillContext' &&
            call.arguments == true,
      );
      expect(saved(), false);
      expect(find.text('temporary failure'), findsOneWidget);
      fail = false;
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(saved(), true);
      expect(auth.user!['must_change_password'], false);
    },
  );
}
