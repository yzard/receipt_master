import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;

import '../platform_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/ui/catalog_search.dart';

void main() {
  for (final component in ['product_names', 'categories']) {
    testWidgets('$component searches typed substrings without saving', (
      tester,
    ) async {
      final queries = <String>[];
      final controller = TextEditingController();
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/$component/suggest');
          queries.add(jsonDecode(request.body)['input']['query']);
          return http.Response(
            jsonEncode({
              'catalog_version': 1,
              'data': [
                {
                  'name': '瓶装水',
                  'product_name_id': 'water',
                  'category_id': 'water-kind',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogSearchField(
              store: store,
              component: component,
              controller: controller,
              label: '名称',
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '装');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(TextField), '装水');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(queries, ['装水']);
      expect(find.text('瓶装水'), findsOneWidget);
      await tester.tap(find.text('瓶装水'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(controller.text, '瓶装水');
      expect(find.text('已有同名记录，将使用已有名称，不会重复添加'), findsOneWidget);
      expect(queries.every((q) => q == '装水' || q == '瓶装水'), isTrue);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
