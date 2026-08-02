import 'package:intl/intl.dart';

import 'finance_repository.dart';

/// Table holding the ledger. Every module writes here — see [ModuleEvent].
const String moduleEventsTable = 'module_events';

/// What a [ModuleEvent] did to the field it names.
enum EventKind {
  /// The row was created; [ModuleEvent.balanceAfter] is its opening value.
  open,

  /// A value was added (savings contribution, further investment).
  increment,

  /// A value was paid down (creditor payment, loan EMI).
  decrement,

  /// A value was overwritten wholesale (investment revaluation, settlement).
  set,
}

/// One value-changing action on one row of one module.
///
/// The app stores no history otherwise: "Add to savings" reads a column, adds
/// to it, and writes it straight back. Without this ledger a growth chart has
/// nothing to draw.
class ModuleEvent {
  const ModuleEvent({
    required this.parentId,
    required this.parentType,
    required this.field,
    required this.kind,
    required this.amount,
    required this.balanceAfter,
    required this.date,
    this.account,
    this.note,
  });

  /// Id of the source row, and the table it lives in.
  final String parentId;
  final String parentType;

  /// Which column moved — 'saved_amount', 'current_value', 'outstanding'.
  final String field;
  final EventKind kind;

  /// The delta. For [EventKind.set] this is the new value, since there is no
  /// meaningful delta when a figure is replaced rather than adjusted.
  final double amount;

  /// The field's value immediately after the action.
  ///
  /// This is the load-bearing column. A growth curve is read as a step
  /// function through recorded balances, never re-derived forward from an
  /// opening figure — forward derivation drifts the moment a row is edited by
  /// hand, and the chart would then contradict the total printed above it.
  final double balanceAfter;

  final DateTime date;

  /// The account the cash moved through, when the user chose one.
  final String? account;
  final String? note;

  Json toJson() => {
        'parent_id': parentId,
        'parent_type': parentType,
        'field': field,
        'kind': kind.name,
        'amount': amount,
        'balance_after': balanceAfter,
        'date': DateFormat('yyyy-MM-dd').format(date),
        if (account != null) 'account': account,
        if (note != null) 'note': note,
      };
}

/// Readers for stored event rows. The storage shape is described here and
/// nowhere else, so a column rename is a one-file change.
class Events {
  const Events._();

  static double amount(Json e) => (e['amount'] as num?)?.toDouble() ?? 0;

  static double balanceAfter(Json e) =>
      (e['balance_after'] as num?)?.toDouble() ?? 0;

  static String field(Json e) => (e['field'] ?? '').toString();
  static String parentId(Json e) => (e['parent_id'] ?? '').toString();
  static String parentType(Json e) => (e['parent_type'] ?? '').toString();
  static String kind(Json e) => (e['kind'] ?? '').toString();

  /// Parse the stored `yyyy-MM-dd`, or null when it is missing or malformed.
  /// Callers skip null-dated events rather than counting them at epoch, which
  /// would plant a spike at the left edge of every chart.
  static DateTime? date(Json e) {
    final v = e['date'];
    if (v == null) return null;
    final d = DateTime.tryParse(v.toString());
    if (d == null) return null;
    return d.isUtc ? d.toLocal() : d;
  }

  /// Events for one module's field, oldest first, undated rows dropped.
  static List<Json> forField(
    List<Json> events,
    String parentType,
    String field,
  ) {
    final out = events
        .where((e) =>
            Events.parentType(e) == parentType &&
            Events.field(e) == field &&
            date(e) != null)
        .toList();
    out.sort((a, b) => date(a)!.compareTo(date(b)!));
    return out;
  }
}

/// Append an event to the ledger.
///
/// Best-effort by design: the value update this describes has already been
/// committed, so a failure here must not surface as an error or roll anything
/// back. A missing event costs one point on a chart; a rolled-back
/// contribution costs the user their data.
Future<void> logModuleEvent(FinanceRepository repo, ModuleEvent event) async {
  try {
    await repo.insert(moduleEventsTable, event.toJson());
  } catch (_) {
    // Intentionally swallowed — see the doc comment above.
  }
}
