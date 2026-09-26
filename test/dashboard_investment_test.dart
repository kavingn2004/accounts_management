import 'package:accounts_app/core/formatters.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(E2E.installSecureStorageMock);

  testWidgets('dashboard shows investment cards with seeded totals',
      (tester) async {
    await E2E.launch(tester);

    // The investment cards sit below the worth grid; scroll them into view.
    final dashboardScroll = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Investment'),
      150,
      scrollable: dashboardScroll,
    );
    await tester.pumpAndSettle();

    expect(find.text('Investment'), findsOneWidget);
    // 'Invested' is now the Investment tile's delta line, not its own card.
    expect(find.textContaining('invested'), findsOneWidget);

    // Seeded investments: current value 58200 + 27100 = 85300;
    // invested 50000 + 25000 = 75000.
    expect(find.text(money(85300)), findsOneWidget);
    expect(find.textContaining(money(75000)), findsOneWidget);
  });

  testWidgets('metric tiles carry a trend indicator', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await E2E.launch(tester);

    // Investment and savings have no stored history, so they report what the
    // data does support. Seeded: 85300 held against 75000 put in (+13.73%),
    // and 192000 saved of a 640000 combined target.
    expect(find.text('↑ 13.7% return'), findsOneWidget);
    expect(find.text('↑ 30% of target'), findsOneWidget);
    expect(find.text('target ${money(640000)}'), findsOneWidget);

    // Debtors and creditors are seeded with no instalment ledger, so walking
    // backwards finds no movement to report rather than inventing one.
    expect(find.text('no change'), findsNWidgets(2));
  });
}
