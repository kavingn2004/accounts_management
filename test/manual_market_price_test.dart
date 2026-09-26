import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/services/quotes/investment_sync.dart';
import 'package:accounts_app/services/quotes/quote_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A price you type in yourself, for holdings the app cannot or should not
/// fetch: an unlisted fund, a gold rate from your own jeweller, or simply a
/// figure you would rather control.
class _Repo implements FinanceRepository {
  final List<(String, String, Json)> updates = [];

  @override
  Future<void> update(String table, String id, Json values) async =>
      updates.add((table, id, values));

  @override
  Future<void> insert(String table, Json values) async {}
  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> list(String table,
          {String orderBy = 'created_at', bool ascending = false}) async =>
      [];
  @override
  Future<List<Json>> accountsWithBalances() async => [];
  @override
  Future<void> delete(String table, String id) async {}
}

int _networkCalls = 0;

InvestmentSync _sync(_Repo repo, {String body = '{}', int status = 200}) {
  _networkCalls = 0;
  return InvestmentSync(
    repo: repo,
    quotes: QuoteService(
      client: MockClient((_) async {
        _networkCalls++;
        return http.Response(body, status);
      }),
    ),
  );
}

const _navBody = '{"data":[{"date":"02-08-2026","nav":"90.00000"}]}';

void main() {
  test('a typed price values the holding without any network access',
      () async {
    final repo = _Repo();
    final rows = [
      {
        'id': '1',
        'name': 'mid cap',
        'type': 'mf',
        'quantity': 5.87,
        'market_price': 85.20,
      }
    ];

    final out = await _sync(repo).run(rows);

    expect(_networkCalls, 0, reason: 'a price you supplied needs no lookup');
    expect(rows.single['current_value'], closeTo(500.12, 0.01)); // 85.20 × 5.87
    expect(out.priced.single.source, 'Manual price');
    expect(repo.updates.single.$3['last_price'], 85.20);
  });

  test('it works for every type, not just gold', () async {
    final repo = _Repo();
    final rows = [
      {'id': '1', 'name': 'Gold', 'type': 'gold', 'quantity': 20,
        'market_price': 11500},
      {'id': '2', 'name': 'Unlisted co', 'type': 'stock', 'quantity': 100,
        'market_price': 42.5},
      {'id': '3', 'name': 'Alt coin', 'type': 'crypto', 'quantity': 3,
        'market_price': 1200},
    ];

    await _sync(repo).run(rows);

    expect(_networkCalls, 0);
    expect(rows[0]['current_value'], 230000.0);
    expect(rows[1]['current_value'], 4250.0);
    expect(rows[2]['current_value'], 3600.0);
  });

  test('a typed price overrides a symbol that would have been fetched',
      () async {
    final repo = _Repo();
    final rows = [
      {
        'id': '1',
        'name': 'mid cap',
        'type': 'mf',
        'symbol': '122639',
        'quantity': 10,
        'market_price': 85.20,
      }
    ];

    await _sync(repo, body: _navBody).run(rows);

    expect(_networkCalls, 0, reason: 'what you typed wins, deliberately');
    expect(rows.single['current_value'], 852.0); // not 900 from the NAV
  });

  test('clearing the typed price hands the row back to live pricing',
      () async {
    final repo = _Repo();
    final rows = [
      {
        'id': '1',
        'name': 'mid cap',
        'type': 'mf',
        'symbol': '122639',
        'quantity': 10,
        // market_price removed by the user
      }
    ];

    await _sync(repo, body: _navBody).run(rows);

    expect(_networkCalls, 1);
    expect(rows.single['current_value'], 900.0); // 90.00 NAV × 10
  });

  test('a price without a quantity values nothing — there is nothing to '
      'multiply', () async {
    final repo = _Repo();
    final rows = [
      {'id': '1', 'name': 'mid cap', 'type': 'mf', 'market_price': 85.20}
    ];

    final out = await _sync(repo).run(rows);

    expect(out.isIdle, isTrue);
    expect(repo.updates, isEmpty);
  });

  test('a zero or negative price is ignored, not treated as free', () async {
    final repo = _Repo();
    final rows = [
      {'id': '1', 'name': 'mid cap', 'type': 'mf', 'quantity': 10,
        'market_price': 0},
    ];

    final out = await _sync(repo).run(rows);

    expect(out.isIdle, isTrue, reason: 'no symbol either, so nothing to do');
    expect(repo.updates, isEmpty);
  });
}
