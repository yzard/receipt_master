import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/domain/models.dart';

void main() {
  test('offline reads survive restart, try the server each time, and isolate accounts', () async {
    final root = Directory.systemTemp.createTempSync('offline-cache');
    addTearDown(() => root.deleteSync(recursive: true));
    Object? outage;
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      if (outage != null) throw outage;
      if (request.url.path.contains('/media/')) {
        return http.Response.bytes([1, 2, 3], 200);
      }
      return http.Response(
        jsonEncode({
          'data': ['cached receipt'],
          'catalog_version': 5,
        }),
        200,
      );
    });
    AppStore store(String account) => AppStore(
      '${root.path}/$account',
      client: client,
      configuration: () async =>
          BackendConnection('https://example.test', 'jwt'),
    );
    var alice = store('alice');
    expect(await alice.request('receipts', 'list', {}), ['cached receipt']);
    expect(await alice.imageBytes('photo'), [1, 2, 3]);
    await alice.flushCache();
    outage = TimeoutException('no signal');
    alice = store('alice');
    expect(await alice.request('receipts', 'list', {}), ['cached receipt']);
    expect(alice.offlineMessage, 'Timeout');
    expect(await alice.imageBytes('photo'), [1, 2, 3]);
    await expectLater(
      store('bob').request('receipts', 'list', {}),
      throwsA(isA<InputError>()),
    );
    await expectLater(
      alice.request('receipts', 'save', {}),
      throwsA(predicate((e) => e.toString() == 'Timeout')),
    );
    expect(attempts, 6);
    outage = null;
    expect(await alice.request('receipts', 'list', {}), ['cached receipt']);
    expect(alice.offlineMessage, isNull);
  });
  test(
    'a rejected credential refreshes once and retries the same operation key',
    () async {
      final root = Directory.systemTemp.createTempSync('auth-retry');
      addTearDown(() => root.deleteSync(recursive: true));
      final bodies = <String>[];
      final store = AppStore(
        root.path,
        configuration: () async =>
            BackendConnection('https://example.test', 'expired'),
        client: MockClient((req) async {
          bodies.add(req.body);
          return req.headers['Authorization'] == 'Bearer expired'
              ? http.Response('{"error":{"message":"expired"}}', 401)
              : http.Response('{"data":[],"catalog_version":1}', 200);
        }),
      );
      store.recoverAuthentication = (token) async {
        expect(token, 'expired');
        return BackendConnection('https://example.test', 'fresh');
      };
      expect(await store.request('receipts', 'list', {}, key: 'same-key'), []);
      expect(bodies, hasLength(2));
      expect(bodies[0], bodies[1]);
      store.recoverAuthentication = (_) async =>
          throw const InputError('revoked');
      await expectLater(
        store.request('receipts', 'list', {}),
        throwsA(predicate((e) => e.toString() == 'revoked')),
      );
    },
  );
  test('successful mutations discard stale caches and server errors never fall back', () async {
    final root = Directory.systemTemp.createTempSync('cache-invalidation');
    addTearDown(() => root.deleteSync(recursive: true));
    var mode = 'online';
    final store = AppStore(
      root.path,
      configuration: () async =>
          BackendConnection('https://example.test', 'jwt'),
      client: MockClient((_) async {
        if (mode == 'offline') throw http.ClientException('offline');
        if (mode == 'forbidden') {
          return http.Response('{"error":{"message":"forbidden"}}', 403);
        }
        return http.Response('{"data":[],"catalog_version":1}', 200);
      }),
    );
    await store.request('receipts', 'list', {});
    mode = 'forbidden';
    await expectLater(
      store.request('receipts', 'list', {}),
      throwsA(predicate((e) => e.toString() == 'forbidden')),
    );
    mode = 'online';
    await store.request('receipts', 'purge', {});
    mode = 'offline';
    await expectLater(
      store.request('receipts', 'list', {}),
      throwsA(isA<InputError>()),
    );
  });
}
