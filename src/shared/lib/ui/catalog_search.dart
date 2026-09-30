import 'package:flutter/material.dart';

import '../data/store.dart';

// The API supplies exact_match after Unicode normalization. This immediate
// check handles ASCII case and whitespace while database suggestions arrive.
String catalogNameKey(String value) => value
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(RegExp('[A-Z]'), (match) => match[0]!.toLowerCase());

/// Read-only database suggestions; selecting only edits the local input unless
/// the caller explicitly provides a save action.
class CatalogSearchField extends StatefulWidget {
  const CatalogSearchField({
    super.key,
    required this.store,
    required this.component,
    required this.controller,
    required this.label,
    this.labelField = 'name',
    this.enabled = true,
    this.suffix,
    this.onSelected,
    this.onSubmitted,
    this.onChanged,
    this.rejectExistingName = false,
    this.currentId,
  });
  final AppStore store;
  final String component, label, labelField;
  final TextEditingController controller;
  final bool enabled;
  final Widget? suffix;
  final void Function(Map<String, dynamic>)? onSelected;
  final void Function(String)? onSubmitted;
  final void Function(String)? onChanged;
  final bool rejectExistingName;
  final String? currentId;
  @override
  State<CatalogSearchField> createState() => _CatalogSearchFieldState();
}

class _CatalogSearchFieldState extends State<CatalogSearchField> {
  final focus = FocusNode();
  int generation = 0;
  String? error;
  String? existingName;
  @override
  void dispose() {
    generation++;
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawAutocomplete<Map<String, dynamic>>(
    textEditingController: widget.controller,
    focusNode: focus,
    displayStringForOption: (row) => row[widget.labelField] as String,
    optionsBuilder: (value) async {
      final current = ++generation;
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted || current != generation) return [];
      try {
        final rows = await widget.store.searchCatalog(
          widget.component,
          value.text,
        );
        if (!mounted || current != generation) return [];
        final matches = rows.where(
          (row) =>
              (row['exact_match'] == true ||
                  catalogNameKey(row['name']) == catalogNameKey(value.text)) &&
              (row['product_name_id'] ?? row['category_id']) !=
                  widget.currentId,
        );
        setState(() {
          error = null;
          existingName = matches.isEmpty ? null : matches.first['name'];
        });
        return rows;
      } catch (_) {
        if (mounted && current == generation) {
          setState(() => error = '搜索失败，可继续输入或重试');
        }
        return [];
      }
    },
    onSelected: (row) {
      setState(
        () => existingName =
            (row['product_name_id'] ?? row['category_id']) == widget.currentId
            ? null
            : row['name'],
      );
      widget.onSelected?.call(row);
    },
    fieldViewBuilder: (context, controller, node, submit) => TextField(
      controller: controller,
      focusNode: node,
      enabled: widget.enabled,
      onChanged: (value) {
        setState(() => existingName = null);
        widget.onChanged?.call(value);
      },
      textInputAction: TextInputAction.done,
      onSubmitted: (value) {
        if (widget.onSubmitted != null) {
          widget.onSubmitted!(controller.text);
        } else {
          submit();
        }
      },
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: widget.suffix,
        helperText:
            error ??
            (existingName != null && !widget.rejectExistingName
                ? '已有同名记录，将使用已有名称，不会重复添加'
                : null),
        errorText: existingName != null && widget.rejectExistingName
            ? '商品种类名称已存在，请使用其他名称'
            : null,
      ),
    ),
    optionsViewBuilder: (context, select, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 300,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: options.length,
              itemBuilder: (context, index) {
                final row = options.elementAt(index);
                return ListTile(
                  title: Text(row[widget.labelField]),
                  selected: AutocompleteHighlightedOption.of(context) == index,
                  onTap: () => select(row),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
