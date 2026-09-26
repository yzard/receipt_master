import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/ui/catalog.dart';

void main() {
  testWidgets('product name tag opens receipts and refreshes after editing', (
    tester,
  ) async {
    tz.initializeTimeZones();
    var edited = false;
    final store = AppStore(
      '/unused',
      configuration: () async =>
          const BackendConnection('https://example.test', 'key'),
      client: MockClient((req) async {
        final input = jsonDecode(req.body)['input'];
        dynamic data;
        switch (req.url.path) {
          case '/api/v1/config/get':
            data = {'weight_unit': 'kg'};
          case '/api/v1/categories/list':
          case '/api/v1/printed_names/list':
            data = [];
          case '/api/v1/product_names/list':
            data = [
              {'product_name_id': 'rice', 'name': '大米'},
            ];
          case '/api/v1/receipts/list':
            expect(input['product_name_id'], 'rice');
            data = {
              'items': edited
                  ? []
                  : [
                      {
                        'receipt_id': 'receipt',
                        'version': 1,
                        'raw_store': 'Shop',
                        'status': 'posted',
                        'created_at_utc_ms': 1780000000000,
                        'occurred_at_utc_ms': 1780000000000,
                        'total_minor': 100,
                        'currency_code': 'USD',
                      },
                    ],
              'next_cursor': null,
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
          body: CatalogPage(
            store: store,
            zone: 'America/New_York',
            onReceipt: (id) async {
              expect(id, 'receipt');
              edited = true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('商品名称').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('大米'));
    await tester.pumpAndSettle();
    expect(find.text('Shop'), findsOneWidget);
    await tester.tap(find.text('Shop'));
    await tester.pumpAndSettle();
    expect(find.text('没有包含此商品名称的收据'), findsOneWidget);
  });

  testWidgets('four catalog tabs map names, classify names and delete tags', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? productName;
    var category = 'category';
    bool deletedCategory = false;
    final names = <String>['鸡蛋', '牛奶'];
    final classifications = <Map<String, dynamic>>[];
    final writes = <String>[];
    final store = AppStore(
      '/unused',
      configuration: () async =>
          const BackendConnection('https://example.test', 'key'),
      client: MockClient((req) async {
        final input = jsonDecode(req.body)['input'];
        dynamic data;
        switch (req.url.path) {
          case '/api/v1/config/get':
            data = {'weight_unit': 'kg'};
          case '/api/v1/categories/list':
            data = [
              {
                'category_id': 'uncategorized',
                'name': '未分类',
                'parent_id': null,
                'system_key': 'uncategorized',
                'depth': 0,
                'path': '未分类',
              },
              if (!deletedCategory)
                {
                  'category_id': 'drinks',
                  'name': '饮料',
                  'parent_id': null,
                  'system_key': null,
                  'depth': 0,
                  'path': '饮料',
                },
              {
                'category_id': 'category',
                'name': '食品',
                'parent_id': null,
                'system_key': null,
                'depth': 0,
                'path': '食品',
              },
            ];
          case '/api/v1/categories/delete':
            expect(input['id'], 'drinks');
            deletedCategory = true;
            category = 'uncategorized';
            data = null;
          case '/api/v1/product_names/delete':
            names.remove(input['id']);
            if (productName == input['id']) productName = null;
            data = null;
          case '/api/v1/product_names/list':
            data = [
              for (final name in names)
                {
                  'product_name_id': name,
                  'name': name,
                  'category_id': category,
                },
            ];
          case '/api/v1/product_names/classify':
            category = input['category_id'];
            classifications.add(Map<String, dynamic>.from(input));
            data = null;
          case '/api/v1/printed_names/list':
            data = [
              {
                'product_id': 'product',
                'printed_name_id': 'name',
                'raw_name': 'Original product',
                'product_name': productName,
                'category_id': category,
                'category_name': '食品',
                'weight_label': '0.50 kg',
              },
            ];
          case '/api/v1/printed_names/set_product_name':
            expect(input['id'], 'name');
            writes.add(input['name']);
            productName = input['name'] == '' ? null : input['name'];
            if (productName != null) {
              names.remove(productName);
              names.insert(0, productName!);
            }
            data = null;
          default:
            fail('Unexpected request: ${req.url.path}');
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
          body: CatalogPage(store: store, zone: "UTC", onReceipt: (_) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('票据名称'), findsOneWidget);
    expect(find.text('商店名称'), findsOneWidget);
    expect(find.textContaining('0.50 kg'), findsNothing);
    for (final value in ['Rice', '']) {
      await tester.enterText(find.byType(TextField), value);
      await tester.tap(find.byTooltip('保存商品名称'));
      await tester.pumpAndSettle();
      expect(find.text('Original product'), findsOneWidget);
    }
    await tester.tap(find.byTooltip('选择商品名称'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('鸡蛋'));
    await tester.pumpAndSettle();
    expect(writes, ['Rice', '', '鸡蛋']);
    Future<void> tab(String text) async {
      final target = find.widgetWithText(ChoiceChip, text);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    await tab('商品名称');
    expect(find.byType(InputChip), findsNWidgets(3));
    expect(find.byType(TextField), findsNothing);
    await tab('商品分类');
    expect(find.text('添加种类'), findsNothing);
    expect(find.byType(InputChip), findsNothing);
    expect(find.text('Original product'), findsNothing);
    await tester.tap(find.byTooltip('选择商品种类').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('饮料').last);
    await tester.pumpAndSettle();
    expect(classifications.single['category_id'], 'drinks');
    expect(classifications.single['id'], '鸡蛋');
    await tab('商品种类');
    expect(find.text('添加种类'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '饮料'),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('关联商品名称变为未分类'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(deletedCategory, isTrue);
    expect(find.text('饮料'), findsNothing);
    await tab('商品名称');
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '鸡蛋'),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('保留所有收据和照片'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(names, isNot(contains('鸡蛋')));
    await tab('票据名称');
    expect(find.text('Original product'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });
  testWidgets(
    'pending mappings and categories lead completed rows and move after saving',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final printed = <Map<String, dynamic>>[
        {'printed_name_id': 'a', 'raw_name': 'A', 'product_name': 'Named'},
        {'printed_name_id': 'b', 'raw_name': 'B', 'product_name': null},
        {'printed_name_id': 'c', 'raw_name': 'C', 'product_name': 'Named'},
        {'printed_name_id': 'd', 'raw_name': 'D', 'product_name': null},
      ];
      final names = <Map<String, dynamic>>[
        {'product_name_id': 'one', 'name': 'Named', 'category_id': 'food'},
        {
          'product_name_id': 'two',
          'name': 'Pending',
          'category_id': 'uncategorized',
        },
        {'product_name_id': 'three', 'name': 'Other', 'category_id': 'food'},
      ];
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((req) async {
          final input = jsonDecode(req.body)['input'];
          dynamic data;
          switch (req.url.path) {
            case '/api/v1/config/get':
              data = {'weight_unit': 'kg'};
            case '/api/v1/categories/list':
              data = [
                {
                  'category_id': 'uncategorized',
                  'name': '未分类',
                  'path': '未分类',
                  'system_key': 'uncategorized',
                },
                {
                  'category_id': 'food',
                  'name': '食品',
                  'path': '食品',
                  'system_key': null,
                },
              ];
            case '/api/v1/printed_names/list':
              data = printed;
            case '/api/v1/product_names/list':
              data = names;
            case '/api/v1/printed_names/set_product_name':
              printed.firstWhere(
                (p) => p['printed_name_id'] == input['id'],
              )['product_name'] = input['name'];
              data = null;
            case '/api/v1/product_names/classify':
              names.firstWhere(
                (n) => n['product_name_id'] == input['id'],
              )['category_id'] = input['category_id'];
              data = null;
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
            body: CatalogPage(
              store: store,
              zone: "UTC",
              onReceipt: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder row(String key) => find.byKey(ValueKey(key));
      final divider = find.byKey(const ValueKey('catalog-completion-divider'));
      void ordered(List<Finder> widgets) {
        for (var i = 1; i < widgets.length; i++) {
          expect(
            tester.getTopLeft(widgets[i]).dy,
            greaterThan(tester.getTopLeft(widgets[i - 1]).dy),
          );
        }
      }

      ordered([
        row('printed-b'),
        row('printed-d'),
        divider,
        row('printed-a'),
        row('printed-c'),
      ]);
      expect(tester.widget<Divider>(divider).thickness, 0.5);
      for (final id in ['b', 'd']) {
        final target = row('printed-$id');
        await tester.enterText(
          find.descendant(of: target, matching: find.byType(TextField)),
          'Named',
        );
        await tester.tap(
          find.descendant(of: target, matching: find.byTooltip('保存商品名称')),
        );
        await tester.pumpAndSettle();
        if (id == 'b') {
          ordered([
            row('printed-d'),
            divider,
            row('printed-a'),
            row('printed-b'),
            row('printed-c'),
          ]);
        }
      }
      expect(divider, findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '商品分类'));
      await tester.pumpAndSettle();
      ordered([
        row('category-two'),
        divider,
        row('category-one'),
        row('category-three'),
      ]);
      await tester.enterText(
        find.descendant(
          of: row('category-two'),
          matching: find.byType(TextField),
        ),
        '食品',
      );
      await tester.tap(
        find.descendant(
          of: row('category-two'),
          matching: find.byTooltip('保存商品种类'),
        ),
      );
      await tester.pumpAndSettle();
      expect(divider, findsNothing);
      ordered([
        row('category-one'),
        row('category-two'),
        row('category-three'),
      ]);
    },
  );

  testWidgets(
    'missing category remains editable and catalog supports pull refresh',
    (tester) async {
      var categoryLoads = 0;
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((req) async {
          dynamic data;
          switch (req.url.path) {
            case '/api/v1/config/get':
              data = {'weight_unit': 'kg'};
            case '/api/v1/categories/list':
              categoryLoads++;
              data = [
                {
                  'category_id': 'uncategorized',
                  'name': '未分类',
                  'path': '未分类',
                  'system_key': 'uncategorized',
                },
              ];
            case '/api/v1/printed_names/list':
              data = [];
            case '/api/v1/product_names/list':
              data = [
                {
                  'product_name_id': 'rice',
                  'name': '大米',
                  'category_id': 'removed',
                },
              ];
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
            body: CatalogPage(
              store: store,
              zone: 'UTC',
              onReceipt: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '商品分类'));
      await tester.pumpAndSettle();
      expect(find.text('未分类'), findsWidgets);
      await tester.drag(find.byType(ListView).last, const Offset(0, 320));
      await tester.pumpAndSettle();
      expect(categoryLoads, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
