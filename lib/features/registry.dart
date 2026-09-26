import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/finance_math.dart';
import '../data/finance_repository.dart';
import '../data/module_event.dart';
import '../models/dashboard_spec.dart';
import '../models/field_spec.dart';

/// Investment types a price can be looked up for. Mirrors the keys of
/// [QuoteService.defaultSources] — a type absent from both is simply manual.
const _priceableTypes = {'stock', 'fund', 'mf', 'crypto', 'gold'};

/// The SIP engine owns a `sip` row's symbol, units and invested total, so the
/// form neither asks for them nor lets them be edited.
const _sipOnly = {'sip'};

/// Subtitle for an investment row.
///
/// Live rows trade "total invested" for the unit price, the quantity it was
/// multiplied by, and the age of that price — a live figure with no visible
/// age is indistinguishable from a stale one. Everything else reads as before.
String _investmentSubtitle(Json r) {
  final type = (r['type'] ?? '').toString();
  final price = (r['last_price'] as num?)?.toDouble();
  final quantity = (r['quantity'] as num?)?.toDouble();
  final at = DateTime.tryParse((r['price_at'] ?? '').toString());

  if (price != null && quantity != null && quantity > 0) {
    return [
      if (type.isNotEmpty) type,
      '${money(price)} × ${quantityText(quantity)}',
      if (at != null) ago(at),
    ].join(' · ');
  }
  return '$type · total invested '
      '${money((r['total_invested'] ?? r['invested_amount']) as num?)}';
}

/// Subtitle for a settle-able debt row. While open/partial it shows how much
/// has been paid down of the original (part-by-part progress) + the due date.
/// Once settled it shows the account the money was received in (debtor) or paid
/// from (creditor), per [received].
String Function(Json) _settlementSubtitle({required bool received}) => (r) {
      final status = (r['status'] ?? 'open').toString();
      if (status == 'settled') {
        final acct = (r['settled_account'] ?? '').toString();
        final where = acct.isEmpty
            ? ''
            : (received ? 'received in $acct' : 'paid from $acct');
        return ['settled', if (where.isNotEmpty) where].join(' · ');
      }
      final original = (r['original_amount'] as num?)?.toDouble() ??
          (r['amount'] as num?)?.toDouble() ??
          0;
      final remaining = (r['amount'] as num?)?.toDouble() ?? 0;
      final due = prettyDate(r['due_date']?.toString());
      final paid = 'paid ${money(original - remaining)} of ${money(original)}';
      return [status, paid, if (due.isNotEmpty) 'due $due'].join(' · ');
    };

/// Central registry of every feature module. The dashboard grid and the
/// generic EntityScreen are both driven by these configs — to add a module,
/// add an entry here (and a matching table in Supabase).
class Modules {
  static final income = EntityConfig(
    table: 'income',
    title: 'Income',
    icon: Icons.south_west,
    tone: ModuleTone.income,
    orderBy: 'date',
    exportable: true,
    dateFiltered: true,
    fields: const [
      FieldSpec('amount', 'Amount', type: FieldType.number, required: true),
      FieldSpec('source', 'Source'),
      FieldSpec('account', 'Account (optional)',
          type: FieldType.select, optionsTable: 'accounts'),
      FieldSpec('note', 'Note'),
      FieldSpec('date', 'Date', type: FieldType.date, required: true),
    ],
    titleOf: (r) => (r['source'] ?? 'Income').toString(),
    subtitleOf: (r) => [
      prettyDate(r['date']?.toString()),
      if (r['account'] != null) r['account'].toString(),
    ].where((s) => s.isNotEmpty).join(' · '),
    trailingOf: (r) => money(r['amount'] as num?),
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('amount', 'Total'),
        StatSpec.count('Entries'),
      ],
      chart: ChartSpec.bars('amount', label: 'Income'),
    ),
  );

  static final expenses = EntityConfig(
    table: 'expenses',
    title: 'Expenses',
    icon: Icons.north_east,
    tone: ModuleTone.expense,
    orderBy: 'date',
    exportable: true,
    dateFiltered: true,
    fields: const [
      FieldSpec('amount', 'Amount', type: FieldType.number, required: true),
      FieldSpec('payee', 'Payee'),
      FieldSpec('account', 'Account (optional)',
          type: FieldType.select, optionsTable: 'accounts'),
      FieldSpec('note', 'Note'),
      FieldSpec('date', 'Date', type: FieldType.date, required: true),
    ],
    titleOf: (r) => (r['payee'] ?? 'Expense').toString(),
    subtitleOf: (r) => [
      prettyDate(r['date']?.toString()),
      if (r['account'] != null) r['account'].toString(),
    ].where((s) => s.isNotEmpty).join(' · '),
    trailingOf: (r) => money(r['amount'] as num?),
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('amount', 'Total'),
        StatSpec.count('Entries'),
      ],
      chart: ChartSpec.bars('amount', label: 'Spending'),
    ),
  );

  static final savings = EntityConfig(
    table: 'savings_goals',
    title: 'Savings',
    icon: Icons.savings,
    tone: ModuleTone.savings,
    fields: const [
      FieldSpec('name', 'Goal name', required: true),
      FieldSpec('target_amount', 'Target amount',
          type: FieldType.number, required: true),
      FieldSpec('saved_amount', 'Saved so far', type: FieldType.number),
      FieldSpec('target_date', 'Target date', type: FieldType.date),
    ],
    incrementField: 'saved_amount',
    incrementLabel: 'Add to savings',
    // The way back out. Same machinery as a debtor repaying you: reduce the
    // balance, and the money lands IN the chosen account rather than leaving
    // it. Without this a goal could only ever be fed, never spent — which is
    // not what saving is for.
    decrementField: 'saved_amount',
    decrementLabel: 'Withdraw',
    decrementConfirm: 'Withdraw',
    paymentInflow: true,
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('saved_amount', 'Saved'),
        StatSpec.sum('target_amount', 'Target'),
        StatSpec.progress('saved_amount', 'target_amount', 'Of target'),
        StatSpec.eventSum('saved_amount', 'Contributed'),
        StatSpec.eventSum('saved_amount', 'Withdrawn',
            kinds: [EventKind.decrement]),
      ],
      chart: ChartSpec.cumulative('saved_amount', label: 'Savings growth'),
      breakdown: BreakdownSpec.byRow(value: 'saved_amount', of: 'target_amount'),
    ),
    titleOf: (r) => (r['name'] ?? '').toString(),
    subtitleOf: (r) =>
        'Saved ${money(r['saved_amount'] as num?)} of ${money(r['target_amount'] as num?)}',
    trailingOf: (r) {
      final target = (r['target_amount'] as num?)?.toDouble() ?? 0;
      final saved = (r['saved_amount'] as num?)?.toDouble() ?? 0;
      final pct = target > 0 ? (saved / target * 100).clamp(0, 100) : 0;
      return '${pct.toStringAsFixed(0)}%';
    },
  );

  static final investment = EntityConfig(
    table: 'investments',
    title: 'Investment',
    icon: Icons.trending_up,
    tone: ModuleTone.invest,
    fields: const [
      FieldSpec('name', 'Name', required: true),
      FieldSpec('type', 'Type',
          type: FieldType.select,
          options: ['stock', 'fund', 'fd', 'mf', 'sip', 'crypto', 'gold',
            'other']),
      // --- Money ---
      // A SIP derives both of these from its installment ledger, so it must
      // not offer them for typing — the engine would overwrite whatever went
      // in, which is worse than never asking.
      FieldSpec('invested_amount', 'Invested',
          type: FieldType.number,
          required: true,
          section: 'Money',
          dependsOn: 'type',
          hiddenWhen: _sipOnly,
          hint: 'What you put in'),
      // Hidden once a quantity is given: the holding is then described as
      // units times a price, and asking for the total as well invites the two
      // to disagree.
      FieldSpec('current_value', 'Current value',
          type: FieldType.number,
          section: 'Money',
          dependsOn: 'type',
          hiddenWhen: _sipOnly,
          hiddenWhenFilled: 'quantity',
          hint: 'What it is worth today — or fill in the holding below '
              'instead and let it be worked out'),
      // --- Holding: units, and where the price comes from ---
      FieldSpec('quantity', 'Quantity held',
          type: FieldType.number,
          section: 'Holding',
          dependsOn: 'type',
          visibleWhen: _priceableTypes,
          hint: 'Shares, units, coins or grams — the price is multiplied by '
              'this',
          hints: {
            'stock': 'Number of shares',
            'mf': 'Units held (not rupees)',
            'fund': 'Units held (not rupees)',
            'crypto': 'Coins held, e.g. 0.35',
            'gold': 'Grams held',
          }),
      // A price you keep yourself, for holdings the app cannot or should not
      // fetch — an unlisted fund, or your jeweller's gold rate rather than
      // international spot. Overrides the symbol when both are present.
      FieldSpec('market_price', 'Current market price',
          type: FieldType.number,
          section: 'Holding',
          dependsOn: 'type',
          visibleWhen: _priceableTypes,
          hint: 'Price of one unit today — leave blank to fetch it live',
          hints: {
            'stock': "Today's share price — leave blank to fetch it live",
            'mf': "Today's NAV — leave blank to fetch it live",
            'fund': "Today's NAV — leave blank to fetch it live",
            'crypto': 'Price of one coin — leave blank to fetch it live',
            'gold': 'Your rate per gram — overrides international spot',
          }),
      FieldSpec(
        'symbol',
        'Symbol (for live prices)',
        section: 'Holding',
        dependsOn: 'type',
        visibleWhen: _priceableTypes,
        hint: 'Leave blank to keep updating this row by hand',
        hints: {
          'stock': 'NSE ticker, e.g. RELIANCE — add .BO for a BSE listing',
          'mf': 'AMFI scheme code, e.g. 120503',
          'fund': 'AMFI scheme code, e.g. 120503',
          'crypto': 'CoinGecko id, e.g. bitcoin or ethereum (not BTC)',
          'gold': "Type 'gold' — priced per gram in INR",
        },
      ),
      // --- SIP: the schedule, from which units and value are derived. ---
      FieldSpec('scheme_code', 'Fund',
          type: FieldType.fundSearch,
          required: true,
          section: 'Schedule',
          dependsOn: 'type',
          visibleWhen: _sipOnly,
          hint: 'Search AMFI by name'),
      FieldSpec('sip_amount', 'Amount per installment',
          type: FieldType.number,
          required: true,
          section: 'Schedule',
          dependsOn: 'type',
          visibleWhen: _sipOnly),
      FieldSpec('sip_frequency', 'Frequency',
          type: FieldType.select,
          options: ['monthly', 'weekly', 'quarterly'],
          section: 'Schedule',
          dependsOn: 'type',
          visibleWhen: _sipOnly),
      FieldSpec('sip_day', 'Debit day',
          type: FieldType.number,
          section: 'Schedule',
          dependsOn: 'type',
          visibleWhen: _sipOnly,
          hint: 'Day of the month (1–31); for weekly, 1 = Monday … 7 = Sunday'),
      // Which account the mandate draws from. With it set, each installment
      // debits the account as it falls due — the way the real mandate does.
      // Left blank, the app asks before moving money instead of guessing.
      FieldSpec('sip_account', 'Debit from account',
          type: FieldType.select,
          optionsTable: 'accounts',
          section: 'Schedule',
          dependsOn: 'type',
          visibleWhen: _sipOnly,
          hint: 'Installments from today onward come out of this account'),
      FieldSpec('sip_start_date', 'First installment',
          type: FieldType.date,
          required: true,
          section: 'Schedule',
          dependsOn: 'type',
          visibleWhen: _sipOnly,
          hint: 'Earlier installments are filled in automatically'),
    ],
    incrementField: 'invested_amount',
    incrementAlsoField: 'current_value',
    // Total amount invested = running sum of every contribution (seeded from
    // the first investment, grown by each "Add investment").
    cumulativeIncrementField: 'total_invested',
    incrementLabel: 'Add investment',
    setField: 'current_value',
    setLabel: 'Update current value',
    principalAccountField: 'invested_amount',
    liveTracked: true,
    redeemable: true,
    cascadeTables: const ['sip_installments'],
    // A SIP's cash boundary: installments dated before the row was created are
    // history and post no cash movement, because those debits were already
    // recorded by hand. Everything from today onward asks first.
    seedOnCreate: (v) => v['type'] != 'sip'
        ? const {}
        : {'cash_from': isoDate(DateTime.now()), 'sip_active': true},
    titleOf: (r) => (r['name'] ?? '').toString(),
    // A live row reports the price it was valued at and how fresh that is —
    // the figure on the right is only trustworthy if you can see its age.
    // Rows without live tracking keep showing what they always did.
    subtitleOf: _investmentSubtitle,
    // The same rule net worth uses, so the row and the total can never
    // disagree about what a holding is worth.
    trailingOf: (r) => money(investmentValue(r)),
    dashboard: const DashboardSpec(
      stats: [
        // Rows created before `total_invested` existed carry the same figure
        // in `invested_amount` — the substitution FinanceMath.dashboard makes.
        StatSpec.sum('total_invested', 'Invested',
            fallback: 'invested_amount'),
        StatSpec.sum('current_value', 'Current value'),
        StatSpec.ratio('current_value', 'total_invested', 'Return',
            againstFallback: 'invested_amount'),
        StatSpec.eventSum('invested_amount', 'Added'),
      ],
      chart: ChartSpec.dualCumulative(
        'invested_amount',
        'current_value',
        label: 'Invested vs value',
        firstLabel: 'Invested',
        secondLabel: 'Value',
      ),
      breakdown: BreakdownSpec.byRow(value: 'current_value'),
    ),
  );

  static final debtors = EntityConfig(
    table: 'debtors',
    title: 'Debtors',
    icon: Icons.person_add_alt,
    tone: ModuleTone.debtor,
    fields: const [
      FieldSpec('person_name', 'Person', required: true),
      FieldSpec('contact', 'Contact'),
      FieldSpec('amount', 'Amount owed to you',
          type: FieldType.number, required: true),
      FieldSpec('due_date', 'Due date', type: FieldType.date),
      FieldSpec('note', 'Note'),
    ],
    decrementField: 'amount',
    decrementLabel: 'Add payment',
    dueDateField: 'due_date',
    paymentInflow: true, // debtor repaying you = money in
    principalAccount: true, // lending them = money out of your account
    statusField: 'status',
    originalAmountField: 'original_amount',
    settledAccountField: 'settled_account',
    paymentsTable: 'debt_payments',
    cascadeTables: const ['debt_payments'],
    titleOf: (r) => (r['person_name'] ?? '').toString(),
    subtitleOf: _settlementSubtitle(received: true),
    trailingOf: (r) => money(r['amount'] as num?),
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.outstanding('amount', 'Outstanding'),
        // Read from the rows, not the ledger: balances part-paid before the
        // ledger existed would otherwise report ₹0 beside a row that plainly
        // says money came in.
        StatSpec.paidDown('amount', 'original_amount', 'Received'),
        StatSpec.count('People'),
      ],
      chart: ChartSpec.cumulative('amount', label: 'Owed to you'),
      breakdown: BreakdownSpec.byRow(value: 'amount'),
    ),
  );

  static final creditors = EntityConfig(
    table: 'creditors',
    title: 'Creditors',
    icon: Icons.person_remove_alt_1,
    tone: ModuleTone.creditor,
    fields: const [
      FieldSpec('person_name', 'Person', required: true),
      FieldSpec('contact', 'Contact'),
      FieldSpec('amount', 'Amount you owe',
          type: FieldType.number, required: true),
      FieldSpec('due_date', 'Due date', type: FieldType.date, required: true),
      FieldSpec('note', 'Note'),
    ],
    decrementField: 'amount',
    decrementLabel: 'Add payment',
    dueDateField: 'due_date',
    principalAccount: true, // borrowing from them = money into your account
    statusField: 'status',
    originalAmountField: 'original_amount',
    settledAccountField: 'settled_account',
    paymentsTable: 'debt_payments',
    cascadeTables: const ['debt_payments'],
    titleOf: (r) => (r['person_name'] ?? '').toString(),
    subtitleOf: _settlementSubtitle(received: false),
    trailingOf: (r) => money(r['amount'] as num?),
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.outstanding('amount', 'Outstanding'),
        StatSpec.paidDown('amount', 'original_amount', 'Paid'),
        StatSpec.count('People'),
      ],
      chart: ChartSpec.cumulative('amount', label: 'You owe'),
      breakdown: BreakdownSpec.byRow(value: 'amount'),
    ),
  );

  static final bills = EntityConfig(
    table: 'bills',
    title: 'Bill Payment',
    icon: Icons.receipt_long,
    tone: ModuleTone.bills,
    fields: const [
      FieldSpec('name', 'Bill name', required: true),
      FieldSpec('amount', 'Amount', type: FieldType.number, required: true),
      FieldSpec('due_day', 'Due day (1–31)', type: FieldType.number),
      FieldSpec('frequency', 'Frequency',
          type: FieldType.select,
          options: ['weekly', 'monthly', 'quarterly', 'yearly']),
    ],
    titleOf: (r) => (r['name'] ?? '').toString(),
    subtitleOf: (r) =>
        '${r['frequency'] ?? ''} · ${r['status'] ?? 'due'} · day ${r['due_day'] ?? '-'}',
    trailingOf: (r) => money(r['amount'] as num?),
    // No chart: a bill is a recurring template, not a balance, so nothing
    // about it moves over time. Figures and a breakdown are the honest maximum.
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('amount', 'Commitment'),
        StatSpec.count('Bills'),
      ],
      breakdown: BreakdownSpec.byRow(value: 'amount'),
    ),
  );

  static final loans = EntityConfig(
    table: 'loans',
    title: 'Loan',
    icon: Icons.request_quote,
    tone: ModuleTone.loan,
    fields: const [
      FieldSpec('lender', 'Lender / Bank', required: true),
      FieldSpec('principal', 'Principal amount',
          type: FieldType.number, required: true),
      FieldSpec('outstanding', 'Outstanding balance',
          type: FieldType.number, required: true),
      FieldSpec('interest_rate', 'Interest rate (%)', type: FieldType.number),
      FieldSpec('emi', 'Monthly EMI', type: FieldType.number),
      FieldSpec('start_date', 'Start date', type: FieldType.date),
      FieldSpec('status', 'Status',
          type: FieldType.select, options: ['active', 'closed']),
      FieldSpec('note', 'Note'),
    ],
    decrementField: 'outstanding',
    decrementLabel: 'Add payment',
    interestRateField: 'interest_rate',
    titleOf: (r) => (r['lender'] ?? '').toString(),
    subtitleOf: (r) =>
        '${r['status'] ?? 'active'} · EMI ${money(r['emi'] as num?)}',
    trailingOf: (r) => money(r['outstanding'] as num?),
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('outstanding', 'Outstanding'),
        StatSpec.sum('emi', 'Monthly EMI'),
        StatSpec.paidDown('outstanding', 'principal', 'Paid'),
      ],
      chart: ChartSpec.cumulative('outstanding', label: 'Outstanding'),
      breakdown: BreakdownSpec.byRow(value: 'outstanding', of: 'principal'),
    ),
  );

  static final transfers = EntityConfig(
    table: 'transfers',
    title: 'Transfers',
    icon: Icons.swap_horiz,
    tone: ModuleTone.debtor,
    orderBy: 'date',
    fields: const [
      FieldSpec('from', 'From account',
          type: FieldType.select, optionsTable: 'accounts', required: true),
      FieldSpec('to', 'To account',
          type: FieldType.select, optionsTable: 'accounts', required: true),
      FieldSpec('amount', 'Amount', type: FieldType.number, required: true),
      FieldSpec('date', 'Date', type: FieldType.date),
      FieldSpec('note', 'Note'),
    ],
    titleOf: (r) => '${r['from'] ?? '?'} → ${r['to'] ?? '?'}',
    subtitleOf: (r) => prettyDate(r['date']?.toString()),
    trailingOf: (r) => money(r['amount'] as num?),
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('amount', 'Moved'),
        StatSpec.count('Transfers'),
      ],
      chart: ChartSpec.bars('amount', label: 'Transfers'),
    ),
  );

  // Note: Alerts and Accounts are not generic CRUD modules — each has its own
  // screen (features/alerts/alerts_screen.dart, features/accounts/...).

  /// Modules listed in the sidebar (in order).
  static final List<EntityConfig> all = [
    income,
    expenses,
    savings,
    investment,
    debtors,
    creditors,
    bills,
    loans,
    transfers,
  ];
}
