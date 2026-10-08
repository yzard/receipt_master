import 'dart:convert';

import 'package:timezone/data/latest.dart' as tzdata;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;

import '../platform_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/ui/reports.dart';
import 'package:receipt_master/ui/report_trend_chart.dart';

void main() {
  testWidgets('trend chart selects a point and swipes to earlier windows', (
    tester,
  ) async {
    int? selected;
    var older = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: ReportTrendChart(
                points: [
                  for (var index = 0; index < 3; index++)
                    {
                      'tick': '0$index',
                      'net': index * 100,
                      'offset': index - 2,
                    },
                ],
                series: const [
                  {
                    'key': 'category:drinks',
                    'group': 'category',
                    'label': '饮料',
                    'values': [0, 100, 200],
                  },
                  {
                    'key': 'product:water',
                    'group': 'product',
                    'label': '瓶装水',
                    'values': [0, 100, 200],
                  },
                ],
                visibleSeries: const {'category:drinks', 'product:water'},
                currency: 'USD',
                selectedIndex: 2,
                onSelect: (index) => selected = index,
                onOlder: () => older++,
                onNewer: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('总金额'), findsOneWidget);
    expect(find.text('商品分类 · 饮料'), findsOneWidget);
    expect(find.text('商品 · 瓶装水'), findsOneWidget);
    final rect = tester.getRect(find.byType(ReportTrendChart));
    await tester.tapAt(Offset(rect.left + 52, rect.center.dy));
    expect(selected, 0);
    await tester.fling(
      find.byType(ReportTrendChart),
      const Offset(260, 0),
      900,
    );
    expect(older, 1);
  });

  testWidgets('selecting an earlier chart point loads that period breakdown', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requestedStarts = <int>[];
    final store = AppStore(
      '/unused',
      configuration: () async =>
          const BackendConnection('https://example.test', 'key'),
      client: MockClient((req) async {
        final input = Map<String, dynamic>.from(jsonDecode(req.body)['input']);
        final dynamic data;
        if (req.url.path.endsWith('/trend')) {
          data = {
            'currency': 'USD',
            'points': [
              {
                'start': 0,
                'end': 1000,
                'previous_start': -1000,
                'offset': -1,
                'tick': '01/01',
                'label': '较早周期',
                'net': 100,
              },
              {
                'start': 1000,
                'end': 2000,
                'previous_start': 0,
                'offset': 0,
                'tick': '02/01',
                'label': '当前周期',
                'net': 200,
              },
            ],
            'series': [],
          };
        } else if (req.url.path.endsWith('/list')) {
          data = [];
        } else {
          requestedStarts.add(input['start'] as int);
          data = {
            'currency': 'USD',
            'net': input['start'] == 0 ? 100 : 200,
            'spend': 100,
            'discounts': 0,
            'refunds': 0,
            'difference': 0,
            'entries': [],
            'groups': [],
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
          body: ReportsPage(store: store, zone: 'UTC', onReceipt: (_) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选 当前周期'), findsOneWidget);
    final chart = tester.getRect(find.byType(ReportTrendChart));
    await tester.tapAt(Offset(chart.left + 52, chart.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('已选 较早周期'), findsOneWidget);
    expect(requestedStarts.take(4).toList(), [1000, 0, 0, -1000]);
  });

  testWidgets(
    'category details use product names and only fall back when missing',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? opened;
      var summaries = 0;
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((req) async {
          final dynamic data;
          if (req.url.path.endsWith('/trend')) {
            data = {
              'currency': 'USD',
              'points': [
                {
                  'start': 1000,
                  'end': 2000,
                  'previous_start': 0,
                  'label': '测试周期',
                  'tick': '01/01',
                  'offset': 0,
                  'net': 201,
                  'unfinished': false,
                },
              ],
              'series': [
                {
                  'key': 'category:drinks',
                  'group': 'category',
                  'label': '饮料',
                  'values': [200],
                },
              ],
            };
          } else if (req.url.path.endsWith('/list')) {
            data = [];
          } else {
            summaries++;
            data = {
              'net': 201,
              'spend': 200,
              'discounts': 0,
              'refunds': 0,
              'difference': 0,
              'rounding_adjustment': 1,
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
      expect(find.text('消费趋势'), findsOneWidget);
      await tester.tap(find.text('曲线'));
      await tester.pumpAndSettle();
      expect(find.text('饮料'), findsWidgets);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(CheckboxListTile).first)).pop();
      await tester.pumpAndSettle();
      expect(find.text('曲线 1'), findsOneWidget);
      expect(find.textContaining('逐项换算舍入差额 USD 0.01'), findsOneWidget);
      await tester.tap(find.text('饮料').last);
      await tester.pumpAndSettle();
      expect(find.text('瓶装水'), findsOneWidget);
      expect(find.text('KWSWTR40PK'), findsNothing);
      expect(find.text('UNMAPPED'), findsOneWidget);
      await tester.tap(find.text('瓶装水'));
      await tester.pumpAndSettle();
      expect(opened, 'mapped');
      expect(
        summaries,
        4,
      ); // Returning from an editor preserves the loaded report.
    },
  );

  testWidgets(
    'pull refresh recalculates both periods and recovers from failure on short reports',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var amount = 100, summaries = 0, trends = 0, fail = false;
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
            case '/api/v1/reports/trend':
              trends++;
              data = {
                'currency': 'USD',
                'points': [
                  {
                    'start': 1000,
                    'end': 2000,
                    'previous_start': 0,
                    'label': '测试周期',
                    'tick': '01/01',
                    'offset': 0,
                    'net': amount,
                    'unfinished': false,
                  },
                ],
                'series': [],
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
      Future<void> pull() async {
        await tester.drag(find.text('报表'), const Offset(0, 500));
        await tester.pumpAndSettle();
      }

      amount = 250;
      await pull();
      expect(trends, 2);
      expect(summaries, 4);
      expect(find.text('USD 2.50'), findsOneWidget);
      expect(inputs.last['start'], 0);
      expect(inputs.last['end'], 1000);
      expect(inputs[2]['start'], 1000);
      expect(inputs[2]['end'], 2000);
      expect(inputs[2].containsKey('currency'), isFalse);
      expect(inputs[2]['zone'], 'UTC');
      expect(find.textContaining('统一显示 USD'), findsOneWidget);
      fail = true;
      await pull();
      expect(find.textContaining('报表更新失败'), findsOneWidget);
      expect(find.text('USD 2.50'), findsOneWidget);
      fail = false;
      amount = 375;
      await tester.tap(find.text('重试统计'));
      await tester.pumpAndSettle();
      expect(find.textContaining('报表更新失败'), findsNothing);
      expect(find.text('USD 3.75'), findsOneWidget);
      expect(summaries, 7);
    },
  );
  testWidgets(
    'curve selection refreshes all categories, disables empty ones and selects category curves independently',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool classified = false, fail = false;
      int trends = 0;
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((req) async {
          dynamic data;
          switch (req.url.path) {
            case '/api/v1/reports/trend':
              trends++;
              if (fail) {
                return http.Response(
                  jsonEncode({
                    'error': {'message': 'network failure'},
                  }),
                  500,
                );
              }
              final category = classified ? 'drinks' : 'uncategorized';
              data = {
                'currency': 'USD',
                'points': [
                  {
                    'start': 1000,
                    'end': 2000,
                    'previous_start': 0,
                    'offset': 0,
                    'tick': 'Jan',
                    'label': '当前周期',
                    'net': 100,
                  },
                ],
                'series': [
                  {
                    'key': 'category:groceries',
                    'group': 'category',
                    'label': '杂货',
                    'values': [classified ? 100 : 0],
                  },
                  {
                    'key': 'category:drinks',
                    'group': 'category',
                    'label': '饮料',
                    'path': '杂货 / 饮料',
                    'depth': 1,
                    'values': [classified ? 100 : 0],
                  },
                  {
                    'key': 'category:nuts',
                    'group': 'category',
                    'label': '坚果',
                    'values': [0],
                  },
                  {
                    'key': 'category:uncategorized',
                    'group': 'category',
                    'label': '未分类',
                    'values': [classified ? 0 : 100],
                  },
                  {
                    'key': 'product:water',
                    'group': 'product',
                    'label': '瓶装水',
                    'values': [100],
                    'category_keys': ['category:$category'],
                  },
                ],
              };
            case '/api/v1/categories/list':
              data = [];
            case '/api/v1/reports/summary':
              data = {
                'currency': 'USD',
                'net': 100,
                'spend': 100,
                'refunds': 0,
                'discounts': 0,
                'difference': 0,
                'groups': [],
                'entries': [],
              };
            default:
              throw StateError(req.url.path);
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
              zone: 'UTC',
              onReceipt: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      classified = true;
      await tester.tap(find.text('曲线'));
      await tester.pumpAndSettle();
      expect(trends, 2);
      expect(find.text('未分类'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(4));
      expect(find.text('瓶装水'), findsNothing);
      await tester.tap(find.byTooltip('展开饮料商品'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(5));
      CheckboxListTile tile(String title) => tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, title),
      );
      expect(tile('坚果').onChanged, isNull);
      expect(tile('未分类').onChanged, isNull);
      expect(tile('饮料').enabled, isTrue);
      expect(find.text('杂货 / 饮料 · 分类合计'), findsOneWidget);
      await tester.tap(find.text('杂货'));
      await tester.pumpAndSettle();
      expect(tile('杂货').value, isTrue);
      expect(tile('饮料').value, isFalse);
      expect(tile('瓶装水').value, isFalse);
      await tester.tap(find.text('饮料'));
      await tester.pumpAndSettle();
      expect(tile('杂货').value, isTrue);
      expect(tile('饮料').value, isTrue);
      expect(tile('瓶装水').value, isFalse);
      await tester.tap(find.text('杂货'));
      await tester.tap(find.text('饮料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('瓶装水'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起饮料商品'));
      await tester.pumpAndSettle();
      expect(find.text('瓶装水'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNWidgets(4));
      Navigator.of(tester.element(find.byType(CheckboxListTile).first)).pop();
      await tester.pumpAndSettle();
      expect(find.text('商品 · 瓶装水'), findsOneWidget);
      fail = true;
      await tester.tap(find.text('曲线 1'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.textContaining('报表更新失败'), findsOneWidget);
    },
  );
}
