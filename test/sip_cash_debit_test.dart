import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/data/nav_api.dart';
import 'package:accounts_app/data/nav_cache.dart';
import 'package:accounts_app/services/sip_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo implements FinanceRepository {
  final Map<String, List<Json>> tables = {};
  int _id = 1;

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

class _Api implements NavApi {
  @override
  Future<NavSeries> history(int code) async {
    final navs = <DateTime, double>{};
    var cursor = DateTime(2026, 1, 1);
    while (cursor.isBefore(DateTime(2026, 12, 31))) {
      navs[cursor] = 100;
      cursor = cursor.add(const Duration(days: 1));
    }
    return NavSeries(code: code, schemeName: 'F', fundHouse: 'H', navs: navs);
  }

  @override
  Future<List<SchemeRef>> search(String q) async => const [];
}

final _today = DateTime(2026, 4, 20);

Future<SipService> _service(_Repo repo) async {
  SharedPreferences.setMockInitialValues({});
  return SipService(
    repo: repo,
    navs: NavCache(
      store: LocalStore(await SharedPreferences.getInstance()),
      api: _Api(),
      clock: () => _today,
    ),
    clock: () => _today,
  );
}

Json _sip({String? cashFrom, String? account, String? createdAt}) => {
      'id': '1',
      'name': 'Mid Cap SIP',
      'type': 'sip',
      'scheme_code': 1,
      'sip_amount': 5000,
      'sip_frequency': 'monthly',
      'sip_day': 5,
      'sip_start_date': '2026-03-05',
      'sip_active': true,
      if (cashFrom != null) 'cash_from': cashFrom,
      if (account != null) 'sip_account': account,
      if (createdAt != null) 'created_at': createdAt,
    };

List<Json> _debits(_Repo repo) =>
    (repo.tables['cash_moves'] ?? []).where((m) => (m['amount'] as num) < 0)
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a SIP with an account debits it when an installment falls due',
      () async {
    final repo = _Repo();
    final row = _sip(cashFrom: '2026-03-01', account: 'INDIAN BANK');

    await (await _service(repo)).refresh([row]);

    // March and April installments, ₹5,000 each, both on or after the boundary.
    final debits = _debits(repo);
    expect(debits, hasLength(2));
    expect(debits.every((m) => m['account'] == 'INDIAN BANK'), isTrue);
    expect(debits.every((m) => m['amount'] == -5000), isTrue,
        reason: 'a SIP debit is money out');
  });

  test('a repeat refresh never debits the same installment twice', () async {
    final repo = _Repo();
    final row = _sip(cashFrom: '2026-03-01', account: 'INDIAN BANK');
    final sip = await _service(repo);

    await sip.refresh([row]);
    await sip.refresh([row]);
    await sip.refresh([row]);

    expect(_debits(repo), hasLength(2), reason: 'cash_posted is the guard');
  });

  test('installments before the boundary are history and move no cash',
      () async {
    final repo = _Repo();
    // Created today: March and April are backfill, already paid by hand.
    final row = _sip(cashFrom: '2026-04-20', account: 'INDIAN BANK');

    await (await _service(repo)).refresh([row]);

    expect(_debits(repo), isEmpty,
        reason: 'those debits were already recorded when they happened');
  });

  test('a missing cash_from falls back to when the row was created', () async {
    final repo = _Repo();
    // The bug: a null boundary silently disabled cash posting forever.
    final row = _sip(account: 'INDIAN BANK', createdAt: '2026-03-01');

    await (await _service(repo)).refresh([row]);

    expect(_debits(repo), hasLength(2),
        reason: 'an unknown boundary must not mean "never debit"');
  });

  test('with no account configured, it asks instead of guessing', () async {
    final repo = _Repo();
    final row = _sip(cashFrom: '2026-03-01');

    final outcome = await (await _service(repo)).refresh([row]);

    expect(_debits(repo), isEmpty);
    expect(outcome.dueForConfirmation, hasLength(2),
        reason: 'the banner is the fallback when no account is known');
  });

  test('the debit names the fund and lands on the installment date', () async {
    final repo = _Repo();
    final row = _sip(cashFrom: '2026-03-01', account: 'INDIAN BANK');

    await (await _service(repo)).refresh([row]);

    final first = _debits(repo).first;
    expect(first['date'], '2026-03-05');
    expect(first['note'], contains('Mid Cap SIP'));
  });
}
