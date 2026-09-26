# Per-page Module Dashboards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every module page a collapsible dashboard header — headline figures plus a chart — backed by a new ledger that records every value change so growth over time can actually be drawn.

**Architecture:** A generic `module_events` table records each value-changing action (`open` / `increment` / `decrement` / `set`) with the resulting `balance_after`. A pure-Dart metrics layer turns rows + events + a date range into `Stat`s and a `Series`; each module declares what it wants via a `DashboardSpec` on its existing `EntityConfig`. One `ModuleDashboard` widget renders the result for all ten pages.

**Tech Stack:** Flutter 3.3+, Riverpod, `fl_chart ^1.2.0` (already a dependency), `intl`, `shared_preferences`, Supabase (JSONB tables + RLS).

**Spec:** `docs/superpowers/specs/2026-08-02-per-page-dashboards-design.md`

## Global Constraints

- Computation files (`module_metrics.dart`, `module_event.dart`) import **no Flutter** — only `intl`, `finance_repository.dart`, `dashboard_spec.dart`, `core/formatters.dart`. This is what makes them unit-testable. `core/formatters.dart` → `core/config.dart` → no Flutter, verified.
- Money is always rendered with `money()` from `lib/core/formatters.dart` (Indian digit grouping, paise only when present). Never `toStringAsFixed` on a rupee figure.
- Dates are stored `yyyy-MM-dd` via `isoDate()`; parsed with `DateTime.tryParse`, converted to local when the parse yields UTC.
- Date windows are **half-open** — `[start, end)` — matching `DateWindow` in `lib/features/dashboard/trends.dart`. `_activeRange()` in `entity_screen.dart` returns an **inclusive** `DateTimeRange`; convert at the boundary, never mix conventions.
- Ledger writes are best-effort and must never throw into the UI or roll back the value update they describe.
- Charts inherit `AppTheme`: `context.colors.border` for axes, `c.positive` / `c.negative` / `c.accent` for marks, `tabular` font features on figures. Copy the styling conventions in `_BarChart` (`lib/features/dashboard/dashboard_screen.dart:442`).
- No backfill. An empty ledger shows "No history yet", never a zero line.
- Run `flutter analyze` before every commit; it must be clean.

---

### Task 1: The `module_events` ledger

**Files:**
- Create: `lib/data/module_event.dart`
- Create: `supabase/migrations/0005_module_events.sql`
- Test: `test/module_event_test.dart`

**Interfaces:**
- Consumes: `Json` from `lib/data/finance_repository.dart`.
- Produces: `EventKind` enum (`open`, `increment`, `decrement`, `set`); `ModuleEvent` class with `.toJson()`; `const moduleEventsTable = 'module_events'`; `Events` static reader (`amount`, `balanceAfter`, `field`, `parentId`, `kind`, `date`, `forField`); `Future<void> logModuleEvent(FinanceRepository, ModuleEvent)`.

- [ ] **Step 1: Write the failing test**

Create `test/module_event_test.dart`:

```dart
import 'package:accounts_app/data/module_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModuleEvent serialisation', () {
    test('writes the storage shape the metrics layer reads back', () {
      final e = ModuleEvent(
        parentId: 'sg-1',
        parentType: 'savings_goals',
        field: 'saved_amount',
        kind: EventKind.increment,
        amount: 5000,
        balanceAfter: 125000,
        date: DateTime(2026, 8, 2),
        account: 'HDFC Bank',
      );
      expect(e.toJson(), {
        'parent_id': 'sg-1',
        'parent_type': 'savings_goals',
        'field': 'saved_amount',
        'kind': 'increment',
        'amount': 5000.0,
        'balance_after': 125000.0,
        'date': '2026-08-02',
        'account': 'HDFC Bank',
      });
    });

    test('omits account and note when absent rather than writing nulls', () {
      final e = ModuleEvent(
        parentId: 'sg-1',
        parentType: 'savings_goals',
        field: 'saved_amount',
        kind: EventKind.open,
        amount: 120000,
        balanceAfter: 120000,
        date: DateTime(2026, 8, 2),
      );
      expect(e.toJson().containsKey('account'), isFalse);
      expect(e.toJson().containsKey('note'), isFalse);
    });
  });

  group('Events reader', () {
    Json ev(String id, String field, String date, double after) => {
          'parent_id': id,
          'parent_type': 'savings_goals',
          'field': field,
          'kind': 'increment',
          'amount': 100.0,
          'balance_after': after,
          'date': date,
        };

    test('forField filters by module and field, oldest first', () {
      final all = [
        ev('a', 'saved_amount', '2026-08-02', 300),
        ev('a', 'saved_amount', '2026-07-01', 100),
        ev('a', 'target_amount', '2026-07-15', 999),
        {...ev('b', 'saved_amount', '2026-07-20', 200), 'parent_type': 'investments'},
      ];
      final out = Events.forField(all, 'savings_goals', 'saved_amount');
      expect(out.length, 2);
      expect(out.map(Events.balanceAfter).toList(), [100.0, 300.0]);
    });

    test('rows with an unparseable date are dropped, not sorted arbitrarily', () {
      final out = Events.forField([
        ev('a', 'saved_amount', 'not-a-date', 50),
        ev('a', 'saved_amount', '2026-07-01', 100),
      ], 'savings_goals', 'saved_amount');
      expect(out.length, 1);
      expect(Events.balanceAfter(out.single), 100.0);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/module_event_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'accounts_app' ... module_event.dart` / "Target of URI doesn't exist".

- [ ] **Step 3: Write the implementation**

Create `lib/data/module_event.dart`:

```dart
import 'package:intl/intl.dart';

import 'finance_repository.dart';

/// Table holding the ledger. Every module writes here — see [ModuleEvent].
const String moduleEventsTable = 'module_events';

/// What a [ModuleEvent] did to the field it names.
enum EventKind {
  /// The row was created; [ModuleEvent.balanceAfter] is its opening value.
  open,

  /// A value was added (savings contribution, further investment).
  increment,

  /// A value was paid down (creditor payment, loan EMI).
  decrement,

  /// A value was overwritten wholesale (investment revaluation, settlement).
  set,
}

/// One value-changing action on one row of one module.
///
/// The app stores no history otherwise: "Add to savings" reads a column, adds
/// to it, and writes it straight back. Without this ledger a growth chart has
/// nothing to draw.
class ModuleEvent {
  const ModuleEvent({
    required this.parentId,
    required this.parentType,
    required this.field,
    required this.kind,
    required this.amount,
    required this.balanceAfter,
    required this.date,
    this.account,
    this.note,
  });

  /// Id of the source row, and the table it lives in.
  final String parentId;
  final String parentType;

  /// Which column moved — 'saved_amount', 'current_value', 'outstanding'.
  final String field;
  final EventKind kind;

  /// The delta. For [EventKind.set] this is the new value, since there is no
  /// meaningful delta when a figure is replaced rather than adjusted.
  final double amount;

  /// The field's value immediately after the action.
  ///
  /// This is the load-bearing column. A growth curve is read as a step
  /// function through recorded balances, never re-derived forward from an
  /// opening figure — forward derivation drifts the moment a row is edited by
  /// hand, and the chart would then contradict the total printed above it.
  final double balanceAfter;

  final DateTime date;

  /// The account the cash moved through, when the user chose one.
  final String? account;
  final String? note;

  Json toJson() => {
        'parent_id': parentId,
        'parent_type': parentType,
        'field': field,
        'kind': kind.name,
        'amount': amount,
        'balance_after': balanceAfter,
        'date': DateFormat('yyyy-MM-dd').format(date),
        if (account != null) 'account': account,
        if (note != null) 'note': note,
      };
}

/// Readers for stored event rows. The storage shape is described here and
/// nowhere else, so a column rename is a one-file change.
class Events {
  const Events._();

  static double amount(Json e) => (e['amount'] as num?)?.toDouble() ?? 0;

  static double balanceAfter(Json e) =>
      (e['balance_after'] as num?)?.toDouble() ?? 0;

  static String field(Json e) => (e['field'] ?? '').toString();
  static String parentId(Json e) => (e['parent_id'] ?? '').toString();
  static String parentType(Json e) => (e['parent_type'] ?? '').toString();
  static String kind(Json e) => (e['kind'] ?? '').toString();

  /// Parse the stored `yyyy-MM-dd`, or null when it is missing or malformed.
  /// Callers skip null-dated events rather than counting them at epoch, which
  /// would plant a spike at the left edge of every chart.
  static DateTime? date(Json e) {
    final v = e['date'];
    if (v == null) return null;
    final d = DateTime.tryParse(v.toString());
    if (d == null) return null;
    return d.isUtc ? d.toLocal() : d;
  }

  /// Events for one module's field, oldest first, undated rows dropped.
  static List<Json> forField(
    List<Json> events,
    String parentType,
    String field,
  ) {
    final out = events
        .where((e) =>
            Events.parentType(e) == parentType &&
            Events.field(e) == field &&
            date(e) != null)
        .toList();
    out.sort((a, b) => date(a)!.compareTo(date(b)!));
    return out;
  }
}

/// Append an event to the ledger.
///
/// Best-effort by design: the value update this describes has already been
/// committed, so a failure here must not surface as an error or roll anything
/// back. A missing event costs one point on a chart; a rolled-back
/// contribution costs the user their data.
Future<void> logModuleEvent(FinanceRepository repo, ModuleEvent event) async {
  try {
    await repo.insert(moduleEventsTable, event.toJson());
  } catch (_) {
    // Intentionally swallowed — see the doc comment above.
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/module_event_test.dart`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write the Supabase migration**

Create `supabase/migrations/0005_module_events.sql`, structurally a copy of `0004_debt_payments.sql`:

```sql
-- =============================================================================
-- 0005 — module_events  (generic per-row value ledger for every module)
-- =============================================================================
-- Savings and investments overwrite their values in place, so the app has no
-- record of how a balance got where it is and no way to chart growth. This
-- table logs every value-changing action on any module: parent_id = source row
-- id, parent_type = source table, field = the column that moved, kind =
-- open/increment/decrement/set, and balance_after = the value that resulted.
--
-- balance_after is recorded at write time so curves are read rather than
-- re-derived; a forward rebuild would drift whenever a row is edited by hand.
--
-- Safe to run on an existing project: creates the table + owner-only RLS only
-- if it isn't already present.
-- =============================================================================

create extension if not exists pgcrypto;

do $$
begin
  if not exists (
    select 1 from pg_tables
    where schemaname = 'public' and tablename = 'module_events'
  ) then
    create table public.module_events (
      id         uuid        primary key default gen_random_uuid(),
      user_id    uuid        not null default auth.uid()
                             references auth.users (id) on delete cascade,
      data       jsonb       not null default '{}'::jsonb,
      created_at timestamptz not null default now()
    );

    create index idx_module_events_user
      on public.module_events (user_id, created_at desc);

    alter table public.module_events enable row level security;

    create policy module_events_select_own on public.module_events
      for select using (user_id = auth.uid());
    create policy module_events_insert_own on public.module_events
      for insert with check (user_id = auth.uid());
    create policy module_events_update_own on public.module_events
      for update using (user_id = auth.uid()) with check (user_id = auth.uid());
    create policy module_events_delete_own on public.module_events
      for delete using (user_id = auth.uid());
  end if;
end;
$$;
```

- [ ] **Step 6: Seed the table empty on-device**

`LocalStore` is table-name-generic, so no store change is needed — but `seedIfNeeded` writes an explicit empty list for every table it knows about, and the ledger should match. In `lib/data/local_repository.dart`, find:

```dart
    await _store.write('transfers', []);
    await _store.write('cash_moves', []);
```

and add one line after it:

```dart
    await _store.write('module_events', []);
```

Also add the same table to the factory reset in `clearAll` — no change needed there, since `LocalStore.clearAll` already wipes every key with the `tbl_` prefix.

- [ ] **Step 7: Verify analyze is clean and commit**

```bash
flutter analyze
git add lib/data/module_event.dart lib/data/local_repository.dart \
        supabase/migrations/0005_module_events.sql test/module_event_test.dart
git commit -m "Add module_events ledger for per-row value history"
```

---

### Task 2: Record events from every value-changing action

**Files:**
- Modify: `lib/features/common/entity_screen.dart` (`_addAmount` :223, `_setValue` :286, `_payAmount` :342, `_markSettled` :480, `_reopen` :557, `_EntrySheet._submit` :1143)
- Test: `test/module_events_e2e_test.dart`

**Interfaces:**
- Consumes: `ModuleEvent`, `EventKind`, `logModuleEvent`, `moduleEventsTable` from Task 1.
- Produces: a populated `module_events` table at runtime. No new Dart API.

- [ ] **Step 1: Write the failing test**

Create `test/module_events_e2e_test.dart`:

```dart
import 'package:accounts_app/data/module_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(E2E.installSecureStorageMock);

  testWidgets('adding to a savings goal records an increment event', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    // The seeded "Emergency fund" goal sits at 120000.
    await t.tap(find.byIcon(Icons.more_vert).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add to savings'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '5000');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    final events = E2E.lastStore!.read(moduleEventsTable);
    expect(events.length, 1);
    expect(events.single['parent_type'], 'savings_goals');
    expect(events.single['field'], 'saved_amount');
    expect(events.single['kind'], 'increment');
    expect(events.single['amount'], 5000.0);
    expect(events.single['balance_after'], 125000.0);
  });

  testWidgets('creating a goal records an opening event', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Goal name'), 'Car');
    await t.enterText(find.widgetWithText(TextField, 'Target amount'), '400000');
    await t.enterText(find.widgetWithText(TextField, 'Saved so far'), '25000');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    final events = E2E.lastStore!.read(moduleEventsTable);
    final open = events.where((e) => e['kind'] == 'open').toList();
    expect(open.length, 1);
    expect(open.single['balance_after'], 25000.0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/module_events_e2e_test.dart`
Expected: FAIL — `Expected: <1> Actual: <0>`, because nothing writes the ledger yet.

- [ ] **Step 3: Add the write helper to `_EntityScreenState`**

In `lib/features/common/entity_screen.dart`, add the import:

```dart
import '../../data/module_event.dart';
```

Then add this method next to `_recordCashMove` (`:143`):

```dart
  /// Append a ledger entry for a value change on [row]. Best-effort — the
  /// update it describes has already been committed (see [logModuleEvent]).
  Future<void> _logEvent({
    required Json row,
    required String field,
    required EventKind kind,
    required double amount,
    required double balanceAfter,
    String? account,
  }) =>
      logModuleEvent(
        ref.read(repoProvider),
        ModuleEvent(
          parentId: row['id'].toString(),
          parentType: cfg.table,
          field: field,
          kind: kind,
          amount: amount,
          balanceAfter: balanceAfter,
          date: DateTime.now(),
          account: account,
          note: cfg.title,
        ),
      );
```

- [ ] **Step 4: Wire `_addAmount`**

In `_addAmount`, immediately after the `repoProvider.update(...)` call and before `if (account != null) await _recordCashMove(...)`, insert:

```dart
    await _logEvent(
      row: row,
      field: field,
      kind: EventKind.increment,
      amount: amount,
      balanceAfter: current + amount,
      account: account,
    );
    if (also != null) {
      await _logEvent(
        row: row,
        field: also,
        kind: EventKind.increment,
        amount: amount,
        balanceAfter: values[also] as double,
      );
    }
```

The `also` branch is what lets the Investment chart draw invested and current value as two lines from one contribution.

- [ ] **Step 5: Wire `_setValue`, `_payAmount`, `_markSettled`, `_reopen`**

Read each method and add a `_logEvent` call immediately after its `repoProvider.update(...)`, using:

| Method | field | kind | amount | balanceAfter |
|---|---|---|---|---|
| `_setValue` | `cfg.setField!` | `EventKind.set` | the new value | the new value |
| `_payAmount` | `cfg.decrementField!` | `EventKind.decrement` | the payment | the balance written to the row, **after** any interest accrual |
| `_markSettled` | `cfg.decrementField ?? 'amount'` | `EventKind.set` | `0` | `0` |
| `_reopen` | `cfg.decrementField ?? 'amount'` | `EventKind.set` | the restored balance | the restored balance |

For `_payAmount` and `_markSettled`, pass the account the dialog collected so the ledger agrees with `cash_moves`. Read the exact local variable names from each method — do not guess them.

`_markSettled` matters more than it looks: `trends.dart:191-194` notes that a written-off debt has no closing timestamp today and so "counts as zero at every instant — no invented drop". A settle event finally gives the outstanding curve a real point to fall on.

- [ ] **Step 6: Wire row creation in `_EntrySheet._submit`**

`_EntrySheet` is a separate widget with its own `ref`, and on create it does not know the new row's id — `LocalRepository.insert` generates it. Change the flow so the opening event is written by the parent after the sheet returns.

In `_EntityScreenState._openSheet` (`:182`), after the sheet is dismissed and before `_refresh()`, add:

```dart
    // Opening event for a newly created row. Written here rather than inside
    // the sheet because the id is generated by the repository on insert, so it
    // is only knowable after the list is re-read.
    if (existing == null && saved == true) {
      final field = cfg.incrementField ?? cfg.decrementField;
      if (field != null) {
        final rows = await ref.read(repoProvider).list(cfg.table);
        if (rows.isNotEmpty) {
          final row = rows.first; // insert() prepends, so this is the new row
          await _logEvent(
            row: row,
            field: field,
            kind: EventKind.open,
            amount: (row[field] as num?)?.toDouble() ?? 0,
            balanceAfter: (row[field] as num?)?.toDouble() ?? 0,
          );
        }
      }
    }
```

Read `_openSheet` first: it must return whether the sheet saved. If `showModalBottomSheet` is not already awaited into a result, change `_EntrySheet` to `Navigator.pop(context, true)` on successful save and capture it as `saved`.

Note the ordering assumption — `LocalRepository.insert` prepends (`local_repository.dart:30`) and `list()` returns store order, so `rows.first` is the row just written. `SupabaseRepository` orders by `created_at desc`, giving the same answer.

- [ ] **Step 7: Run the test to verify it passes**

Run: `flutter test test/module_events_e2e_test.dart`
Expected: PASS, 2 tests.

- [ ] **Step 8: Run the whole suite — nothing else may regress**

Run: `flutter test`
Expected: all tests pass. The debtor/creditor tests in `test/dashboard_trends_test.dart` and `test/accounts_e2e_test.dart` still exercise `debt_payments`, which is untouched.

- [ ] **Step 9: Analyze and commit**

```bash
flutter analyze
git add lib/features/common/entity_screen.dart test/module_events_e2e_test.dart
git commit -m "Record a module_events entry for every value change"
```

---

### Task 3: `DashboardSpec` configuration types

**Files:**
- Create: `lib/models/dashboard_spec.dart`
- Modify: `lib/models/field_spec.dart` (add one field to `EntityConfig`)
- Test: none — these are inert data classes with no behaviour. Task 4 tests them through `module_metrics`.

**Interfaces:**
- Consumes: `EventKind` from Task 1.
- Produces: `StatKind`, `StatSpec` (named constructors `.sum`, `.outstanding`, `.progress`, `.ratio`, `.eventSum`, `.count`), `ChartKind`, `ChartSpec` (`.cumulative`, `.dualCumulative`, `.bars`), `BreakdownSpec.byRow`, `DashboardSpec`, and `EntityConfig.dashboard`.

- [ ] **Step 1: Create the spec types**

Create `lib/models/dashboard_spec.dart`:

```dart
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

class StatSpec {
  const StatSpec._(
    this.kind,
    this.label, {
    this.field,
    this.against,
    this.eventKinds,
  });

  const StatSpec.sum(String field, String label)
      : this._(StatKind.sum, label, field: field);

  const StatSpec.outstanding(String field, String label)
      : this._(StatKind.outstanding, label, field: field);

  const StatSpec.progress(String field, String against, String label)
      : this._(StatKind.progress, label, field: field, against: against);

  const StatSpec.ratio(String field, String against, String label)
      : this._(StatKind.ratio, label, field: field, against: against);

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
}

enum ChartKind {
  /// Combined balance of one field over time, read from the ledger.
  cumulative,

  /// Two cumulative lines on shared axes (invested vs current value).
  dualCumulative,

  /// Sum of a dated column per time bucket, read from the rows themselves.
  /// For modules whose rows carry a `date` — no ledger needed.
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

/// A per-row bar list under the chart — "Emergency fund 62%".
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
```

- [ ] **Step 2: Add the field to `EntityConfig`**

In `lib/models/field_spec.dart`, add the import at the top:

```dart
import 'dashboard_spec.dart';
```

Add `this.dashboard,` to the constructor parameter list (after `this.dateFiltered = false,`), and this field after `dateFiltered` (`:156`):

```dart
  /// Dashboard header shown above the list: headline figures, a chart, and an
  /// optional per-row breakdown. Null means no header.
  ///
  /// The range chips are shown whenever this is set *or* [dateFiltered] is —
  /// but they only filter the list when [dateFiltered] is true. Savings goals,
  /// loans and bills carry no `date` column, so filtering their rows by range
  /// would blank the page; on those modules the range moves the dashboard
  /// alone. Stat labels carry the distinction: "Contributed this month" for an
  /// event-derived figure, plain "Saved" for a current total.
  final DashboardSpec? dashboard;
```

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze`
Expected: "No issues found."

- [ ] **Step 4: Commit**

```bash
git add lib/models/dashboard_spec.dart lib/models/field_spec.dart
git commit -m "Add DashboardSpec config types for per-module dashboards"
```

---

### Task 4: The metrics layer

**Files:**
- Create: `lib/features/common/module_metrics.dart`
- Test: `test/module_metrics_test.dart`

**Interfaces:**
- Consumes: `Json`, `Events`, `EventKind` (Tasks 1), all spec types (Task 3), `money()` from `lib/core/formatters.dart`.
- Produces:
  - `class Stat { final String label; final String value; }`
  - `class SeriesPoint { final String label; final double value; }`
  - `class Series { final ChartKind kind; final String label; final List<SeriesPoint> points; final List<SeriesPoint>? second; final String? firstLabel, secondLabel; bool get isEmpty; }`
  - `class TimeBucket { final String label; final DateTime start, end; }` (`end` inclusive, end-of-day)
  - `List<TimeBucket> buildTimeBuckets(DateTime start, DateTime end)`
  - `List<Stat> statsFor({required DashboardSpec spec, required List<Json> rows, required List<Json> events, required String parentType, DateTime? rangeStart, DateTime? rangeEnd})`
  - `Series? seriesFor({required DashboardSpec spec, required List<Json> rows, required List<Json> events, required String parentType, required DateTime now, DateTime? rangeStart, DateTime? rangeEnd})`

`rangeStart` / `rangeEnd` are **inclusive** — they come straight from `_activeRange()`. Both null means all time.

- [ ] **Step 1: Write the failing tests**

Create `test/module_metrics_test.dart`:

```dart
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/module_event.dart';
import 'package:accounts_app/features/common/module_metrics.dart';
import 'package:accounts_app/models/dashboard_spec.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 8, 2, 12);

Json _goal(String id, double saved, double target) =>
    {'id': id, 'saved_amount': saved, 'target_amount': target};

Json _ev(String id, String date, double after,
        {String field = 'saved_amount',
        String kind = 'increment',
        double amount = 0,
        String type = 'savings_goals'}) =>
    {
      'parent_id': id,
      'parent_type': type,
      'field': field,
      'kind': kind,
      'amount': amount,
      'balance_after': after,
      'date': date,
    };

const _savingsSpec = DashboardSpec(
  stats: [
    StatSpec.sum('saved_amount', 'Saved'),
    StatSpec.sum('target_amount', 'Target'),
    StatSpec.progress('saved_amount', 'target_amount', 'Of target'),
    StatSpec.eventSum('saved_amount', 'Contributed'),
  ],
  chart: ChartSpec.cumulative('saved_amount', label: 'Savings growth'),
);

void main() {
  group('stats', () {
    test('sums and progress come from the rows, not the ledger', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 120000, 200000), _goal('b', 30000, 90000)],
        events: const [],
        parentType: 'savings_goals',
      );
      expect(stats[0].label, 'Saved');
      expect(stats[0].value, '₹1,50,000');
      expect(stats[1].value, '₹2,90,000');
      expect(stats[2].value, '51.7%');
    });

    test('progress clamps at 100% so an overshot goal reads as met', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 250000, 200000)],
        events: const [],
        parentType: 'savings_goals',
      );
      expect(stats[2].value, '100%');
    });

    test('progress against a zero target is dashed, not divided by zero', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 5000, 0)],
        events: const [],
        parentType: 'savings_goals',
      );
      expect(stats[2].value, '—');
    });

    test('eventSum counts only increments inside the inclusive range', () {
      final events = [
        _ev('a', '2026-07-31', 105000, amount: 5000),
        _ev('a', '2026-08-01', 108000, amount: 3000),
        _ev('a', '2026-08-02', 110000, amount: 2000),
        _ev('a', '2026-08-01', 108000, amount: 999, kind: 'open'),
      ];
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 110000, 200000)],
        events: events,
        parentType: 'savings_goals',
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 31),
      );
      expect(stats[3].value, '₹5,000');
    });

    test('a null range means all time', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 110000, 200000)],
        events: [
          _ev('a', '2026-01-05', 5000, amount: 5000),
          _ev('a', '2026-08-02', 110000, amount: 2000),
        ],
        parentType: 'savings_goals',
      );
      expect(stats[3].value, '₹7,000');
    });

    test('ratio is a signed return on capital', () {
      const spec = DashboardSpec(stats: [
        StatSpec.ratio('current_value', 'total_invested', 'Return'),
      ]);
      final stats = statsFor(
        spec: spec,
        rows: [
          {'current_value': 85300.0, 'total_invested': 75000.0},
        ],
        events: const [],
        parentType: 'investments',
      );
      expect(stats.single.value, '+13.7%');
    });

    test('outstanding excludes settled rows', () {
      const spec = DashboardSpec(stats: [
        StatSpec.outstanding('amount', 'Outstanding'),
      ]);
      final stats = statsFor(
        spec: spec,
        rows: [
          {'amount': 5000.0, 'status': 'open'},
          {'amount': 12000.0, 'status': 'partial'},
          {'amount': 3500.0, 'status': 'settled'},
        ],
        events: const [],
        parentType: 'debtors',
      );
      expect(stats.single.value, '₹17,000');
    });
  });

  group('time buckets', () {
    test('a single day is one bucket', () {
      final b = buildTimeBuckets(DateTime(2026, 8, 2), DateTime(2026, 8, 2));
      expect(b.length, 1);
    });

    test('a fortnight buckets by day', () {
      final b = buildTimeBuckets(DateTime(2026, 7, 20), DateTime(2026, 8, 2));
      expect(b.length, 14);
      expect(b.first.start, DateTime(2026, 7, 20));
      expect(b.last.start, DateTime(2026, 8, 2));
    });

    test('a year buckets by month', () {
      final b = buildTimeBuckets(DateTime(2026, 1, 1), DateTime(2026, 12, 31));
      expect(b.length, 12);
      expect(b.first.label, 'Jan');
      expect(b.last.label, 'Dec');
    });

    test('bucket ends are the last instant of their span, not the next start',
        () {
      final b = buildTimeBuckets(DateTime(2026, 1, 1), DateTime(2026, 12, 31));
      expect(b.first.end.month, 1);
      expect(b.first.end.day, 31);
    });
  });

  group('cumulative series', () {
    Series build(List<Json> events, {DateTime? from, DateTime? to}) => seriesFor(
          spec: _savingsSpec,
          rows: [_goal('a', 0, 200000)],
          events: events,
          parentType: 'savings_goals',
          now: _now,
          rangeStart: from,
          rangeEnd: to,
        )!;

    test('carries the last known balance forward across empty buckets', () {
      final s = build([
        _ev('a', '2026-01-15', 10000, kind: 'open', amount: 10000),
        _ev('a', '2026-03-10', 25000, amount: 15000),
      ], from: DateTime(2026, 1, 1), to: DateTime(2026, 12, 31));
      expect(s.points.length, 12);
      expect(s.points[0].value, 10000);
      expect(s.points[1].value, 10000); // Feb — no event, balance holds
      expect(s.points[2].value, 25000);
      expect(s.points[11].value, 25000);
    });

    test('sums the latest balance of every goal, not every event', () {
      final s = build([
        _ev('a', '2026-01-15', 10000, kind: 'open', amount: 10000),
        _ev('b', '2026-01-20', 5000, kind: 'open', amount: 5000),
        _ev('a', '2026-02-01', 30000, amount: 20000),
      ], from: DateTime(2026, 1, 1), to: DateTime(2026, 12, 31));
      expect(s.points[0].value, 15000);
      expect(s.points[1].value, 35000);
    });

    test('a set event bends the curve down rather than accumulating', () {
      final s = build([
        _ev('a', '2026-01-15', 50000,
            field: 'current_value', kind: 'open', amount: 50000),
        _ev('a', '2026-02-15', 42000,
            field: 'current_value', kind: 'set', amount: 42000),
      ], from: DateTime(2026, 1, 1), to: DateTime(2026, 12, 31));
      // The savings spec charts saved_amount; a current_value ledger is not it.
      expect(s.points.every((p) => p.value == 0), isTrue);

      final inv = seriesFor(
        spec: const DashboardSpec(
          stats: [],
          chart: ChartSpec.cumulative('current_value', label: 'Value'),
        ),
        rows: const [],
        events: [
          _ev('a', '2026-01-15', 50000,
              field: 'current_value', kind: 'open', type: 'investments'),
          _ev('a', '2026-02-15', 42000,
              field: 'current_value', kind: 'set', type: 'investments'),
        ],
        parentType: 'investments',
        now: _now,
        rangeStart: DateTime(2026, 1, 1),
        rangeEnd: DateTime(2026, 12, 31),
      )!;
      expect(inv.points[0].value, 50000);
      expect(inv.points[1].value, 42000);
    });

    test('an event on the first of the range is inside it', () {
      final s = build([
        _ev('a', '2026-08-01', 7000, kind: 'open', amount: 7000),
      ], from: DateTime(2026, 8, 1), to: DateTime(2026, 8, 31));
      expect(s.points.first.value, 7000);
    });

    test('balances established before the range carry into it', () {
      final s = build([
        _ev('a', '2025-11-02', 90000, kind: 'open', amount: 90000),
      ], from: DateTime(2026, 8, 1), to: DateTime(2026, 8, 31));
      expect(s.points.first.value, 90000);
    });

    test('an empty ledger yields no series at all', () {
      final s = seriesFor(
        spec: _savingsSpec,
        rows: [_goal('a', 120000, 200000)],
        events: const [],
        parentType: 'savings_goals',
        now: _now,
      );
      expect(s, isNull);
    });
  });

  group('bar series', () {
    test('sums dated rows per bucket', () {
      const spec = DashboardSpec(
        stats: [],
        chart: ChartSpec.bars('amount', label: 'Spending'),
      );
      final s = seriesFor(
        spec: spec,
        rows: [
          {'amount': 1000.0, 'date': '2026-01-10'},
          {'amount': 500.0, 'date': '2026-01-20'},
          {'amount': 2000.0, 'date': '2026-03-01'},
        ],
        events: const [],
        parentType: 'expenses',
        now: _now,
        rangeStart: DateTime(2026, 1, 1),
        rangeEnd: DateTime(2026, 12, 31),
      )!;
      expect(s.points[0].value, 1500);
      expect(s.points[1].value, 0);
      expect(s.points[2].value, 2000);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/module_metrics_test.dart`
Expected: FAIL — "Target of URI doesn't exist: 'package:accounts_app/features/common/module_metrics.dart'".

- [ ] **Step 3: Write the implementation**

Create `lib/features/common/module_metrics.dart`:

```dart
import 'package:intl/intl.dart';

import '../../core/formatters.dart';
import '../../data/finance_repository.dart';
import '../../data/module_event.dart';
import '../../models/dashboard_spec.dart';

/// Per-module dashboard computation.
///
/// Pure Dart — no Flutter imports, no I/O — following the discipline of
/// `features/dashboard/analytics.dart` and `trends.dart`, so every rule below
/// is unit-testable.
///
/// The date arguments throughout are **inclusive** on both ends, because they
/// arrive from `_activeRange()` in `entity_screen.dart`, which speaks in
/// inclusive `DateTimeRange`s. Internally comparisons are made against
/// end-of-day instants so a row dated on the last day is inside the range.

/// One headline figure, already formatted for display.
class Stat {
  const Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  String toString() => 'Stat($label, $value)';
}

class SeriesPoint {
  const SeriesPoint(this.label, this.value);
  final String label;
  final double value;
}

/// A chartable series. [second] is populated only for dual-line charts.
class Series {
  const Series({
    required this.kind,
    required this.label,
    required this.points,
    this.second,
    this.firstLabel,
    this.secondLabel,
  });

  final ChartKind kind;
  final String label;
  final List<SeriesPoint> points;
  final List<SeriesPoint>? second;
  final String? firstLabel;
  final String? secondLabel;

  bool get isEmpty => points.isEmpty;

  /// True when every point is zero. Drawn as an empty state rather than a flat
  /// line on the axis, which would read as a measurement.
  bool get isFlatZero => points.every((p) => p.value == 0);
}

/// One column of a chart: a labelled span with inclusive [start] and [end].
class TimeBucket {
  const TimeBucket(this.label, this.start, this.end);
  final String label;
  final DateTime start;

  /// The last instant of the span, not the next span's start — so a value
  /// recorded on the final day lands in this bucket and not the next.
  final DateTime end;
}

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _endOfDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

double _num(Json r, String key) => (r[key] as num?)?.toDouble() ?? 0;

DateTime? _rowDate(Json r) {
  final v = r['date'];
  if (v == null) return null;
  final d = DateTime.tryParse(v.toString());
  if (d == null) return null;
  return d.isUtc ? d.toLocal() : d;
}

/// Divide [start, end] into a readable number of columns.
///
/// Granularity follows span rather than the selected period, so "All" over
/// three years and "Month" over 31 days both produce a chart you can read.
List<TimeBucket> buildTimeBuckets(DateTime start, DateTime end) {
  final from = _midnight(start);
  final to = _midnight(end);
  final days = to.difference(from).inDays + 1;

  if (days <= 1) {
    return [TimeBucket(DateFormat('d MMM').format(from), from, _endOfDay(from))];
  }

  if (days <= 16) {
    return [
      for (var i = 0; i < days; i++)
        () {
          final d = from.add(Duration(days: i));
          return TimeBucket(DateFormat('d/M').format(d), d, _endOfDay(d));
        }()
    ];
  }

  if (days <= 92) {
    final weeks = (days / 7).ceil();
    return [
      for (var i = 0; i < weeks; i++)
        () {
          final s = from.add(Duration(days: i * 7));
          final rawEnd = s.add(const Duration(days: 6));
          final e = rawEnd.isAfter(to) ? to : rawEnd;
          return TimeBucket(DateFormat('d/M').format(s), s, _endOfDay(e));
        }()
    ];
  }

  // Monthly, inclusive of both endpoint months.
  final out = <TimeBucket>[];
  var cursor = DateTime(from.year, from.month, 1);
  while (!cursor.isAfter(DateTime(to.year, to.month, 1))) {
    final next = DateTime(cursor.year, cursor.month + 1, 1);
    final lastDay = next.subtract(const Duration(days: 1));
    out.add(TimeBucket(
      DateFormat('MMM').format(cursor),
      cursor,
      _endOfDay(lastDay),
    ));
    cursor = next;
  }
  return out;
}

// ---------------------------------------------------------------- stats

List<Stat> statsFor({
  required DashboardSpec spec,
  required List<Json> rows,
  required List<Json> events,
  required String parentType,
  DateTime? rangeStart,
  DateTime? rangeEnd,
}) =>
    [
      for (final s in spec.stats)
        _stat(s, rows, events, parentType, rangeStart, rangeEnd)
    ];

Stat _stat(
  StatSpec s,
  List<Json> rows,
  List<Json> events,
  String parentType,
  DateTime? from,
  DateTime? to,
) {
  double sum(String key) => rows.fold(0.0, (a, r) => a + _num(r, key));

  switch (s.kind) {
    case StatKind.sum:
      return Stat(s.label, money(sum(s.field!)));

    case StatKind.outstanding:
      final total = rows
          .where((r) => r['status'] != 'settled')
          .fold(0.0, (a, r) => a + _num(r, s.field!));
      return Stat(s.label, money(total));

    case StatKind.progress:
      final target = sum(s.against!);
      if (target <= 0) return Stat(s.label, '—');
      final pct = (sum(s.field!) / target * 100).clamp(0.0, 100.0);
      return Stat(s.label, '${_pct(pct)}%');

    case StatKind.ratio:
      final base = sum(s.against!);
      if (base <= 0) return Stat(s.label, '—');
      final pct = (sum(s.field!) - base) / base * 100;
      return Stat(s.label, '${pct >= 0 ? '+' : '−'}${_pct(pct.abs())}%');

    case StatKind.eventSum:
      final kinds = s.eventKinds!.map((k) => k.name).toSet();
      var total = 0.0;
      for (final e in events) {
        if (Events.parentType(e) != parentType) continue;
        if (Events.field(e) != s.field) continue;
        if (!kinds.contains(Events.kind(e))) continue;
        final d = Events.date(e);
        if (d == null) continue;
        if (from != null && d.isBefore(_midnight(from))) continue;
        if (to != null && d.isAfter(_endOfDay(to))) continue;
        total += Events.amount(e);
      }
      return Stat(s.label, money(total));

    case StatKind.count:
      return Stat(s.label, '${rows.length}');
  }
}

/// One decimal place, with a redundant `.0` dropped: 51.7, 100, 13.
/// Matches `_pct` in `features/dashboard/trends.dart`.
String _pct(double v) {
  final rounded = (v * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

// --------------------------------------------------------------- series

Series? seriesFor({
  required DashboardSpec spec,
  required List<Json> rows,
  required List<Json> events,
  required String parentType,
  required DateTime now,
  DateTime? rangeStart,
  DateTime? rangeEnd,
}) {
  final chart = spec.chart;
  if (chart == null) return null;

  final span = _span(
    chart: chart,
    rows: rows,
    events: events,
    parentType: parentType,
    now: now,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
  );
  if (span == null) return null;

  final buckets = buildTimeBuckets(span.$1, span.$2);

  switch (chart.kind) {
    case ChartKind.cumulative:
      return Series(
        kind: chart.kind,
        label: chart.label,
        points: _cumulative(events, parentType, chart.field, buckets),
      );

    case ChartKind.dualCumulative:
      return Series(
        kind: chart.kind,
        label: chart.label,
        points: _cumulative(events, parentType, chart.field, buckets),
        second: _cumulative(events, parentType, chart.second!, buckets),
        firstLabel: chart.firstLabel,
        secondLabel: chart.secondLabel,
      );

    case ChartKind.bars:
      return Series(
        kind: chart.kind,
        label: chart.label,
        points: _bars(rows, chart.field, buckets),
      );
  }
}

/// The (start, end) the chart should span, or null when there is nothing to
/// draw — no ledger for a cumulative chart, no dated rows for a bar chart.
(DateTime, DateTime)? _span({
  required ChartSpec chart,
  required List<Json> rows,
  required List<Json> events,
  required String parentType,
  required DateTime now,
  DateTime? rangeStart,
  DateTime? rangeEnd,
}) {
  if (rangeStart != null && rangeEnd != null) {
    if (chart.kind == ChartKind.bars) {
      final dated = rows.where((r) => _rowDate(r) != null);
      if (dated.isEmpty) return null;
    } else {
      final ev = Events.forField(events, parentType, chart.field);
      final ev2 = chart.second == null
          ? const <Json>[]
          : Events.forField(events, parentType, chart.second!);
      if (ev.isEmpty && ev2.isEmpty) return null;
    }
    return (rangeStart, rangeEnd);
  }

  // "All": span the data itself.
  if (chart.kind == ChartKind.bars) {
    final dates = rows.map(_rowDate).whereType<DateTime>().toList()..sort();
    if (dates.isEmpty) return null;
    return (dates.first, dates.last.isAfter(now) ? dates.last : now);
  }

  final ev = Events.forField(events, parentType, chart.field);
  final ev2 = chart.second == null
      ? const <Json>[]
      : Events.forField(events, parentType, chart.second!);
  if (ev.isEmpty && ev2.isEmpty) return null;
  final first = [
    if (ev.isNotEmpty) Events.date(ev.first)!,
    if (ev2.isNotEmpty) Events.date(ev2.first)!,
  ].reduce((a, b) => a.isBefore(b) ? a : b);
  return (first, now);
}

/// Combined balance across every parent row at the close of each bucket.
///
/// Reads the recorded `balance_after` rather than re-deriving forward from an
/// opening figure, so a `set` event bends the curve and hand-edited rows can't
/// make the chart disagree with the total printed above it. A balance
/// established before the window carries into its first bucket, and a bucket
/// with no events holds the previous balance rather than dropping to zero.
List<SeriesPoint> _cumulative(
  List<Json> events,
  String parentType,
  String field,
  List<TimeBucket> buckets,
) {
  final evs = Events.forField(events, parentType, field);
  final latest = <String, double>{};
  var i = 0;
  final out = <SeriesPoint>[];

  for (final b in buckets) {
    while (i < evs.length && !Events.date(evs[i])!.isAfter(b.end)) {
      latest[Events.parentId(evs[i])] = Events.balanceAfter(evs[i]);
      i++;
    }
    out.add(SeriesPoint(b.label, latest.values.fold(0.0, (a, v) => a + v)));
  }
  return out;
}

/// Sum of a dated column per bucket — for modules whose rows carry a `date`.
List<SeriesPoint> _bars(
  List<Json> rows,
  String field,
  List<TimeBucket> buckets,
) {
  final totals = List<double>.filled(buckets.length, 0);
  for (final r in rows) {
    final d = _rowDate(r);
    if (d == null) continue;
    for (var i = 0; i < buckets.length; i++) {
      if (!d.isBefore(buckets[i].start) && !d.isAfter(buckets[i].end)) {
        totals[i] += _num(r, field);
        break;
      }
    }
  }
  return [
    for (var i = 0; i < buckets.length; i++)
      SeriesPoint(buckets[i].label, totals[i])
  ];
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/module_metrics_test.dart`
Expected: PASS, 17 tests.

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/features/common/module_metrics.dart test/module_metrics_test.dart
git commit -m "Add module_metrics: stats and time series from rows + ledger"
```

---

### Task 5: Themed chart widgets

**Files:**
- Create: `lib/core/charts.dart`
- Test: none directly — exercised through Task 6's widget tests. These are presentation wrappers with no logic worth isolating.

**Interfaces:**
- Consumes: `Series`, `SeriesPoint` (Task 4); `AppCard`, `SectionLabel` from `lib/core/components.dart`; `context.colors`, `context.text`, `AppTheme`, `tabular` from `lib/core/theme.dart`; `money()` from formatters.
- Produces: `SeriesChart({required Series series})`, `ProgressBars({required List<BreakdownRow> rows})`, `BreakdownRow({required String label, required double value, double? of})`, `ChartEmptyState({required String message})`.

- [ ] **Step 1: Write the widgets**

Create `lib/core/charts.dart`:

```dart
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../features/common/module_metrics.dart';
import 'formatters.dart';
import 'theme.dart';

/// Shown instead of a chart when there is no history to draw.
///
/// A flat line at zero is not an acceptable substitute: it reads as a
/// measurement, and a false one. The ledger only starts filling from the first
/// action after this feature ships, so this state is the normal case at first.
class ChartEmptyState extends StatelessWidget {
  const ChartEmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 140,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('No history yet',
                  style: context.text.titleMedium
                      ?.copyWith(color: c.textSecondary)),
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style:
                    context.text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders whichever shape a [Series] declares. One entry point so callers
/// never branch on chart kind themselves.
class SeriesChart extends StatelessWidget {
  const SeriesChart({super.key, required this.series});

  final Series series;

  @override
  Widget build(BuildContext context) {
    if (series.isEmpty || series.isFlatZero) {
      return const ChartEmptyState(
        message: 'Entries you add from now on will appear here.',
      );
    }
    return switch (series.kind) {
      ChartKind.cumulative => _LineChart(series),
      ChartKind.dualCumulative => _DualLineChart(series),
      ChartKind.bars => _BarSeriesChart(series),
    };
  }
}
```

`SeriesChart` needs `import '../models/dashboard_spec.dart';` for `ChartKind`. The three private widgets follow.

```dart
class _LineChart extends StatelessWidget {
  const _LineChart(this.series);
  final Series series;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 150,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: _maxOf(series) * 1.15,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(
            show: true,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          titlesData: _titles(context, series.points),
          lineTouchData: _touch(context),
          lineBarsData: [_bar(series.points, c.accent)],
        ),
      ),
    );
  }
}
```

Factor the shared pieces into file-private helpers so all three charts stay consistent and short:

```dart
double _maxOf(Series s) {
  var m = 0.0;
  for (final p in s.points) {
    if (p.value > m) m = p.value;
  }
  for (final p in s.second ?? const <SeriesPoint>[]) {
    if (p.value > m) m = p.value;
  }
  return m == 0 ? 1 : m;
}

LineChartBarData _bar(List<SeriesPoint> pts, Color color) => LineChartBarData(
      spots: [
        for (var i = 0; i < pts.length; i++)
          FlSpot(i.toDouble(), pts[i].value),
      ],
      isCurved: false,
      color: color,
      barWidth: 2,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        color: color.withValues(alpha: 0.10),
      ),
    );

/// Bottom axis only, thinned so labels never collide on a 12-bucket chart.
FlTitlesData _titles(BuildContext context, List<SeriesPoint> pts) {
  final c = context.colors;
  final step = (pts.length / 6).ceil();
  return FlTitlesData(
    leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 22,
        getTitlesWidget: (value, meta) {
          final i = value.toInt();
          if (i < 0 || i >= pts.length) return const SizedBox();
          if (step > 1 && i % step != 0) return const SizedBox();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              pts[i].label,
              style: context.text.labelSmall?.copyWith(color: c.textSecondary),
            ),
          );
        },
      ),
    ),
  );
}

LineTouchData _touch(BuildContext context) {
  final c = context.colors;
  return LineTouchData(
    touchTooltipData: LineTouchTooltipData(
      getTooltipColor: (_) => c.textPrimary,
      getTooltipItems: (spots) => [
        for (final s in spots)
          LineTooltipItem(
            money(s.y),
            TextStyle(
              color: c.bg,
              fontFamily: AppTheme.sans,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    ),
  );
}
```

```dart
class _DualLineChart extends StatelessWidget {
  const _DualLineChart(this.series);
  final Series series;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        SizedBox(
          height: 150,
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: _maxOf(series) * 1.15,
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(
                show: true,
                border: Border(bottom: BorderSide(color: c.border)),
              ),
              titlesData: _titles(context, series.points),
              lineTouchData: _touch(context),
              lineBarsData: [
                _bar(series.points, c.textSecondary),
                _bar(series.second!, c.accent),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Legend(color: c.textSecondary, label: series.firstLabel ?? ''),
            const SizedBox(width: 20),
            _Legend(color: c.accent, label: series.secondLabel ?? ''),
          ],
        ),
      ],
    );
  }
}

class _BarSeriesChart extends StatelessWidget {
  const _BarSeriesChart(this.series);
  final Series series;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pts = series.points;
    return SizedBox(
      height: 150,
      child: BarChart(
        BarChartData(
          maxY: _maxOf(series) * 1.15,
          alignment: BarChartAlignment.spaceAround,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(
            show: true,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => c.textPrimary,
              getTooltipItem: (group, _, rod, __) => BarTooltipItem(
                money(rod.toY),
                TextStyle(
                  color: c.bg,
                  fontFamily: AppTheme.sans,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          titlesData: _titles(context, pts),
          barGroups: [
            for (var i = 0; i < pts.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: pts[i].value,
                  color: c.accent,
                  width: 12,
                  borderRadius: BorderRadius.circular(3),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}

/// Dot + label used under the dual-line chart. `dashboard_screen.dart` has a
/// private `_LegendDot` of its own; this is the same idea, kept local so the
/// two files stay independent.
class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: context.text.labelSmall
              ?.copyWith(color: context.colors.textSecondary),
        ),
      ],
    );
  }
}
```

Note that `_titles` is shared by all three charts, so `BarChart` and `LineChart` both take an `FlTitlesData` — that type is common to both in `fl_chart` 1.2.

Then the breakdown list:

```dart
/// One row of a per-row breakdown — "Emergency fund, ₹1,20,000 of ₹2,00,000".
class BreakdownRow {
  const BreakdownRow({required this.label, required this.value, this.of});
  final String label;
  final double value;

  /// The total [value] is measured against. Null means the bars are scaled to
  /// the largest row instead of to a target.
  final double? of;
}

/// Horizontal progress bars under a chart.
class ProgressBars extends StatelessWidget {
  const ProgressBars({super.key, required this.rows});

  final List<BreakdownRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final largest =
        rows.map((r) => r.value).fold<double>(0, (a, v) => v > a ? v : a);

    return Column(
      children: [
        for (final r in rows) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.label,
                        style: context.text.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _trailing(r),
                      style: context.text.labelMedium?.copyWith(
                        color: c.textSecondary,
                        fontFeatures: tabular,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: _fraction(r, largest),
                    minHeight: 6,
                    backgroundColor: c.border,
                    valueColor: AlwaysStoppedAnimation(c.accent),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  String _trailing(BreakdownRow r) {
    final of = r.of;
    if (of == null || of <= 0) return money(r.value);
    final pct = (r.value / of * 100).clamp(0, 100);
    return '${money(r.value)} · ${pct.toStringAsFixed(0)}%';
  }

  double _fraction(BreakdownRow r, double largest) {
    final of = r.of;
    if (of != null && of > 0) return (r.value / of).clamp(0.0, 1.0);
    if (largest <= 0) return 0;
    return (r.value / largest).clamp(0.0, 1.0);
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze`
Expected: "No issues found." Fix any `fl_chart` 1.2 API drift against the working reference at `lib/features/dashboard/dashboard_screen.dart:442-541` — that file compiles today, so its call shapes are authoritative.

- [ ] **Step 3: Commit**

```bash
git add lib/core/charts.dart
git commit -m "Add themed chart widgets for module dashboards"
```

---

### Task 6: The dashboard header, mounted on Savings

**Files:**
- Create: `lib/features/common/module_dashboard.dart`
- Modify: `lib/features/common/entity_screen.dart` (body :694-754, delete `_summaryBanner` :947-987 and `_summaryLabel` :989-996, widen the filter-bar condition)
- Modify: `lib/features/registry.dart` (`savings` config :82)
- Test: `test/module_dashboard_test.dart`

**Interfaces:**
- Consumes: `statsFor`, `seriesFor`, `Stat`, `Series` (Task 4); `SeriesChart`, `ProgressBars`, `BreakdownRow`, `ChartEmptyState` (Task 5); `DashboardSpec` (Task 3); `AppCard`, `SectionLabel`, `MoneyText` (components).
- Produces: `ModuleDashboard({required EntityConfig config, required List<Json> rows, required List<Json> events, DateTime? rangeStart, DateTime? rangeEnd})`.

- [ ] **Step 1: Write the failing test**

Create `test/module_dashboard_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(E2E.installSecureStorageMock);

  testWidgets('savings page shows the dashboard header', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Target'), findsOneWidget);
    // Seeded goals: 120000 + 30000 + 42000.
    expect(find.text('₹1,92,000'), findsOneWidget);
  });

  testWidgets('an empty ledger shows the no-history copy, not a zero line',
      (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');
    expect(find.text('No history yet'), findsOneWidget);
  });

  testWidgets('the header collapses and re-expands', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    expect(find.text('No history yet'), findsOneWidget);
    await t.tap(find.byIcon(Icons.expand_less));
    await t.pumpAndSettle();

    // Stats survive the collapse; the chart does not.
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('No history yet'), findsNothing);

    await t.tap(find.byIcon(Icons.expand_more));
    await t.pumpAndSettle();
    expect(find.text('No history yet'), findsOneWidget);
  });

  testWidgets('range chips do not filter a balance module\'s list', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    expect(find.text('Emergency fund'), findsOneWidget);
    await t.tap(find.text('Today'));
    await t.pumpAndSettle();
    // Savings goals carry no date column — the list must be unaffected.
    expect(find.text('Emergency fund'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/module_dashboard_test.dart`
Expected: FAIL — `Expected: exactly one matching candidate / Actual: _TextFinder:<zero widgets with text "Saved">`.

- [ ] **Step 3: Write the header widget**

Create `lib/features/common/module_dashboard.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/charts.dart';
import '../../core/components.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../models/field_spec.dart';
import 'module_metrics.dart';

/// Dashboard header above a module's list: headline figures, a chart, and an
/// optional per-row breakdown. Collapsible to the figures alone, with the
/// choice remembered per module.
class ModuleDashboard extends StatefulWidget {
  const ModuleDashboard({
    super.key,
    required this.config,
    required this.rows,
    required this.events,
    this.rangeStart,
    this.rangeEnd,
  });

  final EntityConfig config;
  final List<Json> rows;
  final List<Json> events;

  /// Inclusive range from the filter chips; both null means all time.
  final DateTime? rangeStart;
  final DateTime? rangeEnd;

  @override
  State<ModuleDashboard> createState() => _ModuleDashboardState();
}

class _ModuleDashboardState extends State<ModuleDashboard> {
  bool _expanded = true;

  String get _prefKey => 'dash_collapsed_${widget.config.table}';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final collapsed = prefs.getBool(_prefKey) ?? false;
    if (mounted && collapsed) setState(() => _expanded = false);
  }

  Future<void> _toggle() async {
    setState(() => _expanded = !_expanded);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.config.dashboard;
    if (spec == null) return const SizedBox.shrink();

    final stats = statsFor(
      spec: spec,
      rows: widget.rows,
      events: widget.events,
      parentType: widget.config.table,
      rangeStart: widget.rangeStart,
      rangeEnd: widget.rangeEnd,
    );

    final series = seriesFor(
      spec: spec,
      rows: widget.rows,
      events: widget.events,
      parentType: widget.config.table,
      now: DateTime.now(),
      rangeStart: widget.rangeStart,
      rangeEnd: widget.rangeEnd,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 0, AppTheme.screenPad, 12),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statRow(context, stats),
            if (_expanded && spec.chart != null) ...[
              const SizedBox(height: 16),
              if (series == null)
                const ChartEmptyState(
                  message: 'Entries you add from now on will appear here.',
                )
              else
                SeriesChart(series: series),
            ],
            if (_expanded && spec.breakdown != null) ...[
              const SizedBox(height: 8),
              ProgressBars(rows: _breakdownRows(spec)),
            ],
          ],
        ),
      ),
    );
  }

  List<BreakdownRow> _breakdownRows(DashboardSpec spec) {
    final b = spec.breakdown!;
    final cfg = widget.config;
    final rows = [
      for (final r in widget.rows)
        BreakdownRow(
          label: cfg.titleOf(r),
          value: (r[b.value] as num?)?.toDouble() ?? 0,
          of: b.of == null ? null : (r[b.of!] as num?)?.toDouble(),
        )
    ]..sort((a, x) => x.value.compareTo(a.value));
    return rows.take(6).toList();
  }

  /// Figures across the top, with the collapse control on the right. Wraps so
  /// four stats survive a narrow phone rather than ellipsizing to nothing.
  Widget _statRow(BuildContext context, List<Stat> stats) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              for (final s in stats)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.label,
                      style: context.text.labelMedium
                          ?.copyWith(color: c.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    MoneyText(s.value),
                  ],
                ),
            ],
          ),
        ),
        if (widget.config.dashboard?.chart != null ||
            widget.config.dashboard?.breakdown != null)
          IconButton(
            onPressed: _toggle,
            visualDensity: VisualDensity.compact,
            tooltip: _expanded ? 'Hide chart' : 'Show chart',
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: c.textSecondary,
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 4: Load events in `EntityScreen`**

In `lib/features/common/entity_screen.dart`, add the imports:

```dart
import 'module_dashboard.dart';
```

`_future` currently holds only the module's rows. Add a parallel field and load it in the same place `_future` is assigned (see `initState` :126 and `_refresh` :176):

```dart
  Future<List<Json>> _events = Future.value(const []);
```

and in both `initState` and `_refresh`, alongside the existing `_future` assignment:

```dart
    _events = cfg.dashboard == null
        ? Future.value(const [])
        : ref.read(repoProvider).list(moduleEventsTable);
```

Add `import '../../data/module_event.dart';` if Task 2 did not already add it.

- [ ] **Step 5: Show the filter bar on every dashboard module**

Replace both occurrences of `if (cfg.dateFiltered) _buildFilterBar()` and the `if (cfg.dateFiltered) _summaryBanner(rows)` line in `build` (:696, :731) so the body reads:

```dart
      body: Column(
        children: [
          if (_showFilterBar) _buildFilterBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<Json>>(
                future: _future,
                builder: (context, snap) {
                  // ... unchanged loading / error branches ...
                  final allRows = snap.data ?? [];
                  final rows = _applyFilter(allRows);
                  return Column(
                    children: [
                      if (cfg.dashboard != null)
                        FutureBuilder<List<Json>>(
                          future: _events,
                          builder: (context, evSnap) => ModuleDashboard(
                            config: cfg,
                            rows: rows,
                            events: evSnap.data ?? const [],
                            rangeStart: _activeRange()?.start,
                            rangeEnd: _activeRange()?.end,
                          ),
                        ),
                      Expanded(child: _list(rows, allRows)),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
```

and add:

```dart
  /// Every module with a dashboard gets the range chips, not just the ones
  /// whose rows carry a `date`. On a module without dates the chips move the
  /// dashboard only — `_applyFilter` still returns the list untouched.
  bool get _showFilterBar => cfg.dateFiltered || cfg.dashboard != null;
```

Extract the existing empty-state branch and `ListView.builder` into a private `Widget _list(List<Json> rows, List<Json> allRows)` so the empty state renders *below* the dashboard rather than replacing it — a module with goals but no entries in range should still show its figures.

- [ ] **Step 6: Delete the superseded summary banner**

Delete `_summaryBanner` (:947-987) and `_summaryLabel` (:989-996) entirely. Their content is replaced by `StatSpec`s on the Income and Expenses configs in Task 7 — do not leave them dead.

- [ ] **Step 7: Give Savings its dashboard**

In `lib/features/registry.dart`, add `import '../models/dashboard_spec.dart';` and add to the `savings` config, after `incrementLabel: 'Add to savings',`:

```dart
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('saved_amount', 'Saved'),
        StatSpec.sum('target_amount', 'Target'),
        StatSpec.progress('saved_amount', 'target_amount', 'Of target'),
        StatSpec.eventSum('saved_amount', 'Contributed'),
      ],
      chart: ChartSpec.cumulative('saved_amount', label: 'Savings growth'),
      breakdown: BreakdownSpec.byRow(value: 'saved_amount', of: 'target_amount'),
    ),
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `flutter test test/module_dashboard_test.dart`
Expected: PASS, 4 tests.

- [ ] **Step 9: Run the whole suite**

Run: `flutter test`
Expected: all pass. `test/date_filter_test.dart` and `test/expense_breakdown_test.dart` exercise the filter bar and must be unaffected — the bar's behaviour on `dateFiltered` modules is unchanged.

- [ ] **Step 10: See it in the app**

```bash
flutter run -d chrome
```
Open the drawer → Savings. Expect: a bordered card above the goal list showing Saved ₹1,92,000 / Target ₹6,40,000 / Of target 30% / Contributed ₹0, the "No history yet" panel, and three progress bars. Add ₹5,000 to a goal and confirm the Contributed figure moves and the chart replaces the empty state.

- [ ] **Step 11: Analyze and commit**

```bash
flutter analyze
git add lib/features/common/module_dashboard.dart lib/features/common/entity_screen.dart \
        lib/features/registry.dart test/module_dashboard_test.dart
git commit -m "Add collapsible dashboard header, mounted on the Savings page"
```

---

### Task 7: Dashboards for the remaining eight modules

**Files:**
- Modify: `lib/features/registry.dart` (income :34, expenses :58, investment :107, debtors :137, creditors :164, bills :190, loans :209, transfers :236)
- Test: `test/module_dashboard_test.dart` (extend)

**Interfaces:**
- Consumes: everything from Tasks 3-6. Produces no new API — configuration only.

- [ ] **Step 1: Write the failing test**

Append to `test/module_dashboard_test.dart`:

```dart
  testWidgets('every module page renders a dashboard header', (t) async {
    await E2E.launch(t);
    for (final page in [
      'Income',
      'Expenses',
      'Savings',
      'Investment',
      'Debtors',
      'Creditors',
      'Bill Payment',
      'Loan',
      'Transfers',
    ]) {
      await E2E.openDrawerItem(t, page);
      expect(find.byType(ModuleDashboard), findsOneWidget,
          reason: '$page has no dashboard header');
    }
  });

  testWidgets('investment shows return on capital', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Investment');
    // Seeded: invested 75000, current value 85300.
    expect(find.text('Return'), findsOneWidget);
    expect(find.text('+13.7%'), findsOneWidget);
  });
```

Add `import 'package:accounts_app/features/common/module_dashboard.dart';` to the test file.

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/module_dashboard_test.dart`
Expected: FAIL — "Income has no dashboard header".

- [ ] **Step 3: Add the eight configs**

In `lib/features/registry.dart`, add a `dashboard:` to each. Exact specs:

```dart
// income
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('amount', 'Total'),
        StatSpec.count('Entries'),
      ],
      chart: ChartSpec.bars('amount', label: 'Income'),
    ),

// expenses
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('amount', 'Total'),
        StatSpec.count('Entries'),
      ],
      chart: ChartSpec.bars('amount', label: 'Spending'),
    ),

// investment
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('total_invested', 'Invested'),
        StatSpec.sum('current_value', 'Current value'),
        StatSpec.ratio('current_value', 'total_invested', 'Return'),
        StatSpec.eventSum('invested_amount', 'Added'),
      ],
      chart: ChartSpec.dualCumulative(
        'invested_amount',
        'current_value',
        label: 'Invested vs value',
        firstLabel: 'Invested',
        secondLabel: 'Value',
      ),
      breakdown: BreakdownSpec.byRow(value: 'current_value'),
    ),

// debtors
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.outstanding('amount', 'Outstanding'),
        StatSpec.eventSum('amount', 'Received',
            kinds: [EventKind.decrement]),
        StatSpec.count('People'),
      ],
      chart: ChartSpec.cumulative('amount', label: 'Owed to you'),
      breakdown: BreakdownSpec.byRow(value: 'amount'),
    ),

// creditors — same shape, 'Paid' instead of 'Received'
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.outstanding('amount', 'Outstanding'),
        StatSpec.eventSum('amount', 'Paid', kinds: [EventKind.decrement]),
        StatSpec.count('People'),
      ],
      chart: ChartSpec.cumulative('amount', label: 'You owe'),
      breakdown: BreakdownSpec.byRow(value: 'amount'),
    ),

// bills
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('amount', 'Commitment'),
        StatSpec.count('Bills'),
      ],
      breakdown: BreakdownSpec.byRow(value: 'amount'),
    ),

// loans
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('outstanding', 'Outstanding'),
        StatSpec.sum('emi', 'Monthly EMI'),
        StatSpec.eventSum('outstanding', 'Paid',
            kinds: [EventKind.decrement]),
      ],
      chart: ChartSpec.cumulative('outstanding', label: 'Outstanding'),
      breakdown: BreakdownSpec.byRow(value: 'outstanding', of: 'principal'),
    ),

// transfers
    dashboard: const DashboardSpec(
      stats: [
        StatSpec.sum('amount', 'Moved'),
        StatSpec.count('Transfers'),
      ],
      chart: ChartSpec.bars('amount', label: 'Transfers'),
    ),
```

Add `import '../data/module_event.dart';` to `registry.dart` for `EventKind`.

Bills has no chart: a bill is a recurring template, not a balance, so there is no quantity that moves over time. Stats and a breakdown are the honest maximum.

Debtors and creditors chart `amount`, whose ledger fills from Task 2's `_payAmount` / `_markSettled` writes. Rows that were paid down before this release have no events and simply do not appear on the curve — the same "no invented history" rule as everywhere else.

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/module_dashboard_test.dart`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the whole suite**

Run: `flutter test`
Expected: all pass.

- [ ] **Step 6: Walk every page in the running app**

```bash
flutter run -d chrome
```
Open each of the nine modules. Check: no overflow warnings in the console, stat labels do not ellipsize on a narrow window, and the chart area shows either a curve or the "No history yet" panel — never a flat line at zero.

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/features/registry.dart test/module_dashboard_test.dart
git commit -m "Add dashboard specs for the remaining eight modules"
```

---

### Task 8: Accounts screen dashboard

**Files:**
- Modify: `lib/features/accounts/accounts_screen.dart`
- Create: `lib/features/accounts/account_metrics.dart`
- Test: `test/account_dashboard_test.dart`

**Interfaces:**
- Consumes: `Series`, `SeriesPoint`, `TimeBucket`, `buildTimeBuckets` (Task 4); `SeriesChart` (Task 5); `FinanceMath.balanceMap` (`lib/data/finance_math.dart:17`).
- Produces: `Series? accountBalanceSeries({required List<Json> accounts, required List<Json> income, required List<Json> expenses, required List<Json> transfers, required List<Json> cashMoves, required DateTime now, DateTime? rangeStart, DateTime? rangeEnd})`.

Accounts is the one page whose history already exists in full: every movement against an account is dated. It needs no ledger — only a walk over the movements it already has. That is why it gets its own metrics file rather than a `DashboardSpec`.

- [ ] **Step 1: Write the failing test**

Create `test/account_dashboard_test.dart`:

```dart
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/features/accounts/account_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 8, 2);

void main() {
  test('balance series walks opening balances forward through movements', () {
    final s = accountBalanceSeries(
      accounts: [
        {'name': 'Cash', 'opening_balance': 5000},
      ],
      income: [
        {'account': 'Cash', 'amount': 2000, 'date': '2026-02-10'},
      ],
      expenses: [
        {'account': 'Cash', 'amount': 500, 'date': '2026-03-05'},
      ],
      transfers: const [],
      cashMoves: const [],
      now: _now,
      rangeStart: DateTime(2026, 1, 1),
      rangeEnd: DateTime(2026, 12, 31),
    )!;

    expect(s.points.length, 12);
    expect(s.points[0].value, 5000); // Jan — opening only
    expect(s.points[1].value, 7000); // Feb — income lands
    expect(s.points[2].value, 6500); // Mar — expense lands
    expect(s.points[11].value, 6500);
  });

  test('transfers between own accounts net to zero overall', () {
    final s = accountBalanceSeries(
      accounts: [
        {'name': 'Cash', 'opening_balance': 1000},
        {'name': 'Bank', 'opening_balance': 1000},
      ],
      income: const [],
      expenses: const [],
      transfers: [
        {'from': 'Cash', 'to': 'Bank', 'amount': 400, 'date': '2026-02-10'},
      ],
      cashMoves: const [],
      now: _now,
      rangeStart: DateTime(2026, 1, 1),
      rangeEnd: DateTime(2026, 12, 31),
    )!;
    expect(s.points.every((p) => p.value == 2000), isTrue);
  });

  test('no accounts means no series', () {
    expect(
      accountBalanceSeries(
        accounts: const [],
        income: const [],
        expenses: const [],
        transfers: const [],
        cashMoves: const [],
        now: _now,
      ),
      isNull,
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/account_dashboard_test.dart`
Expected: FAIL — "Target of URI doesn't exist: '.../account_metrics.dart'".

- [ ] **Step 3: Write the implementation**

Create `lib/features/accounts/account_metrics.dart`:

```dart
import '../../data/finance_repository.dart';
import '../../models/dashboard_spec.dart';
import '../common/module_metrics.dart';

/// Total balance across all accounts at the close of each time bucket.
///
/// Unlike every other module this needs no ledger. Account movements — income,
/// expenses, transfers and the signed `cash_moves` rows — are all dated
/// already, so the curve is a walk over data the app has always had. Opening
/// balances are treated as present from the first bucket, matching
/// [FinanceMath.balanceMap], which has no notion of when an account was opened.
Series? accountBalanceSeries({
  required List<Json> accounts,
  required List<Json> income,
  required List<Json> expenses,
  required List<Json> transfers,
  required List<Json> cashMoves,
  required DateTime now,
  DateTime? rangeStart,
  DateTime? rangeEnd,
}) {
  if (accounts.isEmpty) return null;

  final names = {
    for (final a in accounts) (a['name'] ?? '').toString(),
  }..remove('');

  final opening = accounts.fold<double>(
      0, (a, r) => a + ((r['opening_balance'] as num?)?.toDouble() ?? 0));

  // (date, signed delta) for every movement that touches a known account.
  final moves = <(DateTime, double)>[];

  void add(dynamic account, dynamic date, double delta) {
    final name = account?.toString();
    if (name == null || !names.contains(name)) return;
    final d = date == null ? null : DateTime.tryParse(date.toString());
    if (d == null) return;
    moves.add((d.isUtc ? d.toLocal() : d, delta));
  }

  double amt(Json r) => (r['amount'] as num?)?.toDouble() ?? 0;

  for (final r in income) {
    add(r['account'], r['date'], amt(r));
  }
  for (final r in expenses) {
    add(r['account'], r['date'], -amt(r));
  }
  for (final t in transfers) {
    add(t['from'], t['date'], -amt(t));
    add(t['to'], t['date'], amt(t));
  }
  for (final m in cashMoves) {
    // Already signed: negative is money out.
    add(m['account'], m['date'], amt(m));
  }

  moves.sort((a, b) => a.$1.compareTo(b.$1));

  final DateTime from;
  final DateTime to;
  if (rangeStart != null && rangeEnd != null) {
    from = rangeStart;
    to = rangeEnd;
  } else if (moves.isEmpty) {
    from = now;
    to = now;
  } else {
    from = moves.first.$1;
    to = moves.last.$1.isAfter(now) ? moves.last.$1 : now;
  }

  final buckets = buildTimeBuckets(from, to);
  var running = opening;
  var i = 0;
  final points = <SeriesPoint>[];

  // Movements before the window are folded into the opening figure so the
  // first bucket shows the balance as it actually stood, not as it started.
  while (i < moves.length && moves[i].$1.isBefore(buckets.first.start)) {
    running += moves[i].$2;
    i++;
  }

  for (final b in buckets) {
    while (i < moves.length && !moves[i].$1.isAfter(b.end)) {
      running += moves[i].$2;
      i++;
    }
    points.add(SeriesPoint(b.label, running));
  }

  return Series(
    kind: ChartKind.cumulative,
    label: 'Balance',
    points: points,
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/account_dashboard_test.dart`
Expected: PASS, 3 tests.

- [ ] **Step 5: Mount it on the Accounts screen**

`accounts_screen.dart` is hand-built, not an `EntityScreen`. It already renders a "Total across N accounts" figure at the top of its `ListView` (`:162-175`); the chart goes directly beneath it, keeping that figure as the header's headline rather than duplicating it.

Add these imports:

```dart
import '../../core/charts.dart';
import '../common/module_metrics.dart';
import 'account_metrics.dart';
```

Add a second future alongside `_future` (`:20`):

```dart
  late Future<Series?> _chart;
```

and load it inside `_reload` (`:33`), so pull-to-refresh rebuilds both:

```dart
  void _reload() {
    final repo = ref.read(repoProvider);
    _future = repo.accountsWithBalances();
    _chart = _loadChart(repo);
  }

  Future<Series?> _loadChart(FinanceRepository repo) async {
    final lists = await Future.wait([
      repo.list('accounts'),
      repo.list('income'),
      repo.list('expenses'),
      repo.list('transfers'),
      repo.list('cash_moves'),
    ]);
    return accountBalanceSeries(
      accounts: lists[0],
      income: lists[1],
      expenses: lists[2],
      transfers: lists[3],
      cashMoves: lists[4],
      now: DateTime.now(),
    );
  }
```

Then in the `ListView` children, replace `const SizedBox(height: 20),` (`:175`, immediately after the total `MoneyText`) with:

```dart
                const SizedBox(height: 16),
                if (accounts.isNotEmpty)
                  AppCard(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: FutureBuilder<Series?>(
                      future: _chart,
                      builder: (context, chartSnap) {
                        final series = chartSnap.data;
                        if (series == null) {
                          return const ChartEmptyState(
                            message:
                                'Movements you record will appear here.',
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SectionLabel('Balance over time'),
                            SeriesChart(series: series),
                          ],
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 20),
```

`FinanceRepository` is already imported via `finance_repository.dart` (`:8`), and `SectionLabel` / `AppCard` via `components.dart` (`:5`).

Do not add a range filter here — Accounts has no filter bar today, and adding one is outside this change. `accountBalanceSeries` is called with both range arguments omitted, so it spans from the first movement to today.

- [ ] **Step 6: Verify in the running app**

```bash
flutter run -d chrome
```
Open Accounts. Expect a balance curve rising with the seeded salary and falling with rent, and a Total balance matching the sum of the rows beneath it.

- [ ] **Step 7: Run the whole suite, analyze, commit**

```bash
flutter test
flutter analyze
git add lib/features/accounts/ test/account_dashboard_test.dart
git commit -m "Add balance-over-time dashboard to the Accounts screen"
```

---

## Self-review notes

**Spec coverage.** §3 data model → Task 1. §3 write sites → Task 2. §4 computation → Task 4. §5 configuration → Task 3. §6 UI → Tasks 5, 6, 8. §8 per-page content → Tasks 6, 7. §9 empty states → Task 5 (`ChartEmptyState`) and Task 6 (test). §10 testing → tests in Tasks 1, 2, 4, 6, 7, 8. §11 build order → task order.

**One deliberate deviation from the spec.** §7 says the dated-vs-balance distinction would be "expressed as a new `EntityConfig` property". It isn't — `dateFiltered` already means "the range filters the list", and `dashboard != null` already means "this page wants the range chips". A third property would have to be kept consistent with both. The rule lives in `_showFilterBar` and in the doc comment on `EntityConfig.dashboard` instead. Behaviour is exactly as specified.

**Known gap, accepted.** Debtor and creditor curves only cover activity from this release onward, because `debt_payments` is not backfilled into `module_events`. `outstandingAsOf` in `trends.dart` could reconstruct the earlier shape, but wiring it in means two history sources for one chart. Left out under the same no-invented-history rule as §2; revisit if the curves prove too sparse to be useful.
