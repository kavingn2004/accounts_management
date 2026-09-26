import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/module_event.dart';
import 'package:accounts_app/services/redemption_service.dart';
import 'package:accounts_app/services/sip_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repo implements FinanceRepository {
  _Repo([Map<String, List<Json>>? seed]) : tables = seed ?? {};
  final Map<String, List<Json>> tables;
  int _id = 500;

  @override
  Future<List<Json>> list(String t,
          {String orderBy = 'created_at', bool ascending = false}) async =>
      [...(tables[t] ?? const [])];

  @override
  Future<void> insert(String t, Json v) async =>
      tables.putIfAbsent(t, () => []).add({'id': '${_id++}', ...v});

  @override
  Future<void> update(String t, String id, Json v) async {
    final rows = tables[t] ?? [];
    final i = rows.indexWhere((r) => r['id'].toString() == id);
    if (i >= 0) rows[i] = {...rows[i], ...v};
  }

  @override
  Future<void> delete(String t, String id) async {}
  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

final _today = DateTime(2026, 8, 2);

RedemptionService _service(_Repo repo) =>
    RedemptionService(repo: repo, clock: () => _today);

Json _holding() => {
      'id': '1',
      'name': 'Nifty 50 Index',
      'type': 'fund',
      'symbol': '120503',
      'quantity': 100,
      'last_price': 120,
      'total_invested': 10000,
      'current_value': 12000,
    };

Json _valueOnly() => {
      'id': '2',
      'name': 'Old fund',
      'type': 'fund',
      'total_invested': 10000,
      'current_value': 12000,
    };

Json _sip() => {
      'id': '3',
      'name': 'Mid Cap SIP',
      'type': 'sip',
      'scheme_code': 122639,
      'quantity': 200,
      'last_price': 90,
      'total_invested': 15000,
      'current_value': 18000,
    };

void main() {
  group('unit price', () {
    test('prefers the price the row was last valued at', () {
      expect(RedemptionService.unitPrice(_holding()), 120);
    });

    test('falls back to value ÷ quantity when no price is stored', () {
      final row = _holding()..remove('last_price');
      expect(RedemptionService.unitPrice(row), 120); // 12000 / 100
    });

    test('is null for a holding with no units at all', () {
      expect(RedemptionService.unitPrice(_valueOnly()), isNull);
    });
  });

  group('a holding with units', () {
    test('a partial redemption reduces units and credits the account',
        () async {
      final repo = _Repo();
      final row = _holding();

      await _service(repo).redeem(row,
          units: 25, proceeds: 3000, account: 'Indian Bank');

      expect(row['quantity'], 75);
      // Net invested: contributions less what has been taken back out.
      expect(row['total_invested'], 7000);
      expect(row['current_value'], 9000);

      final move = repo.tables['cash_moves']!.single;
      expect(move['account'], 'Indian Bank');
      expect(move['amount'], 3000, reason: 'money IN is positive');
      expect(move['date'], '2026-08-02');
    });

    test('a full redemption empties the holding without deleting it',
        () async {
      final repo = _Repo();
      final row = _holding();

      await _service(repo)
          .redeem(row, units: 100, proceeds: 12000, account: 'Indian Bank');

      expect(row['quantity'], 0);
      expect(row['current_value'], 0);
      expect(row['total_invested'], -2000,
          reason: 'net of all cash: 10,000 in, 12,000 out — a ₹2,000 gain');
    });

    test('redeeming without naming an account moves no cash', () async {
      final repo = _Repo();
      final row = _holding();

      await _service(repo).redeem(row, units: 25, proceeds: 3000);

      expect(repo.tables['cash_moves'], isNull);
      expect(row['quantity'], 75, reason: 'the holding still changes');
    });

    test('logs the exit in the ledger so the value curve bends', () async {
      final repo = _Repo();
      final row = _holding();

      await _service(repo)
          .redeem(row, units: 25, proceeds: 3000, account: 'Indian Bank');

      final event = repo.tables[moduleEventsTable]!.single;
      expect(event['parent_id'], '1');
      expect(event['field'], 'current_value');
      expect(event['kind'], EventKind.decrement.name);
      expect(event['amount'], 3000);
      expect(event['balance_after'], 9000);
      expect(event['account'], 'Indian Bank');
    });
  });

  group('a holding with no units', () {
    test('redeems by amount alone', () async {
      final repo = _Repo();
      final row = _valueOnly();

      await _service(repo)
          .redeem(row, units: 0, proceeds: 4000, account: 'Indian Bank');

      expect(row['current_value'], 8000);
      expect(row['total_invested'], 6000);
      expect(row.containsKey('quantity'), isFalse);
      expect(repo.tables['cash_moves']!.single['amount'], 4000);
    });
  });

  group('a SIP', () {
    test('records the exit in its ledger, not on the row', () async {
      // The engine recomputes a SIP's units from its ledger on every refresh,
      // so writing them onto the row directly would be undone moments later.
      final repo = _Repo();
      final row = _sip();

      await _service(repo)
          .redeem(row, units: 50, proceeds: 4500, account: 'Indian Bank');

      final entry = repo.tables[SipFields.table]!.single;
      expect(entry['parent_id'], '3');
      expect(entry['source'], 'redemption');
      expect(entry['units'], -50, reason: 'negative units net off the total');
      expect(entry['amount'], -4500);
      expect(entry['units_override'], isTrue);
      expect(entry['cash_posted'], isTrue,
          reason: 'the cash decision was made here, so it must not be '
              'raised again by the due-installment banner');
    });

    test('the ledger totals then reflect the redemption', () async {
      final repo = _Repo();
      final row = _sip();
      repo.tables[SipFields.table] = [
        {
          'id': 'i1',
          'parent_id': '3',
          'date': '2026-01-05',
          'amount': 15000,
          'nav': 75,
          'nav_date': '2026-01-05',
          'units': 200,
          'source': 'auto',
        }
      ];

      await _service(repo).redeem(row, units: 50, proceeds: 4500);

      final parsed = [
        for (final e in repo.tables[SipFields.table]!)
          SipService.installmentFrom(e)
      ];
      expect(
        parsed.fold<double>(0, (a, i) => a + i.units),
        150,
        reason: '200 bought, 50 sold',
      );
      expect(
        parsed.fold<double>(0, (a, i) => a + i.investedAmount),
        10500,
        reason: '15,000 in less 4,500 back out',
      );
    });
  });

  group('refusals', () {
    test('will not redeem more units than are held', () async {
      final repo = _Repo();
      await expectLater(
        _service(repo).redeem(_holding(), units: 101, proceeds: 12120),
        throwsA(isA<RedemptionError>()),
      );
      expect(repo.tables, isEmpty);
    });

    test('will not redeem a zero or negative amount', () async {
      final repo = _Repo();
      await expectLater(
        _service(repo).redeem(_holding(), units: 0, proceeds: 0),
        throwsA(isA<RedemptionError>()),
      );
    });
  });
}

