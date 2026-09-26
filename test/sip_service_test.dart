import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/data/nav_api.dart';
import 'package:accounts_app/data/nav_cache.dart';
import 'package:accounts_app/services/quotes/investment_sync.dart';
import 'package:accounts_app/services/sip_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory repository that behaves like the real one: inserts get an id,
/// updates merge, lists return what was written.
class _Repo implements FinanceRepository {
  final Map<String, List<Json>> tables = {};
  int _nextId = 1;

  @override
  Future<List<Json>> list(String table,
          {String orderBy = 'created_at', bool ascending = false}) async =>
      [...(tables[table] ?? const [])];

  @override
  Future<void> insert(String table, Json values) async {
    tables.putIfAbsent(table, () => []).add({
      'id': '${_nextId++}',
      ...values,
    });
  }

  @override
  Future<void> update(String table, String id, Json values) async {
    final rows = tables[table] ?? [];
    final i = rows.indexWhere((r) => r['id'].toString() == id);
    if (i >= 0) rows[i] = {...rows[i], ...values};
  }

  @override
  Future<void> delete(String table, String id) async {
    tables[table]?.removeWhere((r) => r['id'].toString() == id);
  }

  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

/// NAV published every weekday, rising by [dailyGrowth] a day.
class _FakeApi implements NavApi {
  _FakeApi(this.from, this.to, {this.start = 100, this.dailyGrowth = 0});
  final DateTime from;
  final DateTime to;
  final double start;
  final double dailyGrowth;
  int calls = 0;
  Object? failWith;

  @override
  Future<NavSeries> history(int code) async {
    calls++;
    final failure = failWith;
    if (failure != null) throw failure;
    final navs = <DateTime, double>{};
    var cursor = from;
    var nav = start;
    while (!cursor.isAfter(to)) {
      if (cursor.weekday <= DateTime.friday) navs[cursor] = nav;
      nav += dailyGrowth;
      cursor = cursor.add(const Duration(days: 1));
    }
    return NavSeries(
        code: code, schemeName: 'Test Fund', fundHouse: 'AMC', navs: navs);
  }

  @override
  Future<List<SchemeRef>> search(String query) async => const [];
}

Future<NavCache> _cache(_FakeApi api, {DateTime Function()? clock}) async {
  SharedPreferences.setMockInitialValues({});
  return NavCache(
    store: LocalStore(await SharedPreferences.getInstance()),
    api: api,
    clock: clock,
  );
}

/// Reads work; every write fails, as with a missing table.
class _WriteFailingRepo extends _Repo {
  @override
  Future<void> insert(String table, Json values) async {
    if (table == SipFields.table) {
      throw Exception(
          "Could not find the table 'public.sip_installments' in the schema cache");
    }
    return super.insert(table, values);
  }
}

Json _sipRow({
  String id = '1',
  String start = '2026-01-05',
  num amount = 5000,
  String frequency = 'monthly',
  int day = 5,
  String? cashFrom,
  bool active = true,
}) =>
    {
      'id': id,
      'name': 'Flexi Cap SIP',
      'type': 'sip',
      'scheme_code': 122639,
      'sip_start_date': start,
      'sip_amount': amount,
      'sip_frequency': frequency,
      'sip_day': day,
      'sip_active': active,
      if (cashFrom != null) 'cash_from': cashFrom,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final today = DateTime(2026, 4, 20);
  DateTime clock() => today;

  Future<SipService> service(_Repo repo, _FakeApi api) async => SipService(
        repo: repo,
        navs: await _cache(api, clock: clock),
        clock: clock,
      );

  test('backfills every installment from the start date to today', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today);
    final row = _sipRow();

    final outcome = await (await service(repo, api)).refresh([row]);

    // Jan, Feb, Mar, Apr on the 5th.
    expect(outcome.created, 4);
    expect(repo.tables[SipFields.table], hasLength(4));
    expect(
      repo.tables[SipFields.table]!.map((e) => e['date']),
      ['2026-01-05', '2026-02-05', '2026-03-05', '2026-04-05'],
    );
  });

  test('writes units to quantity and never touches current_value', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today); // flat NAV of 100
    final row = _sipRow();

    await (await service(repo, api)).refresh([row]);

    // 4 × ₹5,000 at a NAV of 100 = 200 units.
    expect(row[InvestmentFields.quantity], 200);
    expect(row['total_invested'], 20000);
    expect(row.containsKey('current_value'), isFalse,
        reason: 'valuation belongs to InvestmentSync — one writer per figure');
    // The symbol is set for us, so the row is priceable without typing a code
    // a second time.
    expect(row[InvestmentFields.symbol], '122639');
  });

  test('a repeat refresh appends nothing', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today);
    final row = _sipRow();
    final sip = await service(repo, api);

    await sip.refresh([row]);
    final second = await sip.refresh([row]);

    expect(second.created, 0);
    expect(repo.tables[SipFields.table], hasLength(4),
        reason: 'installments must never duplicate on re-run');
  });

  test('allots at the next published NAV when the debit lands on a weekend',
      () async {
    final repo = _Repo();
    // 5 Apr 2026 is a Sunday; the NAV used must be Monday the 6th.
    final api = _FakeApi(DateTime(2026, 4, 1), today, start: 100,
        dailyGrowth: 1);
    final row = _sipRow(start: '2026-04-05');

    await (await service(repo, api)).refresh([row]);

    final entry = repo.tables[SipFields.table]!.single;
    expect(entry[InstallmentFields.date], '2026-04-05');
    expect(entry[InstallmentFields.navDate], '2026-04-06');
  });

  test('a start before the fund existed is clamped to its first NAV', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 3, 1), today);
    final row = _sipRow(start: '2025-06-05');

    await (await service(repo, api)).refresh([row]);

    final dates =
        repo.tables[SipFields.table]!.map((e) => e['date']).toList();
    expect(dates, ['2026-03-05', '2026-04-05'],
        reason: 'nothing can be bought before the fund published a NAV');
  });

  test('a paused SIP stops generating but keeps its units', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today);
    final row = _sipRow();
    final sip = await service(repo, api);

    await sip.refresh([row]);
    final unitsBefore = row[InvestmentFields.quantity];

    row['sip_active'] = false;
    row['sip_start_date'] = '2026-01-05';
    final after = await sip.refresh([row]);

    expect(after.created, 0);
    expect(row[InvestmentFields.quantity], unitsBefore);
  });

  test('skipped installments drop out of units and invested', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today);
    final row = _sipRow();
    final sip = await service(repo, api);
    await sip.refresh([row]);

    final first = repo.tables[SipFields.table]!.first;
    await repo.update(SipFields.table, first['id'].toString(),
        {InstallmentFields.skipped: true});
    await sip.refresh([row]);

    expect(row[InvestmentFields.quantity], 150); // 3 of 4 installments
    expect(row['total_invested'], 15000);
  });

  group('cash boundary', () {
    test('backfilled history asks for nothing', () async {
      final repo = _Repo();
      final api = _FakeApi(DateTime(2026, 1, 1), today);
      // Created today: everything before now is history.
      final row = _sipRow(cashFrom: '2026-04-20');

      final outcome = await (await service(repo, api)).refresh([row]);

      expect(outcome.dueForConfirmation, isEmpty,
          reason: 'those debits were already recorded by hand');
    });

    test('an installment on or after the boundary is raised once', () async {
      final repo = _Repo();
      final api = _FakeApi(DateTime(2026, 1, 1), today);
      final row = _sipRow(cashFrom: '2026-04-01');
      final sip = await service(repo, api);

      // First pass creates the rows; ids only exist once re-read, so the
      // banner appears on the following refresh.
      await sip.refresh([row]);
      final outcome = await sip.refresh([row]);

      expect(outcome.dueForConfirmation, hasLength(1));
      expect(outcome.dueForConfirmation.single[InstallmentFields.date],
          '2026-04-05');
      expect(outcome.dueForConfirmation.single['parent_name'],
          'Flexi Cap SIP');
    });

    test('a posted installment stops being raised', () async {
      final repo = _Repo();
      final api = _FakeApi(DateTime(2026, 1, 1), today);
      final row = _sipRow(cashFrom: '2026-04-01');
      final sip = await service(repo, api);
      await sip.refresh([row]);
      final due = (await sip.refresh([row])).dueForConfirmation.single;

      await repo.update(SipFields.table, due['id'].toString(),
          {InstallmentFields.cashPosted: true});
      final after = await sip.refresh([row]);

      expect(after.dueForConfirmation, isEmpty,
          reason: 'cash_posted is what makes posting idempotent');
    });

    test('a skipped installment is not raised for cash', () async {
      final repo = _Repo();
      final api = _FakeApi(DateTime(2026, 1, 1), today);
      final row = _sipRow(cashFrom: '2026-04-01');
      final sip = await service(repo, api);
      await sip.refresh([row]);
      final due = (await sip.refresh([row])).dueForConfirmation.single;

      await repo.update(SipFields.table, due['id'].toString(),
          {InstallmentFields.skipped: true});

      expect((await sip.refresh([row])).dueForConfirmation, isEmpty);
    });

    test('the last account used is offered as the default', () async {
      final repo = _Repo();
      final api = _FakeApi(DateTime(2026, 1, 1), today);
      final row = _sipRow(cashFrom: '2026-04-01');
      final sip = await service(repo, api);
      await sip.refresh([row]);

      final first = repo.tables[SipFields.table]!.first;
      await repo.update(SipFields.table, first['id'].toString(),
          {InstallmentFields.account: 'HDFC'});

      final due = (await sip.refresh([row])).dueForConfirmation.single;
      expect(due['suggested_account'], 'HDFC');
    });
  });

  test('a lumpsum adds units at the NAV for its date', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today);
    final row = _sipRow(start: '2026-04-05');
    final sip = await service(repo, api);
    await sip.refresh([row]);
    final before = (row[InvestmentFields.quantity] as num).toDouble();

    await sip.addLumpsum(row, date: DateTime(2026, 4, 8), amount: 10000);

    expect(row[InvestmentFields.quantity], before + 100); // 10000 / 100
    expect(
      repo.tables[SipFields.table]!
          .where((e) => e[InstallmentFields.source] == 'manual'),
      hasLength(1),
    );
  });

  test('a NAV outage keeps the ledger and reports staleness', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today);
    var now = today;
    final cache = await _cache(api, clock: () => now);
    final sip = SipService(repo: repo, navs: cache, clock: () => now);
    final row = _sipRow();

    await sip.refresh([row]);
    final units = row[InvestmentFields.quantity];

    now = DateTime(2026, 4, 21);
    api.failWith = const NavException('Could not reach the NAV service');
    final outcome = await sip.refresh([row]);

    expect(outcome.stale.keys, ['Flexi Cap SIP']);
    expect(outcome.errors, isEmpty);
    expect(row[InvestmentFields.quantity], units,
        reason: 'an outage must not change what is held');
  });

  test('a scheme that has never been downloaded is an error, not a zero',
      () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today)
      ..failWith = const NavException('Could not reach the NAV service');
    final row = _sipRow();

    final outcome = await (await service(repo, api)).refresh([row]);

    expect(outcome.errors.keys, ['Flexi Cap SIP']);
    expect(row.containsKey(InvestmentFields.quantity), isFalse);
    expect(repo.tables[SipFields.table], isNull);
  });

  test('a ledger that cannot be written is reported, not thrown', () async {
    // Exactly what a project missing the sip_installments migration does.
    final repo = _WriteFailingRepo();
    final api = _FakeApi(DateTime(2026, 1, 1), today);
    final rows = [_sipRow(id: '1'), _sipRow(id: '2')];

    final outcome = await SipService(
      repo: repo,
      navs: await _cache(api, clock: clock),
      clock: clock,
    ).refresh(rows);

    // Reported as unsaved history, not as a failure to value: the figures are
    // still derived correctly, so calling it an error would be a lie.
    expect(outcome.errors, isEmpty);
    expect(outcome.unsaved.values.single, contains('history cannot be saved'));
    expect(outcome.rows, 2, reason: 'every row was still examined');
  });

  group('without a ledger table', () {
    // The table persists installments; it does not invent them. The schedule
    // and the NAV history are enough to know what was bought and when, so a
    // missing table costs the ability to EDIT history, not the value itself.
    test('units and invested are still derived from the schedule', () async {
      final repo = _WriteFailingRepo();
      final api = _FakeApi(DateTime(2026, 1, 1), today);
      final row = _sipRow();

      final outcome = await SipService(
        repo: repo,
        navs: await _cache(api, clock: clock),
        clock: clock,
      ).refresh([row]);

      // Jan–Apr on the 5th, ₹5,000 each at NAV 100.
      expect(row[InvestmentFields.quantity], 200);
      expect(row['total_invested'], 20000);
      expect(row[InvestmentFields.symbol], '122639');

      // And it says the history is not editable, without claiming the values
      // are wrong — they are not.
      expect(outcome.errors, isEmpty);
      expect(outcome.unsaved.values.single, contains('history cannot be saved'));
      expect(repo.tables[SipFields.table], isNull);
    });

    test('the derived schedule respects fund inception', () async {
      final repo = _WriteFailingRepo();
      final api = _FakeApi(DateTime(2026, 3, 1), today);
      final row = _sipRow(start: '2025-06-05');

      await SipService(
        repo: repo,
        navs: await _cache(api, clock: clock),
        clock: clock,
      ).refresh([row]);

      // Only Mar and Apr can have been bought.
      expect(row[InvestmentFields.quantity], 100);
    });

    test('a paused SIP derives nothing new', () async {
      final repo = _WriteFailingRepo();
      final api = _FakeApi(DateTime(2026, 1, 1), today);
      final row = _sipRow(active: false);

      await SipService(
        repo: repo,
        navs: await _cache(api, clock: clock),
        clock: clock,
      ).refresh([row]);

      expect(row[InvestmentFields.quantity], 0);
    });
  });

  test('non-SIP rows are ignored entirely', () async {
    final repo = _Repo();
    final api = _FakeApi(DateTime(2026, 1, 1), today);
    final rows = [
      {'id': '9', 'name': 'Reliance', 'type': 'stock', 'symbol': 'RELIANCE'},
      {'id': '8', 'name': 'No scheme', 'type': 'sip'}, // no scheme_code
    ];

    final outcome = await (await service(repo, api)).refresh(rows);

    expect(outcome.isIdle, isTrue);
    expect(api.calls, 0);
  });
}
