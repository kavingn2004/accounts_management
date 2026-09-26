# Investment live tracking — design

**Date:** 2026-08-02
**Status:** Implemented
**Goal:** Value investment holdings from live market prices instead of a number
typed in by hand.

---

## 1. Problem

An investment row stores `current_value`, overwritten by the row-menu action
"Update current value". It is stale the moment it is entered and it feeds net
worth directly (`FinanceMath.dashboard`, `lib/data/finance_math.dart:84`).

A price alone can't fix this: the row records rupees, not holdings, so there is
nothing to multiply a price by. Live tracking therefore needs two things — a
price source per asset type, and enough per-row data to turn a price into a
value.

## 2. Decisions

| Question | Decision |
|---|---|
| Asset types | Indian stocks, mutual funds/SIP, crypto, gold |
| Fetch path | In-app, direct from the device — no backend, works with Supabase off |
| Valuation | Explicit `symbol` + `quantity` per row; value = price × quantity |
| Refresh | On screen open (throttled 15 min) and on pull-to-refresh (forced) |
| Persistence | Write through to `current_value`, so net worth and charts follow |
| Symbol entry | Typed, verified on save — no search picker yet |

**Opt-in by data, not by flag.** A row is live only when it has *both* a symbol
and a quantity. Every existing row has neither, so nothing changes until the
user fills them in. This is also the safety property: live tracking cannot
overwrite a hand-kept value it was never given a holding for.

## 3. Sources

| Type | Endpoint | Key | CORS |
|---|---|---|---|
| `stock` | `query1.finance.yahoo.com/v8/finance/chart/<T>.NS` | none | **no** |
| `mf`, `sip`, `fund` | `api.mfapi.in/mf/<schemeCode>` | none | yes |
| `crypto` | `api.coingecko.com/api/v3/simple/price?ids=…&vs_currencies=inr` | none | yes |
| `gold` | same, via `pax-gold` ÷ 31.1034768 g/ozt | none | yes |
| `fd`, `other` | — no market price; stays manual | | |

Yahoo sends no CORS headers, so stocks cannot refresh in the web build.
`QuoteSource.availableHere` reports this up front and the UI says "use the
mobile app" rather than retrying a request the browser will keep refusing.

**Gold is international spot.** PAXG is backed by one troy ounce of London Good
Delivery gold and CoinGecko quotes it in INR, which gives a per-gram rate with
no key and no FX conversion. Indian retail gold sells higher — import duty, GST
and making charges sit outside this figure — so a gold row may set
`rate_per_gram` to pin its own rate and stop asking the network.

## 4. Data model

No migration: both backends store rows as JSON blobs (`supabase/schema.sql:66`,
`lib/data/local_store.dart`).

| Key | Written by | Meaning |
|---|---|---|
| `symbol` | user | Ticker, AMFI scheme code, CoinGecko id, or `gold` |
| `quantity` | user | Shares / units / coins / grams |
| `rate_per_gram` | user | Gold only; overrides the live rate |
| `last_price` | sync | Unit price in INR |
| `price_at` | sync | The price's own timestamp — NAV date, or market time |
| `price_source` | sync | Shown on the row, so no figure is anonymous |
| `current_value` | sync | `last_price × quantity` |

`price_at` is the *price's* timestamp, not the fetch time. That distinction is
what lets an unchanged price skip the write entirely: a fund whose NAV is still
Friday's writes nothing, and the row's age stays truthful.

## 5. Components

```
lib/services/quotes/
  quote.dart            Quote (symbol, price, asOf, source), QuoteFailure
  quote_source.dart     interface + shared status→message wording
  yahoo_source.dart     stocks
  mf_source.dart        NAV by scheme code
  coingecko_source.dart crypto (batched) + gold (per gram)
  quote_service.dart    routes by type, batches, throttles, caches
  investment_sync.dart  price × quantity → repo writes + ledger events
```

Dependency direction is one way: screen → sync → service → sources. A source
knows nothing about investment rows, which is what makes each one testable
against a fake `http.Client` and a recorded response.

`QuoteService` is app-wide (`quoteServiceProvider`) so its throttle survives
navigating away and back — a per-screen instance would refetch on every visit,
which is what the throttle exists to prevent.

### Ledger

A value change logs one `EventKind.set` event, exactly as the manual action
does, so the invested-vs-value chart follows live prices. Capped at **one event
per row per day**: the ledger stores dates to the day, so a second is redundant,
and unchecked it would bury real revaluations under noise.

## 6. Error handling

| Situation | Behaviour |
|---|---|
| Network down, 5xx, rate limit | Row keeps its stored value; one quiet notice |
| Bad symbol (404 / empty data) | Same, worded as "check the symbol" |
| Non-INR quote | Refused — mixing currencies would corrupt net worth |
| Browser + stocks | Named as a platform limit, not a network error |
| No symbol or no quantity | Row untouched, subtitle unchanged |
| Any unexpected throw | Caught in `_withLivePrices`; the list still renders |

Failures are per-row and per-source: one bad symbol in a CoinGecko batch does
not cost the others their prices.

## 7. UI

- Two fields on the investment form, hidden for types with no price source, with
  a hint that changes with the selected type (`FieldSpec.dependsOn` / `hints` /
  `visibleWhen`). Gold gains a third, its rate override.
- Saving reports what the symbol resolved to — `₹1,432.20 × 12 = ₹17,186` — or
  why it didn't. The save is never blocked; a row with a bad symbol is still a
  row, it just isn't live.
- A live row's subtitle reads `stock · ₹1,432.20 × 12 · 2h ago`. A live figure
  with no visible age is indistinguishable from a stale one.
- Failures raise a bordered strip above the list, not a dialog: the values on
  screen are still the last good ones.

## 8. Testing

- `test/quote_sources_test.dart` — per source against fixtures: price parsing,
  `.NS` defaulting, non-INR refusal, 404/429/5xx wording, malformed JSON, dead
  socket, CoinGecko batching, PAXG→gram conversion.
- `test/investment_sync_test.dart` — value = price × quantity; rows missing
  either field are never touched and cost no request; a failure leaves the
  stored value standing; manual gold rate skips the network; unchanged price
  writes nothing; one ledger event per row per day; throttle honours the window,
  `force` bypasses it, ten rows of one symbol cost one lookup.
- `test/investment_live_screen_test.dart` — live value and price age render;
  a quantity-less row keeps its manual value; a bad symbol shows the notice;
  the form reveals fields only for priceable types.

## 9. Out of scope

Historical price charts, background refresh while the app is closed, fund-name
search (typed scheme codes for now), and any brokerage account connection.

## 10. Relationship to the SIP NAV design

`2026-07-30-sip-nav-tracking-design.md` (draft, unimplemented) designs a deeper
mutual-fund engine: an installment ledger that *derives* units from a SIP
schedule, plus XIRR and a detail screen. This design is the layer underneath
it — the same NAV source, but the user states the units rather than the app
deriving them.

The two compose rather than conflict. If the SIP engine is built, it takes over
computing units for `sip` rows and should write them to `quantity`, leaving
valuation, throttling, error handling and the ledger cap here unchanged. The
alternative — teaching the sync to read `units` as a fallback — is deliberately
not built yet, since nothing writes that key today.
