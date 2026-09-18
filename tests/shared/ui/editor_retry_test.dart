import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/domain/models.dart';
import 'package:receipt_master/ui/editor.dart';
import 'package:timezone/data/latest.dart' as tzdata;

class TestStore extends AppStore {
  TestStore(http.Client client)
    : super(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: client,
      );

  @override
  Widget image(Map<String, dynamic> photo, {BoxFit? fit, double? width}) =>
      const SizedBox();
}

void main() {
  for (final scenario in [
    'retry',
    'active',
    'save failure',
    'submit failure',
    'no photos',
    'posted',
    'product name',
  ]) {
    testWidgets('receipt retry: $scenario', (tester) async {
      tzdata.initializeTimeZones();
      final receipt = ReceiptDraft.empty(DateTime.now()).toMap();
      if (scenario == 'product name') {
        final line = LineDraft.empty();
        line.rawName = 'RAW PRODUCT';
        line.taxCode = 'E';
        line.sku = '12345';
        line.warnings = ['核对金额'];
        line.display = {
          'productName': 'Old product name',
          'weightText': '',
          'weightUnit': 'kg',
          'quantityText': '',
          'quantityUnit': '',
          'priceText': '',
          'amountText': '',
        };
        receipt['lines'] = [line.toMap()];
      }
      receipt['revision'] = 2;
      receipt['posted'] = scenario == 'posted';
      final events = <String>[];
      final submitted = Completer<void>();
      final store = TestStore(
        MockClient((request) async {
          final path = request.url.path;
          dynamic data;
          if (path.endsWith('/config/get')) {
            data = {'weight_unit': 'kg'};
          } else if (path.endsWith('/categories/list')) {
            data = [
              {'category_id': systemCategories['uncategorized'], 'path': '未分类'},
            ];
          } else if (path.endsWith('/receipts/display_line') ||
              path.endsWith('/receipts/prepare_line')) {
            data = jsonDecode(request.body)['input']['line'];
            if (path.endsWith('/receipts/prepare_line')) {
              expect(data['rawName'], 'RAW PRODUCT');
              expect(data['productNameEdit'], 'New product name');
              events.add('product name preview');
            }
          } else if (path.endsWith('/images/list')) {
            data = scenario == 'no photos'
                ? []
                : [
                    {'image_id': 'photo', 'media_id': 'photo'},
                  ];
          } else if (path.endsWith('/receipts/get') ||
              path.endsWith('/receipts/edit')) {
            data = receipt;
          } else if (path.endsWith('/recognition/list')) {
            events.add('list');
            data = scenario == 'active'
                ? [
                    {'status': 'running'},
                  ]
                : [];
          } else if (path.endsWith('/receipts/save')) {
            events.add('save');
            if (scenario == 'save failure') {
              return http.Response(
                jsonEncode({
                  'error': {'message': '保存失败'},
                }),
                409,
              );
            }
            data = Map<String, dynamic>.from(
              jsonDecode(request.body)['input']['receipt'],
            );
            data['revision'] = 3;
          } else if (path.endsWith('/recognition/start')) {
            events.add('start');
            final input = jsonDecode(request.body)['input'];
            expect(input['receipt_id'], receipt['id']);
            expect(input['expected_version'], scenario == 'posted' ? 2 : 3);
            expect(input['zone'], 'America/New_York');
            await submitted.future;
            if (scenario == 'submit failure') {
              return http.Response(
                jsonEncode({
                  'error': {'message': '提交失败'},
                }),
                503,
              );
            }
            data = {'job_id': 'job', 'status': 'queued'};
          } else {
            fail('Unexpected request: $path');
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
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => EditorPage(
                      store: store,
                      zone: 'America/New_York',
                      receiptId: receipt['id'],
                    ),
                  ),
                ),
                child: const Text('打开收据'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开收据'));
      await tester.pumpAndSettle();
      if (scenario == 'product name') {
        await tester.scrollUntilVisible(
          find.text('RAW PRODUCT'),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -220));
        await tester.pumpAndSettle();
        expect(find.text('Old product name'), findsOneWidget);
        expect(find.text('商品 · 税码 E · SKU 12345'), findsOneWidget);
        expect(find.text('核对金额'), findsNothing);
        expect(
          tester.getTopLeft(find.text('Old product name')).dx,
          lessThan(tester.getTopLeft(find.text('RAW PRODUCT')).dx),
        );
        expect(
          tester.widget<Text>(find.text('RAW PRODUCT')).style?.fontSize,
          12,
        );
        await tester.tap(find.text('RAW PRODUCT'));
        await tester.pumpAndSettle();
        expect(find.text('核对金额'), findsOneWidget);
        final productName = find.widgetWithText(TextField, '商品名称');
        expect(productName, findsOneWidget);
        expect(find.textContaining('标准名称（'), findsNothing);
        expect(
          tester.getCenter(productName).dy,
          greaterThan(
            tester.getCenter(find.widgetWithText(TextField, '票面名称')).dy,
          ),
        );
        await tester.enterText(productName, 'New product name');
        await tester.tap(find.text('应用修改'));
        await tester.pumpAndSettle();
        expect(events, ['product name preview']);
        await tester.pumpWidget(const SizedBox());
        return;
      }
      final retry = find.widgetWithIcon(IconButton, Icons.refresh);
      final trash = find.widgetWithIcon(IconButton, Icons.delete_outline);
      expect(tester.getCenter(retry).dx, lessThan(tester.getCenter(trash).dx));
      if (scenario == 'no photos') {
        expect(tester.widget<IconButton>(retry).onPressed, isNull);
      } else {
        await tester.tap(retry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        if (['retry', 'submit failure', 'posted'].contains(scenario)) {
          expect(tester.widget<IconButton>(retry).onPressed, isNull);
          expect(
            events,
            scenario == 'posted'
                ? ['list', 'start']
                : ['list', 'save', 'start'],
          );
          submitted.complete();
        }
        await tester.pumpAndSettle();
        if (scenario == 'retry' || scenario == 'posted') {
          expect(find.byType(EditorPage), findsNothing);
          expect(find.text('打开收据'), findsOneWidget);
        } else {
          expect(find.byType(EditorPage), findsOneWidget);
          expect(tester.widget<IconButton>(retry).onPressed, isNotNull);
          if (scenario == 'active') expect(events, ['list']);
          if (scenario == 'save failure') expect(events, ['list', 'save']);
        }
      }
    });
  }
}
