import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/l10n/catalog.dart';

Map<String, dynamic> resource() => jsonDecode(
  File('../../src/backend_api/resources/localizations.json').readAsStringSync(),
);

void main() {
  test(
    'loads available languages and all tables once, caching for offline use',
    () async {
      final root = Directory.systemTemp.createTempSync('receipt-translations-');
      addTearDown(() => root.deleteSync(recursive: true));
      final catalog = TranslationCatalog();
      addTearDown(catalog.dispose);
      var requests = 0;
      final data = resource();
      data['available_languages'].add({
        'code': 'fr',
        'name': 'Français',
        'locale': 'fr-FR',
      });
      data['translations']['fr'] = {'设置': 'Paramètres'};
      final client = MockClient((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/localizations/get');
        expect(request.headers.containsKey('Authorization'), isFalse);
        return http.Response(jsonEncode({'data': data}), 200);
      });
      addTearDown(client.close);
      Future<void> load() => catalog.load(
        origin: Uri.parse('https://example.test'),
        client: client,
        cacheRoot: root.path,
      );
      await Future.wait([load(), load()]);
      await load();
      expect(requests, 1);
      expect(catalog.languages.map((entry) => entry.code), ['zh', 'en', 'fr']);
      expect(catalog.translations['fr']!['设置'], 'Paramètres');
      final offline = TranslationCatalog();
      addTearDown(offline.dispose);
      final offlineClient = MockClient(
        (_) async => throw const SocketException('offline'),
      );
      addTearDown(offlineClient.close);
      await expectLater(
        offline.load(
          origin: Uri.parse('https://example.test'),
          client: offlineClient,
          cacheRoot: root.path,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(offline.translations['en']!['设置'], 'Settings');
      expect(offline.languages.last.name, 'Français');
      expect(
        () => offline.install({
          'schema_version': 1,
          'available_languages': [],
          'translations': {},
        }),
        throwsFormatException,
      );
      expect(offline.languages.last.name, 'Français');
    },
  );

  test(
    'server changes ignore late resources and can return to a loaded server',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'receipt-translations-origin-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final catalog = TranslationCatalog();
      addTearDown(catalog.dispose);
      final old = Completer<http.Response>();
      final newer = resource();
      newer['translations']['en']['设置'] = 'New server settings';
      final client = MockClient(
        (request) async => request.url.host == 'old.test'
            ? old.future
            : http.Response(jsonEncode({'data': newer}), 200),
      );
      addTearDown(client.close);
      final pending = catalog.load(
        origin: Uri.parse('https://old.test'),
        client: client,
        cacheRoot: root.path,
      );
      await catalog.load(
        origin: Uri.parse('https://new.test'),
        client: client,
        cacheRoot: root.path,
      );
      old.complete(http.Response(jsonEncode({'data': resource()}), 200));
      await pending;
      expect(catalog.translations['en']!['设置'], 'New server settings');
      await catalog.load(
        origin: Uri.parse('https://old.test'),
        client: client,
        cacheRoot: root.path,
      );
      expect(catalog.translations['en']!['设置'], 'Settings');
    },
  );
}
