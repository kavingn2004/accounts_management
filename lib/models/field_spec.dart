import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/finance_repository.dart';
import 'dashboard_spec.dart';

enum FieldType {
  text,
  number,
  date,
  select,

  /// Searchable mutual-fund picker. Writes three keys rather than one —
  /// `scheme_code` (the field's own key), plus `scheme_name` and `fund_house`
  /// captured at selection so the row can name its fund without a lookup.
  fundSearch,
}

/// Describes one editable field of an entity (drives the add form).
class FieldSpec {
  const FieldSpec(
    this.key,
    this.label, {
    this.type = FieldType.text,
    this.required = false,
    this.options,
    this.optionsTable,
    this.hint,
    this.dependsOn,
    this.hints,
    this.visibleWhen,
    this.hiddenWhen,
    this.hiddenWhenFilled,
    this.section,
  });

  final String key;
  final String label;
  final FieldType type;
  final bool required;
  final List<String>? options; // for FieldType.select (static)

  /// Helper text under the field. For inputs whose correct value isn't
  /// guessable from the label alone — an AMFI scheme code, a CoinGecko id.
  final String? hint;

  /// Key of another field in the same form whose value this one varies with.
  /// An investment's symbol means something different for a stock than for a
  /// mutual fund, and the form should say which is wanted before it's typed
  /// wrong rather than reject it after.
  final String? dependsOn;

  /// [dependsOn] value → helper text, falling back to [hint].
  final Map<String, String>? hints;

  /// Show this field only while [dependsOn] holds one of these values. Null
  /// means always visible. A hidden field is never saved, so switching type
  /// can't leave a stale figure behind on the row.
  final Set<String>? visibleWhen;

  /// Hide this field while [dependsOn] holds one of these values — the
  /// complement of [visibleWhen], for a field that suits every case but one
  /// (an amount typed by hand everywhere except where an engine derives it).
  final Set<String>? hiddenWhen;

  /// Hide this field once the named field has any value at all.
  ///
  /// For two fields that answer the same question different ways: a total
  /// worth, or a quantity times a price. Asking for both invites them to
  /// disagree, and then something has to silently win.
  final String? hiddenWhenFilled;

  /// Heading shown above this field, starting a group. Repeat the same string
  /// on consecutive fields to keep them under one heading.
  final String? section;

  /// For a dynamic select: load option labels from the `name` column of this
  /// table (e.g. 'accounts'). Stored value is the chosen name.
  final String? optionsTable;
}

/// Describes a whole entity screen: which table, how to render rows, and the
/// fields used to create a new one. Adding a new module = adding one of these.
class EntityConfig {
  const EntityConfig({
    required this.table,
    required this.title,
    required this.icon,
    required this.tone,
    required this.fields,
    required this.titleOf,
    this.subtitleOf,
    this.trailingOf,
    this.readOnly = false,
    this.orderBy = 'created_at',
    this.incrementField,
    this.incrementAlsoField,
    this.incrementLabel,
    this.cumulativeIncrementField,
    this.setField,
    this.setLabel,
    this.decrementField,
    this.decrementLabel,
    this.decrementConfirm,
    this.interestRateField,
    this.dueDateField,
    this.paymentInflow = false,
    this.principalAccount = false,
    this.principalAccountField,
    this.statusField,
    this.originalAmountField,
    this.settledAccountField,
    this.paymentsTable,
    this.exportable = false,
    this.dateFiltered = false,
    this.liveTracked = false,
    this.redeemable = false,
    this.cascadeTables = const [],
    this.seedOnCreate,
    this.dashboard,
  });

  final String table;
  final String title;
  final IconData icon;

  /// Category accent. Resolved per-brightness at paint time and used only to
  /// tint this module's 32px icon chip — never a card fill or a figure.
  final ModuleTone tone;
  final List<FieldSpec> fields;
  final String Function(Json) titleOf;
  final String Function(Json)? subtitleOf;
  final String Function(Json)? trailingOf;
  final bool readOnly;
  final String orderBy;

  /// If set, rows get an "add amount" action that increments this numeric
  /// column by a user-entered value (e.g. savings contributions).
  final String? incrementField;

  /// Optional second column that the same "add amount" also increments
  /// (e.g. an investment contribution raises both invested and current value).
  final String? incrementAlsoField;
  final String? incrementLabel;

  /// A column that tracks the running total of [incrementField]: seeded equal
  /// to it when the row is created and grown by every "add amount" action.
  /// Maintained automatically (not a typed form field), so it can't drift.
  final String? cumulativeIncrementField;

  /// If set, rows get an action that OVERWRITES this numeric column with a
  /// user-entered value (e.g. updating an investment's current market value).
  /// Unlike [incrementField] this replaces rather than adds.
  final String? setField;
  final String? setLabel;

  /// If set, rows get a "payment" action that REDUCES this numeric column by a
  /// user-entered amount (e.g. paying down a creditor or loan balance).
  final String? decrementField;
  final String? decrementLabel;

  /// Verb on the dialog's confirm button. Defaults to "Pay", which is right
  /// for a debt and wrong for a savings withdrawal — the same dialog serves
  /// both, so the module says which word it wants.
  final String? decrementConfirm;

  /// If set (with [decrementField]), one period of interest at this annual-%
  /// column is accrued onto the balance before the payment is subtracted.
  final String? interestRateField;

  /// If set, the "add payment" dialog shows a due-date picker (pre-filled from
  /// this column) and writes the chosen date back to it, so the next due date
  /// can be updated alongside a payment (e.g. creditors/debtors).
  final String? dueDateField;

  /// For the "add payment" action: true = money comes IN to the chosen account
  /// (debtor repays you); false = money goes OUT (you pay a creditor/loan).
  final bool paymentInflow;

  /// If true, the create form shows an optional account picker and records the
  /// initial [amount] as a cash movement against that account: money OUT for
  /// what you lent (debtors), money IN for what you borrowed (creditors).
  /// Direction is the opposite of [paymentInflow]. Applied on creation only —
  /// edits don't re-post a movement, so balances aren't double-counted.
  final bool principalAccount;

  /// If set, the create form shows an OPTIONAL "paid from account" picker. When
  /// an account is chosen, the value entered in this numeric field is recorded
  /// as money OUT of that account (e.g. cash spent to buy an investment).
  /// Applied on creation only — edits don't re-post, so balances aren't
  /// double-counted. Unlike [principalAccount] this is optional and reads the
  /// configured field instead of a hardcoded `amount`.
  final String? principalAccountField;

  /// Status column (`open` / `partial` / `settled`) for settle-able modules
  /// (debtors/creditors). When set, payments move the status automatically and
  /// the row menu gains "Mark as settled" / "Reopen" actions.
  final String? statusField;

  /// Column holding the full original amount owed, captured at creation so the
  /// row can show "paid X of Y" as the balance is paid down part by part.
  final String? originalAmountField;

  /// Column recording the account that closed the debt — where the money was
  /// received (debtor) or paid from (creditor). Set from the final settling
  /// payment, or chosen when manually marking the row settled.
  final String? settledAccountField;

  /// If set, each payment is logged as a row here (a per-person installment
  /// ledger), viewable via the "Payments" action. Rows are tagged with
  /// `parent_id` (= the source row id) and `parent_type` (= the source table).
  final String? paymentsTable;

  /// If true, the EntityScreen shows an export menu (CSV / PDF) in the AppBar.
  final bool exportable;

  /// If true, the EntityScreen shows a date-range filter row (Today/Week/Month/
  /// Year/All/Custom). Filters and exports use the row's `date` field.
  final bool dateFiltered;

  /// If true, rows carrying a symbol and a quantity are repriced from the
  /// market when the screen opens and on pull-to-refresh. Rows without both
  /// are left alone, so enabling this never disturbs a hand-kept module.
  final bool liveTracked;

  /// If true, rows can be sold back: units come off the holding and the
  /// proceeds land in a chosen account. The return leg of a module whose
  /// creation takes money out of an account.
  final bool redeemable;

  /// Tables holding child rows keyed by `parent_id` on this row. They are
  /// deleted with it — an installment ledger or payment history whose parent
  /// is gone is unreachable data that nothing will ever clean up.
  final List<String> cascadeTables;

  /// Extra keys written on creation only, derived from what was typed.
  ///
  /// For values that are the app's business rather than the user's — a SIP's
  /// cash boundary date, for instance, which must record when the row started
  /// existing and can never be edited afterwards.
  final Json Function(Json values)? seedOnCreate;

  /// Dashboard header shown above the list: headline figures, a chart, and an
  /// optional per-row breakdown. Null means no header.
  ///
  /// The range chips appear whenever this is set *or* [dateFiltered] is — but
  /// they only filter the list when [dateFiltered] is true. Savings goals,
  /// loans and bills carry no `date` column, so filtering their rows by range
  /// would blank the page; on those modules the range moves the dashboard
  /// alone. Stat labels carry the distinction: "Contributed" for an
  /// event-derived figure that follows the range, plain "Saved" for a current
  /// total that does not.
  final DashboardSpec? dashboard;
}
