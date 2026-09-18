import 'package:flutter_test/flutter_test.dart';
import 'package:receipt_master/domain/models.dart';

void main() {
  test(
    'receipt renders server totals and preserves them through DTO roundtrip',
    () {
      final map = ReceiptDraft.empty(DateTime.utc(2026)).toMap();
      map['summary'] = {'knownTotal': 250, 'difference': 50};
      final receipt = ReceiptDraft.fromMap(map);
      receipt.lines.add(LineDraft.empty()..amountMinor = 999);
      expect(receipt.knownTotal, 250);
      expect(receipt.difference, 50);
      expect(ReceiptDraft.fromMap(receipt.toMap()).summary, map['summary']);
      expect(money(250, 'USD'), 'USD 2.50');
    },
  );
}
