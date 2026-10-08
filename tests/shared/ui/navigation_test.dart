import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;

import '../platform_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/domain/models.dart';
import 'package:receipt_master/main.dart';
import 'package:receipt_master/ui/app_theme.dart';
import 'package:receipt_master/ui/editor.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  testWidgets(
    'visited tabs and receipt overlays preserve scroll without reloading, and saves patch the original list',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(430, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cache = Directory.systemTemp.createTempSync('navigation-cache');
      addTearDown(() => cache.deleteSync(recursive: true));
      var listCalls = 0, printedCalls = 0, saves = 0;
      var receipt = ReceiptDraft.empty(DateTime.now()).toMap()
        ..['id'] = 'receipt-5'
        ..['store'] = 'Store 5'
        ..['revision'] = 1
        ..['totalMinor'] = 100
        ..['summary'] = {'difference': 0};
      final store = AppStore(
        cache.path,
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((req) async {
          final input = jsonDecode(req.body)['input'];
          dynamic data;
          switch (req.url.path) {
            case '/api/v1/receipts/list':
              listCalls++;
              data = {
                'items': [
                  for (var i = 0; i < 30; i++)
                    {
                      'receipt_id': 'receipt-$i',
                      'version': 1,
                      'raw_store': 'Store $i',
                      'status': 'draft',
                      'created_at_utc_ms': 1780000000000 - i * 86400000,
                      'occurred_at_utc_ms': 1780000000000 - i * 86400000,
                      'total_minor': 100,
                      'currency_code': 'USD',
                    },
                ],
                'next_cursor': null,
              };
            case '/api/v1/receipts/get':
              data = receipt;
            case '/api/v1/receipts/edit':
              data = {
                ...input['receipt'],
                'summary': {'difference': 0},
              };
            case '/api/v1/receipts/save':
              saves++;
              receipt = Map<String, dynamic>.from(input['receipt'])
                ..['revision'] = 2;
              data = receipt;
            case '/api/v1/config/get':
              data = {'weight_unit': 'kg', 'report_currency': 'USD'};
            case '/api/v1/printed_names/list':
              printedCalls++;
              data = [];
            default:
              data = [];
          }
          return http.Response(
            jsonEncode({'data': data}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await tester.pumpWidget(
        ReceiptApp(
          store: store,
          zone: 'America/New_York',
          appearance: Appearance(cache.path),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Store 5'), 250);
      await tester.pumpAndSettle();
      final rowPosition = tester.getTopLeft(find.text('Store 5'));
      final overviewController = PrimaryScrollController.of(
        tester.element(find.byKey(const PageStorageKey('receipt-overview'))),
      );
      Future<void> navigate(String title) async {
        await tester.tap(find.byTooltip('打开导航菜单'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(NavigationDrawerDestination, title),
        );
        await tester.pumpAndSettle();
      }

      await navigate('商品');
      await tester.tap(find.widgetWithText(ChoiceChip, '商品名称'));
      await tester.pumpAndSettle();
      await navigate('收据');
      expect(tester.getTopLeft(find.text('Store 5')), rowPosition);
      expect(listCalls, 1);
      await navigate('商品');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '商品名称'))
            .selected,
        isTrue,
      );
      expect(printedCalls, 1);
      expect(overviewController.positions.length, 1);
      await navigate('收据');
      await tester.tap(find.text('Store 5'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(EditorPage), findsOneWidget);
      final name = find.widgetWithText(TextField, '店名 / 连锁店');
      await tester.enterText(name, 'Saved Store');
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorPage), findsNothing);
      expect(find.text('Saved Store'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Saved Store')), rowPosition);
      expect(listCalls, 1);
      expect(saves, 1);
      await tester.tap(find.text('Saved Store'));
      await tester.pumpAndSettle();
      await tester.enterText(name, 'Discarded Store');
      await tester.tap(find.text('放弃改动'));
      await tester.pumpAndSettle();
      expect(find.text('Saved Store'), findsOneWidget);
      expect(find.text('Discarded Store'), findsNothing);
      expect(listCalls, 1);
      expect(saves, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
