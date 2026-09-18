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

void main() {
  testWidgets(
    'failed draft save permits cancelling or discarding and exiting without deleting receipt',
    (tester) async {
      tzdata.initializeTimeZones();
      final receipt = ReceiptDraft.empty(DateTime.now()).toMap();
      var saveCalls = 0;
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((request) async {
          final path = request.url.path;
          dynamic data;
          if (path.endsWith('/config/get')) {
            data = {'weight_unit': 'kg'};
          } else if (path.endsWith('/categories/list') ||
              path.endsWith('/images/list')) {
            data = [];
          } else if (path.endsWith('/receipts/get') ||
              path.endsWith('/receipts/edit')) {
            data = receipt;
          } else if (path.endsWith('/receipts/save')) {
            saveCalls++;
            return http.Response(
              jsonEncode({
                'error': {'message': '数据关系或字段不符合约束'},
              }),
              409,
            );
          } else {
            fail('Unexpected mutation or request: $path');
          }
          return http.Response(jsonEncode({'data': data}), 200);
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
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('草稿保存失败，放弃未保存修改并退出？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorPage), findsOneWidget);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorPage), findsNothing);
      expect(find.text('打开收据'), findsOneWidget);
      expect(saveCalls, 2);
    },
  );
}
