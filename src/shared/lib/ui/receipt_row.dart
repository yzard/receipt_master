import 'package:flutter/material.dart';

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
  Widget build(BuildContext context) => SizedBox(
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
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
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
                    child: Text(deleting ? '删除中' : 'Trash'),
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
                    ? Colors.red.shade100
                    : widget.draft
                    ? Colors.yellow.shade100
                    : Theme.of(context).scaffoldBackgroundColor,
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
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ReceiptColumns(
                      name: Row(
                        children: [
                          Icon(
                            widget.draft
                                ? Icons.edit_note
                                : Icons.receipt_outlined,
                            size: 20,
                            semanticLabel: widget.failed
                                ? '识别失败'
                                : widget.draft
                                ? '草稿待确认'
                                : '已确认',
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
                      date: _date(widget.date),
                      receiptDate: _date(widget.receiptDate),
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
        ],
      ),
    ),
  );
}

Widget _date(String value) => Text(
  value.replaceFirst(' ', '\n'),
  maxLines: 2,
  style: const TextStyle(
    fontSize: 11,
    color: Colors.black87,
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
  Widget heading(String label, String key) => InkWell(
    onTap: () => onSort(key),
    child: Semantics(
      button: true,
      label:
          '$label，${sortBy == key ? (direction == 'asc' ? '升序' : '降序') : '点击排序'}',
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisAlignment: key == 'total'
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            Flexible(child: Text(label, maxLines: 1)),
            if (sortBy == key)
              Icon(
                direction == 'asc' ? Icons.arrow_upward : Icons.arrow_downward,
                size: 12,
              ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: DefaultTextStyle(
      style: const TextStyle(fontSize: 11, color: Colors.black87),
      child: ReceiptColumns(
        name: heading('店名', 'store'),
        date: heading('录入时间', 'created_at'),
        receiptDate: heading('收据时间', 'receipt_time'),
        amount: heading('总金额', 'total'),
      ),
    ),
  );
}
