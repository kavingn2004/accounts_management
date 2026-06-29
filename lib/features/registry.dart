import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/finance_repository.dart';
import '../models/field_spec.dart';

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
    color: AppTheme.cIncome,
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
  );

  static final expenses = EntityConfig(
    table: 'expenses',
    title: 'Expenses',
    icon: Icons.north_east,
    color: AppTheme.cExpense,
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
  );

  static final savings = EntityConfig(
    table: 'savings_goals',
    title: 'Savings',
    icon: Icons.savings,
    color: AppTheme.cSavings,
    fields: const [
      FieldSpec('name', 'Goal name', required: true),
      FieldSpec('target_amount', 'Target amount',
          type: FieldType.number, required: true),
      FieldSpec('saved_amount', 'Saved so far', type: FieldType.number),
      FieldSpec('target_date', 'Target date', type: FieldType.date),
    ],
    incrementField: 'saved_amount',
    incrementLabel: 'Add to savings',
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
    color: AppTheme.cInvest,
    fields: const [
      FieldSpec('name', 'Name', required: true),
      FieldSpec('type', 'Type',
          type: FieldType.select,
          options: ['stock', 'fund', 'fd', 'mf', 'sip', 'crypto', 'gold',
            'other']),
      FieldSpec('invested_amount', 'Invested',
          type: FieldType.number, required: true),
      FieldSpec('current_value', 'Current value', type: FieldType.number),
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
    titleOf: (r) => (r['name'] ?? '').toString(),
    subtitleOf: (r) => '${r['type'] ?? ''} · total invested '
        '${money((r['total_invested'] ?? r['invested_amount']) as num?)}',
    trailingOf: (r) => money(r['current_value'] as num?),
  );

  static final debtors = EntityConfig(
    table: 'debtors',
    title: 'Debtors',
    icon: Icons.person_add_alt,
    color: AppTheme.cDebtor,
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
    titleOf: (r) => (r['person_name'] ?? '').toString(),
    subtitleOf: _settlementSubtitle(received: true),
    trailingOf: (r) => money(r['amount'] as num?),
  );

  static final creditors = EntityConfig(
    table: 'creditors',
    title: 'Creditors',
    icon: Icons.person_remove_alt_1,
    color: AppTheme.cCreditor,
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
    titleOf: (r) => (r['person_name'] ?? '').toString(),
    subtitleOf: _settlementSubtitle(received: false),
    trailingOf: (r) => money(r['amount'] as num?),
  );

  static final bills = EntityConfig(
    table: 'bills',
    title: 'Bill Payment',
    icon: Icons.receipt_long,
    color: AppTheme.cBills,
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
  );

  static final loans = EntityConfig(
    table: 'loans',
    title: 'Loan',
    icon: Icons.request_quote,
    color: AppTheme.cLoan,
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
  );

  static final transfers = EntityConfig(
    table: 'transfers',
    title: 'Transfers',
    icon: Icons.swap_horiz,
    color: AppTheme.cDebtor,
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
