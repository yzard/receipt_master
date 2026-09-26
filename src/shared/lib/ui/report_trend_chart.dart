import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/models.dart';

/// Draws the report amounts supplied by the API. All currency conversion and
/// aggregation have already happened on the server.
class ReportTrendChart extends StatelessWidget {
  const ReportTrendChart({
    super.key,
    required this.points,
    required this.series,
    required this.visibleSeries,
    required this.selectedIndex,
    required this.currency,
    required this.onSelect,
    required this.onOlder,
    required this.onNewer,
  });

  final List<Map<String, dynamic>> points;
  final List<Map<String, dynamic>> series;
  final Set<String> visibleSeries;
  final int selectedIndex;
  final String currency;
  final ValueChanged<int> onSelect;
  final VoidCallback onOlder, onNewer;

  static Color seriesColor(int index, Color tertiary, Color secondary) => [
    tertiary,
    secondary,
    const Color(0xFFD17B24),
    const Color(0xFF008F85),
    const Color(0xFFBE4D86),
    const Color(0xFF6C66C8),
    const Color(0xFF70972F),
  ][index % 7];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Semantics(
        label: '消费趋势折线图，左右滑动查看其他时间，点击数据点查看该期明细',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (event) {
            if (points.isEmpty) return;
            final width = constraints.maxWidth - 64;
            final x = (event.localPosition.dx - 50).clamp(0.0, width);
            final index = (x / width * (points.length - 1)).round();
            onSelect(index);
          },
          onHorizontalDragEnd: (details) {
            final speed = details.primaryVelocity ?? 0;
            if (speed > 120) onOlder();
            if (speed < -120) onNewer();
          },
          child: SizedBox(
            height: 268,
            width: double.infinity,
            child: CustomPaint(
              painter: _TrendPainter(
                points: points,
                series: series,
                visibleSeries: visibleSeries,
                selectedIndex: selectedIndex,
                scale: math.pow(10, currencies[currency] ?? 2).toInt(),
                primary: scheme.primary,
                tertiary: scheme.tertiary,
                secondary: scheme.secondary,
                foreground: scheme.onSurfaceVariant,
                grid: scheme.outlineVariant.withValues(alpha: .6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.series,
    required this.visibleSeries,
    required this.selectedIndex,
    required this.scale,
    required this.primary,
    required this.tertiary,
    required this.secondary,
    required this.foreground,
    required this.grid,
  });

  final List<Map<String, dynamic>> points, series;
  final Set<String> visibleSeries;
  final int selectedIndex;
  final int scale;
  final Color primary, tertiary, secondary, foreground, grid;

  int amount(dynamic value) => (value as num?)?.toInt() ?? 0;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final plot = Rect.fromLTRB(50, 18, size.width - 14, size.height - 34);
    final lines = <(List<int>, Color, bool)>[
      (points.map((p) => amount(p['net'])).toList(), primary, true),
      for (final (index, row) in series.indexed)
        if (visibleSeries.contains(row['key']))
          (
            (row['values'] as List).map(amount).toList(),
            ReportTrendChart.seriesColor(index, tertiary, secondary),
            false,
          ),
    ];
    final values = lines.expand((line) => line.$1).toList();
    final lower = math.min(0, values.reduce(math.min));
    final upper = math.max(1, values.reduce(math.max));
    final padding = math.max(1, ((upper - lower) * .12).ceil());
    final minValue = lower < 0 ? lower - padding : 0;
    final maxValue = upper + padding;
    double x(int index) =>
        plot.left + plot.width * index / math.max(1, points.length - 1);
    double y(int value) =>
        plot.bottom - plot.height * (value - minValue) / (maxValue - minValue);

    for (var step = 0; step <= 4; step++) {
      final level = minValue + (maxValue - minValue) * step / 4;
      final yy = plot.bottom - plot.height * step / 4;
      canvas.drawLine(
        Offset(plot.left, yy),
        Offset(plot.right, yy),
        Paint()
          ..color = grid
          ..strokeWidth = 1,
      );
      final label = _label(level / scale, maxValue / scale);
      _text(canvas, label, Offset(0, yy - 7), foreground, 10);
    }

    final tickStep = math.max(1, (points.length / 5).ceil());
    for (var i = 0; i < points.length; i++) {
      if (i % tickStep != 0 && i != points.length - 1) continue;
      final label = points[i]['tick']?.toString() ?? '';
      _text(canvas, label, Offset(x(i) - 13, plot.bottom + 10), foreground, 10);
    }

    for (final (values, color, total) in lines.reversed) {
      final path = Path();
      for (var i = 0; i < values.length; i++) {
        if (i == 0) {
          path.moveTo(x(i), y(values[i]));
        } else {
          path.lineTo(x(i), y(values[i]));
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = total ? 3 : 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final index = selectedIndex.clamp(0, points.length - 1);
    final selectedX = x(index);
    canvas.drawLine(
      Offset(selectedX, plot.top),
      Offset(selectedX, plot.bottom),
      Paint()
        ..color = primary.withValues(alpha: .35)
        ..strokeWidth = 1.5,
    );
    for (final (values, color, _) in lines) {
      canvas.drawCircle(
        Offset(selectedX, y(values[index])),
        5,
        Paint()..color = color,
      );
      canvas.drawCircle(
        Offset(selectedX, y(values[index])),
        2,
        Paint()..color = Colors.white,
      );
    }
  }

  String _label(double value, double maximum) {
    if (value.abs() >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    final decimals = maximum < 1 ? 2 : (maximum < 10 ? 1 : 0);
    return value.toStringAsFixed(decimals);
  }

  void _text(
    Canvas canvas,
    String value,
    Offset position,
    Color color,
    double size,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => true;
}
