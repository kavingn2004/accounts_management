import 'package:accounts_app/core/formatters.dart';
import 'package:accounts_app/core/theme.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/features/dashboard/dashboard_screen.dart';
import 'package:accounts_app/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Eight distinct payees, all dated inside the current month so the default
/// Month period keeps every one of them.
String _today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

const _payees = <String, double>{
  'Rent': 32000,
  'School fees': 12500,
  'Groceries': 4820,
  'Electricity': 3240,
  'Petrol': 2100,
  'Internet': 1199,
  'Dining out': 900,
  'Gym': 700,
};

class _FakeRepo implements FinanceRepository {
  @override
  Future<Json?> dashboard() async => {'net_worth': 100000};

  @override
  Future<List<Json>> list(String table,
      {String orderBy = 'created_at', bool ascending = false}) async {
    if (table != 'expenses') return [];
    var i = 0;
    return _payees.entries
        .map((e) => {
              'id': '${i++}',
              'payee': e.key,
              'amount': e.value,
              'date': _today(),
            })
        .toList();
  }

  @override
  Future<List<Json>> accountsWithBalances() async => [];
  @override
  Future<void> insert(String table, Json values) async {}
  @override
  Future<void> update(String table, String id, Json values) async {}
  @override
  Future<void> delete(String table, String id) async {}
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [repoProvider.overrideWithValue(_FakeRepo())],
    child: MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(body: DashboardScreen()),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(E2E.installSecureStorageMock);

  testWidgets('seeded data fills the breakdown and offers See more',
      (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await E2E.launch(tester);

    final scroll = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Expense breakdown'), 200,
        scrollable: scroll);
    await tester.pumpAndSettle();

    // The seed puts ten distinct payees in the current month, so five are
    // listed and five sit behind the expander. This pins the seed's shape:
    // if someone thins it out, the dashboard stops demonstrating the feature.
    expect(find.text('Rent'), findsOneWidget); // largest
    expect(find.text('Electricity'), findsOneWidget); // 5th largest
    expect(find.text('Gym'), findsNothing); // smallest, hidden
    expect(find.text('See more (5)'), findsOneWidget);

    await tester.tap(find.text('See more (5)'));
    await tester.pumpAndSettle();
    expect(find.text('Gym'), findsOneWidget);
    expect(find.text('Phone recharge'), findsOneWidget);
  });

  testWidgets('expense breakdown shows 5 rows collapsed, all after See more',
      (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester);

    final scroll = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Expense breakdown'), 200,
        scrollable: scroll);
    await tester.pumpAndSettle();

    // Collapsed: the five largest are listed, the rest are not.
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('Petrol'), findsOneWidget); // 5th largest
    expect(find.text('Internet'), findsNothing); // 6th
    expect(find.text('Gym'), findsNothing); // 8th

    // No "Other" bucket — every payee is either shown or behind See more.
    expect(find.text('Other'), findsNothing);

    // The affordance names how many are hidden (8 - 5 = 3).
    expect(find.text('See more (3)'), findsOneWidget);

    await tester.tap(find.text('See more (3)'));
    await tester.pumpAndSettle();

    // Expanded: every payee is present, with its own amount.
    for (final entry in _payees.entries) {
      expect(find.text(entry.key), findsOneWidget,
          reason: '${entry.key} should be listed when expanded');
    }
    expect(find.text(money(700)), findsOneWidget); // the smallest, Gym
    expect(find.text('Show less'), findsOneWidget);

    // Collapsing hides the tail again.
    await tester.tap(find.text('Show less'));
    await tester.pumpAndSettle();
    expect(find.text('Gym'), findsNothing);
    expect(find.text('See more (3)'), findsOneWidget);
  });
}
