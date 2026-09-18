import 'package:uuid/uuid.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

String newId() => const Uuid().v4();
String normalizeName(String value) =>
    unicode.nfc(value.trim().replaceAll(RegExp(r'\s+'), ' '));
const systemCategories = {
  'uncategorized': '00000000-0000-4000-8000-000000000001',
  'tax': '00000000-0000-4000-8000-000000000002',
  'tip': '00000000-0000-4000-8000-000000000003',
  'deposit': '00000000-0000-4000-8000-000000000004',
  'order_discount': '00000000-0000-4000-8000-000000000005',
};
const kindLabels = {
  'product': '商品',
  'item_discount': '商品优惠',
  'order_discount': '整单优惠',
  'tax': '税费',
  'tip': '小费',
  'deposit': '押金',
  'other_adjustment': '其他调整',
};
const currencies = {
  'USD': 2,
  'CNY': 2,
  'EUR': 2,
  'GBP': 2,
  'JPY': 0,
  'CAD': 2,
  'AUD': 2,
  'KRW': 0,
  'CHF': 2,
  'HKD': 2,
  'TWD': 2,
  'SGD': 2,
  'INR': 2,
  'KWD': 3,
  'BHD': 3,
};

class InputError implements Exception {
  final String message;
  const InputError(this.message);
  @override
  String toString() => message;
}

String fixed(int? number, int digits) {
  if (number == null) return '';
  final n = BigInt.from(number).abs().toString().padLeft(digits + 1, '0');
  return '${number < 0 ? '-' : ''}${digits == 0 ? n : '${n.substring(0, n.length - digits)}.${n.substring(n.length - digits)}'}';
}

String money(int? number, String currency) =>
    '$currency ${fixed(number, currencies[currency] ?? 2)}';

class LineDraft {
  String id, kind, rawName, categoryId;
  String? productId,
      discountTarget,
      quantityUnit,
      taxCode,
      sku,
      productNameEdit;
  int? weightMg,
      quantityMicros,
      unitPriceScaled,
      amountMinor,
      printedAmountMinor;
  bool isWeighed;
  Map<String, dynamic> display;
  List<String> warnings;
  List<Map<String, dynamic>> evidence;
  LineDraft({
    required this.id,
    required this.kind,
    required this.rawName,
    required this.taxCode,
    required this.sku,
    required this.productNameEdit,
    required this.categoryId,
    required this.productId,
    required this.discountTarget,
    required this.quantityUnit,
    required this.weightMg,
    required this.quantityMicros,
    required this.unitPriceScaled,
    required this.amountMinor,
    required this.printedAmountMinor,
    required this.isWeighed,
    required this.warnings,
    required this.evidence,
    required this.display,
  });
  factory LineDraft.empty() => LineDraft(
    id: newId(),
    kind: 'product',
    rawName: '',
    taxCode: null,
    sku: null,
    productNameEdit: null,
    categoryId: systemCategories['uncategorized']!,
    productId: null,
    discountTarget: null,
    quantityUnit: null,
    weightMg: null,
    quantityMicros: null,
    unitPriceScaled: null,
    amountMinor: null,
    printedAmountMinor: null,
    isWeighed: false,
    warnings: [],
    evidence: [],
    display: {},
  );
  factory LineDraft.fromMap(Map<String, dynamic> m) => LineDraft(
    display: Map<String, dynamic>.from(m['display'] ?? {}),
    id: m['id'],
    kind: m['kind'],
    rawName: m['rawName'],
    taxCode: m['taxCode'],
    sku: m['sku'],
    productNameEdit: m['productNameEdit'],
    categoryId: m['categoryId'],
    productId: m['productId'],
    discountTarget: m['discountTarget'],
    quantityUnit: m['quantityUnit'],
    weightMg: m['weightMg'],
    quantityMicros: m['quantityMicros'],
    unitPriceScaled: m['unitPriceScaled'],
    amountMinor: m['amountMinor'],
    printedAmountMinor: m['printedAmountMinor'],
    isWeighed: m['isWeighed'] ?? false,
    warnings: List<String>.from(m['warnings']),
    evidence: (m['evidence'] as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
  );
  Map<String, dynamic> toMap() => {
    'display': display,
    'id': id,
    'kind': kind,
    'rawName': rawName,
    'taxCode': taxCode,
    'sku': sku,
    if (productNameEdit != null) 'productNameEdit': productNameEdit,
    'categoryId': categoryId,
    'productId': productId,
    'discountTarget': discountTarget,
    'quantityUnit': quantityUnit,
    'weightMg': weightMg,
    'quantityMicros': quantityMicros,
    'unitPriceScaled': unitPriceScaled,
    'amountMinor': amountMinor,
    'printedAmountMinor': printedAmountMinor,
    'isWeighed': isWeighed,
    'warnings': warnings,
    'evidence': evidence,
  };
}

class ReceiptDraft {
  String id,
      store,
      recognizedStore,
      branch,
      address,
      country,
      currency,
      timeSource,
      rawTime,
      totalSource;
  int occurredAt, createdAt, revision;
  int? totalMinor;
  bool posted;
  List<LineDraft> lines;
  Map<String, dynamic> summary;
  ReceiptDraft({
    required this.id,
    required this.store,
    required this.recognizedStore,
    required this.branch,
    required this.address,
    required this.country,
    required this.currency,
    required this.timeSource,
    required this.rawTime,
    required this.totalSource,
    required this.occurredAt,
    required this.createdAt,
    required this.revision,
    required this.totalMinor,
    required this.posted,
    required this.lines,
    required this.summary,
  });
  factory ReceiptDraft.empty(DateTime now) => ReceiptDraft(
    id: newId(),
    store: '',
    recognizedStore: '',
    branch: '',
    address: '',
    country: 'US',
    currency: 'USD',
    timeSource: 'estimated_instant',
    rawTime: '',
    totalSource: 'user_entered',
    occurredAt: now.toUtc().millisecondsSinceEpoch,
    createdAt: now.toUtc().millisecondsSinceEpoch,
    revision: 0,
    totalMinor: null,
    posted: false,
    lines: [],
    summary: {},
  );
  factory ReceiptDraft.fromMap(Map<String, dynamic> m) => ReceiptDraft(
    summary: Map<String, dynamic>.from(m['summary'] ?? {}),
    id: m['id'],
    store: m['store'],
    recognizedStore: m['recognizedStore'] ?? '',
    branch: m['branch'],
    address: m['address'],
    country: m['country'],
    currency: m['currency'],
    timeSource: m['timeSource'],
    rawTime: m['rawTime'],
    totalSource: m['totalSource'],
    occurredAt: m['occurredAt'],
    createdAt: m['createdAt'],
    revision: m['revision'],
    totalMinor: m['totalMinor'],
    posted: m['posted'],
    lines: (m['lines'] as List)
        .map((l) => LineDraft.fromMap(Map<String, dynamic>.from(l)))
        .toList(),
  );
  Map<String, dynamic> toMap() => {
    'summary': summary,
    'id': id,
    'store': store,
    'recognizedStore': recognizedStore,
    'branch': branch,
    'address': address,
    'country': country,
    'currency': currency,
    'timeSource': timeSource,
    'rawTime': rawTime,
    'totalSource': totalSource,
    'occurredAt': occurredAt,
    'createdAt': createdAt,
    'revision': revision,
    'totalMinor': totalMinor,
    'posted': posted,
    'lines': lines.map((l) => l.toMap()).toList(),
  };
  int? get knownTotal => summary['knownTotal'];
  int? get difference => summary['difference'];
  void validate(bool publish) {
    if (!currencies.containsKey(currency)) throw const InputError('请选择支持的币种');
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
      throw const InputError('国家请输入两位代码，例如 US');
    }
    if (publish && totalMinor == null) {
      throw const InputError('请填写收据总额，或明确使用明细合计');
    }
    final ids = lines.map((l) => l.id).toSet();
    if (ids.length != lines.length) throw const InputError('明细标识重复');
    for (final l in lines) {
      if (!kindLabels.containsKey(l.kind)) throw const InputError('未知明细类型');
      if (publish && l.amountMinor == null) throw const InputError('请补齐所有明细金额');
      if (l.weightMg != null && l.weightMg! <= 0) {
        throw const InputError('克数必须大于零或留空');
      }
      if (l.quantityMicros != null && l.quantityMicros! <= 0) {
        throw const InputError('数量必须大于零或留空');
      }
      if (l.kind.endsWith('discount')) {
        if ((l.amountMinor ?? 0) > 0) throw const InputError('优惠金额必须为负数');
      }
      if (l.kind == 'item_discount') {
        final targets = lines.where(
          (t) => t.id == l.discountTarget && t.kind == 'product',
        );
        if (targets.length != 1) throw const InputError('商品优惠必须关联本单中的一个商品');
      }
      if (l.quantityMicros != null && (l.quantityUnit ?? '').isEmpty) {
        throw const InputError('填写数量时需要填写单位');
      }
    }
  }
}
