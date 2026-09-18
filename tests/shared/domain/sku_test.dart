import 'package:flutter_test/flutter_test.dart';
import 'package:receipt_master/domain/models.dart';

void main() {
  test(
    'line editing round trip preserves optional tax code and leading-zero SKU',
    () {
      final line = LineDraft.empty()
        ..rawName = 'WHITE PEACH'
        ..taxCode = 'E'
        ..sku = '002338';
      final restored = LineDraft.fromMap(line.toMap());
      expect(restored.rawName, 'WHITE PEACH');
      expect(restored.taxCode, 'E');
      expect(restored.sku, '002338');
      restored.sku = null;
      restored.taxCode = null;
      expect(restored.toMap()['sku'], isNull);
      expect(LineDraft.fromMap(restored.toMap()).taxCode, isNull);
    },
  );
}
