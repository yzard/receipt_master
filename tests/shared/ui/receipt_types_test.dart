import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/ui/logo_aliases.dart';

void main() {
  testWidgets(
    'merchant receipt type is editable independently from product categories',
    (tester) async {
      var kind = 'grocery';
      final writes = <Map<String, dynamic>>[];
      final store = AppStore(
        '/unused',
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((request) async {
          final input =
              jsonDecode(request.body)['input'] as Map<String, dynamic>;
          dynamic data;
          if (request.url.path.endsWith('/logos/list')) {
            data = [];
          } else if (request.url.path.endsWith('/receipt_types/list')) {
            data = [
              {'receipt_type_id': 'grocery', 'name': '杂货', 'system_key': null},
              {
                'receipt_type_id': 'restaurant',
                'name': '餐馆',
                'system_key': null,
              },
            ];
          } else if (request.url.path.endsWith('/merchants/list')) {
            data = [
              {
                'merchant_id': 'store',
                'name': 'Costco',
                'receipt_type_id': kind,
              },
            ];
          } else if (request.url.path.endsWith('/merchants/classify')) {
            writes.add(input);
            kind = input['receipt_type_id'];
          } else {
            fail('Unexpected request ${request.url.path}');
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
          home: LogoAliasesPage(
            embedded: false,
            store: store,
            receiptId: null,
            suggestedName: '',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('店铺'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '店铺名称'), findsOneWidget);
      expect(find.text('Costco'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '店铺类别'));
      await tester.pumpAndSettle();
      expect(find.text('Costco'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('餐馆').last);
      await tester.pumpAndSettle();
      expect(writes.single['receipt_type_id'], 'restaurant');
      expect(writes.single['id'], 'store');
      expect(kind, 'restaurant');
    },
  );
}
