import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/charts.dart';
import '../../core/components.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../data/nav_api.dart';
import '../../data/sip_math.dart';
import '../../models/dashboard_spec.dart';
import '../../data/history.dart';
import '../../services/providers.dart';
import '../../services/sip_service.dart';
import '../common/module_metrics.dart';

/// Everything one SIP is doing: what it is worth, what it cost, what it
/// returned, and every installment behind those figures.
class SipScreen extends ConsumerStatefulWidget {
  const SipScreen({super.key, required this.row});

  /// The investment row. Re-read on load so the screen reflects the ledger
  /// rather than whatever the list happened to be holding.
  final Json row;

  @override
  ConsumerState<SipScreen> createState() => _SipScreenState();
}

class _SipDetail {
  _SipDetail({
    required this.row,
    required this.installments,
    required this.series,
    required this.isStale,
    this.notices = const [],
    this.derived = false,
  });

  final Json row;
  final List<Json> installments;

  /// What could not be loaded, in words. The screen still renders everything
  /// it does have — a partial failure is not a reason to show a dead end.
  final List<String> notices;

  /// Null when NAV has never been downloaded for this scheme — the screen then
  /// shows the ledger without valuing it, rather than showing zeros.
  final NavSeries? series;
  final bool isStale;

  /// True when the installments were worked out from the schedule rather than
  /// read from storage. The figures are the same; the rows just cannot be
  /// edited, so per-row actions are withheld rather than silently doing
  /// nothing.
  final bool derived;
}

class _SipScreenState extends ConsumerState<SipScreen> {
  late Future<_SipDetail> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Assemble what the screen needs, degrading rather than failing.
  ///
  /// Every read here is optional: the row was handed to us, NAV can be stale
  /// or absent, and the ledger may not exist yet. Anything that fails becomes
  /// a line of explanation, because a screen that says "could not load" and
  /// nothing else leaves nobody any better off.
  Future<_SipDetail> _load({bool force = false}) async {
    final repo = ref.read(repoProvider);
    final id = widget.row['id'].toString();
    final notices = <String>[];

    var row = widget.row;
    try {
      final rows = await repo.list(SipService.investmentsTable);
      row = rows.firstWhere(
        (r) => r['id'].toString() == id,
        orElse: () => widget.row,
      );
    } catch (e) {
      notices.add('This holding could not be re-read, so the figures below '
          'are from when the list last loaded. ($e)');
    }

    NavSeries? series;
    var isStale = false;
    final code = SipService.schemeCodeOf(row);
    if (code != null) {
      try {
        final cached =
            await ref.read(navCacheProvider).series(code, force: force);
        series = cached.series;
        isStale = cached.isStale;
      } catch (e) {
        // Not just NavException: a storage failure while caching must not cost
        // the screen its valuation either.
        series = ref.read(navCacheProvider).peek(code);
        isStale = series != null;
        if (series == null) {
          notices.add('NAV for this fund has never been downloaded, so it '
              'cannot be valued yet. ($e)');
        }
      }
    }

    var installments = <Json>[];
    var derived = false;
    try {
      installments = (await repo.list(SipFields.table))
          .where((e) =>
              (e[InstallmentFields.parentId] ?? '').toString() == id)
          .toList();
    } catch (_) {
      // The table stores installments; it does not invent them. Work out the
      // same schedule in memory so the value, the chart and the ledger are all
      // still right — only editing them is lost.
      if (series != null) {
        installments = SipService.derive(row, series);
        derived = true;
      }
      notices.add(
        installments.isEmpty
            ? 'Installment history cannot be read — run the sip_installments '
                'migration.'
            : 'Installment history cannot be saved yet — run the '
                'sip_installments migration. The figures below are worked out '
                'from your schedule and are correct; they just cannot be '
                'edited until the table exists.',
      );
    }
    installments.sort((a, b) => (b[InstallmentFields.date] ?? '')
        .toString()
        .compareTo((a[InstallmentFields.date] ?? '').toString()));

    return _SipDetail(
      row: row,
      installments: installments,
      series: series,
      isStale: isStale,
      notices: notices,
      derived: derived,
    );
  }

  Future<void> _refresh({bool force = true}) async {
    final rows = await ref.read(repoProvider).list(SipService.investmentsTable);
    final mine = rows
        .where((r) => r['id'].toString() == widget.row['id'].toString())
        .toList();
    await ref.read(sipServiceProvider).refresh(mine, force: force);
    await ref.read(investmentSyncProvider).run(mine, force: force);
    ref.read(dataRevisionProvider.notifier).state++;
    if (!mounted) return;
    // Block body, not an arrow: `setState(() => _future = _load())` returns the
    // assigned Future from the closure, which Flutter rejects — and the throw
    // takes the rebuild with it, so every action on this screen would write to
    // storage and then appear to do nothing.
    setState(() {
      _future = _load();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text((widget.row['name'] ?? 'SIP').toString()),
        actions: [
          IconButton(
            tooltip: 'Refresh NAV',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<_SipDetail>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final detail = snap.data;
            if (detail == null) {
              // _load degrades rather than throwing, so reaching here means
              // something genuinely unexpected — show it rather than hide it.
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppTheme.screenPad),
                  child: Text(
                    'Could not load this SIP.\n\n${snap.error ?? ''}',
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium,
                  ),
                ),
              );
            }
            return _body(context, detail);
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context, _SipDetail detail) {
    final parsed = [
      for (final e in detail.installments) SipService.installmentFrom(e)
    ];
    final units = SipMath.totalUnits(parsed);
    final invested = SipMath.totalInvested(parsed);

    final navDate = detail.series == null
        ? null
        : SipMath.resolveValuationDate(DateTime.now(), detail.series!);
    final nav = navDate == null ? null : detail.series!.navOn(navDate);
    // An empty ledger means the figures are *unknown*, not zero. ₹0 is a
    // measurement — it asserts the holding is worth nothing — and printing it
    // for a SIP whose ledger could not even be read is simply false.
    final known = detail.installments.isNotEmpty;
    final value = (!known || nav == null) ? null : units * nav;
    final rate = value == null
        ? null
        : SipMath.xirr(parsed, value, DateTime.now());

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 0, AppTheme.screenPad, 96),
      children: [
        const SizedBox(height: 12),
        for (final notice in detail.notices) ...[
          _Notice(notice),
          const SizedBox(height: 10),
        ],
        _Header(
          value: value,
          invested: known ? invested : null,
          units: known ? units : null,
          nav: nav,
          navDate: navDate,
          isStale: detail.isStale,
          xirr: rate,
        ),
        const SizedBox(height: 12),
        _ValueChart(installments: parsed, series: detail.series),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text('Installments', style: context.text.titleMedium),
            ),
            Text(
              detail.installments.length == 1
                  ? '1 entry'
                  : '${detail.installments.length} entries',
              style: context.text.labelMedium
                  ?.copyWith(color: context.colors.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (detail.installments.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: EmptyState(
              title: 'No installments yet',
              message: 'They are generated from the schedule as they fall due.',
            ),
          )
        else
          for (var i = 0; i < detail.installments.length; i++)
            _InstallmentRow(
              entry: detail.installments[i],
              nav: nav,
              showTopBorder: i > 0,
              onAction: detail.derived
                  ? null
                  : (action) => _rowAction(action, detail.installments[i]),
            ),
      ],
    );
  }

  Future<void> _rowAction(String action, Json entry) async {
    final repo = ref.read(repoProvider);
    final id = entry['id']?.toString();
    if (id == null) return;
    Future<void> record(String verb, Future<void> Function() body) =>
        recordAction(
          repo,
          label: '$verb SIP installment · '
              '${entry[InstallmentFields.date] ?? ''}',
          table: 'investments',
          body: body,
        );

    switch (action) {
      case 'skip':
        final wasSkipped = entry[InstallmentFields.skipped] == true;
        if (wasSkipped) {
          // Un-skipping restores the units; the reason described the skip, so
          // it goes with it rather than lingering against a live installment.
          await record('Un-skipped', () => repo.update(SipFields.table, id, {
                InstallmentFields.skipped: false,
                InstallmentFields.note: null,
              }));
        } else {
          final note = await _askSkipReason();
          if (note == null) return; // cancelled — nothing changes
          await record('Skipped', () => repo.update(SipFields.table, id, {
                InstallmentFields.skipped: true,
                if (note.isNotEmpty) InstallmentFields.note: note,
              }));
        }
        break;
      case 'units':
        final units = await _askUnits(entry);
        if (units == null) return;
        await record('Edited units of', () => repo.update(SipFields.table, id, {
              InstallmentFields.units: units,
              // Marks the figure as the broker's, so a later NAV correction
              // does not silently overwrite what was pasted in.
              'units_override': true,
            }));
        break;
      case 'delete':
        await record('Deleted', () => repo.delete(SipFields.table, id));
        break;
    }
    await _refresh(force: false);
  }

  /// Ask why an installment is being skipped.
  ///
  /// Returns the reason (possibly empty — it is optional), or null if the user
  /// backed out, in which case nothing is written at all.
  Future<String?> _askSkipReason() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Skip this installment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'It stays in the ledger, struck through, but stops counting '
              'towards units and invested capital.',
              style: context.text.labelSmall
                  ?.copyWith(color: context.colors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. mandate bounced',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Skip'),
          ),
        ],
      ),
    );
  }

  Future<double?> _askUnits(Json entry) async {
    final controller = TextEditingController(
        text: ((entry[InstallmentFields.units] as num?)?.toString() ?? ''));
    return showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Units allotted'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Brokers deduct stamp duty before allotting, so their figure is '
              'a shade below amount ÷ NAV. Paste theirs for an exact match.',
              style: context.text.labelSmall
                  ?.copyWith(color: context.colors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Units'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, double.tryParse(controller.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// One thing that could not be loaded, said plainly above the figures it
/// affects — so a number that is missing or stale is never mistaken for one
/// that is simply zero.
class _Notice extends StatelessWidget {
  const _Notice(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.rControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: c.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: context.text.labelMedium?.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Headline figures. Value leads because it is the question the screen answers;
/// the NAV it was computed from sits beneath it, dated, so the figure can be
/// checked rather than trusted.
class _Header extends StatelessWidget {
  const _Header({
    required this.value,
    required this.invested,
    required this.units,
    required this.nav,
    required this.navDate,
    required this.isStale,
    required this.xirr,
  });

  final double? value;

  /// Null when the ledger could not be read at all — distinct from zero.
  final double? invested;
  final double? units;
  final double? nav;
  final DateTime? navDate;
  final bool isStale;
  final double? xirr;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final gain =
        (value == null || invested == null) ? null : value! - invested!;
    final gainPct = (gain == null || invested == null || invested! <= 0)
        ? null
        : gain / invested! * 100;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current value',
              style:
                  context.text.labelMedium?.copyWith(color: c.textSecondary)),
          const SizedBox(height: 2),
          MoneyText(
            value == null ? '—' : money(value),
            style: context.text.displayMedium,
          ),
          // A gain of exactly zero against an unknown holding is noise; only
          // show the line when something actually moved.
          if (gain != null && gain.abs() >= 0.01) ...[
            const SizedBox(height: 4),
            Text(
              '${gain >= 0 ? '+' : '−'}${money(gain.abs())}'
              '${gainPct == null ? '' : ' (${gainPct.abs().toStringAsFixed(1)}%)'}',
              style: context.text.titleSmall?.copyWith(
                color: gain >= 0 ? c.positive : c.negative,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _Figure('Invested', invested == null ? '—' : money(invested)),
              _Figure(
                'Units',
                (units == null || units == 0) ? '—' : units!.toStringAsFixed(3),
              ),
              _Figure(
                'XIRR',
                xirr == null ? '—' : '${(xirr! * 100).toStringAsFixed(1)}%',
              ),
            ],
          ),
          if (nav != null) ...[
            const SizedBox(height: 12),
            Text(
              'NAV ${money(nav)}'
              '${navDate == null ? '' : ' as of ${DateFormat('d MMM').format(navDate!)}'}'
              '${isStale ? ' · not refreshed today' : ''}',
              style:
                  context.text.labelSmall?.copyWith(color: c.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: context.text.labelMedium
                ?.copyWith(color: context.colors.textSecondary)),
        const SizedBox(height: 2),
        MoneyText(value),
      ],
    );
  }
}

/// Value against invested capital over the SIP's life, drawn from NAV history
/// already in cache — no extra request to open this screen.
class _ValueChart extends StatelessWidget {
  const _ValueChart({required this.installments, required this.series});

  final List<Installment> installments;
  final NavSeries? series;

  @override
  Widget build(BuildContext context) {
    if (series == null || installments.isEmpty) {
      return const AppCard(
        child: ChartEmptyState(
          message: 'Installments will chart themselves as they are recorded.',
        ),
      );
    }

    final dates = [for (final i in installments) i.date]..sort();
    final points = _monthEnds(dates.first, DateTime.now());
    final computed = SipMath.valueSeries(installments, series!, points);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Value vs invested', style: context.text.titleMedium),
          const SizedBox(height: 10),
          SeriesChart(
            series: Series(
              kind: ChartKind.dualCumulative,
              label: 'Value vs invested',
              firstLabel: 'Invested',
              secondLabel: 'Value',
              points: [
                for (final p in computed)
                  SeriesPoint(DateFormat('MMM').format(p.date), p.invested),
              ],
              second: [
                for (final p in computed)
                  SeriesPoint(DateFormat('MMM').format(p.date), p.value),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One point per month end, plus today, capped at a year so a long-running
  /// SIP doesn't draw a chart nobody can read.
  static List<DateTime> _monthEnds(DateTime from, DateTime to) {
    final out = <DateTime>[];
    var cursor = DateTime(from.year, from.month + 1, 0);
    while (cursor.isBefore(to)) {
      out.add(cursor);
      cursor = DateTime(cursor.year, cursor.month + 2, 0);
    }
    out.add(to);
    return out.length <= 13 ? out : out.sublist(out.length - 13);
  }
}

/// One installment: when, how much, at what NAV, and what it bought.
class _InstallmentRow extends StatelessWidget {
  const _InstallmentRow({
    required this.entry,
    required this.nav,
    required this.showTopBorder,
    required this.onAction,
  });

  final Json entry;

  /// Today's NAV, for showing what these units are worth now.
  final double? nav;
  final bool showTopBorder;

  /// Null when the row is derived rather than stored — there is nothing to
  /// write an edit to, so the menu is not offered at all.
  final ValueChanged<String>? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final skipped = entry[InstallmentFields.skipped] == true;
    final units = (entry[InstallmentFields.units] as num?)?.toDouble();
    final navUsed = (entry[InstallmentFields.nav] as num?)?.toDouble();
    final amount = (entry[InstallmentFields.amount] as num?)?.toDouble() ?? 0;
    final worth = (units == null || nav == null || skipped) ? null : units * nav!;
    final unresolved = navUsed == null && !skipped;
    final isManual =
        (entry[InstallmentFields.source] ?? 'auto').toString() == 'manual';
    final note = (entry[InstallmentFields.note] ?? '').toString();

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border:
            showTopBorder ? Border(top: BorderSide(color: c.border)) : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      prettyDate(entry[InstallmentFields.date]?.toString()),
                      style: context.text.bodyLarge?.copyWith(
                        decoration:
                            skipped ? TextDecoration.lineThrough : null,
                        color: skipped ? c.textSecondary : null,
                      ),
                    ),
                    if (unresolved) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.help_outline, size: 14, color: c.textSecondary),
                    ],
                    if (entry[InstallmentFields.cashPosted] == true) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle_outline,
                          size: 14, color: c.textSecondary),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  unresolved
                      ? 'NAV not published yet — units pending'
                      : skipped
                          // The reason rides alongside "skipped" rather than
                          // on its own line: a struck-through row with an
                          // unexplained gap in the totals is the thing this
                          // exists to prevent.
                          ? ['skipped', if (note.isNotEmpty) note].join(' · ')
                          : '${units?.toStringAsFixed(3) ?? '—'} units'
                              ' @ ${money(navUsed)}',
                  style: context.text.labelMedium
                      ?.copyWith(color: c.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MoneyText(money(amount)),
              if (worth != null) ...[
                const SizedBox(height: 2),
                Text(
                  'now ${money(worth)}',
                  style: context.text.labelSmall?.copyWith(
                    color: worth >= amount ? c.positive : c.negative,
                  ),
                ),
              ],
              // A skipped row shows no "now" figure, so the space is free —
              // and putting the way back on the row itself means undoing a
              // mistake doesn't mean hunting through a menu for it.
              if (skipped && onAction != null)
                InkWell(
                  onTap: () => onAction!('skip'),
                  borderRadius: BorderRadius.circular(AppTheme.rChip),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    child: Text(
                      'Un-skip',
                      style: context.text.labelMedium
                          ?.copyWith(color: c.accentText),
                    ),
                  ),
                ),
            ],
          ),
          if (onAction == null)
            const SizedBox(width: 8)
          else
          PopupMenuButton<String>(
            tooltip: 'Actions',
            icon: Icon(Icons.more_vert, size: 18, color: c.textSecondary),
            onSelected: onAction!,
            itemBuilder: (_) => [
              // Un-skip lives on the row itself, so the menu only offers the
              // direction the row can actually go.
              if (!skipped)
                const PopupMenuItem(
                  value: 'skip',
                  child: Text('Skip this one'),
                ),
              const PopupMenuItem(
                value: 'units',
                child: Text('Set units exactly'),
              ),
              // Only a lumpsum can be deleted. A scheduled installment is
              // regenerated from the schedule on the next refresh, so deleting
              // one would silently undo itself — "Skip" is the action that
              // actually means "this did not happen", and it keeps the row
              // visible in the ledger rather than hiding the history.
              if (isManual)
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}
