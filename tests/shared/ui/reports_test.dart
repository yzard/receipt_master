import 'dart:convert';

import 'package:timezone/data/latest.dart' as tzdata;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/ui/reports.dart';

void main() {
  testWidgets(
    'category details use product names and only fall back when missing',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? opened;
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((req) async {
          final dynamic data;
          if (req.url.path.endsWith('/range')) {
            data = {
              'start': 1000,
              'end': 2000,
              'previous_start': 0,
              'label': '测试周期',
              'unfinished': false,
            };
          } else if (req.url.path.endsWith('/list')) {
            data = [];
          } else {
            data = {
              'net': 200,
              'spend': 200,
              'discounts': 0,
              'refunds': 0,
              'difference': 0,
              'entries': [
                for (final id in ['mapped', 'unmapped'])
                  {
                    'line_id': id,
                    'receipt_id': id,
                    'kind': 'product',
                    'product_name': id == 'mapped' ? '瓶装水' : ' ',
                    'raw_name': id == 'mapped' ? 'KWSWTR40PK' : 'UNMAPPED',
                    'raw_store': 'Costco',
                    'occurred_at_utc_ms': 1000,
                    'amount_minor': 100,
                  },
              ],
              'groups': [
                {
                  'group': 'category',
                  'label': '饮料',
                  'amount': 200,
                  'line_ids': ['mapped', 'unmapped'],
                },
              ],
            };
          }
          return http.Response(
            jsonEncode({'data': data}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportsPage(
              store: store,
              zone: 'America/New_York',
              onReceipt: (id) async {
                opened = id;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('饮料'));
      await tester.pumpAndSettle();
      expect(find.text('瓶装水'), findsOneWidget);
      expect(find.text('KWSWTR40PK'), findsNothing);
      expect(find.text('UNMAPPED'), findsOneWidget);
      await tester.tap(find.text('瓶装水'));
      await tester.pumpAndSettle();
      expect(opened, 'mapped');
    },
  );

  testWidgets(
    'pull refresh recalculates both periods and recovers from failure on short reports',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var amount = 100, summaries = 0, ranges = 0, fail = false;
      final inputs = <Map<String, dynamic>>[];
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((req) async {
          final input = Map<String, dynamic>.from(
            jsonDecode(req.body)['input'],
          );
          dynamic data;
          switch (req.url.path) {
            case '/api/v1/reports/range':
              ranges++;
              data = {
                'start': 1000,
                'end': 2000,
                'previous_start': 0,
                'label': '测试周期',
                'unfinished': false,
              };
            case '/api/v1/categories/list':
              data = [];
            case '/api/v1/reports/summary':
              summaries++;
              inputs.add(input);
              if (fail) {
                return http.Response(
                  jsonEncode({
                    'error': {'code': 'unavailable', 'message': 'offline'},
                  }),
                  503,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }
              data = {
                'net': amount,
                'spend': amount,
                'discounts': 0,
                'refunds': 0,
                'difference': 0,
                'entries': [],
                'groups': [],
              };
            default:
              throw StateError('Unexpected ${req.url.path}');
          }
          return http.Response(
            jsonEncode({'data': data, 'catalog_version': 1}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportsPage(
              store: store,
              zone: 'UTC',
              onReceipt: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(summaries, 2);
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).last,
      );
      expect(scrollable.position.maxScrollExtent, 0);
      Future<void> pull() async {
        await tester.drag(find.byType(ListView), const Offset(0, 350));
        await tester.pumpAndSettle();
      }

      amount = 250;
      await pull();
      expect(ranges, 2);
      expect(summaries, 4);
      expect(find.text('USD 2.50'), findsOneWidget);
      expect(inputs.last['start'], 0);
      expect(inputs.last['end'], 1000);
      expect(inputs[2]['start'], 1000);
      expect(inputs[2]['end'], 2000);
      expect(inputs[2]['currency'], 'USD');
      fail = true;
      await pull();
      expect(find.textContaining('报表加载失败'), findsOneWidget);
      expect(find.text('USD 2.50'), findsOneWidget);
      fail = false;
      amount = 375;
      await pull();
      expect(find.textContaining('报表加载失败'), findsNothing);
      expect(find.text('USD 3.75'), findsOneWidget);
      expect(summaries, 7);
    },
  );
}
