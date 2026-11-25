import '../l10n/strings.dart';

import 'package:flutter/material.dart';

import '../data/store.dart';
import '../domain/models.dart';
import 'common.dart';
import 'app_theme.dart';

/// The server resolves current name mappings; edits can remove a receipt here.
class ProductReceiptsPage extends StatefulWidget {
  final AppStore store;
  final String productNameId, name, zone;
  final Future<void> Function(String) onReceipt;
  const ProductReceiptsPage({
    super.key,
    required this.store,
    required this.productNameId,
    required this.name,
    required this.zone,
    required this.onReceipt,
  });
  @override
  State<ProductReceiptsPage> createState() => _ProductReceiptsPageState();
}

class _ProductReceiptsPageState extends State<ProductReceiptsPage> {
  List<Map<String, dynamic>>? receipts;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
    widget.store.receiptUpdates.addListener(receiptUpdated);
  }

  @override
  void dispose() {
    widget.store.receiptUpdates.removeListener(receiptUpdated);
    super.dispose();
  }

  void receiptUpdated() {
    final update = widget.store.receiptUpdates.value;
    if (!mounted || update == null || receipts == null) return;
    final r = update.receipt;
    final matches =
        r == null ||
        (r['lines'] as List).any(
          (line) =>
              line['kind'] == 'product' &&
              (line['productNameEdit'] ?? line['display']?['productName']) ==
                  widget.name,
        );
    setState(
      () => receipts = applyReceiptUpdate(
        receipts!,
        matches
            ? update
            : ReceiptUpdate(
                id: update.id,
                receipt: null,
                deleted: true,
                recognitionStatus: null,
              ),
      ),
    );
  }

  Future<void> load() async {
    try {
      final result = await widget.store.receipts(
        false,
        sortBy: 'created_at',
        direction: 'desc',
        productNameId: widget.productNameId,
      );
      if (mounted) {
        setState(() {
          receipts = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> open(String id) async {
    await widget.onReceipt(id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.name)),
    body: error != null
        ? Center(
            child: TextButton(
              onPressed: load,
              child: Text(context.tr("加载失败，点击重试")),
            ),
          )
        : receipts == null
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.sm,
                Space.lg,
                Space.x2l,
              ),
              children: [
                if (receipts!.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(context.tr("没有包含此商品名称的收据")),
                  ),
                if (receipts!.isNotEmpty)
                  Card(
                    child: Column(
                      children: [
                        for (final (index, r) in receipts!.indexed) ...[
                          if (index > 0) const Divider(),
                          receiptTile(context, r),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
  );

  Widget receiptTile(BuildContext context, Map<String, dynamic> receipt) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = receipt['recognition_status'] == 'failed';
    final draft = receipt['status'] == 'draft';
    final statusColor = failed
        ? scheme.error
        : draft
        ? context.tokens.warning
        : context.tokens.text3;
    return ListTile(
      key: ValueKey(receipt['receipt_id']),
      tileColor: failed
          ? AppPalette.errorSurface(context)
          : draft
          ? AppPalette.warningSurface(context)
          : null,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 3,
            height: 40,
            color: failed || draft ? statusColor : Colors.transparent,
          ),
          const SizedBox(width: Space.xs),
          Icon(
            failed
                ? Icons.error_outline
                : draft
                ? Icons.edit_note
                : Icons.receipt_outlined,
            color: statusColor,
            size: 18,
            semanticLabel: failed
                ? context.tr("识别失败")
                : draft
                ? context.tr("草稿待确认")
                : context.tr("已确认"),
          ),
        ],
      ),
      title: Text(
        (receipt['raw_store'] as String?)?.isNotEmpty == true
            ? receipt['raw_store']
            : context.tr("未填写店铺"),
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        context.tr("录入 {0}\n收据 {1}", [
          dateText(receipt['created_at_utc_ms'], widget.zone),
          dateText(receipt['occurred_at_utc_ms'], widget.zone),
        ]),
      ),
      trailing: Text(
        receipt['total_minor'] == null
            ? context.tr("待填写")
            : money(receipt['total_minor'], receipt['currency_code']),
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      onTap: () => open(receipt['receipt_id']),
    );
  }
}
