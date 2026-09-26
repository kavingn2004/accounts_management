import 'dart:async';

import 'finance_repository.dart';
import 'local_store.dart';

/// What one write did to one row.
enum HistoryOpKind { insert, update, delete }

/// A single row write inside a [HistoryEntry], with enough of the row kept to
/// reverse it: the new row for an insert, the old row for an update or delete.
class HistoryOp {
  const HistoryOp({
    required this.kind,
    required this.table,
    required this.id,
    this.before,
    this.after,
  });

  final HistoryOpKind kind;
  final String table;
  final String id;
  final Json? before;
  final Json? after;

  /// The row this one hangs off (a payment's debt, a ledger event's goal), if
  /// any. Used to spot a newer action that depends on a row this one created.
  String? get parentId =>
      ((after ?? before)?['parent_id'])?.toString();

  Json toJson() => {
        'kind': kind.name,
        'table': table,
        'id': id,
        if (before != null) 'before': before,
        if (after != null) 'after': after,
      };

  factory HistoryOp.fromJson(Json j) => HistoryOp(
        kind: HistoryOpKind.values.byName(j['kind'] as String),
        table: j['table'] as String,
        id: j['id'].toString(),
        before: j['before'] == null ? null : Json.from(j['before'] as Map),
        after: j['after'] == null ? null : Json.from(j['after'] as Map),
      );
}

/// One user action — "Added expense", "Paid loan" — and every row it wrote.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.label,
    required this.table,
    required this.at,
    required this.ops,
    this.undone = false,
    this.rebuilt = false,
    this.undoable = true,
  });

  final String id;
  final String label;

  /// The module the action belongs to, for the icon on the History screen.
  final String table;
  final DateTime at;
  final List<HistoryOp> ops;
  final bool undone;

  /// Pieced together from the rows' creation times rather than recorded as it
  /// happened (see HistoryBackfill).
  final bool rebuilt;

  /// False for a rebuilt entry that was only part of a change — a payment
  /// that also lowered a balance, say — which can't be reversed from the rows
  /// alone. Shown for reference only.
  final bool undoable;

  HistoryEntry copyWith({bool? undone}) => HistoryEntry(
        id: id,
        label: label,
        table: table,
        at: at,
        ops: ops,
        undone: undone ?? this.undone,
        rebuilt: rebuilt,
        undoable: undoable,
      );

  Json toJson() => {
        'id': id,
        'label': label,
        'table': table,
        'at': at.toIso8601String(),
        'ops': ops.map((o) => o.toJson()).toList(),
        'undone': undone,
        if (rebuilt) 'rebuilt': true,
        if (!undoable) 'undoable': false,
      };

  factory HistoryEntry.fromJson(Json j) => HistoryEntry(
        id: j['id'].toString(),
        label: (j['label'] ?? '').toString(),
        table: (j['table'] ?? '').toString(),
        at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
        ops: ((j['ops'] as List?) ?? const [])
            .map((o) => HistoryOp.fromJson(Json.from(o as Map)))
            .toList(),
        undone: j['undone'] == true,
        rebuilt: j['rebuilt'] == true,
        undoable: j['undoable'] != false,
      );
}

/// The on-device list of recent actions, newest first, covering the last
/// [keepFor].
///
/// Kept on the device even with cloud sync on: it is an undo buffer for this
/// phone, not part of the user's financial records.
class HistoryLog {
  HistoryLog(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final LocalStore _store;
  final DateTime Function() _now;

  static const keepFor = Duration(days: 14);

  /// Backstop against a runaway week filling device storage.
  static const hardCap = 1000;

  List<HistoryEntry> entries() =>
      _store.readHistory().map(HistoryEntry.fromJson).toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  Future<void> add(HistoryEntry entry) => addAll([entry]);

  Future<void> addAll(List<HistoryEntry> list) =>
      _save([...list, ...entries()]);

  Future<void> markUndone(String id) => _save([
        for (final e in entries()) e.id == id ? e.copyWith(undone: true) : e,
      ]);

  Future<void> clear() => _save(const []);

  Future<void> _save(List<HistoryEntry> list) {
    final since = _now().subtract(keepFor);
    final kept = list.where((e) => !e.at.isBefore(since)).toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    return _store.writeHistory(
        kept.take(hardCap).map((e) => e.toJson()).toList());
  }
}

/// Wraps the real repository and records the writes made inside an [action]
/// so they can be reversed later.
///
/// Writes made outside an action are passed straight through and never
/// recorded. That keeps background work — the SIP engine settling units, the
/// price sync revaluing holdings — out of the user's History.
class HistoryRepository extends FinanceRepository {
  HistoryRepository(this._inner, this._log, {this.childTables = const []});

  final FinanceRepository _inner;
  final HistoryLog _log;

  /// Tables whose rows point at a parent through `parent_id`. Undoing the
  /// parent's creation removes them too, the way deleting it does.
  final List<String> childTables;

  static final _zoneKey = Object();
  int _seq = 0;

  HistoryLog get log => _log;

  List<HistoryOp>? get _ops => Zone.current[_zoneKey] as List<HistoryOp>?;

  /// Run [body] and record every write it makes as one History entry.
  ///
  /// An action started inside another one joins it, so a helper that records
  /// its own action can still be called from a bigger one.
  Future<void> action({
    required String label,
    required String table,
    required Future<void> Function() body,
  }) async {
    if (_ops != null || _undoable == null) return body();
    final ops = <HistoryOp>[];
    try {
      await runZoned(body, zoneValues: {_zoneKey: ops});
    } finally {
      // Whatever landed before a failure is still worth being able to undo.
      if (ops.isNotEmpty) {
        await _log.add(HistoryEntry(
          id: 'h${DateTime.now().microsecondsSinceEpoch}${_seq++}',
          label: label,
          table: table,
          at: DateTime.now(),
          ops: ops,
        ));
      }
    }
  }

  /// Whether [entry] can be undone right now. It can't once it has been, or
  /// while a newer, still-live entry touched one of the same rows — undoing
  /// the older one first would quietly throw that later change away.
  bool canUndo(HistoryEntry entry, [List<HistoryEntry>? all]) {
    if (entry.undone || !entry.undoable) return false;
    final entries = all ?? _log.entries();
    for (final newer in entries) {
      if (newer.id == entry.id) break;
      if (newer.undone) continue;
      if (_overlaps(entry, newer)) return false;
    }
    return true;
  }

  static bool _overlaps(HistoryEntry older, HistoryEntry newer) {
    for (final a in older.ops) {
      for (final b in newer.ops) {
        if (a.table == b.table && a.id == b.id) return true;
        if (a.kind == HistoryOpKind.insert && b.parentId == a.id) return true;
      }
    }
    return false;
  }

  /// Reverse every write of the entry, last first.
  Future<void> undo(String entryId) async {
    final entries = _log.entries();
    final entry = entries.firstWhere((e) => e.id == entryId);
    if (!canUndo(entry, entries)) {
      throw StateError('Undo the newer change first');
    }
    for (final op in entry.ops.reversed) {
      switch (op.kind) {
        case HistoryOpKind.insert:
          await _inner.delete(op.table, op.id);
          await _deleteChildren(op.id);
        case HistoryOpKind.update:
        case HistoryOpKind.delete:
          await _undoable!.restore(op.table, op.before!);
      }
    }
    await _log.markUndone(entryId);
  }

  Future<void> _deleteChildren(String parentId) async {
    for (final table in childTables) {
      try {
        for (final child in await _inner.list(table)) {
          if ((child['parent_id'] ?? '').toString() != parentId) continue;
          await _inner.delete(table, child['id'].toString());
        }
      } catch (_) {
        // A table that does not exist has nothing to clean up.
      }
    }
  }

  Future<Json?> _find(String table, String id) async {
    for (final r in await _inner.list(table)) {
      if (r['id'].toString() == id) return Json.from(r);
    }
    return null;
  }

  @override
  Future<Json?> dashboard() => _inner.dashboard();

  @override
  Future<List<Json>> list(
    String table, {
    String orderBy = 'created_at',
    bool ascending = false,
  }) =>
      _inner.list(table, orderBy: orderBy, ascending: ascending);

  @override
  Future<List<Json>> accountsWithBalances() => _inner.accountsWithBalances();

  UndoableRepository? get _undoable =>
      _inner is UndoableRepository ? _inner as UndoableRepository : null;

  @override
  Future<void> insert(String table, Json values) async {
    final inner = _undoable;
    if (inner == null) return _inner.insert(table, values);
    final id = await inner.insertReturningId(table, values);
    final ops = _ops;
    if (ops != null) {
      ops.add(HistoryOp(
        kind: HistoryOpKind.insert,
        table: table,
        id: id,
        after: {...values, 'id': id},
      ));
    }
  }

  @override
  Future<void> update(String table, String id, Json values) async {
    final ops = _ops;
    final before = ops == null ? null : await _find(table, id);
    await _inner.update(table, id, values);
    if (ops != null && before != null) {
      ops.add(HistoryOp(
        kind: HistoryOpKind.update,
        table: table,
        id: id,
        before: before,
        after: {...before, ...values},
      ));
    }
  }

  @override
  Future<void> delete(String table, String id) async {
    final ops = _ops;
    final before = ops == null ? null : await _find(table, id);
    await _inner.delete(table, id);
    if (ops != null && before != null) {
      ops.add(HistoryOp(
        kind: HistoryOpKind.delete,
        table: table,
        id: id,
        before: before,
      ));
    }
  }
}

/// Record [body] as one History entry when [repo] keeps history; otherwise
/// (a test fake, say) just run it.
Future<void> recordAction(
  FinanceRepository repo, {
  required String label,
  required String table,
  required Future<void> Function() body,
}) =>
    repo is HistoryRepository
        ? repo.action(label: label, table: table, body: body)
        : body();
