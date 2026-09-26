import 'package:accounts_app/core/components.dart';
import 'package:accounts_app/features/ask/ask_button.dart';
import 'package:accounts_app/services/ask/ask_service.dart';
import 'package:accounts_app/services/ask/llm_client.dart';
import 'package:accounts_app/services/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// The Ask feature end to end through the real app: boot, unlock, open the
/// drawer, type a question, read the answer — against the seeded store, with
/// the model stubbed so the run is deterministic and offline.

/// Routes to whatever the test scripted, standing in for Qwen.
class _ScriptedLlm implements LlmClient {
  _ScriptedLlm(this.choice);
  final Object choice; // ToolChoice, or an exception to throw
  int calls = 0;

  @override
  Future<void> prewarm() async {}

  @override
  Future<ToolChoice> chooseTool(String question, String catalogue) async {
    calls++;
    if (choice is ToolChoice) return choice as ToolChoice;
    throw choice;
  }
}

/// The real service over the real seeded repository — only the model is
/// swapped, so everything below it is exactly what ships.
List<Override> _withLlm(LlmClient llm) => [
      askServiceProvider.overrideWith(
        (ref) => AskService(repo: ref.watch(repoProvider), llm: llm),
      ),
    ];

/// The round launcher on the dashboard, which is how most people will reach
/// the chat. The drawer entry goes to the same screen.
Future<void> _openAsk(WidgetTester tester) async {
  await tester.tap(find.byType(AskButton));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String question) async {
  await tester.enterText(find.byType(TextField).first, question);
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.arrow_upward));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(E2E.installSecureStorageMock);

  testWidgets('ask a spending question and get a checkable answer',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final llm = _ScriptedLlm(const ToolChoice('spend_by_payee', {}));
    await E2E.launch(tester, overrides: _withLlm(llm));
    await _openAsk(tester);

    expect(find.text('Ask about your money'), findsOneWidget,
        reason: 'the empty state invites a question');

    // A phrasing the keyword router does not recognise, so the model is
    // actually consulted.
    await _type(tester, 'give me the money picture');

    expect(llm.calls, 1, reason: 'the model chose the tool');
    // The conversation keeps what was asked, not just the answer.
    expect(find.text('give me the money picture'), findsOneWidget);
    // The seed has expenses, so a real total comes back with workings.
    expect(find.textContaining('You spent'), findsOneWidget);
    expect(find.textContaining('from spend_by_payee'), findsOneWidget,
        reason: 'every answer names the tool that produced it');
  });

  testWidgets('a recognised question still goes to the model', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final llm = _ScriptedLlm(const ToolChoice('largest_expenses', {}));
    await E2E.launch(tester, overrides: _withLlm(llm));
    await _openAsk(tester);

    // Keyword-confident phrasing. It used to skip the model; now nothing does.
    await _type(tester, 'how much did I spend last month');

    expect(llm.calls, 1);
    expect(find.textContaining('from largest_expenses'), findsOneWidget);
    expect(find.textContaining('matched by keyword'), findsNothing);
  });

  testWidgets('a tapped suggestion asks without typing', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final llm = _ScriptedLlm(const ToolChoice('account_balances', {}));
    await E2E.launch(tester, overrides: _withLlm(llm));
    await _openAsk(tester);

    await tester.tap(find.text('What is in my bank account?'));
    await tester.pumpAndSettle();

    expect(find.textContaining('from account_balances'), findsOneWidget);
    // The seeded accounts are Cash and HDFC Bank.
    expect(find.textContaining('accounts you hold'), findsOneWidget);
  });

  testWidgets('with the model down it still answers, and says so',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final llm = _ScriptedLlm(const LlmUnavailable('connection refused'));
    await E2E.launch(tester, overrides: _withLlm(llm));
    await _openAsk(tester);

    // Deliberately a phrasing the router is NOT certain about. This test used
    // to ask "how are my investments doing", which is keyword-confident — the
    // model was never called, so the injected failure was never reached and
    // the test passed without exercising the fallback at all.
    await _type(tester, 'give me the July picture');

    expect(llm.calls, 1, reason: 'the model must actually have been tried');
    expect(find.textContaining('from spend_by_payee'), findsOneWidget);
    expect(find.textContaining('model unreachable'), findsOneWidget,
        reason: 'the fallback must be visible, not silent');
  });

  testWidgets('a working model is never reported as a missing one',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final llm = _ScriptedLlm(const ToolChoice('account_balances', {}));
    await E2E.launch(tester, overrides: _withLlm(llm));
    await _openAsk(tester);

    // The deployed site said "no model" under every answer while its model
    // was healthy and reachable. Whatever the phrasing, that must not recur.
    for (final q in ['how much did I spend last month', 'what about august']) {
      await _type(tester, q);
      expect(find.textContaining('no model'), findsNothing, reason: q);
    }
  });

  testWidgets('an invented tool is refused rather than run', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final llm = _ScriptedLlm(const ToolChoice('delete_everything', {}));
    await E2E.launch(tester, overrides: _withLlm(llm));
    await _openAsk(tester);

    await _type(tester, 'wipe my data');

    expect(find.textContaining("don't have a way to answer"), findsOneWidget);
    expect(find.textContaining('from '), findsNothing,
        reason: 'nothing ran, so there is no tool to attribute');
  });

  testWidgets('the answer shows the figures behind it', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final llm = _ScriptedLlm(const ToolChoice('largest_expenses', {'limit': '3'}));
    await E2E.launch(tester, overrides: _withLlm(llm));
    await _openAsk(tester);

    // Unfamiliar phrasing, so the scripted choice (and its limit) is used.
    await _type(tester, 'rank things for me');

    // Three workings rows, each a labelled money figure — the point being
    // that a person can check the sentence above them.
    expect(find.byType(MoneyText), findsNWidgets(3));
  });

  testWidgets('the chat keeps the whole conversation', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final llm = _ScriptedLlm(const ToolChoice('account_balances', {}));
    await E2E.launch(tester, overrides: _withLlm(llm));
    await _openAsk(tester);

    await _type(tester, 'first question');
    await _type(tester, 'second question');

    // Both turns and both answers remain on screen.
    expect(find.text('first question'), findsOneWidget);
    expect(find.text('second question'), findsOneWidget);
    expect(find.textContaining('from account_balances'), findsNWidgets(2));

    // And it can be emptied.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('first question'), findsNothing);
    expect(find.text('Ask about your money'), findsOneWidget);
  });

  testWidgets('the drawer reaches the same chat', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await E2E.launch(tester,
        overrides: _withLlm(_ScriptedLlm(const ToolChoice('account_balances', {}))));
    await E2E.openDrawerItem(tester, 'Ask');

    expect(find.text('Ask about your money'), findsOneWidget);
  });
}
