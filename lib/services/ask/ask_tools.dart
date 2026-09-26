import '../../core/formatters.dart';
import '../../data/finance_math.dart';
import '../../data/finance_repository.dart';
import '../../data/sip_math.dart';
import '../sip_service.dart';

/// One thing the assistant is allowed to do.
///
/// The model never writes a query. It picks a tool by name and fills in typed
/// arguments; the arithmetic happens here, in Dart, over rows the repository
/// already returns under the signed-in user's row-level security.
///
/// That is the whole safety design. There is no SQL string for a model to get
/// wrong and no injection surface, and every tool can be tested on its own
/// without an LLM anywhere near it.
class AskTool {
  const AskTool({
    required this.name,
    required this.description,
    required this.args,
    required this.run,
  });

  final String name;
  final String description;

  /// Argument name → what it means, for the model's tool list.
  final Map<String, String> args;

  /// Rows in, answer out. [args] arrives already validated.
  final AskAnswer Function(AskData data, Map<String, dynamic> args) run;
}

/// Everything the tools read. Fetched once per question so a tool cannot go
/// to the network on its own.
class AskData {
  const AskData({
    this.income = const [],
    this.expenses = const [],
    this.accounts = const [],
    this.transfers = const [],
    this.cashMoves = const [],
    this.investments = const [],
    this.savings = const [],
    this.installments = const [],
    this.debtors = const [],
    this.creditors = const [],
    this.bills = const [],
    this.loans = const [],
  });

  final List<Json> income;
  final List<Json> expenses;
  final List<Json> accounts;
  final List<Json> transfers;
  final List<Json> cashMoves;
  final List<Json> investments;
  final List<Json> savings;
  final List<Json> installments;

  /// People who owe you, and people you owe.
  final List<Json> debtors;
  final List<Json> creditors;

  /// Liabilities. Only net worth reads these, and it must: an answer that
  /// counted holdings but not what is owed against them would be flattering
  /// rather than true.
  final List<Json> bills;
  final List<Json> loans;
}

/// A finished answer: a sentence, and the figures it was built from.
///
/// [rows] is not decoration. A money figure a person cannot check is worse
/// than no figure, so the screen shows the workings under every answer.
class AskAnswer {
  const AskAnswer(this.text, {this.rows = const []});
  final String text;
  final List<({String label, String value})> rows;
}

DateTime? _date(Object? v) => DateTime.tryParse((v ?? '').toString());

const _months = {
  'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
  'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7,
  'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9, 'oct': 10,
  'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
};

/// Turn a period argument into a date range, here rather than in the model.
///
/// A small model asked to compute "last month" as two ISO dates gets it wrong
/// often, and silently — the same reason it is never allowed to do the
/// arithmetic on money. It names a period; this resolves it against the clock.
///
/// Explicit `from`/`to` still win when given, so a precise range is always
/// expressible.
({DateTime? from, DateTime? to}) resolveRange(
  Map<String, dynamic> args,
  DateTime now,
) {
  final explicitFrom = _date(args['from']);
  final explicitTo = _date(args['to']);
  if (explicitFrom != null || explicitTo != null) {
    return (from: explicitFrom, to: explicitTo);
  }

  final period = (args['period'] ?? '').toString().trim().toLowerCase();
  if (period.isEmpty || period == 'all' || period == 'all_time') {
    return (from: null, to: null);
  }

  DateTime endOf(int y, int m) => DateTime(y, m + 1, 0);

  switch (period) {
    case 'today':
      final d = DateTime(now.year, now.month, now.day);
      return (from: d, to: d);
    case 'this_week':
    case 'week':
      final start = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: now.weekday - 1));
      return (from: start, to: now);
    case 'this_month':
    case 'month':
    case 'current_month':
      return (from: DateTime(now.year, now.month, 1), to: now);
    case 'last_month':
    case 'previous_month':
      final m = now.month == 1 ? 12 : now.month - 1;
      final y = now.month == 1 ? now.year - 1 : now.year;
      return (from: DateTime(y, m, 1), to: endOf(y, m));
    case 'this_year':
    case 'year':
    case 'current_year':
      return (from: DateTime(now.year, 1, 1), to: now);
    case 'last_year':
    case 'previous_year':
      return (from: DateTime(now.year - 1, 1, 1), to: DateTime(now.year - 1, 12, 31));
  }

  // "august", "aug 2026", "2026-08"
  final iso = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(period);
  if (iso != null) {
    final y = int.parse(iso.group(1)!);
    final m = int.parse(iso.group(2)!).clamp(1, 12);
    return (from: DateTime(y, m, 1), to: endOf(y, m));
  }
  for (final entry in _months.entries) {
    if (!period.startsWith(entry.key)) continue;
    final year = RegExp(r'(\d{4})').firstMatch(period);
    final y = year != null ? int.parse(year.group(1)!) : now.year;
    final m = entry.value;
    // A bare month name that hasn't happened yet this year means last year.
    final resolved = (year == null && m > now.month) ? y - 1 : y;
    return (from: DateTime(resolved, m, 1), to: endOf(resolved, m));
  }

  return (from: null, to: null);
}
double _amount(Json r) => (r['amount'] as num?)?.toDouble() ?? 0;

/// Rows whose `date` falls in [from]..[to] inclusive. Undated rows are kept:
/// a record that exists must not vanish from a total because someone left the
/// date blank.
List<Json> _between(List<Json> rows, DateTime? from, DateTime? to) {
  // Always a fresh list. Callers sort what comes back, and sorting the
  // caller's own rows would quietly reorder data the rest of the app holds.
  if (from == null && to == null) return List.of(rows);
  return rows.where((r) {
    final d = _date(r['date']) ?? _date(r['created_at']);
    if (d == null) return true;
    if (from != null && d.isBefore(from)) return false;
    if (to != null && d.isAfter(to)) return false;
    return true;
  }).toList();
}

String _range(DateTime? from, DateTime? to) {
  if (from == null && to == null) return 'all time';
  if (from != null && to != null) {
    return '${prettyDate(isoDate(from))} to ${prettyDate(isoDate(to))}';
  }
  return from != null
      ? 'since ${prettyDate(isoDate(from))}'
      : 'up to ${prettyDate(isoDate(to!))}';
}

/// Every tool the assistant may call.
class AskTools {
  const AskTools._();

  /// Prefer `period` — the model names a span and the app resolves it, which
  /// a small model gets right far more often than computing two ISO dates.
  static const _dateArgs = {
    'period': 'one of: today, this_week, this_month, last_month, this_year, '
        'last_year, all — or a month name like "august" or "2026-08"',
    'from': 'exact start date YYYY-MM-DD (only if no period fits)',
    'to': 'exact end date YYYY-MM-DD (only if no period fits)',
  };

  static final List<AskTool> all = [
    AskTool(
      name: 'spend_by_payee',
      description: 'SPENDING ONLY, totalled and broken down by payee. Use '
          'this for any question about expenses or spending alone: "how much '
          'did I spend", "total expense in August", "where is my money '
          'going", "what are my expenses".',
      args: {..._dateArgs, 'payee': 'filter to one payee (optional)'},
      run: (data, args) {
        final range = resolveRange(args, DateTime.now());
        final from = range.from;
        final to = range.to;
        final payee = (args['payee'] ?? '').toString().trim().toLowerCase();

        final rows = _between(data.expenses, from, to).where((r) {
          if (payee.isEmpty) return true;
          return (r['payee'] ?? '').toString().toLowerCase().contains(payee);
        });

        final totals = <String, double>{};
        for (final r in rows) {
          final key = (r['payee'] ?? 'Unlabelled').toString();
          totals[key] = (totals[key] ?? 0) + _amount(r);
        }
        final sorted = totals.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final total = totals.values.fold(0.0, (a, b) => a + b);

        if (sorted.isEmpty) {
          return AskAnswer('No spending recorded for ${_range(from, to)}'
              '${payee.isEmpty ? '' : ' matching "$payee"'}.');
        }
        return AskAnswer(
          payee.isEmpty
              ? 'You spent ${money(total)} across ${rows.length} '
                  '${rows.length == 1 ? 'entry' : 'entries'} '
                  '(${_range(from, to)}). Largest: ${sorted.first.key} '
                  '${money(sorted.first.value)}.'
              : 'You spent ${money(total)} on "$payee" '
                  '(${_range(from, to)}), across ${rows.length} '
                  '${rows.length == 1 ? 'entry' : 'entries'}.',
          rows: [
            for (final e in sorted.take(10))
              (label: e.key, value: money(e.value)),
          ],
        );
      },
    ),
    AskTool(
      name: 'income_vs_expense',
      description: 'BOTH SIDES together: money in, money out, what is left '
          'and how many entries. Use this ONLY when the question mentions '
          'income, earnings, savings, or transactions as a whole: "total '
          'transactions this month", "what did I earn", "am I saving". Do '
          'NOT use it for spending alone.',
      args: _dateArgs,
      run: (data, args) {
        final range = resolveRange(args, DateTime.now());
        final from = range.from;
        final to = range.to;
        final earned = _between(data.income, from, to)
            .fold(0.0, (a, r) => a + _amount(r));
        final spent = _between(data.expenses, from, to)
            .fold(0.0, (a, r) => a + _amount(r));
        final net = earned - spent;
        return AskAnswer(
          net >= 0
              ? 'Over ${_range(from, to)} you took in ${money(earned)} and '
                  'spent ${money(spent)}, keeping ${money(net)}.'
              : 'Over ${_range(from, to)} you took in ${money(earned)} but '
                  'spent ${money(spent)} — ${money(net.abs())} more than came in.',
          rows: [
            (label: 'Income', value: money(earned)),
            (label: 'Expenses', value: money(spent)),
            (label: 'Net', value: money(net)),
            (
              label: 'Entries',
              value: '${_between(data.income, from, to).length + _between(data.expenses, from, to).length}',
            ),
          ],
        );
      },
    ),
    AskTool(
      name: 'account_balances',
      description: 'Current balance of every account, or one named account. '
          'Answers "how much is in my bank".',
      args: {'account': 'filter to one account by name (optional)'},
      run: (data, args) {
        final wanted = (args['account'] ?? '').toString().trim().toLowerCase();
        final balances = FinanceMath.balanceMap(
          accounts: data.accounts,
          income: data.income,
          expenses: data.expenses,
          transfers: data.transfers,
          cashMoves: data.cashMoves,
        );
        final shown = balances.entries
            .where((e) =>
                wanted.isEmpty || e.key.toLowerCase().contains(wanted))
            .toList();
        if (shown.isEmpty) {
          return AskAnswer('No account matches "$wanted".');
        }
        final total = shown.fold(0.0, (a, e) => a + e.value);
        return AskAnswer(
          shown.length == 1
              ? '${shown.first.key} holds ${money(shown.first.value)}.'
              : 'Across ${shown.length} accounts you hold ${money(total)}.',
          rows: [
            for (final e in shown) (label: e.key, value: money(e.value)),
          ],
        );
      },
    ),
    AskTool(
      name: 'net_worth',
      description: 'EVERYTHING TOGETHER: cash, accounts, investments, savings '
          'and what you are owed, less what you owe. Answers "what is my net '
          'worth", "what am I worth", "how much do I have in total", "my '
          'overall position".',
      args: const {},
      run: (data, args) {
        // FinanceMath.dashboard is what the dashboard itself uses. Ask must
        // not compute a second net worth: two definitions of "what am I
        // worth" that disagree is worse than not answering.
        final d = FinanceMath.dashboard(
          balances: FinanceMath.balanceMap(
            accounts: data.accounts,
            income: data.income,
            expenses: data.expenses,
            transfers: data.transfers,
            cashMoves: data.cashMoves,
          ),
          income: data.income,
          expenses: data.expenses,
          investments: data.investments,
          savingsGoals: data.savings,
          debtors: data.debtors,
          creditors: data.creditors,
          loans: data.loans,
          bills: data.bills,
        );

        double at(String k) => (d[k] as num?)?.toDouble() ?? 0;

        // The rows have to add up to the headline, so they are the exact terms
        // of net_worth and nothing else. `credit_worth` is not one of them: it
        // folds in bills, which the app's net worth does not subtract. Taking
        // it from here would leave the breakdown quietly failing to reconcile.
        final payable = at('credit_worth') - at('bills_total');

        // Only the parts that exist. A row reading "Owed to you ₹0" on an app
        // with no debtors is noise, not information.
        final rows = <({String label, String value})>[
          for (final e in {
            'In accounts': at('current_worth'),
            'Investments': at('investment_worth'),
            'Savings set aside': at('saving_worth'),
            'Owed to you': at('debt_worth'),
          }.entries)
            if (e.value != 0) (label: e.key, value: money(e.value)),
          if (payable != 0)
            (label: 'Less owed to others', value: '−${money(payable)}'),
          if (at('loans_total') != 0)
            (label: 'Less loans outstanding',
              value: '−${money(at('loans_total'))}'),
        ];

        return AskAnswer(
          rows.isEmpty
              ? 'There is nothing recorded yet, so your net worth is '
                  '${money(0)}.'
              : 'You are worth ${money(at('net_worth'))} in total.',
          rows: rows,
        );
      },
    ),
    AskTool(
      name: 'investment_summary',
      description: 'What every holding is worth, what it cost, and the return. '
          'Answers "how are my investments doing".',
      args: const {},
      run: (data, args) {
        var invested = 0.0;
        var value = 0.0;
        final rows = <({String label, String value})>[];
        for (final r in data.investments) {
          final cost =
              ((r['total_invested'] ?? r['invested_amount']) as num?)
                      ?.toDouble() ??
                  0;
          final worth = (r['current_value'] as num?)?.toDouble() ?? cost;
          invested += cost;
          value += worth;
          rows.add((
            label: (r['name'] ?? 'Investment').toString(),
            value: '${money(worth)} (cost ${money(cost)})',
          ));
        }
        if (rows.isEmpty) return const AskAnswer('You have no investments yet.');
        final gain = value - invested;
        final pct = invested > 0 ? gain / invested * 100 : 0;
        return AskAnswer(
          'Your ${rows.length} holdings are worth ${money(value)} against '
          '${money(invested)} invested — '
          '${gain >= 0 ? 'up' : 'down'} ${money(gain.abs())}'
          '${invested > 0 ? ' (${pct.abs().toStringAsFixed(1)}%)' : ''}.',
          rows: rows,
        );
      },
    ),
    AskTool(
      name: 'sip_detail',
      description: 'Units, NAV, invested and return for one SIP. Answers '
          '"how is my Tata SIP doing".',
      args: {'name': 'part of the fund name'},
      run: (data, args) {
        final wanted = (args['name'] ?? '').toString().trim().toLowerCase();
        final sips = data.investments.where(SipService.isSip).where((r) =>
            wanted.isEmpty ||
            (r['name'] ?? '').toString().toLowerCase().contains(wanted));
        if (sips.isEmpty) {
          return AskAnswer(wanted.isEmpty
              ? 'You have no SIPs set up.'
              : 'No SIP matches "$wanted".');
        }
        final row = sips.first;
        final id = row['id'].toString();
        final mine = data.installments
            .where((e) => (e['parent_id'] ?? '').toString() == id)
            .map(SipService.installmentFrom)
            .toList();
        final units = SipMath.totalUnits(mine);
        final invested = SipMath.totalInvested(mine);
        final nav = (row['last_price'] as num?)?.toDouble();
        final worth = nav == null ? null : units * nav;

        return AskAnswer(
          worth == null
              ? '${row['name']} holds ${quantityText(units)} units from '
                  '${mine.length} installments; it has no current NAV yet.'
              : '${row['name']} is worth ${money(worth)} — '
                  '${quantityText(units)} units at ${money(nav)}, '
                  'against ${money(invested)} invested across '
                  '${mine.length} installments.',
          rows: [
            (label: 'Units', value: quantityText(units)),
            if (nav != null) (label: 'NAV', value: money(nav)),
            (label: 'Invested', value: money(invested)),
            if (worth != null) (label: 'Value', value: money(worth)),
          ],
        );
      },
    ),
    AskTool(
      name: 'money_owed_to_me',
      description: 'Who still owes you money and how much. Answers "who owes '
          'me", "my debtors", "did X pay me back", "outstanding receivables".',
      args: {'name': 'filter to one person (optional)'},
      run: (data, args) => _owed(
        rows: data.debtors,
        args: args,
        noneAtAll: 'Nobody owes you anything right now.',
        noMatch: (n) => 'Nobody called "$n" owes you anything.',
        one: (name, amount) => '$name owes you ${money(amount)}.',
        many: (count, total) =>
            '$count people owe you ${money(total)} in total.',
      ),
    ),
    AskTool(
      name: 'money_i_owe',
      description: 'Who you still owe money to and how much. Answers "who do '
          'I owe", "my creditors", "what do I owe X", "outstanding payables".',
      args: {'name': 'filter to one person (optional)'},
      run: (data, args) => _owed(
        rows: data.creditors,
        args: args,
        noneAtAll: 'You do not owe anybody at the moment.',
        noMatch: (n) => 'You do not owe anybody called "$n".',
        one: (name, amount) => 'You owe $name ${money(amount)}.',
        many: (count, total) =>
            'You owe ${money(total)} across $count people.',
      ),
    ),
    AskTool(
      name: 'largest_expenses',
      description: 'The biggest individual expenses in a period. Answers '
          '"what did I spend the most on".',
      args: {..._dateArgs, 'limit': 'how many to list, default 5'},
      run: (data, args) {
        final range = resolveRange(args, DateTime.now());
        final from = range.from;
        final to = range.to;
        final limit =
            int.tryParse((args['limit'] ?? '5').toString())?.clamp(1, 20) ?? 5;
        final rows = _between(data.expenses, from, to)
          ..sort((a, b) => _amount(b).compareTo(_amount(a)));
        if (rows.isEmpty) {
          return AskAnswer('No expenses recorded for ${_range(from, to)}.');
        }
        final top = rows.take(limit).toList();
        return AskAnswer(
          'Your largest expense ${_range(from, to)} was '
          '${top.first['payee'] ?? 'an unlabelled entry'} at '
          '${money(_amount(top.first))}.',
          rows: [
            for (final r in top)
              (
                label: '${r['payee'] ?? 'Unlabelled'} · '
                    '${prettyDate(r['date']?.toString())}',
                value: money(_amount(r)),
              ),
          ],
        );
      },
    ),
  ];

  /// Both debt directions read the same way: open balances, largest first,
  /// settled rows excluded because a cleared debt is not money owed.
  static AskAnswer _owed({
    required List<Json> rows,
    required Map<String, dynamic> args,
    required String noneAtAll,
    required String Function(String) noMatch,
    required String Function(String, double) one,
    required String Function(int, double) many,
  }) {
    final wanted = (args['name'] ?? '').toString().trim().toLowerCase();
    final open = rows.where((r) {
      if ((r['status'] ?? 'open').toString() == 'settled') return false;
      final amount = (r['amount'] as num?)?.toDouble() ?? 0;
      if (amount <= 0) return false;
      if (wanted.isEmpty) return true;
      return (r['person_name'] ?? '').toString().toLowerCase().contains(wanted);
    }).toList()
      ..sort((a, b) => ((b['amount'] as num?)?.toDouble() ?? 0)
          .compareTo((a['amount'] as num?)?.toDouble() ?? 0));

    if (open.isEmpty) {
      return AskAnswer(wanted.isEmpty ? noneAtAll : noMatch(wanted));
    }

    final total =
        open.fold(0.0, (a, r) => a + ((r['amount'] as num?)?.toDouble() ?? 0));
    final rowsOut = [
      for (final r in open)
        (
          label: [
            (r['person_name'] ?? 'Someone').toString(),
            if ((r['due_date'] ?? '').toString().isNotEmpty)
              'due ${prettyDate(r['due_date'].toString())}',
          ].join(' · '),
          value: money((r['amount'] as num?)?.toDouble() ?? 0),
        ),
    ];

    return AskAnswer(
      open.length == 1
          ? one((open.first['person_name'] ?? 'Someone').toString(), total)
          : many(open.length, total),
      rows: rowsOut,
    );
  }

  static AskTool? byName(String name) {
    for (final t in all) {
      if (t.name == name) return t;
    }
    return null;
  }
}
