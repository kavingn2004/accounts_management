import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/charts.dart';
import '../../core/components.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../models/dashboard_spec.dart';
import '../../models/field_spec.dart';
import 'module_metrics.dart';

/// Dashboard header above a module's list: headline figures, a chart, and an
/// optional per-row breakdown. Collapsible to the figures alone, with the
/// choice remembered per module.
class ModuleDashboard extends StatefulWidget {
  const ModuleDashboard({
    super.key,
    required this.config,
    required this.rows,
    required this.events,
    this.rangeStart,
    this.rangeEnd,
  });

  final EntityConfig config;
  final List<Json> rows;
  final List<Json> events;

  /// Inclusive range from the filter chips; both null means all time.
  final DateTime? rangeStart;
  final DateTime? rangeEnd;

  @override
  State<ModuleDashboard> createState() => _ModuleDashboardState();
}

class _ModuleDashboardState extends State<ModuleDashboard> {
  bool _expanded = true;

  String get _prefKey => 'dash_collapsed_${widget.config.table}';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted && (prefs.getBool(_prefKey) ?? false)) {
      setState(() => _expanded = false);
    }
  }

  Future<void> _toggle() async {
    setState(() => _expanded = !_expanded);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.config.dashboard;
    if (spec == null) return const SizedBox.shrink();

    final stats = statsFor(
      spec: spec,
      rows: widget.rows,
      events: widget.events,
      parentType: widget.config.table,
      rangeStart: widget.rangeStart,
      rangeEnd: widget.rangeEnd,
    );

    final series = seriesFor(
      spec: spec,
      rows: widget.rows,
      events: widget.events,
      parentType: widget.config.table,
      now: DateTime.now(),
      rangeStart: widget.rangeStart,
      rangeEnd: widget.rangeEnd,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 0, AppTheme.screenPad, 12),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statRow(context, stats, spec),
            if (_expanded && spec.chart != null) ...[
              const SizedBox(height: 16),
              if (series == null)
                const ChartEmptyState(
                  message: 'Entries you add from now on will appear here.',
                )
              else
                SeriesChart(series: series),
            ],
            if (_expanded && spec.breakdown != null) ...[
              const SizedBox(height: 8),
              ProgressBars(rows: _breakdownRows(spec)),
            ],
          ],
        ),
      ),
    );
  }

  /// Largest rows first, capped — a page with thirty debtors should not push
  /// its list off the screen behind a wall of bars.
  List<BreakdownRow> _breakdownRows(DashboardSpec spec) {
    final b = spec.breakdown!;
    final cfg = widget.config;
    final rows = [
      for (final r in widget.rows)
        BreakdownRow(
          label: cfg.titleOf(r),
          value: (r[b.value] as num?)?.toDouble() ?? 0,
          of: b.of == null ? null : (r[b.of!] as num?)?.toDouble(),
        )
    ]..sort((a, x) => x.value.compareTo(a.value));
    return rows.take(6).toList();
  }

  /// Figures across the top, with the collapse control on the right. Wraps so
  /// four stats survive a narrow phone rather than ellipsizing to nothing.
  Widget _statRow(BuildContext context, List<Stat> stats, DashboardSpec spec) {
    final c = context.colors;
    final collapsible = spec.chart != null || spec.breakdown != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              for (final s in stats)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.label,
                      style: context.text.labelMedium
                          ?.copyWith(color: c.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    MoneyText(s.value),
                  ],
                ),
            ],
          ),
        ),
        if (collapsible)
          IconButton(
            onPressed: _toggle,
            visualDensity: VisualDensity.compact,
            tooltip: _expanded ? 'Hide chart' : 'Show chart',
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: c.textSecondary,
            ),
          ),
      ],
    );
  }
}
