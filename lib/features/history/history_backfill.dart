import '../../core/formatters.dart';
import '../../data/finance_repository.dart';
import '../../data/history.dart';
import '../../data/module_event.dart';
import '../../models/field_spec.dart';
import '../registry.dart';
import 'history_label.dart';

/// Pieces together the last [HistoryLog.keepFor] of History from what the
/// rows themselves remember: every row carries its `created_at`.
///
/// That is enough to rebuild adds, which can be undone like any other — the
/// row goes, along with the account movement written in the same save. It is
/// not enough for edits or deletes: the store keeps only the current version
/// of a row, so those were never anywhere to find.
///
/// Safe to run repeatedly. A row already covered by an entry is skipped, so
/// actions recorded live are never duplicated, and a row whose rebuilt add was
/// undone is gone and cannot come back.
class HistoryBackfill {
  HistoryBackfill(this._repo, this._log, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final FinanceRepository _repo;
  final HistoryLog _log;
  final DateTime Function() _now;

  /// How far apart two writes of one save can land. Supabase stamps each row
  /// on arrival, so a row and its account movement are a request apart.
  static const _sameSave = Duration(seconds: 10);

  int _seq = 0;

  /// Add the rebuilt entries to the log; returns how many were added.
  Future<int> run() async {
    final since = _now().subtract(HistoryLog.keepFor);
    final seen = {
      for (final e in _log.entries())
        for (final op in e.ops) '${op.table}:${op.id}',
    };

    bool fresh(String table, Json r) {
      final at = _at(r);
      return at != null &&
          !at.isBefore(since) &&
          !seen.contains('$table:${r['id']}');
    }

    final cash = (await _read('cash_moves'))
        .where((r) => fresh('cash_moves', r))
        .toList();
    final usedCash = <String>{};

    /// Account movements written in the same save as a row at [at].
    List<Json> cashNear(DateTime at, bool Function(Json) matches) {
      final hits = cash.where((c) {
        if (usedCash.contains(c['id'].toString())) return false;
        final cAt = _at(c);
        return cAt != null &&
            cAt.difference(at).abs() <= _sameSave &&
            matches(c);
      }).toList();
      usedCash.addAll(hits.map((c) => c['id'].toString()));
      return hits;
    }

    final built = <HistoryEntry>[];
    final rowsByTable = <String, Map<String, Json>>{};

    // 1. Adds. The principal or paid-from movement of a new debt or holding is
    //    noted with the module's title (see EntityScreen's sheet).
    for (final m in Modules.all) {
      final rows = await _read(m.table);
      rowsByTable[m.table] = {for (final r in rows) r['id'].toString(): r};
      for (final r in rows.where((r) => fresh(m.table, r))) {
        final at = _at(r)!;
        final moves = cashNear(at, (c) => c['note'] == m.title);
        built.add(_entry(
          label: historyLabel(m, 'Added', r),
          table: m.table,
          at: at,
          ops: [_insert(m.table, r), for (final c in moves) _insert('cash_moves', c)],
        ));
      }
    }
    for (final r in (await _read('accounts')).where((r) => fresh('accounts', r))) {
      built.add(_entry(
        label: 'Added account · ${r['name'] ?? ''}',
        table: 'accounts',
        at: _at(r)!,
        ops: [_insert('accounts', r)],
      ));
    }

    // 2. Changes to an existing row — money added to a goal, a payment, a
    //    settlement. The ledger event says what happened, but not what the
    //    row looked like before, so these are shown and not undone.
    final titles = {for (final m in Modules.all) m.title};
    final payments = (await _read('debt_payments'))
        .where((r) => fresh('debt_payments', r))
        .toList();
    final usedPayments = <String>{};
    final events = (await _read(moduleEventsTable)).where((e) {
      if (!fresh(moduleEventsTable, e) || e['kind'] == EventKind.open.name) {
        return false;
      }
      // Background revaluations carry their price source as the note and no
      // account; only what the user did belongs here.
      return titles.contains(e['note']) || e['account'] != null;
    });
    for (final e in events) {
      final at = _at(e)!;
      final parentId = e['parent_id']?.toString();
      final m = _module(e['parent_type']?.toString());
      final parent = rowsByTable[m?.table]?[parentId];
      final paid = payments.where((p) {
        final pAt = _at(p);
        return !usedPayments.contains(p['id'].toString()) &&
            p['parent_id']?.toString() == parentId &&
            pAt != null &&
            pAt.difference(at).abs() <= _sameSave;
      }).toList();
      usedPayments.addAll(paid.map((p) => p['id'].toString()));
      final moves = e['account'] == null
          ? const <Json>[]
          : cashNear(at, (c) => c['account'] == e['account']);
      built.add(_entry(
        label: _eventLabel(e, m, parent),
        table: m?.table ?? moduleEventsTable,
        at: at,
        undoable: false,
        ops: [
          _insert(moduleEventsTable, e),
          for (final p in paid) _insert('debt_payments', p),
          for (final c in moves) _insert('cash_moves', c),
        ],
      ));
    }
    // A payment whose ledger event is missing (older rows, or no ledger table).
    for (final p in payments.where((p) => !usedPayments.contains(p['id'].toString()))) {
      final at = _at(p)!;
      final m = _module(p['parent_type']?.toString());
      final parent = rowsByTable[m?.table]?[p['parent_id']?.toString()];
      final moves = p['account'] == null
          ? const <Json>[]
          : cashNear(at, (c) => c['account'] == p['account']);
      built.add(_entry(
        label: [
          'Payment',
          if (m != null) m.title,
          if (parent != null && m != null) m.titleOf(parent),
          money(p['amount'] as num?),
        ].join(' · '),
        table: m?.table ?? 'debt_payments',
        at: at,
        undoable: false,
        ops: [
          _insert('debt_payments', p),
          for (final c in moves) _insert('cash_moves', c),
        ],
      ));
    }

    // 3. Whatever account movements are left. Ones tied to an SIP or a
    //    redemption belong to a change that can't be rebuilt; the rest stand
    //    alone — typically the money of a debt or holding that has since been
    //    deleted — and undoing one simply removes the movement.
    for (final c in cash.where((c) => !usedCash.contains(c['id'].toString()))) {
      final note = (c['note'] ?? '').toString();
      final partOfSomething = note.startsWith('Redeemed ') ||
          note.endsWith(' SIP') ||
          note.endsWith(' installment');
      final amount = (c['amount'] as num?) ?? 0;
      built.add(_entry(
        label: [
          'Account movement',
          (c['account'] ?? '').toString(),
          '${amount >= 0 ? '+' : ''}${money(amount)}',
          if (note.isNotEmpty) note,
        ].where((s) => s.isNotEmpty).join(' · '),
        table: 'accounts',
        at: _at(c)!,
        undoable: !partOfSomething,
        ops: [_insert('cash_moves', c)],
      ));
    }

    if (built.isNotEmpty) await _log.addAll(built);
    return built.length;
  }

  Future<List<Json>> _read(String table) async {
    try {
      return await _repo.list(table);
    } catch (_) {
      // A table missing from this project has nothing to rebuild.
      return const [];
    }
  }

  static DateTime? _at(Json r) =>
      DateTime.tryParse((r['created_at'] ?? '').toString())?.toLocal();

  static EntityConfig? _module(String? table) {
    for (final m in Modules.all) {
      if (m.table == table) return m;
    }
    return null;
  }

  static String _eventLabel(Json e, EntityConfig? m, Json? parent) {
    final amount = money(e['amount'] as num?);
    final what = [
      if (m != null) m.title,
      if (parent != null && m != null) m.titleOf(parent),
    ].join(' · ');
    return switch (e['kind']) {
      'increment' => 'Added $amount to $what',
      'decrement' => 'Paid $amount on $what',
      _ => 'Set $what to $amount',
    };
  }

  static HistoryOp _insert(String table, Json row) => HistoryOp(
        kind: HistoryOpKind.insert,
        table: table,
        id: row['id'].toString(),
        after: Json.from(row),
      );

  HistoryEntry _entry({
    required String label,
    required String table,
    required DateTime at,
    required List<HistoryOp> ops,
    bool undoable = true,
  }) =>
      HistoryEntry(
        id: 'r${at.microsecondsSinceEpoch}${_seq++}',
        label: label,
        table: table,
        at: at,
        ops: ops,
        rebuilt: true,
        undoable: undoable,
      );
}
