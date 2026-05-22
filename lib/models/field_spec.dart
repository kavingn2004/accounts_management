import 'package:flutter/material.dart';

import '../data/finance_repository.dart';

enum FieldType { text, number, date, select }

/// Describes one editable field of an entity (drives the add form).
class FieldSpec {
  const FieldSpec(
    this.key,
    this.label, {
    this.type = FieldType.text,
    this.required = false,
    this.options,
    this.optionsTable,
  });

  final String key;
  final String label;
  final FieldType type;
  final bool required;
  final List<String>? options; // for FieldType.select (static)

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
    required this.color,
    required this.fields,
    required this.titleOf,
    this.subtitleOf,
    this.trailingOf,
    this.readOnly = false,
    this.orderBy = 'created_at',
    this.incrementField,
    this.incrementAlsoField,
    this.incrementLabel,
    this.decrementField,
    this.decrementLabel,
    this.interestRateField,
    this.paymentInflow = false,
  });

  final String table;
  final String title;
  final IconData icon;
  final Color color;
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

  /// If set, rows get a "payment" action that REDUCES this numeric column by a
  /// user-entered amount (e.g. paying down a creditor or loan balance).
  final String? decrementField;
  final String? decrementLabel;

  /// If set (with [decrementField]), one period of interest at this annual-%
  /// column is accrued onto the balance before the payment is subtracted.
  final String? interestRateField;

  /// For the "add payment" action: true = money comes IN to the chosen account
  /// (debtor repays you); false = money goes OUT (you pay a creditor/loan).
  final bool paymentInflow;
}
