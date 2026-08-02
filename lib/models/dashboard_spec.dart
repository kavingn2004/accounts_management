import '../data/module_event.dart';

/// How one headline figure on a module dashboard is computed.
enum StatKind {
  /// Sum of a numeric column across every row.
  sum,

  /// Sum of a numeric column across rows whose `status` is not 'settled'.
  outstanding,

  /// field / against, as a percentage clamped to 0–100. A met goal reads
  /// 100%, matching `Modules.savings.trailingOf`.
  progress,

  /// (field − against) / against, signed. Return on capital.
  ratio,

  /// Sum of ledger event amounts for a field, inside the selected range.
  /// The only stat that moves when the range chips change on a balance module.
  eventSum,

  /// Number of rows.
  count,
}

/// One figure in a module dashboard's stat row.
class StatSpec {
  const StatSpec._(
    this.kind,
    this.label, {
    this.field,
    this.against,
    this.eventKinds,
    this.fallback,
    this.againstFallback,
  });

  /// [fallback] is read when [field] is absent on a row — for columns added
  /// after rows already existed, such as `total_invested`, whose predecessor
  /// `invested_amount` held the same figure. `FinanceMath.dashboard` makes the
  /// same substitution.
  const StatSpec.sum(String field, String label, {String? fallback})
      : this._(StatKind.sum, label, field: field, fallback: fallback);

  const StatSpec.outstanding(String field, String label)
      : this._(StatKind.outstanding, label, field: field);

  const StatSpec.progress(String field, String against, String label)
      : this._(StatKind.progress, label, field: field, against: against);

  const StatSpec.ratio(
    String field,
    String against,
    String label, {
    String? againstFallback,
  }) : this._(
          StatKind.ratio,
          label,
          field: field,
          against: against,
          againstFallback: againstFallback,
        );

  const StatSpec.eventSum(
    String field,
    String label, {
    List<EventKind> kinds = const [EventKind.increment],
  }) : this._(StatKind.eventSum, label, field: field, eventKinds: kinds);

  const StatSpec.count(String label) : this._(StatKind.count, label);

  final StatKind kind;
  final String label;
  final String? field;
  final String? against;
  final List<EventKind>? eventKinds;

  /// Column read when [field] is absent on a row.
  final String? fallback;

  /// Column read when [against] is absent on a row.
  final String? againstFallback;
}

/// The shape a module's chart takes.
enum ChartKind {
  /// Combined balance of one field over time, read from the ledger.
  cumulative,

  /// Two cumulative lines on shared axes (invested vs current value).
  dualCumulative,

  /// Sum of a dated column per time bucket, read from the rows themselves —
  /// for modules whose rows carry a `date`, which need no ledger.
  bars,
}

class ChartSpec {
  const ChartSpec._(
    this.kind, {
    required this.label,
    required this.field,
    this.second,
    this.firstLabel,
    this.secondLabel,
  });

  const ChartSpec.cumulative(String field, {required String label})
      : this._(ChartKind.cumulative, label: label, field: field);

  const ChartSpec.dualCumulative(
    String field,
    String second, {
    required String label,
    required String firstLabel,
    required String secondLabel,
  }) : this._(
          ChartKind.dualCumulative,
          label: label,
          field: field,
          second: second,
          firstLabel: firstLabel,
          secondLabel: secondLabel,
        );

  const ChartSpec.bars(String field, {required String label})
      : this._(ChartKind.bars, label: label, field: field);

  final ChartKind kind;
  final String label;
  final String field;
  final String? second;
  final String? firstLabel;
  final String? secondLabel;
}

/// A per-row bar list under the chart — "Emergency fund, ₹1,20,000 · 60%".
class BreakdownSpec {
  const BreakdownSpec.byRow({required this.value, this.of});

  /// Column holding each row's magnitude.
  final String value;

  /// Column holding the total that magnitude is measured against. When null
  /// the bars are proportional to the largest row instead of to a target.
  final String? of;
}

/// Everything a module page's dashboard header shows. A module with no
/// `dashboard` renders no header, so this is purely additive.
class DashboardSpec {
  const DashboardSpec({required this.stats, this.chart, this.breakdown});

  final List<StatSpec> stats;
  final ChartSpec? chart;
  final BreakdownSpec? breakdown;
}
