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
    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      flexibleSpace: const FrostedBar(child: SizedBox.expand()),
      title: Text(widget.name),
    ),
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
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top + 72,
                bottom: 24,
              ),
              children: [
                if (receipts!.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(context.tr("没有包含此商品名称的收据")),
                  ),
                for (final r in receipts!)
                  ListTile(
                    key: ValueKey(r['receipt_id']),
                    tileColor: r['recognition_status'] == 'failed'
                        ? AppPalette.errorSurface(context)
                        : r['status'] == 'draft'
                        ? AppPalette.warningSurface(context)
                        : null,
                    title: Text(
                      (r['raw_store'] as String?)?.isNotEmpty == true
                          ? r['raw_store']
                          : context.tr("未填写店铺"),
                    ),
                    subtitle: Text(
                      context.tr("录入 {0}\n收据 {1}", [
                        dateText(r['created_at_utc_ms'], widget.zone),
                        dateText(r['occurred_at_utc_ms'], widget.zone),
                      ]),
                    ),
                    trailing: Text(
                      r['total_minor'] == null
                          ? context.tr("待填写")
                          : money(r['total_minor'], r['currency_code']),
                    ),
                    onTap: () => open(r['receipt_id']),
                  ),
              ],
            ),
          ),
  );
}
