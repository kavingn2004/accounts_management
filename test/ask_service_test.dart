import 'dart:convert';

import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/services/ask/ask_service.dart';
import 'package:accounts_app/services/ask/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Repo implements FinanceRepository {
  _Repo(this.tables);
  final Map<String, List<Json>> tables;

  @override
  Future<List<Json>> list(String t,
      {String orderBy = 'created_at', bool ascending = false}) async {
    if (t == 'sip_installments') {
      throw Exception('relation "sip_installments" does not exist');
    }
    return [...(tables[t] ?? const [])];
  }

  @override
  Future<void> insert(String t, Json v) async {}
  @override
  Future<void> update(String t, String id, Json v) async {}
  @override
  Future<void> delete(String t, String id) async {}
  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

/// Answers with whatever the test scripted, or refuses.
class _FakeLlm implements LlmClient {
  _FakeLlm(this.reply);
  final Object reply; // ToolChoice, or an exception to throw
  String? sawCatalogue;
  String? sawQuestion;
  int calls = 0;

  @override
  Future<void> prewarm() async {}

  @override
  Future<ToolChoice> chooseTool(String q, String catalogue) async {
    calls++;
    sawQuestion = q;
    sawCatalogue = catalogue;
    if (reply is ToolChoice) return reply as ToolChoice;
    throw reply;
  }
}

_Repo _repo() => _Repo({
      'expenses': [
        {'date': '2026-07-03', 'amount': 8000, 'payee': 'Rent'},
        {'date': '2026-07-11', 'amount': 2200, 'payee': 'Groceries'},
        {'date': '2026-08-04', 'amount': 1500, 'payee': 'Bike service'},
      ],
      'income': [
        {'date': '2026-07-05', 'amount': 40000, 'source': 'Salary'},
      ],
      'accounts': [
        {'name': 'INDIAN BANK', 'type': 'bank', 'opening_balance': 5000},
      ],
      'investments': [
        {'id': '1', 'name': 'Nifty 50', 'type': 'fund',
          'total_invested': 10000, 'current_value': 12000},
      ],
    });

final _today = DateTime(2026, 8, 15);

void main() {
  test('even a question the router is sure about goes to the model', () async {
    // This once took the fast path: the router is certain here, and against a
    // local Ollama the model would have spent seconds agreeing. Against a
    // hosted model it is a fraction of a second, so every question is routed
    // the same way rather than two ways depending on phrasing.
    final llm = _FakeLlm(const ToolChoice('largest_expenses', {}));
    final result = await AskService(repo: _repo(), llm: llm, clock: () => _today)
        .ask('how much did I spend in July');

    expect(llm.calls, 1);
    expect(result.routedBy, 'model');
    expect(result.tool, 'largest_expenses',
        reason: 'the model chose, so the keyword guess must not win');
  });

  test('an unfamiliar phrasing is handed to the model', () async {
    final llm = _FakeLlm(const ToolChoice(
        'spend_by_payee', {'from': '2026-07-01', 'to': '2026-07-31'}));
    // No keyword the router recognises, so it is not confident.
    final result = await AskService(repo: _repo(), llm: llm, clock: () => _today)
        .ask('give me the July picture');

    expect(result.tool, 'spend_by_payee');
    expect(result.routedBy, 'model');
    expect(result.answer.text, contains('₹10,200'));
    // The question goes to the model; the data never does.
    expect(llm.sawQuestion, 'give me the July picture');
    expect(llm.sawCatalogue, contains('spend_by_payee'));
    expect(llm.sawCatalogue, isNot(contains('8000')),
        reason: 'no transaction may appear in what is sent to the model');
  });

  test('an unreachable model falls back to rules, still answering', () async {
    final llm = _FakeLlm(const LlmUnavailable('down'));
    // Not "tell me about the portfolio", which this test used to ask: that is
    // keyword-confident, so the model was never called and the injected
    // failure never happened. The fallback was never actually tested.
    final result = await AskService(repo: _repo(), llm: llm, clock: () => _today)
        .ask('give me the July picture');

    expect(llm.calls, 1, reason: 'the model must actually have been tried');
    expect(result.routedBy, 'fallback');
    expect(result.tool, 'spend_by_payee');
    expect(result.answer.text, contains('₹10,200'));
  });

  test('with no model at all it still works', () async {
    final result = await AskService(repo: _repo(), clock: () => _today)
        .ask('what is my bank balance');
    expect(result.tool, 'account_balances');
    expect(result.routedBy, 'rules');
  });

  // Keyword routing is now only ever a stand-in for a model that is absent or
  // unreachable, and the footer distinguishes the two. It used to conflate
  // them with "did not need the model", so the deployed build reported "no
  // model" under every answer while its model was healthy.
  group('how the answer was routed is reported honestly', () {
    test('a configured model is consulted whatever the phrasing', () async {
      final llm = _FakeLlm(const ToolChoice('spend_by_payee', {}));

      for (final q in ['what is my bank balance', 'give me the July picture']) {
        final result =
            await AskService(repo: _repo(), llm: llm, clock: () => _today)
                .ask(q);
        expect(result.routedBy, 'model', reason: q);
      }
      expect(llm.calls, 2);
    });

    test('a failed model is called out, not quietly swallowed', () async {
      final llm = _FakeLlm(const LlmUnavailable('down'));
      final result =
          await AskService(repo: _repo(), llm: llm, clock: () => _today)
              .ask('give me the July picture');

      expect(result.routedBy, 'fallback');
      expect(result.tool, 'spend_by_payee',
          reason: 'the keyword router still answers it');
    });
  });

  // Observed against the real model on 16 August: asked for "last month" it
  // answered period=august — this month — so the user got the wrong month's
  // figures. It also emitted period twice. The phrase needs no intelligence
  // to read, so the app reads it and overrules the model.
  group('a plainly stated period is not left to the model', () {
    test('overrules the wrong month the model named', () async {
      final llm =
          _FakeLlm(const ToolChoice('income_vs_expense', {'period': 'august'}));
      final result =
          await AskService(repo: _repo(), llm: llm, clock: () => _today)
              .ask('income vs expenses for last month');

      expect(result.args['period'], 'last_month');
    });

    test('clears dates the model invented, which would win otherwise', () {
      // resolveRange prefers explicit from/to over period, so leaving them in
      // would make the pinned period decorative.
      final pinned = AskService.pinPeriod(
        'what did I spend this month',
        const ToolChoice('spend_by_payee',
            {'period': 'july', 'from': '2026-07-01', 'to': '2026-07-31'}),
      );

      expect(pinned.args['period'], 'this_month');
      expect(pinned.args.containsKey('from'), isFalse);
      expect(pinned.args.containsKey('to'), isFalse);
    });

    test('leaves the model alone when no relative phrase is used', () {
      // "since july" is a span the model reads better than the router, which
      // would flatten it to July alone.
      const choice = ToolChoice(
          'spend_by_payee', {'from': '2026-07-01', 'to': '2026-08-15'});
      final pinned =
          AskService.pinPeriod('where did my cash go since july', choice);

      expect(pinned.args, choice.args);
    });

    test('keeps the tool the model chose', () {
      final pinned = AskService.pinPeriod('how did I do last month',
          const ToolChoice('income_vs_expense', {'period': 'august'}));
      expect(pinned.tool, 'income_vs_expense');
    });
  });

  test('an invented tool is refused, not run', () async {
    final llm = _FakeLlm(const ToolChoice('drop_all_tables', {}));
    await expectLater(
      AskService(repo: _repo(), llm: llm).ask('do the thing with the stuff'),
      throwsA(isA<AskFailure>()),
    );
  });

  test('empty arguments are dropped rather than passed through', () async {
    // Models fill every field they are shown; an empty payee must not become
    // a filter that matches nothing.
    final llm = _FakeLlm(const ToolChoice('spend_by_payee',
        {'payee': '', 'from': null, 'to': '  '}));
    final result =
        await AskService(repo: _repo(), llm: llm).ask('anything at all?');
    expect(result.answer.text, contains('₹11,700'),
        reason: 'all three expenses, unfiltered');
  });

  test('a missing table does not take the question down', () async {
    // sip_installments throws in this repo, as on a project without the
    // migration.
    final result = await AskService(repo: _repo(), clock: () => _today)
        .ask('how is my sip');
    expect(result.tool, 'sip_detail');
    expect(result.answer.text, contains('no SIPs'));
  });

  test('an empty question is refused politely', () async {
    await expectLater(
      AskService(repo: _repo()).ask('   '),
      throwsA(isA<AskFailure>()),
    );
  });

  group('rule routing', () {
    ToolChoice r(String q) => AskService.route(q, now: _today);

    test('reads the common intents', () {
      expect(r('how much did I spend on food').tool, 'spend_by_payee');
      expect(r('what is my bank balance').tool, 'account_balances');
      expect(r('how are my investments').tool, 'investment_summary');
      expect(r('how is my tata sip').tool, 'sip_detail');
      expect(r('what did I earn').tool, 'income_vs_expense');
      expect(r('biggest expense').tool, 'largest_expenses');
    });

    test('names the period rather than computing dates', () {
      // Date arithmetic moved out of the router and the model alike: both
      // name a span, and the tools resolve it against the clock.
      expect(r('what did I spend last month').args['period'], 'last_month');
      expect(r('spending this month').args['period'], 'this_month');
      expect(r('total expense in august').args['period'], 'august');
      expect(r('spending in aug 2024').args['period'], 'aug 2024');
    });

    test('a question naming no period gets none', () {
      expect(r('where is my money going').args.containsKey('period'), isFalse);
    });
  });

  group('model output parsing', () {
    test('survives a fenced code block', () {
      final c = OpenAiCompatibleClient.parseChoice(
          '```json\n{"tool":"account_balances","args":{}}\n```');
      expect(c.tool, 'account_balances');
    });

    test('survives chatter either side', () {
      final c = OpenAiCompatibleClient.parseChoice(
          'Sure! {"tool":"spend_by_payee","args":{"payee":"rent"}} Hope that helps.');
      expect(c.tool, 'spend_by_payee');
      expect(c.args['payee'], 'rent');
    });

    test('accepts the "arguments" spelling too', () {
      final c = OpenAiCompatibleClient.parseChoice(
          '{"name":"sip_detail","arguments":{"name":"tata"}}');
      expect(c.tool, 'sip_detail');
      expect(c.args['name'], 'tata');
    });

    test('reads the compact line the prompt asks for', () {
      final c = OpenAiCompatibleClient.parseChoice(
          'spend_by_payee; period=last_month; payee=groceries');
      expect(c.tool, 'spend_by_payee');
      expect(c.args['period'], 'last_month');
      expect(c.args['payee'], 'groceries');
    });

    test('a bare tool name needs no arguments', () {
      expect(OpenAiCompatibleClient.parseChoice('account_balances').tool,
          'account_balances');
    });

    test('ignores a trailing explanation on later lines', () {
      final c = OpenAiCompatibleClient.parseChoice(
          'sip_detail; name=tata\nThis will show your SIP.');
      expect(c.tool, 'sip_detail');
      expect(c.args['name'], 'tata');
    });

    test('tolerates quotes and stray spacing', () {
      final c = OpenAiCompatibleClient.parseChoice(
          '  largest_expenses ;  limit = "3" ');
      expect(c.tool, 'largest_expenses');
      expect(c.args['limit'], '3');
    });

    test('a value containing a space survives', () {
      final c = OpenAiCompatibleClient.parseChoice(
          'account_balances; account=Indian Bank');
      expect(c.args['account'], 'Indian Bank');
    });

    test('refuses prose with no decision in it', () {
      expect(
        () => OpenAiCompatibleClient.parseChoice('I think you spent a lot!'),
        throwsA(isA<LlmUnavailable>()),
      );
    });
  });

  // The deployed build talks to netlify/functions/ask-llm.mjs instead of
  // Ollama, and the only thing that changes is the base URL. These pin the
  // parts of that arrangement the app is responsible for.
  group('talking to a proxy', () {
    test('a relative base URL posts to the site\'s own /api path', () async {
      late Uri asked;
      final client = OpenAiCompatibleClient(
        baseUrl: '/api',
        model: '',
        client: MockClient((req) async {
          asked = req.url;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'account_balances'}
                }
              ]
            }),
            200,
          );
        }),
      );

      final choice = await client.chooseTool('what is in the bank', 'tools');

      expect(asked.toString(), '/api/chat/completions');
      expect(choice.tool, 'account_balances');
    });

    test('prewarm stays local — a proxy is never woken up', () async {
      var called = false;
      final client = OpenAiCompatibleClient(
        baseUrl: '/api',
        model: '',
        client: MockClient((req) async {
          called = true;
          return http.Response('', 200);
        }),
      );

      await client.prewarm();

      expect(called, isFalse);
    });

    test('a proxy with no key configured reads as unavailable', () async {
      final client = OpenAiCompatibleClient(
        baseUrl: '/api',
        model: '',
        client: MockClient(
          (req) async => http.Response('{"error":"No model configured"}', 503),
        ),
      );

      // AskService catches this and answers by keyword instead, so a deploy
      // missing GROQ_API_KEY degrades rather than breaks.
      expect(
        () => client.chooseTool('anything', 'tools'),
        throwsA(isA<LlmUnavailable>()),
      );
    });
  });
}
