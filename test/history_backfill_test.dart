import 'package:accounts_app/data/history.dart';
import 'package:accounts_app/data/local_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/features/history/history_backfill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late LocalStore store;
  late HistoryRepository repo;
  final now = DateTime(2026, 9, 26, 12);

  String ago({int days = 0, int seconds = 0}) => now
      .subtract(Duration(days: days, seconds: seconds))
      .toIso8601String();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = HistoryRepository(
      LocalRepository(store),
      HistoryLog(store, now: () => now),
      childTables: const ['module_events', 'debt_payments'],
    );
  });

  Future<int> backfill() =>
      HistoryBackfill(repo, repo.log, now: () => now).run();

  test('a creditor added with an account comes back as one undoable add',
      () async {
    await store.write('creditors', [
      {'id': 'c1', 'person_name': 'Ravi', 'amount': 10000, 'created_at': ago(days: 3)},
    ]);
    await store.write('cash_moves', [
      {
        'id': 'm1',
        'account': 'INDIAN bank',
        'amount': 10000,
        'note': 'Creditors',
        'created_at': ago(days: 3, seconds: -1),
      },
    ]);

    expect(await backfill(), 1);
    final entry = repo.log.entries().single;
    expect(entry.rebuilt, isTrue);
    expect(entry.label, startsWith('Added Creditors'));
    expect(entry.ops.map((o) => o.table), ['creditors', 'cash_moves']);

    await repo.undo(entry.id);
    expect(store.read('creditors'), isEmpty);
    expect(store.read('cash_moves'), isEmpty);
  });

  test('money left behind by a deleted debt can be removed', () async {
    await store.write('cash_moves', [
      {
        'id': 'm1',
        'account': 'INDIAN bank',
        'amount': 10000,
        'note': 'Creditors',
        'created_at': ago(days: 2),
      },
    ]);
    await backfill();
    final entry = repo.log.entries().single;
    expect(entry.label, contains('INDIAN bank'));
    expect(repo.canUndo(entry), isTrue);
    await repo.undo(entry.id);
    expect(store.read('cash_moves'), isEmpty);
  });

  test('a payment is shown but not undoable, and guards its debt', () async {
    await store.write('creditors', [
      {'id': 'c1', 'person_name': 'Ravi', 'amount': 8000, 'created_at': ago(days: 5)},
    ]);
    await store.write('module_events', [
      {
        'id': 'e1',
        'parent_id': 'c1',
        'parent_type': 'creditors',
        'kind': 'decrement',
        'amount': 2000,
        'account': 'Cash',
        'note': 'Creditors',
        'created_at': ago(days: 1),
      },
    ]);
    await store.write('debt_payments', [
      {'id': 'p1', 'parent_id': 'c1', 'amount': 2000, 'created_at': ago(days: 1)},
    ]);
    await store.write('cash_moves', [
      {'id': 'm1', 'account': 'Cash', 'amount': -2000, 'note': 'Creditors',
       'created_at': ago(days: 1)},
    ]);

    await backfill();
    final entries = repo.log.entries();
    expect(entries, hasLength(2));
    final pay = entries.first, add = entries.last;
    expect(pay.label, 'Paid ₹2,000 on Creditors · Ravi');
    expect(pay.ops.map((o) => o.table),
        ['module_events', 'debt_payments', 'cash_moves']);
    expect(repo.canUndo(pay), isFalse);
    expect(repo.canUndo(add), isFalse,
        reason: 'the debt has been paid against since');
  });

  test('older rows, seeded rows and price refreshes are left out', () async {
    await store.write('expenses', [
      {'id': 'x1', 'payee': 'Old', 'amount': 1, 'created_at': ago(days: 20)},
      {'id': 'x2', 'payee': 'Seeded', 'amount': 1},
    ]);
    await store.write('module_events', [
      {'id': 'e1', 'parent_id': 'i1', 'parent_type': 'investments',
       'kind': 'set', 'amount': 5, 'note': 'mfapi', 'created_at': ago()},
    ]);
    expect(await backfill(), 0);
  });

  test('running again adds nothing, and live entries are not duplicated',
      () async {
    await repo.action(
      label: 'Added Taxi',
      table: 'expenses',
      body: () => repo.insert('expenses', {'payee': 'Taxi', 'amount': 5}),
    );
    await store.write('income', [
      {'id': 'i1', 'source': 'Pay', 'amount': 9, 'created_at': ago(days: 4)},
    ]);
    expect(await backfill(), 1);
    expect(await backfill(), 0);
    expect(repo.log.entries(), hasLength(2));
  });
}
