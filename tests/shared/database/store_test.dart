import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/domain/models.dart';

void main() {
  test(
    'accepted uploads are not repeated when recognition submission retries',
    () async {
      final dir = Directory.systemTemp.createTempSync('capture-complete-');
      addTearDown(() => dir.deleteSync(recursive: true));
      Map<String, dynamic>? saved;
      var uploads = 0;
      final starts = <String>[];
      Future<http.Response> server(http.Request req) async {
        dynamic data;
        if (req.url.path.endsWith('/upload')) {
          uploads++;
          saved!['revision'] = uploads + 1;
          data = {'receipt': saved};
        } else {
          final body = jsonDecode(req.body);
          if (req.url.path.endsWith('/save')) {
            saved ??= Map<String, dynamic>.from(body['input']['receipt'])
              ..['revision'] = 1;
            data = saved;
          } else if (req.url.path.endsWith('/get')) {
            data = saved;
          } else if (req.url.path.endsWith('/start')) {
            expect(uploads, 2);
            expect(body["input"]["expected_version"], 3);
            starts.add(req.body);
            if (starts.length == 1) {
              return http.Response(
                '{"error":{"message":"lost response"}}',
                503,
              );
            }
            data = {'job_id': 'durable-job', 'status': 'queued'};
          }
        }
        return http.Response(jsonEncode({'data': data}), 200);
      }

      AppStore repository() => AppStore(
        dir.path,
        client: MockClient(server),
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
      );
      final first = repository();
      await first.queueCapture(
        [
          Uint8List.fromList([1]),
          Uint8List.fromList([2]),
        ],
        true,
        1,
        'UTC',
      );
      while (first.submissionStates.values.any((v) => v == '上传中')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(uploads, 2);
      final second = repository();
      await second.retryUploads();
      while (second.submissionStates.values.any((v) => v == '上传中')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(second.submissionStates, isEmpty);
      expect(starts.length, 2);
      expect(starts[1], starts[0]);
      expect(uploads, 2);
      expect(Directory('${dir.path}/submissions').listSync(), isEmpty);
      first.dispose();
      second.dispose();
    },
  );

  test(
    'captures return before network and failed submissions survive reopening',
    () async {
      final dir = Directory.systemTemp.createTempSync('capture-queue-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gate = Completer<void>();
      final requests = <String>[];
      final first = AppStore(
        dir.path,
        client: MockClient((req) async {
          requests.add(req.body);
          await gate.future;
          return http.Response('{"error":{"message":"offline"}}', 503);
        }),
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
      );
      final a = await first
          .queueCapture(
            [
              Uint8List.fromList([1, 2]),
            ],
            true,
            1,
            'UTC',
          )
          .timeout(const Duration(seconds: 2));
      final b = await first
          .queueCapture(
            [
              Uint8List.fromList([3, 4]),
            ],
            false,
            2,
            'UTC',
          )
          .timeout(const Duration(seconds: 2));
      expect(a, isNot(b));
      expect(first.submissionStates.length, 2);
      expect(
        Directory('${dir.path}/submissions')
            .listSync()
            .where((f) => f.path.endsWith('.json'))
            .length,
        2,
      );
      gate.complete();
      while (first.submissionStates.values.any((v) => v == '上传中')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final retried = <String>[];
      final reopened = AppStore(
        dir.path,
        client: MockClient((req) async {
          retried.add(req.body);
          return http.Response('{"error":{"message":"offline"}}', 503);
        }),
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
      );
      await reopened.retryUploads();
      while (reopened.submissionStates.values.any((v) => v == '上传中')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(retried.toSet(), requests.toSet());
      expect(
        Directory('${dir.path}/pending')
            .listSync()
            .where((f) => f.path.endsWith('.photo'))
            .length,
        2,
      );
      first.dispose();
      reopened.dispose();
    },
  );

  test(
    'repository uses authenticated backend origin and server receipt version',
    () async {
      final requests = <http.Request>[];
      final store = AppStore(
        '/unused',
        client: MockClient((req) async {
          requests.add(req);
          return http.Response(
            jsonEncode({
              'data': {'id': 'r', 'revision': 7},
              'catalog_version': 4,
            }),
            200,
          );
        }),
        configuration: () async => const BackendConnection(
          'https://example.test:8443/v1/chat/completions',
          'key',
        ),
      );
      final result = await store.load('r');
      expect(result['revision'], 7);
      expect(store.versions['r'], 7);
      expect(store.catalogVersion, 4);
      expect(
        requests.single.url.toString(),
        'https://example.test:8443/api/v1/receipts/get',
      );
      expect(requests.single.headers['Authorization'], 'Bearer key');
    },
  );
  test('conflict does not silently update local revision', () async {
    final store = AppStore(
      '/unused',
      client: MockClient(
        (req) async => http.Response('{"error":{"message":"conflict"}}', 409),
      ),
      configuration: () async =>
          const BackendConnection('https://example.test', 'key'),
    );
    store.versions['r'] = 3;
    await expectLater(
      store.save({'id': 'r', 'revision': 3}, true, 0),
      throwsA(isA<InputError>()),
    );
    expect(store.versions['r'], 3);
  });
  test('failed upload retains original bytes and retry identity', () async {
    final dir = Directory.systemTemp.createTempSync('upload-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppStore(
      dir.path,
      client: MockClient(
        (req) async => http.Response('{"error":{"message":"offline"}}', 503),
      ),
      configuration: () async =>
          const BackendConnection('https://example.test', 'key'),
    );
    store.versions['r'] = 1;
    await expectLater(
      store.importImage('r', utf8.encode('original photo'), true, 1),
      throwsA(isA<InputError>()),
    );
    final photos = Directory('${dir.path}/pending')
        .listSync()
        .where((f) => f.path.endsWith('.photo'))
        .toList();
    expect(photos.length, 1);
    expect(File(photos.single.path).readAsStringSync(), 'original photo');
  });
  test(
    'batch is durable before sending and concurrent retries share one upload',
    () async {
      final dir = Directory.systemTemp.createTempSync('batch-upload-');
      addTearDown(() => dir.deleteSync(recursive: true));
      var calls = 0;
      final store = AppStore(
        dir.path,
        client: MockClient((req) async {
          calls++;
          return http.Response('{"error":{"message":"offline"}}', 503);
        }),
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
      );
      store.versions['r'] = 1;
      final first = await store.queueImage(
        'r',
        utf8.encode('photo one'),
        true,
        1,
      );
      await store.queueImage('r', utf8.encode('photo two'), true, 2);
      final a = store.sendUpload(first), b = store.sendUpload(first);
      expect(identical(a, b), isTrue);
      await expectLater(Future.wait([a, b]), throwsA(isA<InputError>()));
      expect(calls, 1);
      expect(store.uploads, isEmpty);
      expect(
        Directory('${dir.path}/pending')
            .listSync()
            .where((f) => f.path.endsWith('.photo'))
            .length,
        2,
      );
    },
  );
}
