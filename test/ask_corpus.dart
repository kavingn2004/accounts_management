/// A generated question corpus for measuring routing accuracy.
///
/// Built from templates crossed with periods and subjects rather than written
/// by hand, so it covers phrasings nobody thought to try — which is the whole
/// point of measuring instead of spot-checking.
library;

class AskCase {
  const AskCase(this.question, this.tool, {this.period});
  final String question;

  /// The tool this question must route to.
  final String tool;

  /// The period it must resolve to, when it names one.
  final String? period;
}

/// (phrase, canonical period) pairs. The empty phrase means "no period named".
const _periods = <(String, String?)>[
  ('', null),
  (' this month', 'this_month'),
  (' current month', 'this_month'),
  (' last month', 'last_month'),
  (' previous month', 'last_month'),
  (' this year', 'this_year'),
  (' last year', 'last_year'),
  (' this week', 'this_week'),
  (' today', 'today'),
  (' in august', 'august'),
  (' in aug', 'aug'),
  (' in july', 'july'),
  (' in january', 'january'),
  (' in december', 'december'),
  (' overall', 'all'),
  (' all time', 'all'),
];

const _spendTemplates = [
  'how much did i spend',
  'what did i spend',
  'where is my money going',
  'total spending',
  'total expense',
  'total expenses',
  'my spending',
  'show my expenses',
  'how much have i spent',
  'expense report',
  'what are my expenses',
  'spending breakdown',
  'where did my money go',
  'money spent',
];

const _totalsTemplates = [
  'total transactions',
  'transaction summary',
  'how many transactions',
  'give me a summary',
  'financial overview',
  'what did i earn',
  'my income',
  'did i save anything',
  'am i saving money',
  'income and expenses',
  'how much did i earn',
  'savings rate',
];

const _balanceTemplates = [
  'what is my balance',
  'account balance',
  'how much is in my bank',
  'show my accounts',
  'bank balance',
  'how much money do i have',
  'balance of indian bank',
  'my account balances',
];

const _investTemplates = [
  'how are my investments doing',
  'investment summary',
  'my portfolio',
  'portfolio value',
  'how are my funds',
  'investment returns',
  'what are my investments worth',
  'show my portfolio',
];

const _sipTemplates = [
  'how is my sip',
  'sip performance',
  'my sip returns',
  'tata sip',
  'show my sip',
  'sip units',
];

const _owedToMeTemplates = [
  'who owes me money',
  'who owes me',
  'my debtors',
  'show my debtors',
  'outstanding receivables',
  'who has to pay me back',
  'money owed to me',
  'what did i lend',
];

const _iOweTemplates = [
  'who do i owe',
  'my creditors',
  'what do i owe',
  'outstanding payables',
  'who have i borrowed from',
  'money i owe',
];

/// Net worth is the whole picture, so these must not be pulled apart by the
/// keywords that claim a piece of it — "worth" alone belongs to investments,
/// "have" to accounts.
const _netWorthTemplates = [
  'what is my net worth',
  'my net worth',
  'net worth',
  'whats my networth',
  'what am i worth',
  'how much am i worth',
  'what is my total worth',
  'my overall position',
  'how much is everything i have',
  'all my money',
];

const _largestTemplates = [
  'what was my biggest expense',
  'largest expense',
  'biggest spend',
  'my most expensive purchase',
  'top expenses',
  'largest transactions', // deliberately ambiguous with "transaction"
];

/// Every case, deduplicated by question text.
List<AskCase> buildCorpus() {
  final out = <String, AskCase>{};

  void add(List<String> templates, String tool, {bool periodic = true}) {
    for (final t in templates) {
      for (final (phrase, period) in _periods) {
        if (!periodic && phrase.isNotEmpty) continue;
        final q = '$t$phrase';
        out[q] = AskCase(q, tool, period: period);
        final withQ = '$q?';
        out[withQ] = AskCase(withQ, tool, period: period);
      }
    }
  }

  add(_spendTemplates, 'spend_by_payee');
  add(_totalsTemplates, 'income_vs_expense');
  add(_largestTemplates, 'largest_expenses');
  add(_owedToMeTemplates, 'money_owed_to_me', periodic: false);
  add(_iOweTemplates, 'money_i_owe', periodic: false);
  add(_balanceTemplates, 'account_balances', periodic: false);
  add(_netWorthTemplates, 'net_worth', periodic: false);
  add(_investTemplates, 'investment_summary', periodic: false);
  add(_sipTemplates, 'sip_detail', periodic: false);

  // Casing and padding variants, to catch anything case-sensitive.
  for (final c in out.values.toList()) {
    final upper = c.question.toUpperCase();
    out[upper] = AskCase(upper, c.tool, period: c.period);
    final padded = '  ${c.question}  ';
    out[padded] = AskCase(padded, c.tool, period: c.period);
  }

  return out.values.toList();
}
