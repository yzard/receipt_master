import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/android_update.dart';
import 'package:receipt_master/data/auth_session.dart';
import 'package:receipt_master/data/backend_defaults.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final origin = Uri.parse('https://receipts.example.test/');
  AuthSession session(http.Client client) =>
      AuthSession(
          client,
          loadDefaults: () async =>
              const BackendDefaults('https://receipts.example.test/'),
        )
        ..endpoint = origin.toString()
        ..token = 'test-session-jwt'
        ..refreshToken = 'test-refresh'
        ..expiresAt = DateTime.now().millisecondsSinceEpoch + 900000;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });
  test(
    'manifest and APK requests authenticate without following redirects',
    () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-session-jwt');
        expect(request.followRedirects, false);
        expect(request.url.origin, origin.origin);
        paths.add(request.url.path);
        return http.Response('artifact', 200);
      });
      final downloads = AndroidDownloads(session(client), client, origin);
      for (final path in [
        '/android-update.json',
        '/receipt_master.apk',
        '/updates/${'a' * 64}.apk',
      ]) {
        final response = await downloads.get(path);
        expect(response.statusCode, 200);
        await response.stream.drain<void>();
      }
      expect(paths, hasLength(3));
    },
  );
  test(
    'never sends credentials to another update host or while signed out',
    () async {
      final client = MockClient(
        (_) async => throw StateError('credentials leaked'),
      );
      final auth = session(client);
      await expectLater(
        AndroidDownloads(
          auth,
          client,
          Uri.parse('https://other.example.test/'),
        ).get('/android-update.json'),
        throwsException,
      );
      await expectLater(
        AndroidDownloads(
          auth,
          client,
          origin,
        ).get('https://other.example.test/update.apk'),
        throwsException,
      );
      await auth.clear();
      await expectLater(
        AndroidDownloads(auth, client, origin).get('/android-update.json'),
        throwsException,
      );
    },
  );
  test('a revoked login stops downloads and clears that session', () async {
    final client = MockClient((_) async => http.Response('revoked', 401));
    final auth = session(client);
    await expectLater(
      AndroidDownloads(auth, client, origin).get('/receipt_master.apk'),
      throwsA(isA<AuthenticationError>()),
    );
    expect(auth.token, isEmpty);
    expect(auth.refreshToken, isEmpty);
  });
}
