import '../../data/finance_repository.dart';
import '../sip_service.dart';
import 'ask_tools.dart';
import 'llm_client.dart';

/// The names that exist in one person's records.
///
/// A router cannot know that "kiki" is a payee or "jana" a debtor — those are
/// facts about the data, not about English. Matching the question against the
/// names actually present is what turns "how much for kiki" from a generic
/// spending breakdown into an answer.
class AskEntities {
  const AskEntities({
    this.payees = const {},
    this.people = const {},
    this.accounts = const {},
    this.holdings = const {},
  });

  final Set<String> payees;

  /// Debtors and creditors, mapped to which side they are on.
  final Map<String, String> people;
  final Set<String> accounts;
  final Set<String> holdings;

  static AskEntities from(AskData data) {
    String? name(Json r, String key) {
      final v = (r[key] ?? '').toString().trim();
      return v.length < 2 ? null : v;
    }

    final people = <String, String>{};
    for (final r in data.debtors) {
      final n = name(r, 'person_name');
      if (n != null) people[n.toLowerCase()] = 'money_owed_to_me';
    }
    for (final r in data.creditors) {
      final n = name(r, 'person_name');
      // Someone can be on both sides; owing them is the likelier question.
      if (n != null) people[n.toLowerCase()] = 'money_i_owe';
    }

    return AskEntities(
      payees: {
        for (final r in data.expenses)
          if (name(r, 'payee') != null) name(r, 'payee')!.toLowerCase()
      },
      people: people,
      accounts: {
        for (final r in data.accounts)
          if (name(r, 'name') != null) name(r, 'name')!.toLowerCase()
      },
      holdings: {
        for (final r in data.investments)
          if (name(r, 'name') != null) name(r, 'name')!.toLowerCase()
      },
    );
  }

  /// The first known name the question mentions, as a whole word.
  static String? find(String q, Iterable<String> names) {
    // Longest first: "indian bank" should beat "bank".
    final sorted = names.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final n in sorted) {
      if (RegExp('\\b${RegExp.escape(n)}\\b').hasMatch(q)) return n;
    }
    return null;
  }
}

/// A question, answered.
class AskResult {
  const AskResult({
    required this.answer,
    required this.tool,
    this.args = const {},
    this.routedBy = 'model',
  });

  final AskAnswer answer;

  /// Which tool produced it. Shown to the user: an answer about money should
  /// say where it came from.
  final String tool;
  final Map<String, dynamic> args;

  /// How the tool was chosen:
  ///   `model`    — the LLM picked it
  ///   `rules`    — no model is configured, so the keyword router picked it
  ///   `fallback` — a model is configured but could not be reached
  ///
  /// The three are distinct in the answer's footer. They were not always:
  /// `rules` once covered both "no model" and "did not need the model", so a
  /// working model was reported as a missing one on every answer.
  final String routedBy;
}

class AskFailure implements Exception {
  const AskFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Answers questions about the user's own finances.
///
/// The model's only job is choosing a tool and its arguments. Every figure is
/// computed here from rows the repository returned, and every sentence is
/// written from those figures — so no transaction, balance or holding is ever
/// sent anywhere, and no arithmetic is ever left to a language model.
///
/// What does leave, when a model is configured and the router is unsure, is
/// the question as typed. Against local Ollama it goes no further than this
/// machine. Against the deployed proxy it reaches a third party, and a
/// question can name a payee — "how much did I pay Anand" — so the wording is
/// private in a way the amounts never stop being.
class AskService {
  AskService({
    required FinanceRepository repo,
    LlmClient? llm,
    DateTime Function()? clock,
  })  : _repo = repo,
        _llm = llm,
        _now = clock ?? DateTime.now;

  final FinanceRepository _repo;
  final LlmClient? _llm;

  /// Pinned in tests so "this month" means the same thing on every run.
  final DateTime Function() _now;
  DateTime get now => _now();

  /// Warm the model up ahead of the first question. Safe to call repeatedly.
  Future<void> prewarm() async {
    try {
      await _llm?.prewarm();
    } catch (_) {
      // Never surfaces: a cold model is slow, not broken.
    }
  }

  Future<AskResult> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty) throw const AskFailure('Ask me something about your money.');

    final data = await _load();

    // Every question goes to the model when one is configured.
    //
    // This used to short-circuit whenever the keyword router was certain,
    // because a local Ollama takes seconds to reach the same tool. Against a
    // hosted model that costs a fraction of a second, so the saving is not
    // worth the inconsistency: the router only recognises phrasings someone
    // thought of, and "certain" is not the same as right.
    //
    // The router is still computed first, unconditionally — it is what answers
    // when there is no model, or when the model cannot be reached.
    final routed = classify(q, entities: AskEntities.from(data));
    ToolChoice choice;
    String routedBy;
    if (_llm == null) {
      choice = routed.choice;
      routedBy = 'rules';
    } else {
      try {
        choice = pinPeriod(q, await _llm.chooseTool(q, catalogue()));
        routedBy = 'model';
      } on LlmUnavailable {
        choice = routed.choice;
        // Distinct from 'rules': the router answered either way, but a model
        // that was configured and then failed is worth saying out loud.
        routedBy = 'fallback';
      }
    }

    final tool = AskTools.byName(choice.tool);
    if (tool == null) {
      throw AskFailure('I don\'t have a way to answer that yet '
          '(it asked for "${choice.tool}").');
    }

    return AskResult(
      answer: tool.run(data, _clean(choice.args)),
      tool: tool.name,
      args: choice.args,
      routedBy: routedBy,
    );
  }

  /// Drop nulls and empty strings so a tool sees an absent argument rather
  /// than an empty one — models like to fill every field they are shown.
  static Map<String, dynamic> _clean(Map<String, dynamic> args) => {
        for (final e in args.entries)
          if (e.value != null && e.value.toString().trim().isNotEmpty)
            e.key: e.value,
      };

  /// The tool list as the model sees it.
  static String catalogue() => AskTools.all
      .map((t) => '- ${t.name}: ${t.description}'
          '${t.args.isEmpty ? '' : '\n  args: ${t.args.entries.map((a) => '${a.key} (${a.value})').join('; ')}'}')
      .join('\n');

  /// Keyword routing, used when no model is configured or it cannot be
  /// reached.
  ///
  /// Deliberately dumb and completely predictable. It means the feature still
  /// answers the common questions with the model switched off entirely, which
  /// also makes the whole pipeline testable without one.
  static ToolChoice route(String question, {DateTime? now}) =>
      classify(question).choice;

  /// Route a question, and say whether the routing is certain.
  ///
  /// Certain means an explicit keyword matched, not that the catch-all fired.
  /// [ask] no longer branches on it — every question goes to the model when
  /// one is configured — but the corpus tests measure it, and it is the signal
  /// to reach for if the fast path is ever wanted back for a slow local model.
  static ({ToolChoice choice, bool confident}) classify(
    String question, {
    AskEntities entities = const AskEntities(),
  }) {
    final q = question.toLowerCase();
    final args = <String, dynamic>{};

    // Name the period; the tools resolve it against the clock.
    final period = _period(q);
    if (period != null) args['period'] = period;

    // Order matters: a question can contain several cues, and the most
    // specific reading has to win. "largest transactions" is a ranking
    // question that happens to use the word transaction.
    bool has(List<String> words) => words.any(q.contains);

    ({ToolChoice choice, bool confident}) sure(String tool,
            [Map<String, dynamic>? a]) =>
        (choice: ToolChoice(tool, a ?? args), confident: true);

    // 0. A name from the user's own records beats every keyword. "how much for
    //    kiki" is about kiki, whatever else the sentence contains.
    final person = AskEntities.find(q, entities.people.keys);
    if (person != null) {
      return sure(entities.people[person]!, {'name': person});
    }
    final holding = AskEntities.find(q, entities.holdings);
    if (holding != null) {
      return sure(
        q.contains('sip') ? 'sip_detail' : 'investment_summary',
        q.contains('sip') ? {'name': holding} : const {},
      );
    }
    final account = AskEntities.find(q, entities.accounts);
    if (account != null) {
      return sure('account_balances', {'account': account});
    }
    final payee = AskEntities.find(q, entities.payees);
    if (payee != null) {
      return sure('spend_by_payee', {...args, 'payee': payee});
    }

    // 0.5 Net worth, before anything that would grab a piece of it. "what am
    //     I worth" is not a question about accounts or investments alone, and
    //     both of those have keywords that would otherwise claim it.
    if (has(['net worth', 'networth', 'net-worth', 'am i worth',
             'i worth', 'total worth', 'overall position',
             'everything i have', 'all my money'])) {
      return sure('net_worth', const {});
    }

    // 1. Ranking — "biggest", "top 5", "most expensive".
    if (has(['biggest', 'largest', 'highest', 'top ', 'most expensive',
             'most spent', 'worst'])) {
      return sure('largest_expenses');
    }

    // 2. Debts, then holdings.
    if (has(['owes me', 'owe me', 'owed to me', 'debtor', 'receivable',
             'lent', 'lend', 'borrowed from me', 'pay me back'])) {
      return sure('money_owed_to_me', const {});
    }
    if (has(['i owe', 'creditor', 'payable', 'borrowed'])) {
      return sure('money_i_owe', const {});
    }
    if (q.contains('sip')) return sure('sip_detail');
    if (has(['invest', 'portfolio', 'fund', 'holding', 'nav',
             'stock', 'equity'])) {
      return sure('investment_summary', const {});
    }

    // 3. Where money sits, rather than where it went.
    if (has(['balance', 'account', 'bank', 'wallet',
             'money do i have', 'money i have', 'how much do i have'])) {
      return sure('account_balances', const {});
    }

    // 4. Period totals: both sides of the ledger and a count.
    //    "sav" deliberately, so save / saving / savings all land here.
    if (has(['transaction', 'summary', 'overview', 'earn', 'income',
             'sav', 'salary', 'left over', 'surplus', 'cash flow'])) {
      return sure('income_vs_expense');
    }

    // 5. Spending, said plainly.
    if (has(['spend', 'spent', 'spending', 'expense', 'expenditure', 'cost',
             'paid', 'payee', 'money going', 'money go', 'purchase',
             'bought', 'outgoing'])) {
      return sure('spend_by_payee');
    }

    // 6. Nothing matched. Spending is the likeliest guess, but it IS a guess —
    //    so say so, and let the model take the question if one is available.
    return (choice: ToolChoice('spend_by_payee', args), confident: false);
  }

  /// Take the period back off the model when the question states one plainly.
  ///
  /// A small model is bad at this in a specific, repeatable way: asked about
  /// "last month" on 16 August it answers `period=august` — this month — and
  /// the user gets the wrong month's figures with nothing to show for it.
  /// Sometimes it emits `period` twice. Meanwhile the phrase "last month"
  /// needs no intelligence to read, and [_period] already reads it correctly.
  ///
  /// So the model chooses the tool, and a plainly-stated period overrules
  /// whatever it said. Only the phrases that cannot mean anything else are
  /// pinned: "since july" stays with the model, because its from/to span is a
  /// better reading than the bare month the router would return.
  static ToolChoice pinPeriod(String question, ToolChoice choice) {
    final pinned = _relativePeriod(question.toLowerCase());
    if (pinned == null) return choice;
    final args = Map<String, dynamic>.from(choice.args)
      // resolveRange gives explicit dates precedence over the period, so a
      // pinned period has to clear the dates or it changes nothing.
      ..remove('from')
      ..remove('to')
      ..['period'] = pinned;
    return ToolChoice(choice.tool, args);
  }

  /// The unambiguous relative periods, and nothing else.
  static String? _relativePeriod(String q) {
    if (q.contains('last month') || q.contains('previous month')) {
      return 'last_month';
    }
    if (q.contains('this month') || q.contains('current month')) {
      return 'this_month';
    }
    if (q.contains('last year')) return 'last_year';
    if (q.contains('this year') || q.contains('current year')) {
      return 'this_year';
    }
    if (q.contains('this week')) return 'this_week';
    if (q.contains('today')) return 'today';
    return null;
  }

  /// The period a question names, or null when it names none.
  static String? _period(String q) {
    if (q.contains('last month') || q.contains('previous month')) {
      return 'last_month';
    }
    if (q.contains('this month') || q.contains('current month') ||
        q.contains('the month')) {
      return 'this_month';
    }
    if (q.contains('last year')) return 'last_year';
    if (q.contains('this year') || q.contains('current year')) {
      return 'this_year';
    }
    if (q.contains('this week') || q.contains('the week')) return 'this_week';
    if (q.contains('today')) return 'today';
    if (q.contains('all time') || q.contains('overall') ||
        q.contains('ever')) {
      return 'all';
    }
    // A named month: "in august", "for aug", "aug 2026".
    for (final name in const [
      'january', 'february', 'march', 'april', 'may', 'june', 'july',
      'august', 'september', 'october', 'november', 'december',
      'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept',
      'oct', 'nov', 'dec',
    ]) {
      if (!RegExp('\\b$name\\b').hasMatch(q)) continue;
      final year = RegExp(r'\b(20\d{2})\b').firstMatch(q);
      return year == null ? name : '$name ${year.group(1)}';
    }
    return null;
  }

  /// Read everything the tools might need, once.
  ///
  /// Tables that do not exist yet (a project without the newer migrations)
  /// come back empty rather than taking the question down with them.
  Future<AskData> _load() async {
    Future<List<Json>> table(String name) async {
      try {
        return await _repo.list(name);
      } catch (_) {
        return const [];
      }
    }

    return AskData(
      income: await table('income'),
      expenses: await table('expenses'),
      accounts: await table('accounts'),
      transfers: await table('transfers'),
      cashMoves: await table('cash_moves'),
      investments: await table('investments'),
      savings: await table('savings_goals'),
      installments: await table(SipFields.table),
      debtors: await table('debtors'),
      creditors: await table('creditors'),
      // Both only matter to net worth, which is the whole picture or nothing:
      // leaving loans out would overstate it by every rupee still owed.
      bills: await table('bills'),
      loans: await table('loans'),
    );
  }
}
