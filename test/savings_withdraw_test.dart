import 'package:accounts_app/core/theme.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/module_event.dart';
import 'package:accounts_app/features/common/entity_screen.dart';
import 'package:accounts_app/features/registry.dart';
import 'package:accounts_app/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo implements FinanceRepository {
  _Repo(this.tables);
  final Map<String, List<Json>> tables;
  int _id = 400;

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

Future<Map<String, List<Json>>> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final tables = <String, List<Json>>{
    'savings_goals': [
      {
        'id': 'g1',
        'name': 'Emergency fund',
        'target_amount': 50000,
        'saved_amount': 10000,
      }
    ],
    'accounts': [
      {'id': 'a1', 'name': 'INDIAN BANK', 'type': 'bank'},
    ],
  };
  await tester.pumpWidget(ProviderScope(
    overrides: [repoProvider.overrideWithValue(_Repo(tables))],
    child: MaterialApp(
      theme: AppTheme.light,
      home: EntityScreen(config: Modules.savings),
    ),
  ));
  await tester.pumpAndSettle();
  return tables;
}

Future<void> _withdraw(WidgetTester tester, String amount,
    {bool pickAccount = true}) async {
  await tester.drag(find.byType(ListView).last, const Offset(0, -240));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.more_vert).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Withdraw').last);
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).first, amount);
  await tester.pumpAndSettle();
  if (pickAccount) {
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('INDIAN BANK').last);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('withdrawing reduces the goal and credits the account',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    await _withdraw(tester, '4000');

    expect(tables['savings_goals']!.single['saved_amount'], 6000);

    final move = tables['cash_moves']!.single;
    expect(move['account'], 'INDIAN BANK');
    expect(move['amount'], 4000,
        reason: 'money coming OUT of savings goes INTO the account');
  });

  testWidgets('it cannot take out more than is saved', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    await _withdraw(tester, '999999');

    expect(tables['savings_goals']!.single['saved_amount'], 0,
        reason: 'clamped at what was there — a goal cannot go negative');
    expect(tables['cash_moves']!.single['amount'], 10000,
        reason: 'and only what existed is credited');
  });

  testWidgets('a withdrawal bends the savings curve', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    await _withdraw(tester, '4000');

    final event = tables[moduleEventsTable]!
        .firstWhere((e) => e['kind'] == EventKind.decrement.name);
    expect(event['parent_id'], 'g1');
    expect(event['field'], 'saved_amount');
    expect(event['amount'], 4000);
    expect(event['balance_after'], 6000);
    expect(event['account'], 'INDIAN BANK');
  });

  testWidgets('without an account the goal still drops, no cash moves',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    await _withdraw(tester, '2500', pickAccount: false);

    expect(tables['savings_goals']!.single['saved_amount'], 7500);
    expect(tables['cash_moves'], isNull,
        reason: 'nowhere was named, so no balance may be touched');
  });

  testWidgets('the dialog is worded as a withdrawal, not a payment',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _open(tester);
    await tester.drag(find.byType(ListView).last, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();

    expect(find.text('Withdraw'), findsOneWidget);
    expect(find.text('Add to savings'), findsOneWidget,
        reason: 'both directions are offered');

    await tester.tap(find.text('Withdraw').last);
    await tester.pumpAndSettle();
    expect(find.text('Withdraw amount'), findsOneWidget);
    expect(find.text('To account (optional)'), findsOneWidget);
  });
}
