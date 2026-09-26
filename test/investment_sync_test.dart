import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/module_event.dart';
import 'package:accounts_app/services/quotes/investment_sync.dart';
import 'package:accounts_app/services/quotes/quote_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Records what the sync writes, so a test can assert on the rows that were
/// touched *and* on the rows that were left alone.
class _RecordingRepo implements FinanceRepository {
  final List<(String table, String id, Json values)> updates = [];
  final List<Json> inserted = [];

  @override
  Future<void> update(String table, String id, Json values) async {
    updates.add((table, id, values));
  }

  @override
  Future<void> insert(String table, Json values) async {
    inserted.add({'table': table, ...values});
  }

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

/// One canned body per host, plus a count of how many calls were made.
class _Net {
  int calls = 0;
  final List<Uri> urls = [];

  http.Client client(Map<String, String> byHostPath, {int status = 200}) {
    return MockClient((req) async {
      calls++;
      urls.add(req.url);
      for (final entry in byHostPath.entries) {
        if (req.url.toString().contains(entry.key)) {
          return http.Response(entry.value, status);
        }
      }
      return http.Response('{}', 404);
    });
  }
}

const _yahoo = '{"chart":{"result":[{"meta":{"currency":"INR",'
    '"regularMarketPrice":100.0,"regularMarketTime":1754130600}}]}}';
const _gecko = '{"bitcoin":{"inr":5000000},"pax-gold":{"inr":311034.768}}';

Json _row(
  String id,
  String name,
  String type, {
  String? symbol,
  num? quantity,
  num? currentValue,
  num? marketPrice,
  num? lastPrice,
  String? priceAt,
}) =>
    {
      'id': id,
      'name': name,
      'type': type,
      if (symbol != null) 'symbol': symbol,
      if (quantity != null) 'quantity': quantity,
      if (currentValue != null) 'current_value': currentValue,
      if (marketPrice != null) 'market_price': marketPrice,
      if (lastPrice != null) 'last_price': lastPrice,
      if (priceAt != null) 'price_at': priceAt,
    };

InvestmentSync _sync(_RecordingRepo repo, http.Client client,
        {DateTime Function()? clock}) =>
    InvestmentSync(
      repo: repo,
      quotes: QuoteService(client: client, clock: clock),
      clock: clock,
    );

void main() {
  test('values a holding as price × quantity and writes it through', () async {
    final repo = _RecordingRepo();
    final net = _Net();
    final rows = [
      _row('1', 'Reliance', 'stock',
          symbol: 'RELIANCE', quantity: 12, currentValue: 1000),
    ];

    final out = await _sync(repo, net.client({'query1': _yahoo})).run(rows);

    expect(out.checked, 1);
    expect(out.updated, 1);
    expect(out.failures, isEmpty);

    final (table, id, values) = repo.updates.single;
    expect(table, 'investments');
    expect(id, '1');
    expect(values['current_value'], 1200.0); // 100 × 12
    expect(values['last_price'], 100.0);
    expect(values['price_source'], contains('Yahoo'));

    // The caller's copy is updated in place so the list can repaint at once.
    expect(rows.single['current_value'], 1200.0);
  });

  test('never touches a row without both a symbol and a quantity', () async {
    final repo = _RecordingRepo();
    final net = _Net();
    final rows = [
      _row('1', 'Old fund', 'mf', currentValue: 50000), // neither
      _row('2', 'Half set', 'stock', symbol: 'TCS', currentValue: 9000), // no qty
      _row('3', 'Also half', 'stock', quantity: 5, currentValue: 900), // no symbol
      _row('4', 'FD', 'fd', currentValue: 100000),
    ];

    final out = await _sync(repo, net.client({'query1': _yahoo})).run(rows);

    expect(out.isIdle, isTrue);
    expect(repo.updates, isEmpty);
    expect(net.calls, 0, reason: 'nothing eligible, so nothing is fetched');
    expect(rows[1]['current_value'], 9000, reason: 'manual value stands');
  });

  test('a failed lookup leaves the stored value standing', () async {
    final repo = _RecordingRepo();
    final net = _Net();
    final rows = [
      _row('1', 'Reliance', 'stock',
          symbol: 'RELIANCE', quantity: 12, currentValue: 17000),
    ];

    final out = await _sync(repo, net.client({}, status: 500)).run(rows);

    expect(out.updated, 0);
    expect(out.failures.keys, ['Reliance']);
    expect(repo.updates, isEmpty);
    expect(rows.single['current_value'], 17000,
        reason: 'a price outage must not blank a portfolio');
  });

  test('a type with no price source is reported, not silently skipped',
      () async {
    final repo = _RecordingRepo();
    final net = _Net();
    final rows = [
      _row('1', 'Bank FD', 'fd', symbol: 'FD123', quantity: 1),
    ];

    final out = await _sync(repo, net.client({})).run(rows);

    expect(out.checked, 1);
    expect(out.failures['Bank FD'], contains('no live price source'));
    expect(net.calls, 0);
  });

  test('a typed gold rate overrides the market and costs no request',
      () async {
    final repo = _RecordingRepo();
    final net = _Net();
    final rows = [
      _row('1', 'Gold coins', 'gold', quantity: 20, marketPrice: 11500),
    ];

    final out = await _sync(repo, net.client({'coingecko': _gecko})).run(rows);

    expect(net.calls, 0);
    expect(repo.updates.single.$3['current_value'], 230000.0); // 11500 × 20
    expect(out.priced.single.source, 'Manual price');
  });

  test('gold without an override is priced per gram from spot', () async {
    final repo = _RecordingRepo();
    final net = _Net();
    final rows = [_row('1', 'Gold', 'gold', symbol: 'gold', quantity: 10)];

    await _sync(repo, net.client({'coingecko': _gecko})).run(rows);

    // 311034.768 / 31.1034768 = 10000/g, × 10g.
    expect(repo.updates.single.$3['current_value'], closeTo(100000, 0.01));
  });

  test('an unchanged price writes nothing at all', () async {
    final repo = _RecordingRepo();
    final net = _Net();
    final asOf =
        DateTime.fromMillisecondsSinceEpoch(1754130600 * 1000).toIso8601String();
    final rows = [
      _row('1', 'Reliance', 'stock',
          symbol: 'RELIANCE',
          quantity: 12,
          currentValue: 1200,
          lastPrice: 100,
          priceAt: asOf),
    ];

    final out = await _sync(repo, net.client({'query1': _yahoo})).run(rows);

    expect(out.checked, 1);
    expect(out.updated, 0);
    expect(repo.updates, isEmpty,
        reason: 'a NAV that has not moved should not churn the row');
    expect(out.priced, hasLength(1), reason: 'it was still priced');
  });

  group('ledger', () {
    test('logs one revaluation event when the value moves', () async {
      final repo = _RecordingRepo();
      final net = _Net();
      final rows = [
        _row('1', 'Reliance', 'stock',
            symbol: 'RELIANCE', quantity: 12, currentValue: 1000),
      ];

      await _sync(repo, net.client({'query1': _yahoo})).run(rows);

      final event = repo.inserted.single;
      expect(event['table'], moduleEventsTable);
      expect(event['parent_id'], '1');
      expect(event['field'], 'current_value');
      expect(event['kind'], 'set');
      expect(event['balance_after'], 1200.0);
    });

    test('does not log a second event on a day that already has one',
        () async {
      final repo = _RecordingRepo();
      final net = _Net();
      final today = DateTime(2026, 8, 2, 14, 30);
      final rows = [
        _row('1', 'Reliance', 'stock',
            symbol: 'RELIANCE', quantity: 12, currentValue: 1000),
      ];
      final events = [
        {
          'parent_id': '1',
          'parent_type': 'investments',
          'field': 'current_value',
          'kind': 'set',
          'amount': 1150,
          'balance_after': 1150,
          'date': '2026-08-02',
        }
      ];

      await _sync(repo, net.client({'query1': _yahoo}), clock: () => today)
          .run(rows, events: events);

      expect(repo.updates, hasLength(1), reason: 'the value still updates');
      expect(repo.inserted, isEmpty,
          reason: 'the ledger stores one point per day; more is noise');
    });
  });

  group('throttle', () {
    test('a second run inside the window serves the cached price', () async {
      final repo = _RecordingRepo();
      final net = _Net();
      var now = DateTime(2026, 8, 2, 10);
      final service = QuoteService(client: net.client({'query1': _yahoo}),
          clock: () => now);
      final sync = InvestmentSync(repo: repo, quotes: service);

      final rows = [
        _row('1', 'Reliance', 'stock',
            symbol: 'RELIANCE', quantity: 12, currentValue: 1000)
      ];
      await sync.run(rows);
      expect(net.calls, 1);

      now = now.add(const Duration(minutes: 5));
      await sync.run(rows);
      expect(net.calls, 1, reason: 'still inside the 15-minute window');
    });

    test('force bypasses the window, and time eventually does too', () async {
      final repo = _RecordingRepo();
      final net = _Net();
      var now = DateTime(2026, 8, 2, 10);
      final service = QuoteService(client: net.client({'query1': _yahoo}),
          clock: () => now);
      final sync = InvestmentSync(repo: repo, quotes: service);
      final rows = [
        _row('1', 'Reliance', 'stock',
            symbol: 'RELIANCE', quantity: 12, currentValue: 1000)
      ];

      await sync.run(rows);
      await sync.run(rows, force: true); // pull-to-refresh
      expect(net.calls, 2);

      now = now.add(const Duration(minutes: 20));
      await sync.run(rows);
      expect(net.calls, 3);
    });

    test('ten rows of one fund cost one lookup', () async {
      final repo = _RecordingRepo();
      final net = _Net();
      final rows = [
        for (var i = 0; i < 10; i++)
          _row('$i', 'Fund $i', 'crypto', symbol: 'bitcoin', quantity: 1),
      ];

      await _sync(repo, net.client({'coingecko': _gecko})).run(rows);

      expect(net.calls, 1);
      expect(repo.updates, hasLength(10));
    });
  });
}
