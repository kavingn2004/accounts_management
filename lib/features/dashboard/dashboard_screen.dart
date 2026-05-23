import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../models/field_spec.dart';
import '../../services/providers.dart';
import '../common/entity_screen.dart';
import '../registry.dart';
import 'analytics.dart';

/// Analytics dashboard: net-worth banner, income/expense cards, and charts
/// (income-vs-expense bars + expense pie) with a Week/Month/Year filter.
/// Modules are reached from the sidebar.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardData {
  _DashboardData(this.summary, this.income, this.expenses, this.accounts);
  final Json? summary;
  final List<Json> income;
  final List<Json> expenses;
  final List<Json> accounts;
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late Future<_DashboardData> _future;
  Period _period = Period.month;

  static const _pieColors = [
    AppTheme.cExpense,
    AppTheme.cInvest,
    AppTheme.cBills,
    AppTheme.cSavings,
    AppTheme.cAlerts,
    Color(0xFF8D6E63),
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
    return _DashboardData(summary, income, expenses, accounts);
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
          final pie = buildExpensePie(_period, data?.expenses ?? []);
          // Period totals drive the cards so they track the Week/Month/Year filter.
          final periodIncome =
              buckets.fold<double>(0, (a, b) => a + b.income);
          final periodExpense =
              buckets.fold<double>(0, (a, b) => a + b.expense);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _NetWorthBanner(value: money(d?['net_worth'] as num?)),
              const SizedBox(height: 12),
              if ((data?.accounts ?? []).isNotEmpty)
                _BalancesCard(accounts: data!.accounts),
              const SizedBox(height: 4),
              _PeriodFilter(
                period: _period,
                onChanged: (p) => setState(() => _period = p),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      label: 'Income (${_period.label.toLowerCase()})',
                      value: money(periodIncome),
                      icon: Icons.south_west,
                      color: AppTheme.cIncome,
                      onTap: () => _openModule(context, Modules.income),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricCard(
                      label: 'Expense (${_period.label.toLowerCase()})',
                      value: money(periodExpense),
                      icon: Icons.north_east,
                      color: AppTheme.cExpense,
                      onTap: () => _openModule(context, Modules.expenses),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _ChartCard(
                title: 'Income vs Expense',
                child: _BarChart(buckets: buckets),
              ),
              const SizedBox(height: 16),
              _ChartCard(
                title: 'Expense breakdown',
                child: _ExpensePie(slices: pie, colors: _pieColors),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// ---------- Filter ----------
class _PeriodFilter extends StatelessWidget {
  const _PeriodFilter({required this.period, required this.onChanged});
  final Period period;
  final ValueChanged<Period> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final p in Period.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(p.label),
              selected: period == p,
              showCheckmark: false,
              selectedColor: AppTheme.primary,
              labelStyle: TextStyle(
                color: period == p
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              onSelected: (_) => onChanged(p),
            ),
          ),
      ],
    );
  }
}

/// ---------- Chart card wrapper ----------
class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

/// ---------- Bar chart ----------
class _BarChart extends StatelessWidget {
  const _BarChart({required this.buckets});
  final List<Bucket> buckets;

  @override
  Widget build(BuildContext context) {
    final maxVal = buckets.fold<double>(
        0, (m, b) => [m, b.income, b.expense].reduce((a, c) => a > c ? a : c));
    if (maxVal <= 0) return const _EmptyChart(message: 'No data for this period');

    return Column(
      children: [
        SizedBox(
          height: 200,
          child: BarChart(
            BarChartData(
              maxY: maxVal * 1.2,
              alignment: BarChartAlignment.spaceAround,
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              barTouchData: const BarTouchData(enabled: true),
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
                    reservedSize: 24,
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      if (i < 0 || i >= buckets.length) return const SizedBox();
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(buckets[i].label,
                            style: const TextStyle(fontSize: 10)),
                      );
                    },
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < buckets.length; i++)
                  BarChartGroupData(x: i, barRods: [
                    BarChartRodData(
                      toY: buckets[i].income,
                      color: AppTheme.cIncome,
                      width: 7,
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(3)),
                    ),
                    BarChartRodData(
                      toY: buckets[i].expense,
                      color: AppTheme.cExpense,
                      width: 7,
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(3)),
                    ),
                  ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LegendDot(color: AppTheme.cIncome, label: 'Income'),
            SizedBox(width: 20),
            _LegendDot(color: AppTheme.cExpense, label: 'Expense'),
          ],
        ),
      ],
    );
  }
}

/// ---------- Pie chart ----------
class _ExpensePie extends StatelessWidget {
  const _ExpensePie({required this.slices, required this.colors});
  final List<PieSlice> slices;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<double>(0, (a, s) => a + s.value);
    if (total <= 0) return const _EmptyChart(message: 'No expenses to show');

    return Column(
      children: [
        SizedBox(
          height: 180,
          child: PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 40,
              sections: [
                for (var i = 0; i < slices.length; i++)
                  PieChartSectionData(
                    value: slices[i].value,
                    color: colors[i % colors.length],
                    radius: 56,
                    title: '${(slices[i].value / total * 100).round()}%',
                    titleStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Legend
        ...List.generate(slices.length, (i) {
          final s = slices[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: colors[i % colors.length],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(s.label)),
                Text(money(s.value),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          );
        }),
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
          width: 12,
          height: 12,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
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
      height: 120,
      child: Center(
        child: Text(message, style: TextStyle(color: Colors.grey.shade500)),
      ),
    );
  }
}

/// ---------- Header cards (unchanged style) ----------
class _NetWorthBanner extends StatelessWidget {
  const _NetWorthBanner({required this.value});
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [AppTheme.primaryDark, AppTheme.accent],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.30),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.account_balance, color: Colors.white70, size: 18),
              SizedBox(width: 6),
              Text('Net worth',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Balances',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...accounts.map((a) {
              final bal = (a['balance'] as num?)?.toDouble() ?? 0;
              final isBank = (a['type'] ?? 'cash') == 'bank';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(isBank ? Icons.account_balance : Icons.payments,
                        size: 18, color: AppTheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(a['name'].toString())),
                    Text(money(bal),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: bal < 0 ? AppTheme.cExpense : null,
                        )),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  if (onTap != null) ...[
                    const Spacer(),
                    Icon(Icons.chevron_right,
                        size: 18, color: Colors.grey.shade400),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Text(label,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              const SizedBox(height: 4),
              Text(
                value,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
