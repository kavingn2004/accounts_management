# SIP tracking with live NAV — design

**Date:** 2026-07-30
**Status:** Draft, awaiting review
**Goal:** Show the live current value of mutual-fund SIPs (held in Groww) inside
the accounts app, derived automatically rather than typed in by hand.

---

## 1. Problem

Investments are tracked today by typing a number: the `investment` module
(`lib/features/registry.dart:107`) stores `invested_amount`, `total_invested`
and `current_value`, and a row menu action **"Update current value"** overwrites
`current_value` with whatever you last saw in Groww. That number is stale the
moment it is entered, and it silently distorts net worth
(`FinanceMath.dashboard`, `lib/data/finance_math.dart:84`).

For a SIP the real state is not a rupee value at all — it is a growing pile of
**units**, bought at a different NAV every installment. Value is a function of
units and today's NAV. If the app models units, the value maintains itself.

### Why not integrate with Groww

Groww exposes no public portfolio API for retail users. Their published API
covers stock/F&O order placement and requires a trading API key; mutual-fund
holdings are not part of it. There is no supported way to pull the portfolio.

What *is* freely available is the NAV itself. AMFI publishes every scheme's NAV
daily, and `api.mfapi.in` mirrors it as JSON with full history. Verified
2026-07-30:

```
GET https://api.mfapi.in/mf/search?q=parag+parikh+flexi
  → [{"schemeCode":122639,"schemeName":"Parag Parikh Flexi Cap Fund - Direct Plan - Growth"}, …]

GET https://api.mfapi.in/mf/122639/latest
  → {"meta":{"fund_house":"PPFAS Mutual Fund","scheme_category":"Equity Scheme - Flexi Cap Fund",…},
     "data":[{"date":"29-07-2026","nav":"91.01190"}],"status":"SUCCESS"}
```

Response headers include `access-control-allow-origin: *`, so the deployed
Flutter **web** build can call it directly — no Supabase edge-function proxy.
Full history for one scheme is a single ~130 KB request.

---

## 2. Decisions taken

| Question | Decision |
|---|---|
| Source of current value | Full SIP ledger + historical NAV — installments derive units, units × latest NAV = value |
| Backfill of past installments | Auto-generate from the SIP setup (fund, amount, frequency, day, start date), then editable |
| Cash impact on accounts | **Future only** — backfilled history posts no cash movements; installments falling due from today onward debit a chosen account on confirmation |
| Detail view scope | Current value, gain/loss, XIRR, installment ledger, and a value-over-time chart |

The "future only" cash rule exists to avoid double-counting: expenses already
logged by hand for past SIP debits stay untouched, and no retrospective
movement is invented for them.

---

## 3. Architecture

### Integration insight

`FinanceMath.dashboard()` derives net worth from each investment row's
`current_value`, and the invested total from `total_invested`
(`lib/data/finance_math.dart:84-94`). So the SIP engine's entire contract with
the rest of the app is: **keep those two keys correct on the existing
`investments` row.** Dashboard, net worth, worth breakdown, and trends then
continue to work with no changes.

### New files

| File | Responsibility | Depends on |
|---|---|---|
| `lib/data/nav_api.dart` | HTTP client for `api.mfapi.in`: `search(String q)` → `List<SchemeRef>`, `history(int code)` → `NavSeries` (metadata + date→NAV map) | `package:http` |
| `lib/data/nav_cache.dart` | Persists each scheme's `NavSeries` in `LocalStore` under `nav_<code>` with a fetch stamp; serves cache when fresh or offline | `LocalStore`, `NavApi` |
| `lib/data/sip_math.dart` | Pure, no I/O: schedule generation, NAV resolution, units, valuation, XIRR, value series | — |
| `lib/services/sip_service.dart` | Orchestration: generate/refresh installments, write derived keys back through `FinanceRepository` | repo, cache, math |
| `lib/features/investments/sip_screen.dart` | SIP detail screen | service, `fl_chart` |

### Changed files

- `pubspec.yaml` — add `http: ^1.2.2` (the app currently has no HTTP client).
- `lib/data/local_store.dart` — a second namespace (`nav_`) alongside `tbl_`.
  `clearAll()` currently removes only `tbl_`-prefixed keys
  (`local_store.dart:37`); it must clear `nav_` keys too, so a factory reset
  leaves no orphaned NAV cache.
- `lib/features/registry.dart` — SIP fields on the `investment` module.
- `lib/features/common/entity_screen.dart` — a `FieldType.fundSearch` field, and
  tap-through to the SIP screen for rows with a `scheme_code`.
- `lib/models/field_spec.dart` — the new field type.

Each unit is independently testable: `sip_math` is pure functions over
fixtures, `nav_cache` takes an injectable `NavApi`, `sip_service` takes an
injectable cache and repository.

---

## 4. Data model

No Supabase migration is required — both backends store rows as JSON blobs
(`supabase/schema.sql:66`, `lib/data/local_store.dart`).

### Extra keys on an `investments` row (when `type == 'sip'`)

| Key | Written by | Meaning |
|---|---|---|
| `scheme_code` | user (fund picker) | AMFI scheme code, e.g. `122639` |
| `scheme_name`, `fund_house` | picker | Display, captured at selection |
| `sip_amount` | user | Per-installment amount |
| `sip_frequency` | user | `monthly` \| `weekly` \| `quarterly` |
| `sip_day` | user | Day of month (1–31), or weekday for weekly |
| `sip_start_date` | user | First installment date |
| `sip_active` | user | Paused SIPs stop generating new installments |
| `cash_from` | engine | Row creation date — the boundary between backfill (no cash movement) and live installments (§5.5) |
| `units` | engine | Σ units across non-skipped installments |
| `nav`, `nav_date` | engine | Latest NAV used for valuation, and its date |
| `current_value` | engine | `units × nav` |
| `total_invested` | engine | Σ amount across non-skipped installments |

`current_value` and `total_invested` become **derived** for SIP rows: rewritten
on every refresh, never hand-edited. The existing manual "Update current value"
action stays available for non-SIP rows (stocks, gold, FD) and is hidden for
SIP rows so the two can't fight.

### New table `sip_installments`

Mirrors the existing `debt_payments` pattern (`parent_id` → owning row).

| Key | Meaning |
|---|---|
| `parent_id` | Investment row id |
| `date` | Scheduled installment date (`YYYY-MM-DD`) |
| `amount` | Rupees debited |
| `nav`, `nav_date` | NAV used for allotment, and the date it belongs to |
| `units` | `amount / nav`, or a user override |
| `source` | `auto` (generated) \| `manual` (lumpsum or hand-added) |
| `skipped` | Excluded from units and invested totals |
| `account` | Account debited (future installments only) |
| `cash_posted` | Guard flag — a `cash_moves` row was written for this one |

`cash_posted` makes cash posting idempotent, so a re-generation or a repeated
refresh can never double-debit an account.

For Supabase, add `'sip_installments'` to the `app_tables` array in
`supabase/schema.sql:58` so the table and its RLS policies are created.

---

## 5. Engine behaviour

### 5.1 Schedule generation

Given `sip_start_date`, `sip_frequency`, `sip_day`, produce every installment
date from start through today (inclusive).

- Monthly with `sip_day = 31` in a 30-day month or February clamps to the last
  day of that month.
- Generation stops at today. Future-dated installments are never pre-created.
- If `sip_start_date` precedes the fund's earliest NAV (inception), the
  schedule is clamped to the first available NAV date and the user is warned.

### 5.2 NAV resolution — two distinct rules

These are genuinely different and getting them backwards causes wrong units:

**Allotment (installment → NAV): walk forward.** NAV is published only on
business days. A SIP debited on a Sunday is allotted at the *next* business
day's NAV. Resolve to the earliest available NAV date `>= installment date`,
searching up to 7 days. No NAV within 7 days → leave the installment
`nav: null` and flag it for attention rather than guessing.

**Valuation (today → NAV): walk backward.** Today's NAV is published late
evening IST, so during the day the newest available NAV is yesterday's. Resolve
to the latest available NAV date `<= target date`, searching back up to 10
days. The date used is surfaced in the UI as "as of 29 Jul".

### 5.3 Units, value, returns

```
units(installment)  = amount / nav          (skipped → 0)
units(row)          = Σ units(installment)
current_value       = units(row) × latest NAV
total_invested      = Σ amount              (skipped → 0)
gain                = current_value − total_invested
gain %              = gain / total_invested × 100
XIRR                = rate r solving Σ amountᵢ × (1+r)^(−daysᵢ/365) = current_value
```

XIRR uses Newton–Raphson seeded at 0.10, capped at 100 iterations, tolerance
1e-7, with a bisection fallback over [−0.99, 10] if the derivative collapses.
Non-convergence (or fewer than two cash flows, or a span under ~30 days) shows
`—` rather than a misleading figure.

### 5.4 Refresh

- Triggered on Investment screen load and on pull-to-refresh.
- NAV history is fetched **at most once per calendar day per scheme**; otherwise
  the cache is used. This keeps a normal session at zero network calls.
- Refresh does three things per SIP row: (a) append any installments that have
  become due since the last run, (b) re-resolve NAV for any installment left
  unresolved, (c) recompute and write `units`, `total_invested`,
  `current_value`, `nav`, `nav_date`.
- Rows are written through `FinanceRepository`, so `dataRevisionProvider`
  (`lib/services/providers.dart:47`) bumps and the dashboard reloads as usual.

### 5.5 Newly due installments and cash

The past/future boundary is a concrete stored value, not an implicit "now": the
SIP row records `cash_from` = the date the row was created. Installments dated
**before** `cash_from` are backfill — units only, no cash movement, no banner.
Installments dated **on or after** `cash_from` are created **unconfirmed** and
raise a banner on the Investment screen:
*"1 SIP installment due — 5 Aug, ₹5,000"*. Confirming asks which account to
debit (defaulting to the last one used for that SIP) and writes a `cash_moves`
row via the existing pattern (`entity_screen.dart:143`), then sets
`cash_posted`. Dismissing marks it `skipped`.

Units are counted as soon as the installment is generated — the debit
confirmation affects account balances only, not valuation.

---

## 6. Error handling

| Situation | Behaviour |
|---|---|
| Network unavailable / API 5xx | Serve cached NAV; screen shows a "stale — as of *date*" badge. `current_value` is never zeroed or cleared. |
| No cache and no network (first run) | The SIP row is created with units unresolved and a "tap to retry" state. Nothing is written to `current_value`. |
| Scheme returns `status != SUCCESS` or empty `data` | Treated as a fetch failure; the scheme code is flagged as possibly wrong in the row's detail screen. |
| NAV missing for an installment date | Forward-walk 7 days; still missing → installment shown in the ledger with a warning chip and excluded from units until resolved. |
| SIP start before fund inception | Clamp to inception, show a one-time warning on the detail screen. |
| XIRR fails to converge | Show `—`. Value and gain/loss still display. |
| Malformed cached JSON | Discard cache entry and refetch. |

### Known variance from Groww

Actual allotted units are marginally lower than `amount / nav` because of
0.005% stamp duty on purchases (and, for some plans, transaction charges). Over
a year of ₹5,000 monthly this is roughly ₹3 of value — immaterial, but it means
the app's units will read very slightly high versus the Groww app. Mitigation:
each ledger row's `units` is editable, so an exact figure can be pasted in from
Groww if precision matters. This is documented rather than modelled.

Also not modelled: IDCW (dividend) payouts and reinvestment. Growth-plan
schemes — what Groww sells by default — have neither, so units change only via
installments. Selecting an IDCW plan in the fund picker shows a warning that
valuation will drift.

---

## 7. Screens

Follows the existing visual language (see `UI_REDESIGN.md`): ivory/clay paper
surfaces, serif figures for numbers, bordered surfaces, no card fills.

### Investment list (existing screen, `entity_screen.dart`)

- SIP rows get a subtitle of `sip · 214.53 units · as of 29 Jul` and keep the
  current value as the trailing figure.
- Tapping a SIP row opens the SIP detail screen instead of the edit sheet;
  editing moves to the row menu.
- The create sheet, when `type = sip`, reveals: fund search field, SIP amount,
  frequency, day, start date. The fund search calls `NavApi.search` with a
  debounce and lists full scheme names — **pick the "Direct Plan - Growth"
  variant**, which is what Groww sells; regular-plan NAVs differ by the
  distributor commission and would understate returns.

### SIP detail screen (`sip_screen.dart`)

1. **Header** — current value as the large serif figure; beneath it total
   invested, gain/loss in rupees with %, XIRR, and the "as of *date*" stamp.
2. **Chart** — `fl_chart` line chart of value vs invested over the SIP's life,
   computed from NAV history already in cache (same library and styling as
   `lib/features/dashboard/trends.dart`).
3. **Ledger** — every installment: date, amount, NAV, units bought, and what
   those units are worth today. Skipped rows are struck through; unresolved
   rows carry a warning chip.
4. **Actions** — add a lumpsum, edit or skip an installment, override units,
   refresh now, pause/resume the SIP.

---

## 8. Testing

Everything numeric is tested without network access.

**`test/sip_math_test.dart`** (pure, fixture NAV map)
- Monthly schedule across month lengths; day 31 clamps to 28/29/30.
- Weekly and quarterly generation.
- Allotment resolves *forward* over a weekend; valuation resolves *backward*.
- No NAV within the 7-day window leaves the installment unresolved.
- Units and totals exclude skipped installments.
- XIRR against a known series (a flat 12% annual series returns ≈0.12); single
  cash flow and sub-30-day spans return null.

**`test/nav_cache_test.dart`** (fake `NavApi`)
- Second call the same day hits cache, not the API.
- Next calendar day refetches.
- API throw with a warm cache serves stale data; with a cold cache surfaces the
  error.
- Corrupt cached JSON triggers a refetch.

**`test/sip_service_test.dart`** (fake cache + `LocalRepository`)
- Creating a SIP backfills installments and writes `units`, `current_value`,
  `total_invested`.
- Refresh appends only newly due installments — no duplicates on repeat runs.
- `cash_posted` prevents a second `cash_moves` row for the same installment.
- Backfilled historical installments post no cash movements.

**`test/sip_screen_test.dart`** — widget test over a seeded store using the
existing `E2E` harness (`test/support.dart`): figures render, ledger lists the
installments, chart builds.

**Regression:** existing suites must stay green, in particular
`dashboard_investment_test.dart` and `local_repository_test.dart`, since
`current_value` now has a second writer.

---

## 9. Implementation order

Each phase ends green and independently useful.

1. **NAV client, cache, math** — `nav_api.dart`, `nav_cache.dart`,
   `sip_math.dart`, plus their three test files. No UI.
2. **SIP creation and backfill** — registry fields, fund-picker field type,
   `sip_service.dart` generation. A created SIP shows a correct
   `current_value` in the existing list and on the dashboard.
3. **Refresh wiring** — daily NAV refresh and installment top-up on Investment
   screen load and pull-to-refresh, with the stale badge.
4. **SIP detail screen** — header figures, ledger, chart.
5. **Due-installment confirmation** — banner, account picker, `cash_moves`
   posting guarded by `cash_posted`.

---

## 10. Out of scope

- Any direct Groww account connection (not technically possible).
- Parsing CAS / Groww statement files.
- Stocks, ETFs, and gold — they need a price source, not a NAV source.
- Capital-gains or tax reporting.
- Automatic execution of SIPs (the app records; it does not transact).
- Push notifications for due installments (the in-app banner covers it).

---

## 11. Open questions

None blocking. Two worth revisiting after phase 4:

- Whether the value-over-time chart should aggregate **all** SIPs on the
  dashboard, not just per-fund on the detail screen.
- Whether a paused SIP should keep valuing (it will — units still exist) but be
  visually distinguished in the list.
