import 'package:accounts_app/app.dart';
import 'package:accounts_app/data/local_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final secure = <String, String>{};
  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      switch (call.method) {
        case 'write':
          secure[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return secure[args['key']];
        case 'delete':
          secure.remove(args['key']);
          return null;
        case 'deleteAll':
          secure.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(secure);
        case 'containsKey':
          return secure.containsKey(args['key']);
      }
      return null;
    });
  });

  Future<void> pumpApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs);
    await LocalRepository(store).seedIfNeeded();
    await tester.pumpWidget(ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(store)],
      child: const AccountsApp(),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> setPin(WidgetTester tester) async {
    expect(find.text('Set a PIN'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '1234');
    await tester.enterText(fields.at(1), '1234');
    await tester.tap(find.text('Save PIN'));
    await tester.pumpAndSettle();
  }

  testWidgets('boot → set PIN → dashboard with seeded data', (tester) async {
    await pumpApp(tester);
    await setPin(tester);
    expect(find.text('Accounflow'), findsOneWidget);
    expect(find.text('Net worth'), findsOneWidget);
  });

  testWidgets('navigate to Income and delete an entry', (tester) async {
    await pumpApp(tester);
    await setPin(tester);

    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('Income')));
    await tester.pumpAndSettle();

    // Show all dates so the seeded 'Salary' (dated weeks ago) is visible
    // regardless of today's date and the default current-month filter.
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    expect(find.text('Salary'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Salary'), findsNothing);
  });

  testWidgets('alerts: view list and add a custom alert', (tester) async {
    await pumpApp(tester);
    await setPin(tester);

    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Alerts'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Test alert');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    // Info-severity custom alert sorts to the bottom; scroll it into view.
    final found = find.text('Test alert');
    await tester.scrollUntilVisible(found, 150,
        scrollable: find.byType(Scrollable).last);
    expect(found, findsOneWidget);
  });
}
