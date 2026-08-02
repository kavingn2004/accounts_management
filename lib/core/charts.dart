import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../features/common/module_metrics.dart';
import '../models/dashboard_spec.dart';
import 'formatters.dart';
import 'theme.dart';

/// Shown instead of a chart when there is no history to draw.
///
/// A flat line at zero is not an acceptable substitute: it reads as a
/// measurement, and a false one. The ledger only starts filling from the first
/// value change after this feature ships, so this is the normal state at first.
class ChartEmptyState extends StatelessWidget {
  const ChartEmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 140,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No history yet',
                style:
                    context.text.titleMedium?.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders whichever shape a [Series] declares, so callers never branch on
/// chart kind themselves.
class SeriesChart extends StatelessWidget {
  const SeriesChart({super.key, required this.series});

  final Series series;

  @override
  Widget build(BuildContext context) {
    if (series.isEmpty || series.isFlatZero) {
      return const ChartEmptyState(
        message: 'Entries you add from now on will appear here.',
      );
    }
    return switch (series.kind) {
      ChartKind.cumulative => _LineChart(series),
      ChartKind.dualCumulative => _DualLineChart(series),
      ChartKind.bars => _BarSeriesChart(series),
    };
  }
}

class _LineChart extends StatelessWidget {
  const _LineChart(this.series);

  final Series series;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 150,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: _maxOf(series) * 1.15,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(
            show: true,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          titlesData: _titles(context, series.points),
          lineTouchData: _touch(context),
          lineBarsData: [_bar(series.points, c.accent)],
        ),
      ),
    );
  }
}

class _DualLineChart extends StatelessWidget {
  const _DualLineChart(this.series);

  final Series series;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        SizedBox(
          height: 150,
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: _maxOf(series) * 1.15,
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(
                show: true,
                border: Border(bottom: BorderSide(color: c.border)),
              ),
              titlesData: _titles(context, series.points),
              lineTouchData: _touch(context),
              lineBarsData: [
                _bar(series.points, c.textSecondary),
                _bar(series.second!, c.accent),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Legend(color: c.textSecondary, label: series.firstLabel ?? ''),
            const SizedBox(width: 20),
            _Legend(color: c.accent, label: series.secondLabel ?? ''),
          ],
        ),
      ],
    );
  }
}

class _BarSeriesChart extends StatelessWidget {
  const _BarSeriesChart(this.series);

  final Series series;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pts = series.points;
    return SizedBox(
      height: 150,
      child: BarChart(
        BarChartData(
          maxY: _maxOf(series) * 1.15,
          alignment: BarChartAlignment.spaceAround,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(
            show: true,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => c.textPrimary,
              getTooltipItem: (group, _, rod, __) => BarTooltipItem(
                money(rod.toY),
                TextStyle(
                  color: c.bg,
                  fontFamily: AppTheme.sans,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          titlesData: _titles(context, pts),
          barGroups: [
            for (var i = 0; i < pts.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: pts[i].value,
                  color: c.accent,
                  width: 12,
                  borderRadius: BorderRadius.circular(3),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}

double _maxOf(Series s) {
  var m = 0.0;
  for (final p in s.points) {
    if (p.value > m) m = p.value;
  }
  for (final p in s.second ?? const <SeriesPoint>[]) {
    if (p.value > m) m = p.value;
  }
  return m == 0 ? 1 : m;
}

LineChartBarData _bar(List<SeriesPoint> pts, Color color) => LineChartBarData(
      spots: [
        for (var i = 0; i < pts.length; i++) FlSpot(i.toDouble(), pts[i].value),
      ],
      isCurved: false,
      color: color,
      barWidth: 2,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        color: color.withValues(alpha: 0.10),
      ),
    );

/// Bottom axis only, thinned so labels never collide on a 12-bucket chart.
FlTitlesData _titles(BuildContext context, List<SeriesPoint> pts) {
  final c = context.colors;
  final step = (pts.length / 6).ceil();
  return FlTitlesData(
    leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 22,
        getTitlesWidget: (value, meta) {
          final i = value.toInt();
          if (i < 0 || i >= pts.length) return const SizedBox();
          if (step > 1 && i % step != 0) return const SizedBox();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              pts[i].label,
              style: context.text.labelSmall?.copyWith(color: c.textSecondary),
            ),
          );
        },
      ),
    ),
  );
}

LineTouchData _touch(BuildContext context) {
  final c = context.colors;
  return LineTouchData(
    touchTooltipData: LineTouchTooltipData(
      getTooltipColor: (_) => c.textPrimary,
      getTooltipItems: (spots) => [
        for (final s in spots)
          LineTooltipItem(
            money(s.y),
            TextStyle(
              color: c.bg,
              fontFamily: AppTheme.sans,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    ),
  );
}

/// Dot + label under the dual-line chart. `dashboard_screen.dart` has a private
/// `_LegendDot` of its own; this is the same idea, kept local so the two files
/// stay independent.
class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: context.text.labelSmall
              ?.copyWith(color: context.colors.textSecondary),
        ),
      ],
    );
  }
}

/// One row of a per-row breakdown — "Emergency fund, ₹1,20,000 · 60%".
class BreakdownRow {
  const BreakdownRow({required this.label, required this.value, this.of});

  final String label;
  final double value;

  /// The total [value] is measured against. Null means the bars are scaled to
  /// the largest row instead of to a target.
  final double? of;
}

/// Horizontal progress bars under a chart.
class ProgressBars extends StatelessWidget {
  const ProgressBars({super.key, required this.rows});

  final List<BreakdownRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final largest =
        rows.map((r) => r.value).fold<double>(0, (a, v) => v > a ? v : a);

    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.label,
                        style: context.text.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _trailing(r),
                      style: context.text.labelMedium?.copyWith(
                        color: c.textSecondary,
                        fontFeatures: tabular,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: _fraction(r, largest),
                    minHeight: 6,
                    backgroundColor: c.border,
                    valueColor: AlwaysStoppedAnimation(c.accent),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _trailing(BreakdownRow r) {
    final of = r.of;
    if (of == null || of <= 0) return money(r.value);
    final pct = (r.value / of * 100).clamp(0, 100);
    return '${money(r.value)} · ${pct.toStringAsFixed(0)}%';
  }

  double _fraction(BreakdownRow r, double largest) {
    final of = r.of;
    if (of != null && of > 0) return (r.value / of).clamp(0.0, 1.0);
    if (largest <= 0) return 0;
    return (r.value / largest).clamp(0.0, 1.0);
  }
}
