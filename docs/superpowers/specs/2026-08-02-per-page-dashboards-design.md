# Per-page dashboards — design

**Date:** 2026-08-02
**Status:** Draft, awaiting review
**Goal:** Give every module page its own dashboard — a few headline figures and
a chart — so the Savings page answers "how much have I saved, and how fast?"
without a trip to the main dashboard.

---

## 1. Problem

Every module page in the app is the same screen. `EntityScreen`
(`lib/features/common/entity_screen.dart`) is driven by an `EntityConfig` from
`lib/features/registry.dart`, and it renders one thing: a flat list of rows.
The only summary it offers is `_summaryBanner`
(`lib/features/common/entity_screen.dart:947`), a single total, and only for
the two modules flagged `dateFiltered` — Income and Expenses.

So the Savings page shows four goal rows and nothing else. The combined saved
total, the combined target, progress against it, and any sense of pace all live
either on the main dashboard or nowhere.

### Why the growth chart can't be built today

Savings and investments **store no history**. "Add to savings" reads the
current value, adds to it, and writes it straight back
(`lib/features/common/entity_screen.dart:266-278`); "Update current value" does
the same by replacement (`_setValue`, `:286`). Nothing records that the change
happened. `trends.dart:18-21` already documents this constraint and works
around it by reporting return-on-capital instead of a period comparison.

Three existing tables look like they might help. None does:

| Table | Why it doesn't work |
|---|---|
| `debt_payments` | Only debtors/creditors write it (`paymentsTable` in `EntityConfig`). Savings, investments, loans and bills log nothing. |
| `cash_moves` | Written only when the user picks an account, which is **optional** on every one of these dialogs. Carries no `parent_id`, so a contribution can't be attributed to a specific goal. |
| Row `created_at` | One timestamp per goal, not per contribution. Gives a start point, not a curve. |

A growth chart therefore requires a new ledger. That is the substance of this
change; the dashboard widgets are the easy half.

---

## 2. Decisions taken

| Question | Decision |
|---|---|
| Where does history come from? | A new generic `module_events` ledger — one table, every module |
| Backfill of past contributions? | No. The curve starts empty and fills from the first action after release |
| Where does the dashboard sit? | Collapsible header above the list, expanded by default, collapse state remembered per module |
| Which pages? | All 9 registry modules **and** the Accounts screen |
| Period control? | The existing date-filter bar drives the dashboard; every page gets one |
| `debt_payments`? | Left alone. Debtors/creditors dual-write — `debt_payments` for the settle flow, `module_events` for charts |

### Rejected alternatives

**Per-module ledger tables** (`savings_contributions`, `investment_values`,
`loan_payments`, …) mirroring `debt_payments` one for one. Each table would be
simpler, but it is five-plus migrations and five read paths answering the same
shape of question. The `EntityConfig` pattern exists precisely to avoid
per-module code; this would reintroduce it in the data layer.

**Periodic balance snapshots** — snapshot every row's value nightly and chart
the snapshots. Needs no action instrumentation and yields smooth curves, but
requires a scheduler the app does not have, and is simply wrong for an app that
runs offline for days at a time.

**Backfilling a synthetic opening entry per row** so the chart isn't empty on
day one. Rejected because the resulting straight line looks like measured
history and isn't. An honest empty state is better than a fabricated curve.

---

## 3. Data model — `module_events`

One row per value-changing action, on any module.

```
id            uuid
parent_id     string   -- the source row's id
parent_type   string   -- source table: 'savings_goals', 'investments', …
field         string   -- which column moved: 'saved_amount', 'current_value', …
kind          string   -- 'open' | 'increment' | 'decrement' | 'set'
amount        number   -- the delta; for 'set', the new value
balance_after number   -- the field's value immediately after the action
account       string?  -- account the cash moved through, when one was chosen
date          string   -- yyyy-MM-dd
note          string?
```

`balance_after` is the load-bearing column. A growth curve is read as a step
function through recorded balances, never re-derived forward from an opening
figure. Forward derivation drifts the moment a row is edited by hand — and the
chart would then contradict the total printed above it. `trends.dart:184-190`
makes the same argument for walking debt balances backwards; this is the same
rule applied at write time.

**Storage.** `LocalStore` (`lib/data/local_store.dart`) is table-name-generic —
on-device storage needs no change beyond using the new name. Supabase gets
`supabase/migrations/0005_module_events.sql`, structurally a copy of
`0004_debt_payments.sql`: JSONB `data` column, owner-only RLS, guarded by an
`if not exists` so it is safe to re-run.

### Write sites

Six places in `EntityScreen`, all of which already mutate a numeric column:

| Site | Event |
|---|---|
| `_addAmount` (`:223`) | `kind: 'increment'` on `incrementField`; a second event for `incrementAlsoField` when set |
| `_setValue` (`:286`) | `kind: 'set'` on `setField` |
| `_payAmount` (`:342`) | `kind: 'decrement'` on `decrementField`, `balance_after` taken *after* any interest accrual |
| `_markSettled` (`:480`) | `kind: 'set'` with `balance_after: 0` |
| `_reopen` (`:557`) | `kind: 'set'` restoring the balance |
| `_submit` in `_EntrySheet` (`:1143`), on create | `kind: 'open'`, `balance_after` = the initial value |

The `'open'` event matters: without it a goal created at ₹50,000 and never
topped up has no events at all, and its curve would start at zero.

`_markSettled` matters for a subtler reason. `trends.dart:191-194` notes that a
debt written off has no closing timestamp today, so it "counts as zero at every
instant — no invented drop". With a settle event recorded, the outstanding
curve can finally show the drop on the day it actually happened. The backwards
walk in `outstandingAsOf` stays as it is — it remains correct — but new rows
gain a real closing point.

Debtors and creditors keep writing `debt_payments` exactly as they do now
(inside `_payAmount` and `_markSettled`) **in addition** to `module_events`.
The settle flow, status transitions and the Payments viewer all read
`debt_payments`; changing them is unrelated to this work and carries real risk
of breaking settlement. The duplication is accepted deliberately and should be
revisited only as its own change.

---

## 4. Computation — `lib/features/common/module_metrics.dart`

Pure Dart. No Flutter imports, no I/O — the same discipline as
`lib/features/dashboard/analytics.dart` and `lib/features/dashboard/trends.dart`,
so every rule is unit-testable.

```dart
List<Stat> statsFor(EntityConfig cfg, List<Json> rows, List<Json> events, DateWindow w);
Series     seriesFor(EntityConfig cfg, List<Json> rows, List<Json> events, Period p);
```

- `Stat` — label, formatted value, optional `Trend` (reused from `trends.dart`).
- `Series` — a list of `(bucketLabel, value)` points plus a `SeriesKind`
  (`line`, `bars`, `dualLine`).

Reuses rather than reimplements: `currentWindow` / `previousWindow` /
`DateWindow` / `Trend` / `TrendMood` from `trends.dart`, and the bucket
construction from `analytics.dart:51` (`buildBuckets`). Where `buildBuckets` is
hardwired to income-vs-expense pairs, it is generalised to bucket an arbitrary
list of dated values; the existing dashboard call site keeps its behaviour.

---

## 5. Configuration — `EntityConfig.dashboard`

One new optional field on `EntityConfig` (`lib/models/field_spec.dart:32`), so
a module declares its dashboard the same way it declares its form fields:

```dart
dashboard: const DashboardSpec(
  stats: [
    StatSpec.sum('saved_amount', 'Saved'),
    StatSpec.sum('target_amount', 'Target'),
    StatSpec.progress('saved_amount', 'target_amount', '% of target'),
    StatSpec.eventSum('saved_amount', 'Contributed'),   // respects the range
  ],
  chart: ChartSpec.cumulative('saved_amount', label: 'Savings growth'),
  breakdown: BreakdownSpec.byRow(value: 'saved_amount', of: 'target_amount'),
),
```

A module with no `dashboard` renders no header, so the field is additive and
nothing breaks while the nine are filled in.

---

## 6. UI

**`lib/core/charts.dart`** — themed `fl_chart` wrappers: `LineChartCard`,
`BarChartCard`, `DualLineChartCard`, `ProgressBars`, `DonutCard`. Styled once
against `AppTheme` so charts inherit the ivory/clay paper look — hairline
borders, tabular figures, tone only on the mark — instead of `fl_chart`
defaults. `fl_chart: ^1.2.0` is already a dependency and already used by
`dashboard_screen.dart`.

**`lib/features/common/module_dashboard.dart`** — the header itself: stat row,
chart card, optional breakdown, and a chevron that collapses it to the stat row
alone. Collapsed state persisted per module in `shared_preferences` under
`dash_collapsed_<table>`.

**`entity_screen.dart`** — body becomes filter bar → `ModuleDashboard` → list.
`_summaryBanner` (`:947`) and `_summaryLabel` (`:989`) are absorbed into the
new header and deleted; today's "Total this month / N entries" becomes two
`StatSpec`s on the Income and Expenses configs, so nothing is lost.

**`accounts_screen.dart`** — mounts the same `ModuleDashboard`, fed by a
balance-over-time series derived from `cash_moves` plus income, expenses and
transfers via `FinanceMath.balanceMap` (`lib/data/finance_math.dart:17`).
Accounts is the one page whose history already exists in full, because every
movement against an account is dated.

### File sizes

`entity_screen.dart` is 1430 lines already. The dashboard adds no rendering
code to it — the header is one widget in its own file, and the metrics are
computed in another. Net change to `entity_screen.dart` is a small addition at
the four write sites and a body swap, minus the ~50 lines of `_summaryBanner`.

---

## 7. How the date range binds

Every page gains the `_DateRange` filter bar (`:912`). But the range cannot
mean the same thing everywhere: savings goals, loans and bills rows carry **no
`date` column**, so filtering the list by range would blank the page.

- **Dated modules** — Income, Expenses, Transfers. The range filters stats,
  chart *and* list. Unchanged from today.
- **Balance modules** — Savings, Investments, Loans, Bills, Debtors, Creditors,
  Accounts. The range filters the **dashboard only**; the list always shows
  every row.

Stat labels carry the distinction so the screen can't be misread: a balance
module says "Contributed this month" for its event-derived figure and plain
"Saved" for its current total — never "Saved this month", which would imply the
list had been filtered too.

This is expressed as a new `EntityConfig` property rather than inferred, so the
rule is visible at the config site alongside `dateFiltered`.

---

## 8. Per-page content

| Page | Stats | Chart |
|---|---|---|
| **Savings** | Saved · Target · % of target · Contributed in range | Cumulative saved over time; per-goal progress bars |
| **Investment** | Invested · Current value · Return % · Added in range | Invested vs current value, two lines |
| **Income** | Total in range · Avg per bucket · Top source | Bars per bucket |
| **Expenses** | Total in range · Avg per day · Largest payee | Bars per bucket; payee donut |
| **Debtors** | Outstanding · Received in range · Settled count | Outstanding over time |
| **Creditors** | Outstanding · Paid in range · Next due | Outstanding over time |
| **Loans** | Outstanding · Total EMI · Principal paid in range | Outstanding over time |
| **Bills** | Monthly commitment · Due this month · Count | Bars by frequency |
| **Transfers** | Moved in range · Count · Busiest pair | Bars per bucket |
| **Accounts** | Total balance · Account count · Net change in range | Balance over time |

Debtors, creditors and loans chart their outstanding balance using
`outstandingAsOf` (`trends.dart:196`), which already reconstructs a balance at
an instant by walking backwards from today. It is fed `debt_payments` for the
first two and `module_events` for loans.

---

## 9. Empty and error states

A module whose ledger is empty must not draw a flat line at zero — that reads
as a measurement, and a false one. The chart area instead shows:

> **No history yet** — entries you add from now on will appear here.

Stats derived from current row values (Saved, Target, Outstanding) render
normally in that state; only the time series is suppressed. A range containing
no events on an otherwise-populated ledger shows an empty chart with the axis
intact, which is a real answer — nothing happened that month.

Ledger writes are best-effort: if the `module_events` insert fails, the value
update itself has already been committed and the UI does not roll it back or
block. A missing event costs a point on a chart; a rolled-back contribution
costs the user their data.

---

## 10. Testing

Unit tests in `test/module_metrics_test.dart`, following
`test/dashboard_trends_test.dart`:

- Cumulative series built from a mixed `open` / `increment` / `set` ledger.
- Empty ledger → no series, and stats still computed from rows.
- Range boundaries — an event dated on the first of the month lands inside it,
  matching the half-open `DateWindow` rule.
- `set` events override rather than accumulate (an investment revalued down
  must bend the curve down).
- Bucketing for each `Period`, including the year case with sparse months.

Widget tests in `test/module_dashboard_test.dart`:

- Header renders its stats; chevron collapses to the stat row and back.
- Empty-ledger module shows the "No history yet" copy, not a zero line.
- Balance module's list is unaffected by the range chips.

An end-to-end test in the style of `test/investment_e2e_test.dart`: create a
savings goal and add to it twice, then assert three `module_events` rows exist
— one `open` and two `increment` — each with the correct `balance_after`, and
that the header total matches the sum of the goal rows.

---

## 11. Build order

1. `module_events` — migration, event write helper, wired into the four sites.
   Ships invisible; the ledger starts filling.
2. `module_metrics.dart` + tests. No UI.
3. `charts.dart` + `module_dashboard.dart`, mounted on Savings only.
4. Remaining eight modules as config entries.
5. Accounts screen.

Each step is independently verifiable, and step 1 landing first means the
ledger has real data by the time the charts appear.
