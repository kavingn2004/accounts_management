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
