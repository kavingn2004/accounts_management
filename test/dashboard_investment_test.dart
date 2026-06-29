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
      find.text('Investment worth'),
      150,
      scrollable: dashboardScroll,
    );
    await tester.pumpAndSettle();

    expect(find.text('Investment worth'), findsOneWidget);
    expect(find.text('Invested'), findsOneWidget);

    // Seeded investments: current value 58200 + 27100 = 85300;
    // invested 50000 + 25000 = 75000.
    expect(find.text(money(85300)), findsOneWidget);
    expect(find.text(money(75000)), findsOneWidget);
  });
}
