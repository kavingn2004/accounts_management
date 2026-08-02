import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/components.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../models/field_spec.dart';
import '../../services/providers.dart';
import '../common/entity_screen.dart';
import '../registry.dart';
import 'analytics.dart';
import 'trends.dart';

/// Analytics dashboard: net-worth card, a grid of module metrics, and charts.
/// The period filter sits above the metric grid because it now drives the
/// whole screen — the four period-sensitive tiles and their trend indicators
/// as well as the chart below.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardData {
  _DashboardData(
    this.summary,
    this.income,
    this.expenses,
    this.accounts,
    this.debtors,
    this.creditors,
    this.payments,
  );
  final Json? summary;
  final List<Json> income;
  final List<Json> expenses;
  final List<Json> accounts;

  /// Raw settle-able rows plus the instalment ledger, which together let the
  /// debtor/creditor balances be rebuilt as they stood at the period's start.
  final List<Json> debtors;
  final List<Json> creditors;
  final List<Json> payments;
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late Future<_DashboardData> _future;
  Period _period = Period.month;

  /// Breakdown bars use muted module tones rather than six saturated hues.
  /// Order matters: adjacent entries must not share a hue family, so `alerts`
  /// (#4A4A7A) is deliberately absent — it reads as the same purple as
  /// `invest` at bar size, in both themes.
  static const _breakdownTones = [
    ModuleTone.expense, // red
    ModuleTone.invest, // purple
    ModuleTone.bills, // ochre
    ModuleTone.savings, // teal
    ModuleTone.debtor, // blue
    ModuleTone.loan, // brown
  ];

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_DashboardData> _load() async {
    final repo = ref.read(repoProvider);
    final summary = await repo.dashboard();
    final income = await repo.list('income');
    final expenses = await repo.list('expenses');
    final accounts = await repo.accountsWithBalances();
    final debtors = await repo.list('debtors');
    final creditors = await repo.list('creditors');
    // The instalment ledger is optional — a project that hasn't run the
    // debt_payments migration must still get a dashboard. Without it the
    // debtor/creditor tiles simply report no movement.
    List<Json> payments;
    try {
      payments = await repo.list('debt_payments');
    } catch (_) {
      payments = const [];
    }
    return _DashboardData(
        summary, income, expenses, accounts, debtors, creditors, payments);
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  void _openModule(BuildContext context, EntityConfig cfg) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EntityScreen(config: cfg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Reload whenever data changes elsewhere (e.g. a bank/income added).
    ref.listen<int>(dataRevisionProvider, (_, __) {
      setState(() {
        _future = _load();
      });
    });
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<_DashboardData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          final d = data?.summary;
          final buckets =
              buildBuckets(_period, data?.income ?? [], data?.expenses ?? []);
          final breakdown =
              buildExpenseBreakdown(_period, data?.expenses ?? []);
          final periodIncome = buckets.fold<double>(0, (a, b) => a + b.income);
          final periodExpense = buckets.fold<double>(0, (a, b) => a + b.expense);
          final periodLabel = _period.label.toLowerCase();

          // One clock reading for every indicator, so a tile computed either
          // side of midnight can't disagree with its neighbour.
          final now = DateTime.now();
          double num_(String key) => (d?[key] as num?)?.toDouble() ?? 0;

          // Income and expenses are flows: this window against the last one.
          final incomeTrend = flowTrend(_period, data?.income ?? const [],
              goodWhenUp: true, now: now);
          final expenseTrend = flowTrend(_period, data?.expenses ?? const [],
              goodWhenUp: false, now: now);

          // Debtors and creditors are balances: now against the period's
          // start. The ledger covers both tables and is keyed by parent row id,
          // which is unique across them, so each side reads the whole thing.
          final payments = data?.payments ?? const <Json>[];
          final debtorTrend = stockTrend(
              _period, data?.debtors ?? const [], payments,
              goodWhenUp: true, now: now);
          final creditorTrend = stockTrend(
              _period, data?.creditors ?? const [], payments,
              goodWhenUp: false,
              now: now,
              // credit_worth folds in recurring bills, which are templates
              // rather than balances and so have no history to rebuild.
              constantBase: num_('bills_total'));

          // Investments and savings store no history — their figures are
          // overwritten in place. Each reports what its data does support.
          final investTrend =
              returnTrend(num_('investment_worth'), num_('invested_total'));
          final savingTrend =
              progressTrend(num_('saving_worth'), num_('saving_target'));

          return ListView(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.screenPad, 0, AppTheme.screenPad, 96),
            children: [
              _NetWorthCard(
                netWorth: money(d?['net_worth'] as num?),
                currentWorth: money(d?['current_worth'] as num?),
              ),
              _SectionHeader(
                title: 'Overview',
                trailing: _PeriodPill(
                  period: _period,
                  onChanged: (p) => setState(() => _period = p),
                ),
              ),
              _MetricGrid(children: [
                MetricTile(
                  icon: Icons.south_west,
                  tone: ModuleTone.income,
                  label: 'Income ($periodLabel)',
                  value: money(periodIncome),
                  delta: incomeTrend?.label,
                  deltaColor: _moodColor(context, incomeTrend),
                  onTap: () => _openModule(context, Modules.income),
                ),
                MetricTile(
                  icon: Icons.north_east,
                  tone: ModuleTone.expense,
                  label: 'Expense ($periodLabel)',
                  value: money(periodExpense),
                  delta: expenseTrend?.label,
                  deltaColor: _moodColor(context, expenseTrend),
                  onTap: () => _openModule(context, Modules.expenses),
                ),
                MetricTile(
                  icon: Icons.savings,
                  tone: ModuleTone.savings,
                  label: 'Savings',
                  value: money(d?['saving_worth'] as num?),
                  delta: savingTrend?.label,
                  deltaColor: _moodColor(context, savingTrend),
                  sub: savingTrend == null
                      ? null
                      : 'target ${money(d?['saving_target'] as num?)}',
                  onTap: () => _openModule(context, Modules.savings),
                ),
                MetricTile(
                  icon: Icons.trending_up,
                  tone: ModuleTone.invest,
                  label: 'Investment',
                  value: money(d?['investment_worth'] as num?),
                  delta: investTrend?.label,
                  deltaColor: _moodColor(context, investTrend),
                  sub: 'invested ${money(d?['invested_total'] as num?)}',
                  onTap: () => _openModule(context, Modules.investment),
                ),
                MetricTile(
                  icon: Icons.person_add_alt,
                  tone: ModuleTone.debtor,
                  label: 'Debtors',
                  value: money(d?['debt_worth'] as num?),
                  delta: debtorTrend?.label,
                  deltaColor: _moodColor(context, debtorTrend),
                  onTap: () => _openModule(context, Modules.debtors),
                ),
                MetricTile(
                  icon: Icons.person_remove_alt_1,
                  tone: ModuleTone.creditor,
                  label: 'Creditors',
                  value: money(d?['credit_worth'] as num?),
                  delta: creditorTrend?.label,
                  deltaColor: _moodColor(context, creditorTrend),
                  onTap: () => _openModule(context, Modules.creditors),
                ),
              ]),
              if ((data?.accounts ?? []).isNotEmpty) ...[
                const SizedBox(height: 10),
                _BalancesCard(accounts: data!.accounts),
              ],
              const SizedBox(height: 10),
              _ChartCard(
                title: 'Income vs expense',
                child: _BarChart(buckets: buckets),
              ),
              const SizedBox(height: 10),
              _ChartCard(
                title: 'Expense breakdown',
                child: _ExpenseBars(
                    slices: breakdown, tones: _breakdownTones),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Colour for a trend line: favourable green, unfavourable red, and nothing
/// for a flat or unknown movement (the tile falls back to secondary text).
Color? _moodColor(BuildContext context, Trend? t) => switch (t?.mood) {
      TrendMood.good => context.colors.positive,
      TrendMood.bad => context.colors.negative,
      _ => null,
    };

/// Row heading above a section of the dashboard, matching the card titles
/// below it. Carries the period pill for the metric grid.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
      child: Row(
        children: [
          Expanded(child: Text(title, style: context.text.titleMedium)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Two-column metric grid. A plain wrap keeps every tile the same height
/// without the fixed aspect ratio a GridView would impose.
class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < children.length; i += 2)
          Padding(
            padding: EdgeInsets.only(
                bottom: i + 2 < children.length ? 10 : 0),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: children[i]),
                  const SizedBox(width: 10),
                  Expanded(
                    child: i + 1 < children.length
                        ? children[i + 1]
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Net worth beside current (liquid) worth, split by a hairline.
class _NetWorthCard extends StatelessWidget {
  const _NetWorthCard({required this.netWorth, required this.currentWorth});
  final String netWorth;
  final String currentWorth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Net worth',
                      style: context.text.labelMedium
                          ?.copyWith(color: c.textSecondary)),
                  const SizedBox(height: 2),
                  MoneyText(netWorth, style: context.text.displayMedium),
                ],
              ),
            ),
            const SizedBox(width: 14),
            VerticalDivider(width: 1, thickness: 1, color: c.border),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Current value',
                    style: context.text.labelMedium
                        ?.copyWith(color: c.textSecondary)),
                const SizedBox(height: 2),
                MoneyText(currentWorth, style: context.text.titleLarge),
                const SizedBox(height: 2),
                Text('Wallet + bank',
                    style: context.text.labelSmall
                        ?.copyWith(color: c.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bordered pill in the chart header that swaps the period.
class _PeriodPill extends StatelessWidget {
  const _PeriodPill({required this.period, required this.onChanged});
  final Period period;
  final ValueChanged<Period> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopupMenuButton<Period>(
      initialValue: period,
      onSelected: onChanged,
      tooltip: 'Period',
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.rControl),
        side: BorderSide(color: c.border),
      ),
      itemBuilder: (_) => [
        for (final p in Period.values)
          PopupMenuItem(
            value: p,
            height: 40,
            child: Text(p.label, style: context.text.bodyMedium),
          ),
      ],
      child: Container(
        height: 26,
        padding: const EdgeInsets.only(left: 9, right: 6),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(AppTheme.rChip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(period.label, style: context.text.labelMedium),
            const SizedBox(width: 5),
            Icon(Icons.keyboard_arrow_down, size: 13, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.text.titleMedium),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.buckets});
  final List<Bucket> buckets;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxVal = buckets.fold<double>(
        0, (m, b) => [m, b.income, b.expense].reduce((a, x) => a > x ? a : x));
    if (maxVal <= 0) {
      return const _EmptyChart(message: 'No data for this period');
    }

    return Column(
      children: [
        SizedBox(
          height: 150,
          child: BarChart(
            BarChartData(
              maxY: maxVal * 1.15,
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
              titlesData: FlTitlesData(
                leftTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      if (i < 0 || i >= buckets.length) return const SizedBox();
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          buckets[i].label,
                          style: context.text.labelSmall
                              ?.copyWith(color: c.textSecondary),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < buckets.length; i++)
                  BarChartGroupData(x: i, barsSpace: 5, barRods: [
                    BarChartRodData(
                      toY: buckets[i].income,
                      color: c.positive,
                      width: 14,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    BarChartRodData(
                      toY: buckets[i].expense,
                      color: c.negative,
                      width: 14,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LegendDot(color: c.positive, label: 'Income'),
            const SizedBox(width: 20),
            _LegendDot(color: c.negative, label: 'Expense'),
          ],
        ),
      ],
    );
  }
}

/// Expense breakdown as horizontal bars, largest first. Shows the top
/// [_collapsedCount] and expands to every payee on demand.
class _ExpenseBars extends StatefulWidget {
  const _ExpenseBars({required this.slices, required this.tones});
  final List<BreakdownSlice> slices;
  final List<ModuleTone> tones;

  @override
  State<_ExpenseBars> createState() => _ExpenseBarsState();
}

class _ExpenseBarsState extends State<_ExpenseBars> {
  static const _collapsedCount = 5;
  bool _expanded = false;

  @override
  void didUpdateWidget(_ExpenseBars old) {
    super.didUpdateWidget(old);
    // Changing the period rebuilds the list; collapse so the card doesn't
    // silently stay long after the user switches to a busier month.
    if (old.slices.length != widget.slices.length) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final slices = widget.slices;
    if (slices.isEmpty) return const _EmptyChart(message: 'No expenses to show');

    // Scale against the largest slice, not the total — otherwise a dominant
    // first row squashes everything below it into invisible slivers.
    final maxVal = slices.fold<double>(0, (m, s) => s.value > m ? s.value : m);
    final hidden = slices.length - _collapsedCount;
    final shown =
        _expanded ? slices.length : slices.length.clamp(0, _collapsedCount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < shown; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == shown - 1 ? 0 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        slices[i].label,
                        style: context.text.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    MoneyText(money(slices[i].value)),
                  ],
                ),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final frac = maxVal > 0 ? slices[i].value / maxVal : 0.0;
                    return Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: c.border,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: (constraints.maxWidth * frac)
                              .clamp(3.0, constraints.maxWidth),
                          decoration: BoxDecoration(
                            color:
                                widget.tones[i % widget.tones.length].of(context),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        if (hidden > 0) ...[
          const SizedBox(height: 14),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(AppTheme.rChip),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _expanded ? 'Show less' : 'See more ($hidden)',
                    style: context.text.labelMedium
                        ?.copyWith(color: c.accentText),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: c.accentText,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(3)),
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

class _EmptyChart extends StatelessWidget {
  const _EmptyChart({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 110,
      child: Center(
        child: Text(
          message,
          style: context.text.bodyMedium
              ?.copyWith(color: context.colors.textSecondary),
        ),
      ),
    );
  }
}

/// Per-account balances (cash + banks).
class _BalancesCard extends StatelessWidget {
  const _BalancesCard({required this.accounts});
  final List<Json> accounts;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Balances', style: context.text.titleMedium),
          const SizedBox(height: 6),
          ...accounts.map((a) {
            final bal = (a['balance'] as num?)?.toDouble() ?? 0;
            final isBank = (a['type'] ?? 'cash') == 'bank';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  IconChip(
                    isBank ? Icons.account_balance : Icons.payments_outlined,
                    isBank ? ModuleTone.savings : ModuleTone.bills,
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      a['name'].toString(),
                      style: context.text.bodyLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  MoneyText(
                    money(bal),
                    color: bal < 0 ? c.negative : null,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
