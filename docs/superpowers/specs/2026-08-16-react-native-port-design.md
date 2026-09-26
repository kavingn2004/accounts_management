# Accounts app — React stack: separate web, mobile, and backend

Date: 2026-08-16
Status: proposed (awaiting review)
Supersedes: the single-app and two-app drafts of the same date

## Goal

Reproduce the existing Flutter app (`accounts_management`, ~14.6k lines of Dart,
9 modules, 45 test files) as **three separate applications** in a new folder,
against the same Supabase project and schema:

- **`apps/api`** — Node + TypeScript backend. Owns all database access, all
  money-moving logic, market data, the SIP engine, and the LLM proxy.
- **`apps/mobile`** — React Native (Expo) app for iOS and Android.
- **`apps/web`** — React (Vite) single-page app for the browser.

The Flutter app keeps working and keeps shipping against the same database.
This is a parallel implementation, not a migration.

## Assumptions

Decided rather than asked. Cheap to reverse at phase 0, expensive later.

1. **Monorepo at `/home/stacx-24/gn/accounts_ts/`** (pnpm workspaces + turbo).
   Rename the root freely; nothing else moves.
2. **`apps/mobile` is Expo SDK 54 + expo-router, native-only.** Now that web has
   its own app, the mobile app drops react-native-web and stops compromising for
   the browser.
3. **`apps/web` is Vite + React + TypeScript + React Router**, deployed to
   Netlify as a static SPA — matching how the Flutter web build deploys today.
   Not Next.js: this is an auth-gated personal finance app with no SEO surface
   and no need for SSR, and a server runtime would be a third deploy target
   earning nothing.
4. **Fastify + TypeScript + Zod** for the backend. Express is dated; NestJS
   brings a DI framework this doesn't need.
5. **Auth stays with Supabase Auth.** Both clients sign in against Supabase
   directly and send the resulting JWT to the API as a bearer token.
6. **No schema changes.** Same tables, migrations, and RLS. Both the Flutter app
   and this stack read the same rows.
7. **RLS stays on.** The API queries with a per-request user JWT, not the
   service-role key, so Postgres still enforces isolation.

## The real design question: what do web and mobile share?

Two React apps that render different primitives (`<div>` vs `<View>`) cannot
share components. They *can* share everything else — and if they don't, they
will drift, and a bug fixed in one will survive in the other.

So the split is drawn deliberately:

| Layer | Shared? | Where |
|---|---|---|
| Entity/field/dashboard specs, the 9 module configs | **yes** | `packages/shared` |
| Money math, SIP math, module events, formatters | **yes** | `packages/shared` |
| Typed API client, query keys, cache invalidation | **yes** | `packages/api-client` |
| Screen behaviour — filters, form state, validation, action dispatch | **yes** | `packages/logic` (headless hooks) |
| Chart geometry — scales, `d` path strings, tick placement | **yes** | `packages/logic` |
| Design tokens — colours, radii, spacing, type scale | **yes** | `packages/tokens` |
| Components, styling, navigation, gestures | **no** | each app |

`packages/logic` is the piece that makes this work. `useEntityList`,
`useEntryForm`, `useDateRange`, `useModuleDashboard`, `useRowActions` are plain
React — no DOM, no React Native — returning state and callbacks. Web and mobile
each render them their own way. Same behaviour, two skins, one place to fix it.

Chart geometry shares further than it looks: `d3-shape` produces an SVG path
string, and both `<svg><path d=…>` and `<Svg><Path d=…>` consume it unchanged.
Only the element names differ.

## Why a backend changes more than the folder layout

In the Flutter app, business logic lives in the UI. [`entity_screen.dart`](../../../lib/features/common/entity_screen.dart)
is 2,481 lines and contains 20 `Future<void> _action(...)` methods that debit
accounts, accrue interest, settle debts, and redeem holdings — all client-side,
all trusting the client. Fine for one first-party app; wrong the moment there
are three.

| Concern | Flutter (today) | This design |
|---|---|---|
| Row CRUD | client → Supabase | client → API → Postgres |
| Increment / payment / settle / redeem | client-side, multi-step, non-atomic | **API, one transaction** |
| Interest accrual | client-side | API |
| Cascade delete | client loops child tables | API, one transaction |
| Market quotes (Yahoo/mfapi/CoinGecko) | each client, each launch | **API, cached once for all users** |
| NAV history | per-device cache | API, shared daily cache |
| SIP installment engine | client-side on screen open | API, plus a scheduled job |
| LLM proxy | Netlify function | API route |
| PDF export | client (`pdf` package) | API |
| Rendering, navigation, gestures | client | client |

Three of these are genuine upgrades, not relocations:

- **Atomicity.** `_payAmount` today reads a row, accrues interest, writes a
  balance, writes a status, inserts a payment row, and posts a cash movement —
  as separate calls. A dropped connection halfway leaves the data wrong. On the
  server it is one transaction.
- **Quote fetching.** Every client currently hits Yahoo and CoinGecko itself.
  In a browser that needs CORS luck; everywhere it burns rate limit per device.
  One server-side cache serves every user and every platform.
- **Trust.** No client can write an arbitrary balance. The API recomputes it
  from the `EntityConfig` rules.

## Specs are data, and both sides need them

The nine `EntityConfig`s in [`registry.dart`](../../../lib/features/registry.dart)
are needed by the two frontends (to render forms and dashboards) *and* by the
backend (to validate writes and execute actions). They belong to no single app.

Two adjustments make them portable:

- `EntityConfig.icon` is `IconData` in Dart, a Flutter type. In shared it
  becomes an icon **name** (`'south_west'`), resolved to a component in each
  frontend — a Lucide glyph on web, its RN equivalent on mobile.
- `titleOf` / `subtitleOf` / `trailingOf` are pure functions over a row. They
  stay shared, because server-side CSV and PDF export must render the same
  titles the lists show.

Consequence: **the API has no per-module `if` statements**, exactly as
`EntityScreen` has none today.

## Authorization

The API does **not** use the service-role key for user data. Each request
carries the caller's Supabase JWT; the API builds a per-request Supabase client
bound to that token, so every query runs as that user and RLS applies exactly as
it does for the Flutter app. A bug in a handler cannot return another user's
rows, because Postgres refuses.

Service role is confined to two request-free modules: the scheduled SIP job, and
the shared NAV/quote cache tables, which hold no user data.

```
web / mobile ──sign in──▶ Supabase Auth ──JWT──▶ client
client ──Bearer JWT──▶ API ──same JWT──▶ Postgres (RLS enforced)
API ──service role──▶ nav_cache, quote_cache, sip scheduler only
```

## API surface

```
POST   /v1/rows/:table                       create
GET    /v1/rows/:table?from&to&order         list (date filter, ordering)
PATCH  /v1/rows/:table/:id                   update
DELETE /v1/rows/:table/:id                   delete + cascade children

POST   /v1/rows/:table/:id/actions/increment   { amount, account? }
POST   /v1/rows/:table/:id/actions/set         { value }
POST   /v1/rows/:table/:id/actions/payment     { amount, account?, dueDate? }
POST   /v1/rows/:table/:id/actions/settle      { account? }
POST   /v1/rows/:table/:id/actions/reopen
POST   /v1/rows/:table/:id/actions/redeem      { units | amount, account }
GET    /v1/rows/:table/:id/payments

GET    /v1/dashboard/overview                  home screen figures
GET    /v1/dashboard/:table?from&to            module dashboard + chart series
GET    /v1/accounts                            balances + metrics
GET    /v1/alerts                              evaluated alert list
GET    /v1/events?table&from&to                module event log

GET    /v1/quotes?symbols=RELIANCE.NS,bitcoin  cached market prices
GET    /v1/funds/search?q=                     AMFI scheme search
GET    /v1/nav/:schemeCode?from                NAV history (shared cache)

POST   /v1/sip/:id/amount                      change SIP amount / step-up
POST   /v1/sip/:id/lumpsum                     { amount, date }
POST   /v1/sip/:id/installments/:seq/confirm
POST   /v1/sip/:id/installments/:seq/skip

POST   /v1/ask                                 { question } → answer + figures
GET    /v1/export/:table.csv?from&to
GET    /v1/export/:table.pdf?from&to
```

## Package mapping

| Flutter | Shared | Web | Mobile | API |
|---|---|---|---|---|
| `flutter_riverpod` | `@tanstack/react-query` (client + keys) | `zustand` | `zustand` | — |
| `supabase_flutter` | — | `@supabase/supabase-js` (auth) | `@supabase/supabase-js` (auth) | `@supabase/supabase-js` (per-request) |
| `flutter_secure_storage` | — | WebCrypto + `localStorage` | `expo-secure-store` | — |
| `crypto` (PIN sha256) | — | `crypto.subtle` | `expo-crypto` | — |
| `http` | `fetch` wrapper | — | — | `undici` |
| `intl` | `Intl.NumberFormat` + `date-fns` | — | — | — |
| `fl_chart` | `d3-scale` / `d3-shape` (geometry) | `<svg>` | `react-native-svg` | — |
| `shared_preferences` | — | `localStorage` | `async-storage` | — |
| `pdf` / `printing` | — | download link | `expo-sharing` | `pdfkit` |
| Material 3 widgets | design tokens | CSS modules | `StyleSheet` | — |
| `Navigator` | — | `react-router` | `expo-router` | — |
| — | — | — | — | `fastify`, `zod`, `jose`, `node-cron` |

**On charts:** only three shapes exist (`ChartKind`: line, dual-line, bars) plus
progress bars. Sharing the geometry and rendering four small SVG components per
app beats a charting library that would need Skia on native and a different
library on web.

**On the PIN on web:** a browser PIN is a UX lock, not a security boundary —
anything the page can read, a determined user can read. The Flutter web build
has exactly this property today. The real boundary is the Supabase session and
RLS; the PIN only guards a left-open tab.

## Folder structure

```
accounts_ts/
├── apps/
│   ├── api/                                # Node + Fastify + TypeScript
│   │   ├── src/
│   │   │   ├── server.ts                   # fastify instance, plugins, listen
│   │   │   ├── env.ts                      # Zod-validated process.env
│   │   │   ├── auth/
│   │   │   │   ├── verifyJwt.ts            # jose + Supabase JWKS
│   │   │   │   └── requestClient.ts        # per-request supabase-js (user JWT)
│   │   │   ├── db/
│   │   │   │   ├── repository.ts           # table CRUD, RLS-scoped
│   │   │   │   ├── transaction.ts          # multi-write atomicity
│   │   │   │   └── serviceClient.ts        # service role — cache + cron only
│   │   │   ├── routes/
│   │   │   │   ├── rows.ts      actions.ts    payments.ts
│   │   │   │   ├── dashboard.ts accounts.ts   alerts.ts   events.ts
│   │   │   │   ├── quotes.ts    funds.ts      nav.ts
│   │   │   │   └── sip.ts       ask.ts        export.ts
│   │   │   ├── domain/                     # the ported business rules
│   │   │   │   ├── increment.ts  setValue.ts  payment.ts
│   │   │   │   ├── settle.ts     redeem.ts    cascadeDelete.ts
│   │   │   │   ├── cashMovement.ts  moduleEvents.ts  interest.ts
│   │   │   │   └── validateWrite.ts        # EntityConfig-driven field checks
│   │   │   ├── quotes/  quoteService  cache  yahoo  mf  coingecko  sync
│   │   │   ├── nav/     navApi  navCache
│   │   │   ├── sip/     sipService  scheduler
│   │   │   ├── ask/     askService  askTools  llmClient
│   │   │   └── export/  csv.ts  pdf.ts
│   │   ├── test/                           # vitest + fastify.inject
│   │   └── Dockerfile  fly.toml  tsconfig.json
│   │
│   ├── web/                                # Vite + React SPA
│   │   ├── index.html
│   │   ├── src/
│   │   │   ├── main.tsx  App.tsx  router.tsx
│   │   │   ├── styles/
│   │   │   │   ├── tokens.css              # generated from packages/tokens
│   │   │   │   ├── base.css  reset.css
│   │   │   ├── routes/
│   │   │   │   ├── login.tsx  pin-setup.tsx  pin-lock.tsx
│   │   │   │   ├── dashboard.tsx           ← dashboard_screen.dart
│   │   │   │   ├── module.$table.tsx       ← EntityScreen, one route for all 9
│   │   │   │   ├── accounts.tsx  alerts.tsx  ask.tsx  profile.tsx
│   │   │   │   └── sip.$id.tsx
│   │   │   ├── components/
│   │   │   │   ├── AppCard  IconChip  MoneyText  SectionLabel
│   │   │   │   ├── MetricTile  ListRow  FilterChip
│   │   │   │   ├── Sheet  Dialog  SettingsRow  EmptyState
│   │   │   │   └── charts/ Series Line Dual Bar ProgressBars Empty
│   │   │   ├── features/
│   │   │   │   ├── entity/
│   │   │   │   │   ├── EntityScreen.tsx  EntityRow.tsx  RowMenu.tsx
│   │   │   │   │   ├── FilterBar.tsx  EntryForm.tsx
│   │   │   │   │   ├── fields/  Text Number Date Select FundSearch
│   │   │   │   │   ├── dialogs/ AddAmount Set Payment Settle Redeem Confirm
│   │   │   │   │   └── notices/ UnsavedHistory SipError StaleNav DueInstallment Price
│   │   │   │   ├── dashboard/  ModuleDashboard  Overview  Trends
│   │   │   │   ├── shell/      Sidebar  TopBar  ThemeToggle
│   │   │   │   ├── investments/ FundPicker  SipScreen
│   │   │   │   └── ask/        AskButton  AskPanel
│   │   │   └── lib/  auth.ts  pin.ts  download.ts
│   │   ├── public/  fonts/  icons/
│   │   ├── vite.config.ts  netlify.toml  _redirects
│   │   └── test/                           # vitest + Testing Library + MSW
│   │
│   └── mobile/                             # Expo, native only
│       ├── app/                            # expo-router: routes only, thin
│       │   ├── _layout.tsx                 # QueryClient, stores, theme, AuthGate
│       │   ├── (auth)/  login  pin-setup  pin-lock
│       │   └── (app)/
│       │       ├── _layout.tsx             ← home_shell.dart + app_drawer.dart
│       │       ├── index.tsx               ← dashboard_screen.dart
│       │       ├── m/[module].tsx          ← EntityScreen, one route for all 9
│       │       ├── accounts.tsx  alerts.tsx  ask.tsx  profile.tsx
│       │       └── sip/[id].tsx
│       ├── src/
│       │   ├── theme/   styles.ts  ThemeProvider.tsx  icons.ts
│       │   ├── components/                 # same names as web, RN primitives
│       │   ├── features/                   # same structure as web
│       │   └── lib/  auth.ts  pin.ts  share.ts
│       ├── assets/fonts/  (Inter, SourceSerif4 — copied)
│       ├── assets/icon/   (logo.png — copied)
│       ├── app.config.ts  eas.json  jest.config.js
│       └── __tests__/
│
├── packages/
│   ├── shared/                             # specs + pure math. No React.
│   │   └── src/
│   │       ├── models/   fieldSpec  dashboardSpec  entityConfig
│   │       ├── registry/ income expenses savings investment debtors
│   │       │             creditors bills loans transfers  index
│   │       ├── math/     financeMath  sipMath  moduleMetrics
│   │       ├── events/   moduleEvent
│   │       ├── format/   money  dates  quantity
│   │       └── types.ts                    # Json, Row, API request/response
│   ├── api-client/                         # typed fetch + query keys
│   │   └── src/  client  rows  actions  dashboard  quotes  sip  ask  export
│   ├── logic/                              # headless React. No DOM, no RN.
│   │   └── src/
│   │       ├── useEntityList  useEntryForm  useRowActions  useDateRange
│   │       ├── useModuleDashboard  useOverview  useAccounts  useAlerts
│   │       ├── useSip  useFundSearch  useAsk  useAuth
│   │       └── charts/  scales  linePath  barLayout  ticks
│   ├── tokens/                             # one source, three outputs
│   │   └── src/  colors  radii  spacing  type  tone
│   │       └── build/  tokens.css  tokens.native.ts
│   └── tsconfig/                           # shared base configs + eslint
│
├── supabase/                               # copied — single source of truth
├── docker-compose.yml                      # api + local postgres for dev
├── pnpm-workspace.yaml  package.json  turbo.json
└── README.md
```

## One structural change to `EntityScreen`

It is not ported as one file anywhere. Its 20 action methods split three ways:

- **The money logic leaves the client entirely** — `_payAmount`, `_addAmount`,
  `_setValue`, `_redeem`, `_markSettled`, `_delete` become
  `apps/api/src/domain/*.ts`, each a pure function over `(row, config, input)`
  returning the writes to perform, testable without a server or a screen.
- **The orchestration becomes a shared hook** — `useRowActions` in
  `packages/logic` decides which actions a row offers (from its `EntityConfig`),
  collects input, posts, and invalidates. Written once for both frontends.
- **Only the dialogs and the list rendering are per-app.** `EntityScreen.tsx`
  lands around 150 lines in each frontend.

## Phased plan

Each phase ends green: `pnpm test` passes, API boots, web builds, mobile runs.

| # | Phase | Delivers | Gate |
|---|---|---|---|
| 0 | Monorepo scaffold | pnpm workspaces, turbo, TS configs, lint, vitest/Jest/RNTL, docker-compose | three apps boot empty; CI runs |
| 1 | `shared` — specs | `fieldSpec`, `dashboardSpec`, `entityConfig`, all 9 registry entries | equivalence test vs the Dart registry, field for field |
| 2 | `shared` — math | `financeMath`, `sipMath`, `moduleEvent`, `moduleMetrics`, formatters | ports `sip_math_test`, `module_event_test`, `module_metrics_test` |
| 3 | `tokens` | colours, radii, spacing, type scale → `tokens.css` + `tokens.native.ts` | contrast tests reproduce the ratios asserted in `UI_REDESIGN.md` §2 |
| 4 | API foundation | Fastify, env, JWT verify, per-request RLS client, `/v1/rows/*` CRUD | `fastify.inject` tests; a cross-user test proves RLS holds |
| 5 | API domain actions | increment, set, payment (+interest), settle, reopen, redeem, cascade delete, cash movements, events — all transactional | ports `savings_withdraw`, `cascade_delete`, `module_events_e2e`, `redemption` |
| 6 | `api-client` + `logic` | typed client, query keys, `useEntityList`, `useEntryForm`, `useRowActions`, `useDateRange` | hooks tested headlessly with MSW; ports `date_filter` |
| 7 | Web shell + auth | Vite app, router, sign-in, PIN, sidebar, theme | real sign-in end to end against the API |
| 8 | Web entity screen | list, row, row menu, entry form, all field types, filter bar, action dialogs | ports `accounts_e2e` against the live API |
| 9 | Mobile shell + auth | Expo router, sign-in, PIN, drawer, theme | ports `auth_email_redirect_test`; real sign-in on device |
| 10 | Mobile entity screen | same surface, RN primitives, same `logic` hooks | ports `accounts_e2e` on device |
| 11 | Dashboards | API `/dashboard/*`, `/accounts`, `/alerts`; chart geometry in `logic`; both frontends render | ports `module_dashboard`, `dashboard_trends`, `alert_engine`, `expense_breakdown` |
| 12 | Market data | quote sources + server cache, NAV cache, fund search, investment sync | ports `quote_sources`, `nav_cache`, `investment_sync`, `investment_*` |
| 13 | SIP engine | `sipService`, installment ledger, scheduler, SIP screen + fund picker on both | ports the 9 sip tests |
| 14 | Ask | `askTools`, prompt, `llmClient`, `/v1/ask`, Ask UI on both | ports `ask_service`, `ask_tools`, `ask_prompt`, `ask_routing_accuracy` |
| 15 | Export & settings | CSV + PDF on the API, download on web, `expo-sharing` on mobile, profile, theme switch | manual export verified on all three |
| 16 | Deploy | API on Fly.io, web on Netlify (proxying `/api`), EAS build profiles, icons/splash | signed iOS/Android builds; web live; API health-checked |

Parallelism: phases 1–3 unblock everything. Phases 4–5 (API) run alongside 3.
Phases 7–8 (web) and 9–10 (mobile) are independent of each other once 6 lands —
two people can take one frontend each. Phase 8 is the largest single phase; 10
is materially cheaper because it reuses every hook 8 proved.

## Testing

The 45 Dart test files are the port's specification, not an afterthought.

- **`shared`** (`sip_math`, `finance_math`, `module_event`, `module_metrics`,
  `ask_*`) — port to vitest nearly line for line. Written **before** the
  implementation in each phase.
- **`logic`** — headless hook tests with `@testing-library/react` and MSW.
  These carry the screen behaviour for *both* frontends, so they are where the
  Flutter widget tests' assertions mostly land.
- **`api`** — `fastify.inject` integration tests against a local Postgres
  running the real `supabase/migrations`, including an explicit cross-user test
  proving user A cannot read user B's rows through any route.
- **`web` / `mobile`** — thin rendering tests only (Testing Library / RNTL).
  If a test in either app is asserting a *rule*, it belongs in `logic`.
- **E2E** (`accounts_e2e`, `investment_journey_e2e`, `module_events_e2e`) —
  against the real API on a seeded test database.

[`test/support.dart`](../../../test/support.dart) is the single highest-value
file to port early — it defines how every other test builds an app under test.

## Deployment

| App | Target | Notes |
|---|---|---|
| `api` | Fly.io (Docker) | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_KEY`, `GROQ_API_KEY` as secrets |
| `web` | Netlify, static SPA | `_redirects`: `/api/*` → the Fly app, `/*` → `index.html`. Replaces the current Flutter web deploy only when you choose to cut over. |
| `mobile` | EAS Build → App Store / Play | absolute `EXPO_PUBLIC_API_URL`; no relative `/api` off-web |

The existing `netlify/functions/ask-llm.mjs` is retired — its job moves into
`POST /v1/ask`, where the key is already server-side.

## Risks

- **You now own authorization.** RLS underneath is the backstop, but "a handler
  forgot to scope a query" is a bug class that does not exist today. Mitigation:
  the per-request client is the *only* path to user tables, and the service-role
  client lives in a module route handlers cannot import — enforced by an eslint
  `no-restricted-imports` rule.
- **Three apps drift.** The mitigation is structural, not disciplinary: rules
  live in `shared` and `logic`, and a rule asserted in a `web/` or `mobile/`
  test is a review failure. If the two frontends ever disagree about behaviour,
  something was implemented in the wrong package.
- **Two clients on one database** (this stack and Flutter). Any future schema
  change needs both updated together. `supabase/` stays the single source.
- **Offline dies.** The Flutter app degrades to on-device storage when Supabase
  is absent. Phase 6 ships TanStack Query persistence so *reads* work offline;
  writes require the API.
- **Spec transcription errors are silent.** A mistyped `hiddenWhenFilled` gives
  working UI with wrong data. The phase 1 equivalence test is the mitigation.
- **PDF output differs.** `pdfkit` will not be pixel-identical to Dart's `pdf`.
  Accepted — content parity only.
- **Effort.** A rewrite of 14.6k lines plus ~6k lines of tests, across three
  runtimes. Larger than a single app, and correspondingly better factored.
  Not a weekend.

## Out of scope

- Migrating or retiring the Flutter app.
- Any schema, RLS, or migration change.
- New features. Parity first.
- Server-side rendering, SEO, or public pages on web.
- Multi-user or shared accounts. Still one user, one dataset.
