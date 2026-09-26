import 'dart:convert';
import 'dart:io';

import 'package:receipt_master/ui/capture.dart';

import 'package:receipt_master/ui/logo_aliases.dart';
import 'package:flutter/material.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/main.dart';
import 'package:receipt_master/ui/app_theme.dart';
import 'package:receipt_master/ui/receipt_row.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:timezone/data/latest.dart' as tzdata;

class CancelPicker extends ImagePickerPlatform {
  int cameraCalls = 0, galleryCalls = 0;
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    cameraCalls++;
    return null;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    galleryCalls++;
    return [];
  }
}

void main() {
  testWidgets('page title scrolls away while the menu opens a left drawer', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    tester.view.physicalSize = const Size(430, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = AppStore(
      '/unused',
      configuration: () async =>
          const BackendConnection('https://example.test', 'key'),
      client: MockClient(
        (req) async => http.Response(
          jsonEncode({
            'data': {
              'items': [
                for (var i = 0; i < 30; i++)
                  {
                    'receipt_id': 'receipt-$i',
                    'version': 1,
                    'raw_store': 'Store $i',
                    'status': 'posted',
                    'recognition_status': 'applied',
                    'created_at_utc_ms': 1780000000000 - i * 86400000,
                    'occurred_at_utc_ms': 1780000000000 - i * 86400000,
                    'total_minor': 100 + i,
                    'currency_code': 'USD',
                  },
              ],
              'next_cursor': null,
            },
          }),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      ReceiptApp(
        store: store,
        zone: 'America/New_York',
        appearance: Appearance(store.cacheRoot),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('收据'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('收据'), findsNothing);
    expect(find.byTooltip('打开导航菜单'), findsOneWidget);
    await tester.tap(find.byTooltip('打开导航菜单'));
    await tester.pumpAndSettle();
    expect(find.text('报表'), findsOneWidget);
    expect(find.text('商品管理'), findsOneWidget);
  });

  testWidgets(
    'overview requests all four server sort orders and toggles direction',
    (tester) async {
      tzdata.initializeTimeZones();
      final sorts = <List<String>>[];
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((req) async {
          final input = jsonDecode(req.body)['input'];
          sorts.add([input['sort_by'], input['direction']]);
          return http.Response(
            jsonEncode({
              'data': {
                'items': [
                  {
                    'receipt_id': 'r',
                    'version': 1,
                    'raw_store': 'Example Store',
                    'status': 'draft',
                    'recognition_status': 'applied',
                    'created_at_utc_ms': 1780000000000,
                    'occurred_at_utc_ms': 1770000000000,
                    'total_minor': 450,
                    'currency_code': 'USD',
                  },
                ],
                'next_cursor': null,
              },
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        ReceiptApp(
          store: store,
          zone: 'America/New_York',
          appearance: Appearance(store.cacheRoot),
        ),
      );
      await tester.pumpAndSettle();
      expect(sorts.last, ['created_at', 'desc']);
      expect(find.textContaining('待确认 ·'), findsNothing);
      for (final entry in {
        '店名': 'store',
        '录入时间': 'created_at',
        '收据时间': 'receipt_time',
        '总金额': 'total',
      }.entries) {
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();
        final firstDirection = sorts.last[1];
        expect(sorts.last[0], entry.value);
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();
        expect(sorts.last, [
          entry.value,
          firstDirection == 'asc' ? 'desc' : 'asc',
        ]);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'home opens camera and gallery directly; cancellation creates no receipt',
    (tester) async {
      tzdata.initializeTimeZones();
      final original = ImagePickerPlatform.instance;
      final picker = CancelPicker();
      ImagePickerPlatform.instance = picker;
      addTearDown(() => ImagePickerPlatform.instance = original);
      final temporary = Directory.systemTemp.createTempSync(
        'receipt-camera-ui-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final paths = <String>[];
      final store = AppStore(
        temporary.path,
        client: MockClient((req) async {
          paths.add(req.url.path);
          return http.Response('{"data":{"items":[],"next_cursor":null}}', 200);
        }),
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
      );
      await tester.pumpWidget(
        ReceiptApp(
          store: store,
          zone: 'America/New_York',
          appearance: Appearance(store.cacheRoot),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('拍照'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      expect(find.byType(CapturePage), findsOneWidget);
      expect(find.text("拍摄"), findsOneWidget);
      expect(find.text("完成"), findsOneWidget);
      await tester.pageBack();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      await tester.pumpAndSettle();
      expect(picker.cameraCalls, 0);
      expect(find.text('收据草稿'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('上传照片'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(picker.galleryCalls, 1);
      expect(paths.where((p) => p.endsWith('/save')), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('backend failure is visible without creating a local database', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tzdata.initializeTimeZones();
    final store = AppStore(
      '/does-not-exist',
      client: MockClient(
        (req) async => http.Response('{"error":{"message":"后端不可用"}}', 503),
      ),
      configuration: () async =>
          const BackendConnection('https://example.test', 'key'),
    );
    await tester.pumpWidget(
      ReceiptApp(
        store: store,
        zone: 'America/New_York',
        appearance: Appearance(store.cacheRoot),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('数据加载失败'), findsWidgets);
    final menu = tester.getRect(find.byTooltip('打开导航菜单'));
    for (final label in ['拍照', '上传照片', '手动']) {
      final action = find.byTooltip(label);
      expect(action, findsOneWidget);
      expect(find.text(label), findsNothing);
      final rect = tester.getRect(action);
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.center.dy, closeTo(menu.center.dy, 1));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'compact row reveals Trash on left swipe and deletes only on tap',
    (tester) async {
      var deleted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReceiptRow(
              name: 'Test grocery',
              date: '2026-09-15 19:27',
              receiptDate: '2026-09-14 19:27',
              failed: false,
              amount: 'USD 6.48',
              draft: true,
              onOpen: () {},
              onDelete: () async {
                deleted++;
              },
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(ReceiptRow)).height, 56);
      expect(find.text('Trash'), findsNothing);
      await tester.dragFrom(
        tester.getTopLeft(find.byType(ReceiptRow)) + const Offset(600, 48),
        const Offset(-100, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Trash'), findsOneWidget);
      expect(deleted, 0);
      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();
      expect(deleted, 1);
      expect(find.text('Trash'), findsNothing);
    },
  );
  testWidgets(
    'receipt table columns align across different names and amounts',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              child: Column(
                children: [
                  ReceiptTableHeader(
                    sortBy: 'created_at',
                    direction: 'desc',
                    onSort: (_) {},
                  ),
                  ReceiptRow(
                    name: 'A',
                    date: '2026-09-15 10:20',
                    receiptDate: '2026-09-12 10:20',
                    failed: false,
                    amount: 'USD 1.00',
                    draft: true,
                    onOpen: () {},
                    onDelete: () async {},
                  ),
                  ReceiptRow(
                    name: 'A very long grocery store name',
                    date: '2026-09-14 09:10',
                    receiptDate: '2026-09-13 09:10',
                    failed: true,
                    amount: 'USD 1000.00',
                    draft: false,
                    onOpen: () {},
                    onDelete: () async {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(ReceiptRow).at(0),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color,
        AppPalette.warningSurface(
          tester.element(find.byType(ReceiptRow).first),
        ),
      );
      expect(
        tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(ReceiptRow).at(1),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color,
        AppPalette.errorSurface(tester.element(find.byType(ReceiptRow).last)),
      );
      expect(find.text('收据时间'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester.getTopLeft(find.text('A')).dx,
        tester.getTopLeft(find.text('A very long grocery store name')).dx,
      );
      expect(
        tester.getTopLeft(find.text('录入时间')).dx,
        tester.getTopLeft(find.text('2026-09-15\n10:20')).dx,
      );
      expect(
        tester.getTopLeft(find.text('2026-09-15\n10:20')).dx,
        tester.getTopLeft(find.text('2026-09-14\n09:10')).dx,
      );
      expect(
        tester.getTopRight(find.text('USD 1.00')).dx,
        tester.getTopRight(find.text('USD 1000.00')).dx,
      );
      expect(
        tester.getTopRight(find.text('总金额')).dx,
        tester.getTopRight(find.text('USD 1000.00')).dx,
      );
    },
  );
  testWidgets('permanent receipt deletion requires confirmation', (
    tester,
  ) async {
    tzdata.initializeTimeZones();
    var deleted = false, purgeCalls = 0;
    final store = AppStore(
      '/unused',
      configuration: () async =>
          const BackendConnection('https://example.test', 'key'),
      client: MockClient((req) async {
        dynamic data;
        if (req.url.path.endsWith('/receipts/list')) {
          data = {
            'items': deleted
                ? []
                : [
                    {
                      'receipt_id': 'receipt',
                      'version': 1,
                      'raw_store': 'Shop',
                      'status': 'posted',
                      'recognition_status': 'applied',
                      'created_at_utc_ms': 1780000000000,
                      'occurred_at_utc_ms': 1780000000000,
                      'total_minor': 100,
                      'currency_code': 'USD',
                    },
                  ],
            'next_cursor': null,
          };
        } else if (req.url.path.endsWith('/receipts/purge')) {
          purgeCalls++;
          deleted = true;
        } else {
          throw StateError(req.url.path);
        }
        return http.Response(jsonEncode({'data': data}), 200);
      }),
    );
    await tester.pumpWidget(
      ReceiptApp(
        store: store,
        zone: 'America/New_York',
        appearance: Appearance(store.cacheRoot),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> revealAndTap() async {
      await tester.drag(find.byType(ReceiptRow), const Offset(-100, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();
    }

    await revealAndTap();
    expect(find.text('永久删除这张收据？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(purgeCalls, 0);
    await revealAndTap();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(purgeCalls, 1);
    expect(find.byType(ReceiptRow), findsNothing);
  });

  testWidgets(
    'logo image alias can be added edited and removed through the backend',
    (tester) async {
      final aliases = <Map<String, dynamic>>[
        {'logo_id': 'logo', 'media_id': 'crop', 'name': null},
      ];
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((request) async {
          if (request.method == 'GET') return http.Response('', 404);
          final input = jsonDecode(request.body)['input'];
          dynamic result;
          if (request.url.path.endsWith('/list')) {
            result = aliases;
          }
          if (request.url.path.endsWith('/save')) {
            aliases.clear();
            expect(input['id'], 'logo');
            expect(input.containsKey('raw'), isFalse);
            aliases.add({
              'logo_id': 'logo',
              'media_id': 'crop',
              'name': input['name'],
            });
            result = {'name': input['name']};
          }
          if (request.url.path.endsWith('/delete')) {
            aliases.clear();
          }
          return http.Response(
            jsonEncode({'data': result, 'catalog_version': 1}),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LogoAliasesPage(
            store: store,
            receiptId: null,
            suggestedName: '',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('尚未设置店名'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存别名'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextFormField).at(0), 'H Mart');
      await tester.tap(find.text('保存别名'));
      await tester.pumpAndSettle();
      expect(find.text('H Mart'), findsOneWidget);
      await tester.tap(find.text('H Mart'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'H MART');
      await tester.tap(find.text('保存别名'));
      await tester.pumpAndSettle();
      expect(find.text('H MART'), findsOneWidget);
      await tester.tap(find.byTooltip('删除商店名称样本'));
      await tester.pumpAndSettle();
      expect(aliases, isNotEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除商店名称样本'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(aliases, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
