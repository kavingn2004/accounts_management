import 'package:accounts_app/app.dart';
import 'package:accounts_app/data/local_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shared E2E setup: mocks the secure-storage channel (for PIN) and pumps the
/// real app against a seeded in-memory store.
class E2E {
  static final _secure = <String, String>{};
  static const _channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  static void installSecureStorageMock() {
    _secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      switch (call.method) {
        case 'write':
          _secure[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return _secure[args['key']];
        case 'delete':
          _secure.remove(args['key']);
          return null;
        case 'deleteAll':
          _secure.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(_secure);
        case 'containsKey':
          return _secure.containsKey(args['key']);
      }
      return null;
    });
  }

  static LocalStore? lastStore;

  /// Boot the real app against a seeded on-device store.
  ///
  /// [overrides] is for anything that would otherwise reach the network — the
  /// quote service and the NAV API — so an end-to-end run is deterministic and
  /// offline. Everything else stays as the app wires it, which is the point.
  static Future<void> pumpApp(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs);
    lastStore = store;
    await LocalRepository(store).seedIfNeeded();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        ...overrides,
      ],
      child: const AccountsApp(),
    ));
    await tester.pumpAndSettle();
  }

  static Future<void> setPin(WidgetTester tester) async {
    expect(find.text('Set a PIN'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '1234');
    await tester.enterText(fields.at(1), '1234');
    await tester.tap(find.text('Save PIN'));
    await tester.pumpAndSettle();
  }

  /// Boot the app and unlock to the dashboard.
  static Future<void> launch(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    await pumpApp(tester, overrides: overrides);
    await setPin(tester);
  }

  /// Bring a widget into view before tapping it. Forms are taller than the
  /// 800x600 default test surface, and a tap that misses fails silently.
  static Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  static Future<void> openDrawerItem(
      WidgetTester tester, String title) async {
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    // The drawer rows are custom widgets (not ListTile) since the redesign,
    // so match on the label inside the Drawer subtree.
    final item = find.descendant(
      of: find.byType(Drawer),
      matching: find.text(title),
    );
    final drawerScroll = find
        .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(item, 120, scrollable: drawerScroll);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();
  }
}
