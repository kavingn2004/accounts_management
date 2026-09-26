import 'package:accounts_app/data/history.dart';
import 'package:accounts_app/data/local_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late LocalStore store;
  late LocalRepository inner;
  late HistoryRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    inner = LocalRepository(store);
    repo = HistoryRepository(inner, HistoryLog(store),
        childTables: const ['module_events', 'debt_payments']);
  });

  Future<void> addExpense(String payee, num amount) => repo.action(
        label: 'Added $payee',
        table: 'expenses',
        body: () async {
          await repo.insert('expenses', {'payee': payee, 'amount': amount});
          await repo.insert('cash_moves', {'account': 'Cash', 'amount': -amount});
        },
      );

  test('writes outside an action are not recorded', () async {
    await repo.insert('expenses', {'payee': 'Sync', 'amount': 1});
    expect(repo.log.entries(), isEmpty);
    expect(store.read('expenses'), hasLength(1));
  });

  test('every write in one action lands in a single entry', () async {
    await addExpense('Groceries', 500);
    final entries = repo.log.entries();
    expect(entries, hasLength(1));
    expect(entries.single.label, 'Added Groceries');
    expect(entries.single.ops.map((o) => o.table),
        ['expenses', 'cash_moves']);
  });

  test('keeps the last 14 days, newest first', () async {
    final log = repo.log;
    HistoryEntry at(String id, int daysAgo) => HistoryEntry(
          id: id,
          label: id,
          table: 'expenses',
          at: DateTime.now().subtract(Duration(days: daysAgo)),
          ops: const [],
        );
    await log.addAll([at('old', 15), at('week', 7), at('edge', 13)]);
    await log.add(at('today', 0));
    expect(log.entries().map((e) => e.label), ['today', 'week', 'edge']);
  });

  test('more than 30 actions within the window are all kept', () async {
    for (var i = 0; i < 35; i++) {
      await addExpense('E$i', i);
    }
    expect(repo.log.entries(), hasLength(35));
    expect(repo.log.entries().first.label, 'Added E34');
  });

  test('undoing an add removes the row and everything written with it',
      () async {
    await addExpense('Groceries', 500);
    final entry = repo.log.entries().single;
    await repo.undo(entry.id);
    expect(store.read('expenses'), isEmpty);
    expect(store.read('cash_moves'), isEmpty);
    expect(repo.log.entries().single.undone, isTrue);
    expect(repo.canUndo(repo.log.entries().single), isFalse);
  });

  test('undoing an add also removes rows hung off it later, unrecorded',
      () async {
    await addExpense('Loan', 1000);
    final id = store.read('expenses').single['id'].toString();
    // e.g. the opening ledger event, written after the sheet closes.
    await repo.insert('module_events', {'parent_id': id, 'amount': 1000});
    await repo.undo(repo.log.entries().single.id);
    expect(store.read('module_events'), isEmpty);
  });

  test('undoing an edit restores the old values exactly', () async {
    await inner.insert('expenses', {'payee': 'Rent', 'amount': 100});
    final id = store.read('expenses').single['id'].toString();
    await repo.action(
      label: 'Edited Rent',
      table: 'expenses',
      body: () => repo.update('expenses', id, {'amount': 200, 'note': 'x'}),
    );
    expect(store.read('expenses').single['amount'], 200);
    await repo.undo(repo.log.entries().first.id);
    final row = store.read('expenses').single;
    expect(row['amount'], 100);
    expect(row.containsKey('note'), isFalse);
  });

  test('undoing a delete brings the row back with its id and place',
      () async {
    await inner.insert('expenses', {'payee': 'Old', 'amount': 1});
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await inner.insert('expenses', {'payee': 'Mid', 'amount': 2});
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await inner.insert('expenses', {'payee': 'New', 'amount': 3});
    final mid = store.read('expenses')[1];
    await repo.action(
      label: 'Deleted Mid',
      table: 'expenses',
      body: () => repo.delete('expenses', mid['id'].toString()),
    );
    expect(store.read('expenses'), hasLength(2));
    await repo.undo(repo.log.entries().first.id);
    final rows = store.read('expenses');
    expect(rows.map((r) => r['payee']), ['New', 'Mid', 'Old']);
    expect(rows[1]['id'], mid['id']);
  });

  test('an older entry is blocked while a newer one touched the same row',
      () async {
    await addExpense('Rent', 100);
    final id = store.read('expenses').single['id'].toString();
    await repo.action(
      label: 'Edited Rent',
      table: 'expenses',
      body: () => repo.update('expenses', id, {'amount': 150}),
    );
    final entries = repo.log.entries();
    final edit = entries[0], add = entries[1];
    expect(repo.canUndo(add), isFalse);
    expect(() => repo.undo(add.id), throwsStateError);

    await repo.undo(edit.id);
    expect(repo.canUndo(repo.log.entries()[1]), isTrue);
    await repo.undo(add.id);
    expect(store.read('expenses'), isEmpty);
  });

  test('unrelated entries can be undone in any order', () async {
    await addExpense('A', 1);
    await addExpense('B', 2);
    final older = repo.log.entries()[1];
    expect(repo.canUndo(older), isTrue);
    await repo.undo(older.id);
    expect(store.read('expenses').map((r) => r['payee']), ['B']);
  });

  test('a payment against a row blocks undoing that row\'s creation',
      () async {
    await repo.action(
      label: 'Added debtor',
      table: 'debtors',
      body: () => repo.insert('debtors', {'name': 'Ravi', 'amount': 500}),
    );
    final id = store.read('debtors').single['id'].toString();
    await repo.action(
      label: 'Payment',
      table: 'debtors',
      body: () =>
          repo.insert('debt_payments', {'parent_id': id, 'amount': 100}),
    );
    expect(repo.canUndo(repo.log.entries()[1]), isFalse);
  });

  test('factory reset clears the history', () async {
    await addExpense('A', 1);
    await store.clearAll();
    expect(repo.log.entries(), isEmpty);
  });
}
