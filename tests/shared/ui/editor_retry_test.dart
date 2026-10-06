import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;

import '../platform_test.dart';

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
      SizedBox(
        key: ValueKey('test-photo-${photo['image_id']}'),
        width: width ?? 160,
        height: 200,
        child: const ColoredBox(color: Colors.grey),
      );
}

void main() {
  for (final width in [430.0, 600.0, 700.0, 1200.0]) {
    testWidgets('receipt editor layout at $width logical pixels', (
      tester,
    ) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final receipt = ReceiptDraft.empty(DateTime.now()).toMap();
      final store = TestStore(
        MockClient((request) async {
          final path = request.url.path;
          dynamic data;
          if (path.endsWith('/receipt_types/list')) {
            data = [];
          } else if (path.endsWith('/config/get')) {
            data = {'weight_unit': 'kg'};
          } else if (path.endsWith('/categories/list')) {
            data = [];
          } else if (path.endsWith('/images/list')) {
            data = [
              {
                'image_id': 'photo',
                'media_id': 'photo',
                'width_px': 800,
                'height_px': 1200,
              },
              if (width == 700)
                {
                  'image_id': 'photo-2',
                  'media_id': 'photo-2',
                  'width_px': 800,
                  'height_px': 1200,
                },
            ];
          } else if (path.endsWith('/receipts/get')) {
            data = receipt;
          } else {
            fail('Unexpected request: $path');
          }
          return http.Response(jsonEncode({'data': data}), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(
            store: store,
            zone: 'America/New_York',
            receiptId: receipt['id'],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final photoPanel = find.byKey(const ValueKey('receipt-photo-panel'));
      final form = find.byKey(const ValueKey('receipt-edit-form'));
      final saveActions = find.byKey(const ValueKey('receipt-save-actions'));
      expect(saveActions, findsOneWidget);
      expect(find.text('放弃改动'), findsOneWidget);
      expect(find.text('保存草稿'), findsOneWidget);
      expect(find.text('录入并退出'), findsOneWidget);
      expect(tester.getBottomRight(saveActions).dy, lessThan(900));
      expect(tester.getSize(saveActions).width, lessThan(340));
      if (width < 600) {
        expect(photoPanel, findsNothing);
        expect(form, findsOneWidget);
        return;
      }
      expect(photoPanel, findsOneWidget);
      expect(
        tester.getSize(photoPanel).width,
        closeTo((width - 1) * (width < 800 ? 9 / 20 : 1 / 2), 2),
      );
      expect(
        tester.getTopLeft(photoPanel).dx,
        lessThan(tester.getTopLeft(form).dx),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('test-photo-photo'))).width,
        closeTo(tester.getSize(photoPanel).width - 24, 2),
      );
      expect(
        tester.getTopLeft(saveActions).dx,
        greaterThan(tester.getTopRight(photoPanel).dx),
      );
      final imageBounds = tester.getRect(
        find.byKey(const ValueKey('receipt-photo-image-0')),
      );
      expect(
        imageBounds.height,
        greaterThan(tester.getSize(photoPanel).height * 0.8),
      );
      final rotateBounds = tester.getRect(find.byTooltip('旋转 90°'));
      expect(imageBounds.contains(rotateBounds.center), isTrue);
      expect(rotateBounds.top, lessThan(imageBounds.top + 60));
      final photoTop = tester.getTopLeft(find.text('第 1 张')).dy;
      await tester.drag(form, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('第 1 张')).dy, photoTop);
      if (width == 700) {
        await tester.drag(photoPanel, const Offset(0, -650));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('receipt-photo-image-1')),
          findsOneWidget,
        );
      }
    });
  }

  for (final scenario in [
    'retry',
    'active',
    'load failure',
    'submit failure',
    'no photos',
    'posted',
    'dirty retry',
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
      var loads = 0;
      final store = TestStore(
        MockClient((request) async {
          final path = request.url.path;
          dynamic data;
          if (path.endsWith('/receipt_types/list')) {
            data = [];
          } else if (path.endsWith('/config/get')) {
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
              expect(data['taxCode'], 'ABC');
              events.add('product name preview');
            }
          } else if (path.endsWith('/images/list')) {
            data = scenario == 'no photos'
                ? []
                : [
                    {'image_id': 'photo', 'media_id': 'photo'},
                  ];
          } else if (path.endsWith('/receipts/get')) {
            loads++;
            if (loads > 1) {
              events.add('load');
              if (scenario == 'load failure') {
                return http.Response(
                  jsonEncode({
                    'error': {'message': '读取失败'},
                  }),
                  503,
                );
              }
            }
            data = receipt;
          } else if (path.endsWith('/receipts/edit')) {
            data = receipt;
          } else if (path.endsWith('/recognition/list')) {
            events.add('list');
            data = scenario == 'active'
                ? [
                    {'status': 'running'},
                  ]
                : [];
          } else if (path.endsWith('/recognition/start')) {
            events.add('start');
            final input = jsonDecode(request.body)['input'];
            expect(input['receipt_id'], receipt['id']);
            expect(input['expected_version'], 2);
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
        final formScrollable = find
            .descendant(
              of: find.byKey(const ValueKey('receipt-edit-form')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('RAW PRODUCT'),
          400,
          scrollable: formScrollable,
        );
        await tester.drag(formScrollable, const Offset(0, -220));
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
          lessThan(tester.getCenter(find.widgetWithText(TextField, '票面名称')).dy),
        );
        await tester.enterText(productName, 'New product name');
        final taxCode = find.widgetWithText(TextField, '税码（最多三个字符，可留空）');
        expect(tester.widget<TextField>(taxCode).maxLength, 3);
        await tester.enterText(taxCode, 'ABC');
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
        if (scenario == 'dirty retry') {
          await tester.enterText(
            find.widgetWithText(TextField, '店名 / 连锁店'),
            'Unsaved store',
          );
          await tester.pump(const Duration(milliseconds: 800));
          expect(events, isEmpty);
        }
        await tester.tap(retry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        if (scenario == 'dirty retry') {
          expect(events, ['list']);
          expect(find.text('放弃未保存修改并重新识别？'), findsOneWidget);
          await tester.tap(find.text('确认'));
          await tester.pump(const Duration(milliseconds: 100));
        }
        if ([
          'retry',
          'submit failure',
          'posted',
          'dirty retry',
        ].contains(scenario)) {
          expect(tester.widget<IconButton>(retry).onPressed, isNull);
          expect(events, ['list', 'load', 'start']);
          submitted.complete();
        }
        await tester.pumpAndSettle();
        if (['retry', 'posted', 'dirty retry'].contains(scenario)) {
          expect(find.byType(EditorPage), findsNothing);
          expect(find.text('打开收据'), findsOneWidget);
        } else {
          expect(find.byType(EditorPage), findsOneWidget);
          expect(tester.widget<IconButton>(retry).onPressed, isNotNull);
          if (scenario == 'active') expect(events, ['list']);
          if (scenario == 'load failure') expect(events, ['list', 'load']);
        }
      }
    });
  }

  for (final action in ['放弃改动', '保存草稿', '录入并退出']) {
    testWidgets('draft action $action', (tester) async {
      tzdata.initializeTimeZones();
      final line = LineDraft.empty()
        ..rawName = 'Milk'
        ..amountMinor = 100;
      final receipt = ReceiptDraft.empty(DateTime.now()).toMap()
        ..['store'] = 'Original'
        ..['revision'] = 2
        ..['timeSource'] = 'user_entered'
        ..['totalMinor'] = 100
        ..['lines'] = [line.toMap()]
        ..['summary'] = {'knownTotal': 100, 'difference': 0};
      final writes = <String>[];
      final store = TestStore(
        MockClient((request) async {
          final path = request.url.path;
          dynamic data;
          if (path.endsWith('/receipt_types/list')) {
            data = [];
          } else if (path.endsWith('/config/get')) {
            data = {'weight_unit': 'kg'};
          } else if (path.endsWith('/categories/list') ||
              path.endsWith('/images/list') ||
              path.endsWith('/receipts/check_duplicates')) {
            data = [];
          } else if (path.endsWith('/receipts/get')) {
            data = receipt;
          } else if (path.endsWith('/receipts/edit')) {
            data = {
              'totalMinor': 100,
              'summary': {'knownTotal': 100, 'difference': 0},
            };
          } else if (path.endsWith('/receipts/save') ||
              path.endsWith('/receipts/confirm')) {
            final confirmed = path.endsWith('/receipts/confirm');
            final input = jsonDecode(request.body)['input']['receipt'];
            writes.add('${confirmed ? 'confirm' : 'save'}:${input['store']}');
            data = Map<String, dynamic>.from(input)
              ..['revision'] = 3
              ..['posted'] = confirmed;
          } else {
            fail('Unexpected request: $path');
          }
          return http.Response(jsonEncode({'data': data}), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
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
      await tester.enterText(
        find.widgetWithText(TextField, '店名 / 连锁店'),
        'Edited',
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(writes, isEmpty);
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.byType(EditorPage), findsNothing);
      expect(
        writes,
        action == '放弃改动'
            ? isEmpty
            : ["${action == '录入并退出' ? 'confirm' : 'save'}:Edited"],
      );
    });
  }

  testWidgets('back asks before writing unsaved draft changes', (tester) async {
    tzdata.initializeTimeZones();
    final receipt = ReceiptDraft.empty(DateTime.now()).toMap()
      ..['store'] = 'Original'
      ..['revision'] = 2;
    final writes = <String>[];
    final store = TestStore(
      MockClient((request) async {
        final path = request.url.path;
        dynamic data;
        if (path.endsWith('/receipt_types/list')) {
          data = [];
        } else if (path.endsWith('/config/get')) {
          data = {'weight_unit': 'kg'};
        } else if (path.endsWith('/categories/list') ||
            path.endsWith('/images/list')) {
          data = [];
        } else if (path.endsWith('/receipts/get')) {
          data = receipt;
        } else if (path.endsWith('/receipts/edit')) {
          data = {'totalMinor': null, 'summary': {}};
        } else if (path.endsWith('/receipts/save')) {
          data = Map<String, dynamic>.from(
            jsonDecode(request.body)['input']['receipt'],
          )..['revision'] = 3;
          writes.add(data['store']);
        } else {
          fail('Unexpected request: $path');
        }
        return http.Response(jsonEncode({'data': data}), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
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
    await tester.enterText(
      find.widgetWithText(TextField, '店名 / 连锁店'),
      'Edited',
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(writes, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('离开收据编辑？'), findsOneWidget);
    expect(writes, isEmpty);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿').last);
    await tester.pumpAndSettle();
    expect(writes, ['Edited']);
    expect(find.byType(EditorPage), findsNothing);
  });

  testWidgets('discarding a new manual receipt removes its empty draft', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    String? receiptId;
    var revision = 0;
    var purged = false;
    final store = TestStore(
      MockClient((request) async {
        final path = request.url.path;
        dynamic data;
        if (path.endsWith('/receipt_types/list')) {
          data = [];
        } else if (path.endsWith('/config/get')) {
          data = {'weight_unit': 'kg'};
        } else if (path.endsWith('/categories/list') ||
            path.endsWith('/images/list')) {
          data = [];
        } else if (path.endsWith('/receipts/save')) {
          data = Map<String, dynamic>.from(
            jsonDecode(request.body)['input']['receipt'],
          )..['revision'] = ++revision;
          receiptId = data['id'];
        } else if (path.endsWith('/receipts/purge')) {
          final input = jsonDecode(request.body)['input'];
          expect(input['id'], receiptId);
          expect(input['expected_version'], revision);
          purged = true;
          data = {};
        } else {
          fail('Unexpected request: $path');
        }
        return http.Response(jsonEncode({'data': data}), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => EditorPage(
                    store: store,
                    zone: 'America/New_York',
                    receiptId: null,
                  ),
                ),
              ),
              child: const Text('新建收据'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新建收据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃改动'));
    await tester.pumpAndSettle();
    expect(purged, isTrue);
    expect(find.byType(EditorPage), findsNothing);
  });

  for (final scenario in ['warning', 'missing difference']) {
    testWidgets('receipt confirmation $scenario', (tester) async {
      tzdata.initializeTimeZones();
      final line = LineDraft.empty()
        ..rawName = 'Milk'
        ..amountMinor = 100;
      if (scenario == 'warning') line.warnings = ['核对金额'];
      final receipt = ReceiptDraft.empty(DateTime.now()).toMap()
        ..['revision'] = 2
        ..['timeSource'] = 'recognized'
        ..['totalMinor'] = 100
        ..['lines'] = [line.toMap()];
      var confirmed = 0;
      final store = TestStore(
        MockClient((request) async {
          final path = request.url.path;
          dynamic data;
          if (path.endsWith('/receipt_types/list')) {
            data = [];
          } else if (path.endsWith('/config/get')) {
            data = {'weight_unit': 'kg'};
          } else if (path.endsWith('/categories/list') ||
              path.endsWith('/images/list') ||
              path.endsWith('/receipts/check_duplicates')) {
            data = [];
          } else if (path.endsWith('/receipts/get')) {
            data = receipt;
          } else if (path.endsWith('/receipts/edit')) {
            data = {
              'totalMinor': 100,
              'summary': {
                'knownTotal': 100,
                'difference': scenario == 'warning' ? 0 : null,
              },
            };
          } else if (path.endsWith('/receipts/confirm')) {
            confirmed++;
            data = Map<String, dynamic>.from(
              jsonDecode(request.body)['input']['receipt'],
            )..['revision'] = 3;
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
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
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
      await tester.tap(find.text('录入并退出'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(confirmed, 0);
      if (scenario == 'warning') {
        expect(find.text('仍要录入这张收据？'), findsOneWidget);
        expect(find.text('有明细尚待核对'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(EditorPage), findsOneWidget);
        await tester.tap(find.text('录入并退出'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(confirmed, 1);
        expect(find.byType(EditorPage), findsNothing);
      } else {
        expect(find.text('仍要录入这张收据？'), findsNothing);
        expect(find.textContaining('无法计算收据差额'), findsOneWidget);
        expect(find.byType(EditorPage), findsOneWidget);
      }
    });
  }
}
