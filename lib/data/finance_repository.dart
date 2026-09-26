/// One database row. Named `Json` to avoid clashing with Flutter's `Row` widget.
typedef Json = Map<String, dynamic>;

/// Storage-agnostic data interface used across the app. The concrete
/// implementation is [LocalRepository] (on-device storage).
abstract class FinanceRepository {
  /// Single-row dashboard snapshot (net worth + this-month income/expense).
  Future<Json?> dashboard();

  /// All rows of a table, newest first.
  Future<List<Json>> list(
    String table, {
    String orderBy = 'created_at',
    bool ascending = false,
  });

  Future<void> insert(String table, Json values);
  Future<void> update(String table, String id, Json values);
  Future<void> delete(String table, String id);

  /// Accounts with their live computed balance (key 'balance' added per row).
  Future<List<Json>> accountsWithBalances();
}

/// The two extra writes History's undo needs. Kept apart from
/// [FinanceRepository] so lightweight fakes don't have to implement them; a
/// repository without them simply records nothing to undo.
abstract interface class UndoableRepository {
  /// Insert and return the new row's id.
  Future<String> insertReturningId(String table, Json values);

  /// Put [row] back exactly as given — same id, same `created_at` — replacing
  /// the current row with that id or re-creating it.
  Future<void> restore(String table, Json row);
}
