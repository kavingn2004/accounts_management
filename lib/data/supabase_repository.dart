import 'package:supabase_flutter/supabase_flutter.dart';

import 'finance_math.dart';
import 'finance_repository.dart';

/// Supabase-backed implementation of [FinanceRepository].
///
/// Each app "table" is a Postgres table with the record's fields stored in a
/// JSONB `data` column (see supabase/schema.sql). This mirrors the on-device
/// model exactly, so all balance/dashboard math is reused from [FinanceMath].
/// Row Level Security scopes every query to the signed-in user, but we also set
/// `user_id` on insert to satisfy the insert policy.
class SupabaseRepository extends FinanceRepository {
  SupabaseRepository(this._client);

  final SupabaseClient _client;

  String get _uid => _client.auth.currentUser!.id;

  SupabaseQueryBuilder _table(String table) => _client.from(table);

  /// Flatten a stored row ({id, data, created_at}) into the flat map the app
  /// expects, with the real primary key exposed as `id`.
  Json _flatten(Map<String, dynamic> row) {
    final data = (row['data'] as Map?)?.cast<String, dynamic>() ?? {};
    return {
      ...data,
      'id': row['id'],
      'created_at': row['created_at'],
    };
  }

  @override
  Future<List<Json>> list(
    String table, {
    String orderBy = 'created_at',
    bool ascending = false,
  }) async {
    // Insertion order (newest first) matches the on-device store; the app does
    // its own date-range filtering/sorting on the returned rows.
    final rows = await _table(table)
        .select('id, data, created_at')
        .order('created_at', ascending: false);
    return rows.map((r) => _flatten(r)).toList();
  }

  @override
  Future<void> insert(String table, Json values) async {
    final data = {...values}..remove('id');
    await _table(table).insert({'user_id': _uid, 'data': data});
  }

  @override
  Future<void> update(String table, String id, Json values) async {
    // Merge into the existing JSON document (same semantics as the local store).
    final current = await _table(table).select('data').eq('id', id).single();
    final merged = {
      ...((current['data'] as Map?)?.cast<String, dynamic>() ?? {}),
      ...values,
    }..remove('id');
    await _table(table).update({'data': merged}).eq('id', id);
  }

  @override
  Future<void> delete(String table, String id) async {
    await _table(table).delete().eq('id', id);
  }

  @override
  Future<List<Json>> accountsWithBalances() async {
    final snapshot = await _fetchAll([
      'accounts',
      'income',
      'expenses',
      'transfers',
      'cash_moves',
    ]);
    return FinanceMath.accountsWithBalances(
      accounts: snapshot['accounts']!,
      balances: _balances(snapshot),
    );
  }

  @override
  Future<Json?> dashboard() async {
    final snapshot = await _fetchAll([
      'accounts',
      'income',
      'expenses',
      'transfers',
      'cash_moves',
      'investments',
      'savings_goals',
      'debtors',
      'creditors',
      'loans',
      'bills',
    ]);
    return FinanceMath.dashboard(
      balances: _balances(snapshot),
      income: snapshot['income']!,
      expenses: snapshot['expenses']!,
      investments: snapshot['investments']!,
      savingsGoals: snapshot['savings_goals']!,
      debtors: snapshot['debtors']!,
      creditors: snapshot['creditors']!,
      loans: snapshot['loans']!,
      bills: snapshot['bills']!,
    );
  }

  Map<String, double> _balances(Map<String, List<Json>> s) =>
      FinanceMath.balanceMap(
        accounts: s['accounts']!,
        income: s['income']!,
        expenses: s['expenses']!,
        transfers: s['transfers']!,
        cashMoves: s['cash_moves']!,
      );

  /// Fetch several tables concurrently, returning a name -> rows map.
  Future<Map<String, List<Json>>> _fetchAll(List<String> tables) async {
    final results = await Future.wait(tables.map(list));
    return {for (var i = 0; i < tables.length; i++) tables[i]: results[i]};
  }
}
