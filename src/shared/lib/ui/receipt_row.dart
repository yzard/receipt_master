import '../l10n/strings.dart';

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// A left swipe reveals a deliberate delete action; swiping alone never deletes.
class ReceiptRow extends StatefulWidget {
  final String name, date, receiptDate, amount;
  final bool draft, failed;
  final VoidCallback onOpen;
  final Future<void> Function() onDelete;
  const ReceiptRow({
    super.key,
    required this.name,
    required this.date,
    required this.receiptDate,
    required this.amount,
    required this.draft,
    required this.failed,
    required this.onOpen,
    required this.onDelete,
  });
  @override
  State<ReceiptRow> createState() => _ReceiptRowState();
}

class _ReceiptRowState extends State<ReceiptRow> {
  double reveal = 0;
  bool deleting = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stripe = widget.failed
        ? scheme.error
        : widget.draft
        ? context.tokens.warning
        : Colors.transparent;
    return SizedBox(
      height: 56,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (reveal > 0)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 80,
                    height: 56,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                        padding: EdgeInsets.zero,
                        shape: const RoundedRectangleBorder(),
                      ),
                      onPressed: deleting
                          ? null
                          : () async {
                              setState(() => deleting = true);
                              try {
                                await widget.onDelete();
                              } finally {
                                if (mounted) {
                                  setState(() {
                                    deleting = false;
                                    reveal = 0;
                                  });
                                }
                              }
                            },
                      child: Text(deleting ? context.tr("删除中") : 'Trash'),
                    ),
                  ),
                ),
              ),
            Transform.translate(
              offset: Offset(-reveal, 0),
              child: GestureDetector(
                onHorizontalDragUpdate: deleting
                    ? null
                    : (details) => setState(
                        () => reveal = (reveal - details.delta.dx).clamp(0, 80),
                      ),
                onHorizontalDragEnd: deleting
                    ? null
                    : (_) => setState(() => reveal = reveal >= 30 ? 80 : 0),
                child: Material(
                  color: widget.failed
                      ? AppPalette.errorSurface(context)
                      : widget.draft
                      ? AppPalette.warningSurface(context)
                      : scheme.surfaceContainerLowest,
                  child: InkWell(
                    onTap: deleting
                        ? null
                        : () {
                            if (reveal > 0) {
                              setState(() => reveal = 0);
                            } else {
                              widget.onOpen();
                            }
                          },
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(width: 3, color: stripe),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: ReceiptColumns(
                          name: Row(
                            children: [
                              Icon(
                                widget.failed
                                    ? Icons.error_outline
                                    : widget.draft
                                    ? Icons.edit_note
                                    : Icons.receipt_outlined,
                                size: 18,
                                color: widget.failed || widget.draft
                                    ? stripe
                                    : context.tokens.text3,
                                semanticLabel: widget.failed
                                    ? context.tr("识别失败")
                                    : widget.draft
                                    ? context.tr("草稿待确认")
                                    : context.tr("已确认"),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          date: _date(context, widget.date),
                          receiptDate: _date(context, widget.receiptDate),
                          amount: Text(
                            widget.amount,
                            maxLines: 1,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _date(BuildContext context, String value) => Text(
  value.replaceFirst(' ', '\n'),
  maxLines: 2,
  style: TextStyle(
    fontSize: 11,
    color: AppPalette.muted(context),
    fontFeatures: [FontFeature.tabularFigures()],
  ),
);

/// Shared column proportions keep every row and its headings aligned.
class ReceiptColumns extends StatelessWidget {
  final Widget name, date, receiptDate, amount;
  const ReceiptColumns({
    super.key,
    required this.name,
    required this.date,
    required this.receiptDate,
    required this.amount,
  });
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(flex: 4, child: name),
      const SizedBox(width: 6),
      Expanded(flex: 3, child: date),
      const SizedBox(width: 6),
      Expanded(flex: 3, child: receiptDate),
      const SizedBox(width: 6),
      Expanded(
        flex: 3,
        child: Align(alignment: Alignment.centerRight, child: amount),
      ),
    ],
  );
}

class ReceiptTableHeader extends StatelessWidget {
  final String sortBy, direction;
  final ValueChanged<String> onSort;
  const ReceiptTableHeader({
    super.key,
    required this.sortBy,
    required this.direction,
    required this.onSort,
  });
  Widget heading(BuildContext context, String label, String key) => InkWell(
    onTap: () => onSort(key),
    child: Semantics(
      button: true,
      label:
          '$label，${sortBy == key ? (direction == 'asc' ? context.tr("升序") : context.tr("降序")) : context.tr("点击排序")}',
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisAlignment: key == 'total'
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                style: sortBy == key
                    ? TextStyle(color: Theme.of(context).colorScheme.onSurface)
                    : null,
              ),
            ),
            if (sortBy == key)
              Icon(
                direction == 'asc' ? Icons.arrow_upward : Icons.arrow_downward,
                size: 12,
                color: Theme.of(context).colorScheme.onSurface,
              ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: DefaultTextStyle(
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
          child: ReceiptColumns(
            name: heading(context, context.tr("店名"), 'store'),
            date: heading(context, context.tr("录入时间"), 'created_at'),
            receiptDate: heading(context, context.tr("收据时间"), 'receipt_time'),
            amount: heading(context, context.tr("总金额"), 'total'),
          ),
        ),
      ),
    );
  }
}
