# Foundation: monorepo, `packages/shared`, `packages/tokens` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `accounts_ts` monorepo and build the two dependency-free packages every other app needs — `packages/shared` (entity specs, the 9 module configs, money/SIP math, module events, formatters) and `packages/tokens` (design tokens for web and native).

**Architecture:** A npm-workspaces monorepo. `packages/shared` is plain TypeScript with zero runtime dependencies beyond `date-fns` — no React, no Fastify, no database — so the API and both frontends can import it. Every value is transcribed from the Flutter source and pinned by a test ported from the corresponding Dart test.

**Tech Stack:** TypeScript 5.7 (strict), npm workspaces, vitest, tsx, `date-fns`. Node 24.

## Global Constraints

- Node ≥ 22. Verified here on v24.18.0, npm 11.16.0.
- **npm workspaces, not pnpm** — pnpm is not installed on this machine. The spec says pnpm; this is the one deviation. Layout is identical.
- `packages/shared` must have **no dependency on React, React Native, Fastify, or any database client**. Enforced by review, and by the fact that nothing else is installed in it.
- TypeScript `strict: true`, `noUncheckedIndexedAccess: true`. Money bugs hide in `undefined`.
- All money is a `number` of rupees. Currency symbol is `₹` (`AppConfig.currencySymbol`).
- Dates crossing the wire are `yyyy-MM-dd` strings, matching Postgres `date` columns.
- Source of truth for every transcribed value is the Flutter repo at
  `/home/stacx-24/gn/accounts_management`. Exact file and line ranges are given per task.
- Commit after every task. Conventional-commit prefixes (`feat:`, `test:`, `chore:`).

---

### Task 1: Monorepo scaffold

**Files:**
- Create: `accounts_ts/package.json`
- Create: `accounts_ts/tsconfig.base.json`
- Create: `accounts_ts/.gitignore`
- Create: `accounts_ts/packages/shared/package.json`
- Create: `accounts_ts/packages/shared/tsconfig.json`
- Create: `accounts_ts/packages/shared/vitest.config.ts`
- Create: `accounts_ts/packages/shared/src/index.ts`
- Test: `accounts_ts/packages/shared/test/smoke.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: workspace `@accounts/shared`, importable as `@accounts/shared` from any app; `npm test` at the root runs every workspace's tests.

- [ ] **Step 1: Create the workspace root**

`accounts_ts/package.json`:
```json
{
  "name": "accounts-ts",
  "private": true,
  "type": "module",
  "workspaces": ["packages/*", "apps/*"],
  "engines": { "node": ">=22" },
  "scripts": {
    "test": "npm run test --workspaces --if-present",
    "typecheck": "npm run typecheck --workspaces --if-present",
    "build": "npm run build --workspaces --if-present"
  },
  "devDependencies": {
    "typescript": "^5.7.2",
    "vitest": "^2.1.8"
  }
}
```

`accounts_ts/tsconfig.base.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "verbatimModuleSyntax": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true,
    "sourceMap": true
  }
}
```

`accounts_ts/.gitignore`:
```
node_modules/
dist/
*.tsbuildinfo
.env
.env.local
coverage/
```

- [ ] **Step 2: Create the shared package**

`accounts_ts/packages/shared/package.json`:
```json
{
  "name": "@accounts/shared",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": { ".": "./src/index.ts" },
  "scripts": {
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "date-fns": "^4.1.0"
  }
}
```

`accounts_ts/packages/shared/tsconfig.json`:
```json
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": { "rootDir": ".", "outDir": "dist" },
  "include": ["src", "test"]
}
```

`accounts_ts/packages/shared/vitest.config.ts`:
```ts
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: { include: ['test/**/*.test.ts'], environment: 'node' },
})
```

`accounts_ts/packages/shared/src/index.ts`:
```ts
export const packageName = '@accounts/shared'
```

- [ ] **Step 3: Write the smoke test**

`accounts_ts/packages/shared/test/smoke.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import { packageName } from '../src/index.js'

describe('workspace', () => {
  it('resolves the shared package', () => {
    expect(packageName).toBe('@accounts/shared')
  })
})
```

- [ ] **Step 4: Install and run**

Run:
```bash
cd /home/stacx-24/gn/accounts_ts && npm install && npm test
```
Expected: `1 passed` from `packages/shared`.

- [ ] **Step 5: Commit**

```bash
cd /home/stacx-24/gn/accounts_ts
git init -b main
git add -A
git commit -m "chore: scaffold accounts_ts monorepo with shared package"
```

---

### Task 2: Core types and formatters

Ports [`lib/core/formatters.dart`](../../../lib/core/formatters.dart) (56 lines) and the `Json` alias from `lib/data/finance_repository.dart`.

**Files:**
- Create: `packages/shared/src/types.ts`
- Create: `packages/shared/src/format/money.ts`
- Create: `packages/shared/src/format/dates.ts`
- Create: `packages/shared/src/format/quantity.ts`
- Modify: `packages/shared/src/index.ts`
- Test: `packages/shared/test/format.test.ts`

**Interfaces:**
- Consumes: Task 1's package.
- Produces:
  - `type Json = Record<string, unknown>`
  - `type Row = Json & { id: string }`
  - `money(value: number | null | undefined): string`
  - `prettyDate(iso: string | null | undefined): string`
  - `isoDate(d: Date): string`
  - `ago(t: Date, now?: Date): string`
  - `quantityText(q: number): string`
  - `num(v: unknown): number | null` — the single "read a numeric cell" helper every later task uses instead of casting.

- [ ] **Step 1: Write the failing test**

`packages/shared/test/format.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import { money, prettyDate, isoDate, ago, quantityText, num } from '../src/index.js'

describe('money', () => {
  it('uses Indian digit grouping', () => {
    expect(money(842600)).toBe('₹8,42,600')
  })
  it('omits paise for whole rupees', () => {
    expect(money(1000)).toBe('₹1,000')
  })
  it('shows paise only when present', () => {
    expect(money(1000.5)).toBe('₹1,000.50')
  })
  it('treats null as zero', () => {
    expect(money(null)).toBe('₹0')
  })
  it('keeps the sign on negatives', () => {
    expect(money(-250)).toBe('-₹250')
  })
})

describe('prettyDate', () => {
  it('formats an ISO date', () => {
    expect(prettyDate('2026-05-22')).toBe('22 May 2026')
  })
  it('returns empty for null or empty input', () => {
    expect(prettyDate(null)).toBe('')
    expect(prettyDate('')).toBe('')
  })
  it('returns the input unchanged when unparseable', () => {
    expect(prettyDate('not-a-date')).toBe('not-a-date')
  })
})

describe('isoDate', () => {
  it('formats yyyy-MM-dd in local time', () => {
    expect(isoDate(new Date(2026, 7, 16))).toBe('2026-08-16')
  })
})

describe('ago', () => {
  const now = new Date(2026, 7, 16, 12, 0, 0)
  const minus = (ms: number) => new Date(now.getTime() - ms)

  it('reads "just now" under 90 seconds', () => {
    expect(ago(minus(89_000), now)).toBe('just now')
  })
  it('reads minutes under an hour', () => {
    expect(ago(minus(5 * 60_000), now)).toBe('5m ago')
  })
  it('reads hours under a day', () => {
    expect(ago(minus(2 * 3_600_000), now)).toBe('2h ago')
  })
  it('reads days up to a week', () => {
    expect(ago(minus(3 * 86_400_000), now)).toBe('3d ago')
  })
  it('falls back to a plain date beyond a week', () => {
    expect(ago(minus(9 * 86_400_000), now)).toBe('7 Aug')
  })
})

describe('quantityText', () => {
  it('drops the decimal for whole units', () => {
    expect(quantityText(12)).toBe('12')
  })
  it('keeps three decimals', () => {
    expect(quantityText(2.61858342317984)).toBe('2.619')
  })
  it('trims trailing zeros', () => {
    expect(quantityText(2.5)).toBe('2.5')
  })
  it('keeps small fractions', () => {
    expect(quantityText(0.35)).toBe('0.35')
  })
})

describe('num', () => {
  it('reads numbers', () => {
    expect(num(5)).toBe(5)
  })
  it('reads numeric strings, as Postgres numerics arrive', () => {
    expect(num('5.5')).toBe(5.5)
  })
  it('returns null for absent or non-numeric cells', () => {
    expect(num(null)).toBeNull()
    expect(num(undefined)).toBeNull()
    expect(num('abc')).toBeNull()
    expect(num('')).toBeNull()
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd /home/stacx-24/gn/accounts_ts/packages/shared && npx vitest run test/format.test.ts`
Expected: FAIL — `No matching export ... "money"`.

- [ ] **Step 3: Implement**

`packages/shared/src/types.ts`:
```ts
/** One database row, as every repository and spec function sees it. */
export type Json = Record<string, unknown>

/** A persisted row. Anything that came back from the database has an id. */
export type Row = Json & { id: string }

/**
 * Read a numeric cell.
 *
 * Postgres `numeric` columns arrive over PostgREST as strings, and an absent
 * column arrives as `undefined`. Every call site would otherwise repeat the
 * same three-way check, and the one that forgets is a silent zero in a total.
 */
export function num(v: unknown): number | null {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v)
    return Number.isFinite(n) ? n : null
  }
  return null
}

/** `num`, defaulted. For sums, where an absent cell contributes nothing. */
export const numOr = (v: unknown, fallback = 0): number => num(v) ?? fallback
```

`packages/shared/src/format/money.ts`:
```ts
/** Single-currency app — the symbol used across all money formatting. */
export const CURRENCY_SYMBOL = '₹'

const grouped = new Intl.NumberFormat('en-IN', {
  minimumFractionDigits: 0,
  maximumFractionDigits: 0,
})
const groupedPaise = new Intl.NumberFormat('en-IN', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

/**
 * Format a number as currency with Indian digit grouping, e.g. ₹8,42,600.
 *
 * Paise appear only when the amount actually has them — the figures in this
 * app are whole rupees, but a ledger must never silently round money away.
 *
 * The symbol is placed by hand rather than via `style: 'currency'` so a
 * negative reads `-₹250` (sign outside) rather than the locale's `-₹250` /
 * `(₹250)` variance across runtimes.
 */
export function money(value: number | null | undefined): string {
  const v = value ?? 0
  const whole = Number.isInteger(v)
  const body = (whole ? grouped : groupedPaise).format(Math.abs(v))
  return `${v < 0 ? '-' : ''}${CURRENCY_SYMBOL}${body}`
}
```

`packages/shared/src/format/dates.ts`:
```ts
import { format, isValid, parseISO } from 'date-fns'

/** Parse a yyyy-MM-dd (or ISO) string into a friendly date, e.g. 22 May 2026. */
export function prettyDate(iso: string | null | undefined): string {
  if (iso === null || iso === undefined || iso === '') return ''
  const d = parseISO(iso)
  if (!isValid(d)) return iso
  return format(d, 'd MMM yyyy')
}

/** yyyy-MM-dd, for sending dates to Postgres `date` columns. */
export function isoDate(d: Date): string {
  return format(d, 'yyyy-MM-dd')
}

/**
 * Compact age of a figure: "just now", "5m ago", "2h ago", "3d ago".
 *
 * For live prices, where how old a number is matters more than the clock time
 * it was taken at. Beyond a week it falls back to a plain date, because "9d
 * ago" is harder to place than "24 Jul".
 */
export function ago(t: Date, now: Date = new Date()): string {
  const ms = now.getTime() - t.getTime()
  const seconds = Math.floor(ms / 1000)
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)
  const days = Math.floor(hours / 24)

  if (seconds < 90) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  if (hours < 24) return `${hours}h ago`
  if (days <= 7) return `${days}d ago`
  return format(t, 'd MMM')
}
```

`packages/shared/src/format/quantity.ts`:
```ts
/**
 * A holding at a readable precision: 12, 0.35, 2.619.
 *
 * Units divide out of money and NAV, so they arrive with the full baggage of
 * binary floating point — 2.61858342317984 is not a figure anyone holds. Three
 * decimals is what fund houses themselves publish.
 */
export function quantityText(q: number): string {
  if (Number.isInteger(q)) return String(q)
  const fixed = q.toFixed(3)
  return fixed.includes('.')
    ? fixed.replace(/0+$/, '').replace(/\.$/, '')
    : fixed
}
```

`packages/shared/src/index.ts` (replace the placeholder):
```ts
export * from './types.js'
export * from './format/money.js'
export * from './format/dates.js'
export * from './format/quantity.js'
```

- [ ] **Step 4: Run the tests**

Run: `cd /home/stacx-24/gn/accounts_ts/packages/shared && npx vitest run test/format.test.ts`
Expected: PASS, 21 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/stacx-24/gn/accounts_ts
git add -A
git commit -m "feat(shared): port formatters and numeric cell readers"
```

---

### Task 3: Module events

Ports [`lib/data/module_event.dart`](../../../lib/data/module_event.dart) (135 lines). The ledger every dashboard chart reads.

**Files:**
- Create: `packages/shared/src/events/moduleEvent.ts`
- Modify: `packages/shared/src/index.ts`
- Test: `packages/shared/test/moduleEvent.test.ts`

**Interfaces:**
- Consumes: `Json`, `num`, `isoDate` from Task 2.
- Produces:
  - `const MODULE_EVENTS_TABLE = 'module_events'`
  - `type EventKind = 'open' | 'increment' | 'decrement' | 'set'`
  - `interface ModuleEvent { parentId, parentType, field, kind, amount, balanceAfter, date: Date, account?, note? }`
  - `moduleEventToRow(e: ModuleEvent): Json`
  - `Events.amount / balanceAfter / field / parentId / parentType / kind / date`
  - `Events.forField(events: Json[], parentType: string, field: string): Json[]`

- [ ] **Step 1: Write the failing test**

`packages/shared/test/moduleEvent.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import { Events, moduleEventToRow, MODULE_EVENTS_TABLE } from '../src/index.js'
import type { ModuleEvent } from '../src/index.js'

const base: ModuleEvent = {
  parentId: 'row-1',
  parentType: 'savings_goals',
  field: 'saved_amount',
  kind: 'increment',
  amount: 500,
  balanceAfter: 2500,
  date: new Date(2026, 4, 22),
}

describe('moduleEventToRow', () => {
  it('names the ledger table', () => {
    expect(MODULE_EVENTS_TABLE).toBe('module_events')
  })

  it('writes the storage shape', () => {
    expect(moduleEventToRow(base)).toEqual({
      parent_id: 'row-1',
      parent_type: 'savings_goals',
      field: 'saved_amount',
      kind: 'increment',
      amount: 500,
      balance_after: 2500,
      date: '2026-05-22',
    })
  })

  it('omits account and note when absent', () => {
    expect(moduleEventToRow(base)).not.toHaveProperty('account')
    expect(moduleEventToRow(base)).not.toHaveProperty('note')
  })

  it('includes account and note when given', () => {
    const row = moduleEventToRow({ ...base, account: 'HDFC', note: 'bonus' })
    expect(row.account).toBe('HDFC')
    expect(row.note).toBe('bonus')
  })
})

describe('Events readers', () => {
  it('reads numeric columns that arrive as strings', () => {
    expect(Events.amount({ amount: '500' })).toBe(500)
    expect(Events.balanceAfter({ balance_after: '2500' })).toBe(2500)
  })

  it('reads zero for absent numeric columns', () => {
    expect(Events.amount({})).toBe(0)
    expect(Events.balanceAfter({})).toBe(0)
  })

  it('reads string columns, empty when absent', () => {
    expect(Events.field({ field: 'saved_amount' })).toBe('saved_amount')
    expect(Events.parentType({})).toBe('')
  })

  it('parses a stored date', () => {
    expect(Events.date({ date: '2026-05-22' })?.getFullYear()).toBe(2026)
  })

  it('returns null for a missing or malformed date', () => {
    expect(Events.date({})).toBeNull()
    expect(Events.date({ date: 'nonsense' })).toBeNull()
  })
})

describe('Events.forField', () => {
  const events = [
    { parent_type: 'savings_goals', field: 'saved_amount', date: '2026-03-01', amount: 1 },
    { parent_type: 'savings_goals', field: 'saved_amount', date: '2026-01-01', amount: 2 },
    { parent_type: 'investments', field: 'saved_amount', date: '2026-02-01', amount: 3 },
    { parent_type: 'savings_goals', field: 'current_value', date: '2026-02-01', amount: 4 },
    { parent_type: 'savings_goals', field: 'saved_amount', amount: 5 },
  ]

  it('keeps only the named module and field', () => {
    const out = Events.forField(events, 'savings_goals', 'saved_amount')
    expect(out.map((e) => e.amount)).toEqual([2, 1])
  })

  it('drops undated rows rather than planting them at epoch', () => {
    const out = Events.forField(events, 'savings_goals', 'saved_amount')
    expect(out.some((e) => e.amount === 5)).toBe(false)
  })

  it('sorts oldest first', () => {
    const out = Events.forField(events, 'savings_goals', 'saved_amount')
    const dates = out.map((e) => Events.date(e)!.getTime())
    expect(dates).toEqual([...dates].sort((a, b) => a - b))
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest run test/moduleEvent.test.ts`
Expected: FAIL — no export `Events`.

- [ ] **Step 3: Implement**

`packages/shared/src/events/moduleEvent.ts`:
```ts
import { isValid, parseISO } from 'date-fns'
import { isoDate } from '../format/dates.js'
import { numOr, type Json } from '../types.js'

/** Table holding the ledger. Every module writes here. */
export const MODULE_EVENTS_TABLE = 'module_events'

/** What a {@link ModuleEvent} did to the field it names. */
export type EventKind =
  /** The row was created; `balanceAfter` is its opening value. */
  | 'open'
  /** A value was added (savings contribution, further investment). */
  | 'increment'
  /** A value was paid down (creditor payment, loan EMI). */
  | 'decrement'
  /** A value was overwritten wholesale (revaluation, settlement). */
  | 'set'

/**
 * One value-changing action on one row of one module.
 *
 * The app stores no history otherwise: "Add to savings" reads a column, adds
 * to it, and writes it straight back. Without this ledger a growth chart has
 * nothing to draw.
 */
export interface ModuleEvent {
  /** Id of the source row, and the table it lives in. */
  parentId: string
  parentType: string
  /** Which column moved — 'saved_amount', 'current_value', 'outstanding'. */
  field: string
  kind: EventKind
  /**
   * The delta. For kind 'set' this is the new value, since there is no
   * meaningful delta when a figure is replaced rather than adjusted.
   */
  amount: number
  /**
   * The field's value immediately after the action.
   *
   * This is the load-bearing column. A growth curve is read as a step function
   * through recorded balances, never re-derived forward from an opening figure
   * — forward derivation drifts the moment a row is edited by hand, and the
   * chart would then contradict the total printed above it.
   */
  balanceAfter: number
  date: Date
  /** The account the cash moved through, when the user chose one. */
  account?: string
  note?: string
}

export function moduleEventToRow(e: ModuleEvent): Json {
  return {
    parent_id: e.parentId,
    parent_type: e.parentType,
    field: e.field,
    kind: e.kind,
    amount: e.amount,
    balance_after: e.balanceAfter,
    date: isoDate(e.date),
    ...(e.account !== undefined ? { account: e.account } : {}),
    ...(e.note !== undefined ? { note: e.note } : {}),
  }
}

const str = (v: unknown): string => (v === null || v === undefined ? '' : String(v))

/**
 * Readers for stored event rows. The storage shape is described here and
 * nowhere else, so a column rename is a one-file change.
 */
export const Events = {
  amount: (e: Json): number => numOr(e.amount),
  balanceAfter: (e: Json): number => numOr(e.balance_after),
  field: (e: Json): string => str(e.field),
  parentId: (e: Json): string => str(e.parent_id),
  parentType: (e: Json): string => str(e.parent_type),
  kind: (e: Json): string => str(e.kind),

  /**
   * Parse the stored `yyyy-MM-dd`, or null when missing or malformed. Callers
   * skip null-dated events rather than counting them at epoch, which would
   * plant a spike at the left edge of every chart.
   */
  date(e: Json): Date | null {
    if (e.date === null || e.date === undefined) return null
    const d = parseISO(String(e.date))
    return isValid(d) ? d : null
  },

  /** Events for one module's field, oldest first, undated rows dropped. */
  forField(events: Json[], parentType: string, field: string): Json[] {
    return events
      .filter(
        (e) =>
          Events.parentType(e) === parentType &&
          Events.field(e) === field &&
          Events.date(e) !== null,
      )
      .sort((a, b) => Events.date(a)!.getTime() - Events.date(b)!.getTime())
  },
}
```

Append to `packages/shared/src/index.ts`:
```ts
export * from './events/moduleEvent.js'
```

- [ ] **Step 4: Run the tests**

Run: `npx vitest run test/moduleEvent.test.ts`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(shared): port the module event ledger"
```

---

### Task 4: Finance math

Ports [`lib/data/finance_math.dart`](../../../lib/data/finance_math.dart) (148 lines). Pinned by the Dart tests in `test/local_repository_test.dart` and `test/investment_value_fallback_test.dart`.

**Files:**
- Create: `packages/shared/src/math/financeMath.ts`
- Modify: `packages/shared/src/index.ts`
- Test: `packages/shared/test/financeMath.test.ts`

**Interfaces:**
- Consumes: `Json`, `num`, `numOr` from Task 2.
- Produces:
  - `investmentValue(row: Json): number`
  - `balanceMap(input: BalanceInput): Record<string, number>` where
    `BalanceInput = { accounts: Json[]; income: Json[]; expenses: Json[]; transfers: Json[]; cashMoves: Json[] }`
  - `accountsWithBalances(accounts: Json[], balances: Record<string, number>): Json[]`
  - `dashboardSnapshot(input: DashboardInput): DashboardSnapshot` — see the interface in Step 3; keys match the Dart map exactly.

- [ ] **Step 1: Write the failing test**

`packages/shared/test/financeMath.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import {
  investmentValue,
  balanceMap,
  accountsWithBalances,
  dashboardSnapshot,
} from '../src/index.js'

describe('investmentValue', () => {
  it('uses a stated current value', () => {
    expect(investmentValue({ current_value: 1200, invested_amount: 1000 })).toBe(1200)
  })

  it('respects a deliberate zero — a written-off holding is worth zero', () => {
    expect(investmentValue({ current_value: 0, invested_amount: 1000 })).toBe(0)
  })

  it('falls back to total_invested when no value is stated', () => {
    expect(investmentValue({ total_invested: 900, invested_amount: 800 })).toBe(900)
  })

  it('falls back to invested_amount for rows predating total_invested', () => {
    expect(investmentValue({ invested_amount: 800 })).toBe(800)
  })

  it('is zero when nothing is known', () => {
    expect(investmentValue({})).toBe(0)
  })
})

describe('balanceMap', () => {
  const accounts = [
    { name: 'HDFC', opening_balance: 1000 },
    { name: 'Cash', opening_balance: 500 },
  ]

  it('starts from the opening balance', () => {
    expect(balanceMap({ accounts, income: [], expenses: [], transfers: [], cashMoves: [] }))
      .toEqual({ HDFC: 1000, Cash: 500 })
  })

  it('adds income and subtracts expenses', () => {
    const b = balanceMap({
      accounts,
      income: [{ account: 'HDFC', amount: 200 }],
      expenses: [{ account: 'HDFC', amount: 50 }],
      transfers: [],
      cashMoves: [],
    })
    expect(b.HDFC).toBe(1150)
  })

  it('moves money between accounts on a transfer', () => {
    const b = balanceMap({
      accounts,
      income: [],
      expenses: [],
      transfers: [{ from: 'HDFC', to: 'Cash', amount: 300 }],
      cashMoves: [],
    })
    expect(b).toEqual({ HDFC: 700, Cash: 800 })
  })

  it('applies signed cash movements', () => {
    const b = balanceMap({
      accounts,
      income: [],
      expenses: [],
      transfers: [],
      cashMoves: [{ account: 'Cash', amount: -120 }, { account: 'Cash', amount: 20 }],
    })
    expect(b.Cash).toBe(400)
  })

  it('ignores movements naming an account that does not exist', () => {
    const b = balanceMap({
      accounts,
      income: [{ account: 'Ghost', amount: 999 }],
      expenses: [],
      transfers: [],
      cashMoves: [],
    })
    expect(b).toEqual({ HDFC: 1000, Cash: 500 })
  })
})

describe('accountsWithBalances', () => {
  it('adds a balance key without mutating the input', () => {
    const accounts = [{ name: 'HDFC', opening_balance: 1000 }]
    const out = accountsWithBalances(accounts, { HDFC: 1150 })
    expect(out[0]).toEqual({ name: 'HDFC', opening_balance: 1000, balance: 1150 })
    expect(accounts[0]).not.toHaveProperty('balance')
  })

  it('reads zero for an account with no computed balance', () => {
    expect(accountsWithBalances([{ name: 'New' }], {})[0]!.balance).toBe(0)
  })
})

describe('dashboardSnapshot', () => {
  const empty = {
    balances: {},
    income: [],
    expenses: [],
    investments: [],
    savingsGoals: [],
    debtors: [],
    creditors: [],
    loans: [],
    bills: [],
  }

  it('is all zeros with no data', () => {
    const d = dashboardSnapshot(empty)
    expect(d.net_worth).toBe(0)
    expect(d.current_worth).toBe(0)
  })

  it('sums net worth from cash, investments, savings and receivables', () => {
    const d = dashboardSnapshot({
      ...empty,
      balances: { HDFC: 1000 },
      investments: [{ current_value: 500 }],
      savingsGoals: [{ saved_amount: 200, target_amount: 1000 }],
      debtors: [{ amount: 300 }],
    })
    expect(d.net_worth).toBe(2000)
    expect(d.saving_target).toBe(1000)
  })

  it('subtracts creditors and active loans', () => {
    const d = dashboardSnapshot({
      ...empty,
      balances: { HDFC: 1000 },
      creditors: [{ amount: 400 }],
      loans: [{ status: 'active', outstanding: 100 }],
    })
    expect(d.net_worth).toBe(500)
  })

  it('excludes settled debts from what is owed', () => {
    const d = dashboardSnapshot({
      ...empty,
      debtors: [{ amount: 300, status: 'settled' }, { amount: 100, status: 'open' }],
      creditors: [{ amount: 999, status: 'settled' }],
    })
    expect(d.debt_worth).toBe(100)
    expect(d.credit_worth).toBe(0)
  })

  it('excludes closed loans', () => {
    const d = dashboardSnapshot({
      ...empty,
      loans: [{ status: 'closed', outstanding: 5000 }],
    })
    expect(d.loans_total).toBe(0)
  })

  it('folds bills into credit worth', () => {
    const d = dashboardSnapshot({ ...empty, bills: [{ amount: 250 }] })
    expect(d.bills_total).toBe(250)
    expect(d.credit_worth).toBe(250)
  })

  it('prefers total_invested and falls back to invested_amount', () => {
    const d = dashboardSnapshot({
      ...empty,
      investments: [
        { total_invested: 900, invested_amount: 100, current_value: 1000 },
        { invested_amount: 400, current_value: 450 },
      ],
    })
    expect(d.invested_total).toBe(1300)
    expect(d.investment_worth).toBe(1450)
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest run test/financeMath.test.ts`
Expected: FAIL — no export `investmentValue`.

- [ ] **Step 3: Implement**

`packages/shared/src/math/financeMath.ts`:
```ts
import { num, numOr, type Json } from '../types.js'

/**
 * What one investment row is worth.
 *
 * `current_value` when a figure has been stated — typed in, or written by the
 * live-price sync. Otherwise **what the holding cost**, because a row with no
 * stated value is not a row worth nothing. Two ways that legitimately happens:
 *
 *  - the row was added with only an invested amount (the field is optional);
 *  - a SIP was created today and the fund has not published a NAV to allot at
 *    yet, so it holds no units even though the money has left the account.
 *
 * Reading zero in either case understates the portfolio by the entire cost of
 * the holding, on the row and in net worth alike. A deliberate zero is left
 * alone: a written-off holding is worth zero and must stay so.
 */
export function investmentValue(row: Json): number {
  const stated = num(row.current_value)
  if (stated !== null) return stated
  return numOr(row.total_invested ?? row.invested_amount)
}

export interface BalanceInput {
  accounts: Json[]
  income: Json[]
  expenses: Json[]
  transfers: Json[]
  /** Signed movements: negative = money out, positive = money in. */
  cashMoves: Json[]
}

/**
 * Live balance per account name: opening balance plus every cash movement that
 * references the account (income +, expense −, transfers, payment moves).
 * Single source of truth for both the accounts list and net worth.
 */
export function balanceMap(input: BalanceInput): Record<string, number> {
  const balances: Record<string, number> = {}
  for (const a of input.accounts) {
    balances[String(a.name ?? '')] = numOr(a.opening_balance)
  }

  // A movement naming an account that no longer exists is dropped, not
  // created — otherwise deleting an account would resurrect it as a phantom
  // balance in net worth.
  const add = (name: unknown, delta: number): void => {
    if (name === null || name === undefined) return
    const key = String(name)
    if (!(key in balances)) return
    balances[key] = balances[key]! + delta
  }

  for (const r of input.income) add(r.account, numOr(r.amount))
  for (const r of input.expenses) add(r.account, -numOr(r.amount))
  for (const t of input.transfers) {
    add(t.from, -numOr(t.amount))
    add(t.to, numOr(t.amount))
  }
  for (const m of input.cashMoves) add(m.account, numOr(m.amount))

  return balances
}

/** Accounts with a computed `balance` key added to each row. */
export function accountsWithBalances(
  accounts: Json[],
  balances: Record<string, number>,
): Json[] {
  return accounts.map((a) => ({
    ...a,
    balance: balances[String(a.name ?? '')] ?? 0,
  }))
}

export interface DashboardInput {
  balances: Record<string, number>
  income: Json[]
  expenses: Json[]
  investments: Json[]
  savingsGoals: Json[]
  debtors: Json[]
  creditors: Json[]
  loans: Json[]
  bills: Json[]
}

export interface DashboardSnapshot {
  net_worth: number
  /** cash + all bank balances */
  current_worth: number
  /** owed to you (debtors / collections) */
  debt_worth: number
  /** you owe (creditors + bills) */
  credit_worth: number
  /** savings goals set aside */
  saving_worth: number
  /** combined goal targets */
  saving_target: number
  /** current value of holdings */
  investment_worth: number
  /** total amount put in */
  invested_total: number
  /** recurring bills, folded into credit_worth */
  bills_total: number
  /** subtracted by net_worth, so anything itemising that figure needs it */
  loans_total: number
  month_income: number
  month_expense: number
}

/** Single-row dashboard snapshot: net worth plus this period's income/expense. */
export function dashboardSnapshot(input: DashboardInput): DashboardSnapshot {
  const sum = (rows: Json[], key: string): number =>
    rows.reduce((a, r) => a + numOr(r[key]), 0)

  /** Settled debts are closed out — exclude them from what's owed. */
  const sumOwed = (rows: Json[]): number =>
    rows.filter((r) => r.status !== 'settled').reduce((a, r) => a + numOr(r.amount), 0)

  const accountsTotal = Object.values(input.balances).reduce((a, b) => a + b, 0)
  const investmentsTotal = input.investments.reduce((a, r) => a + investmentValue(r), 0)
  // `total_invested` is the running sum of every contribution (the investment
  // module's cumulativeIncrementField). Rows created before that column existed
  // fall back to `invested_amount`, which held the same figure.
  const investedTotal = input.investments.reduce(
    (a, r) => a + numOr(r.total_invested ?? r.invested_amount),
    0,
  )
  const savings = sum(input.savingsGoals, 'saved_amount')
  const savingsTarget = sum(input.savingsGoals, 'target_amount')
  const receivable = sumOwed(input.debtors)
  const payable = sumOwed(input.creditors)
  const billsTotal = sum(input.bills, 'amount')
  const loansTotal = input.loans
    .filter((r) => r.status === 'active')
    .reduce((a, r) => a + numOr(r.outstanding), 0)

  return {
    net_worth:
      accountsTotal + investmentsTotal + savings + receivable - payable - loansTotal,
    current_worth: accountsTotal,
    debt_worth: receivable,
    credit_worth: payable + billsTotal,
    saving_worth: savings,
    saving_target: savingsTarget,
    investment_worth: investmentsTotal,
    invested_total: investedTotal,
    bills_total: billsTotal,
    loans_total: loansTotal,
    month_income: sum(input.income, 'amount'),
    month_expense: sum(input.expenses, 'amount'),
  }
}
```

Append to `packages/shared/src/index.ts`:
```ts
export * from './math/financeMath.js'
```

- [ ] **Step 4: Run the tests**

Run: `npx vitest run test/financeMath.test.ts`
Expected: PASS, 19 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(shared): port finance math — balances, net worth, investment value"
```

---

### Task 5: Spec models

Ports [`lib/models/field_spec.ts`](../../../lib/models/field_spec.dart) (254 lines) and [`lib/models/dashboard_spec.dart`](../../../lib/models/dashboard_spec.dart) (171 lines). Types only, plus the constructor helpers the registry uses — no behaviour, so the test is a type/shape test.

**Files:**
- Create: `packages/shared/src/models/fieldSpec.ts`
- Create: `packages/shared/src/models/dashboardSpec.ts`
- Create: `packages/shared/src/models/entityConfig.ts`
- Modify: `packages/shared/src/index.ts`
- Test: `packages/shared/test/models.test.ts`

**Interfaces:**
- Consumes: `Json` from Task 2, `EventKind` from Task 3.
- Produces:
  - `type FieldType = 'text' | 'number' | 'date' | 'select' | 'fundSearch'`
  - `interface FieldSpec { key; label; type?; required?; options?; optionsTable?; hint?; dependsOn?; hints?; visibleWhen?; hiddenWhen?; hiddenWhenFilled?; section? }` — `visibleWhen`/`hiddenWhen` are `readonly string[]` (Dart uses `Set<String>`; an array keeps the config JSON-serialisable for the API).
  - `interface EntityConfig { … }` with every option from the Dart class, plus `icon: string` (a name, not a Flutter `IconData`) and `tone: ModuleTone`.
  - `type ModuleTone = 'income' | 'expense' | 'savings' | 'invest' | 'debtor' | 'creditor' | 'bills' | 'loan' | 'alerts'`
  - Stat builders: `statSum(field, label, opts?)`, `statOutstanding`, `statProgress`, `statRatio`, `statEventSum`, `statPaidDown`, `statCount`
  - Chart builders: `chartCumulative`, `chartDualCumulative`, `chartBars`
  - `breakdownByRow({ value, of? })`

- [ ] **Step 1: Write the failing test**

`packages/shared/test/models.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import {
  statSum,
  statCount,
  statProgress,
  statRatio,
  statEventSum,
  statPaidDown,
  statOutstanding,
  chartBars,
  chartCumulative,
  chartDualCumulative,
  breakdownByRow,
} from '../src/index.js'

describe('stat builders', () => {
  it('builds a sum with an optional fallback column', () => {
    expect(statSum('amount', 'Total')).toEqual({ kind: 'sum', label: 'Total', field: 'amount' })
    expect(statSum('total_invested', 'Invested', { fallback: 'invested_amount' }))
      .toEqual({
        kind: 'sum',
        label: 'Invested',
        field: 'total_invested',
        fallback: 'invested_amount',
      })
  })

  it('builds a count with no field', () => {
    expect(statCount('Entries')).toEqual({ kind: 'count', label: 'Entries' })
  })

  it('builds progress against a target column', () => {
    expect(statProgress('saved_amount', 'target_amount', 'Of target')).toEqual({
      kind: 'progress',
      label: 'Of target',
      field: 'saved_amount',
      against: 'target_amount',
    })
  })

  it('builds a ratio with an against-fallback', () => {
    expect(statRatio('current_value', 'total_invested', 'Return', {
      againstFallback: 'invested_amount',
    })).toEqual({
      kind: 'ratio',
      label: 'Return',
      field: 'current_value',
      against: 'total_invested',
      againstFallback: 'invested_amount',
    })
  })

  it('defaults an event sum to increments', () => {
    expect(statEventSum('saved_amount', 'Contributed')).toEqual({
      kind: 'eventSum',
      label: 'Contributed',
      field: 'saved_amount',
      eventKinds: ['increment'],
    })
  })

  it('takes explicit event kinds', () => {
    expect(statEventSum('saved_amount', 'Withdrawn', { kinds: ['decrement'] }).eventKinds)
      .toEqual(['decrement'])
  })

  it('builds outstanding and paidDown', () => {
    expect(statOutstanding('amount', 'Outstanding').kind).toBe('outstanding')
    expect(statPaidDown('amount', 'original_amount', 'Received')).toEqual({
      kind: 'paidDown',
      label: 'Received',
      field: 'amount',
      against: 'original_amount',
    })
  })
})

describe('chart builders', () => {
  it('builds bars', () => {
    expect(chartBars('amount', 'Income')).toEqual({
      kind: 'bars',
      label: 'Income',
      field: 'amount',
    })
  })

  it('builds a cumulative line', () => {
    expect(chartCumulative('saved_amount', 'Savings growth')).toEqual({
      kind: 'cumulative',
      label: 'Savings growth',
      field: 'saved_amount',
    })
  })

  it('builds a dual cumulative line with both series labelled', () => {
    expect(
      chartDualCumulative('invested_amount', 'current_value', {
        label: 'Invested vs value',
        firstLabel: 'Invested',
        secondLabel: 'Value',
      }),
    ).toEqual({
      kind: 'dualCumulative',
      label: 'Invested vs value',
      field: 'invested_amount',
      second: 'current_value',
      firstLabel: 'Invested',
      secondLabel: 'Value',
    })
  })
})

describe('breakdownByRow', () => {
  it('is proportional to the largest row when no target is given', () => {
    expect(breakdownByRow({ value: 'amount' })).toEqual({ value: 'amount' })
  })

  it('measures against a target column when given', () => {
    expect(breakdownByRow({ value: 'saved_amount', of: 'target_amount' })).toEqual({
      value: 'saved_amount',
      of: 'target_amount',
    })
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest run test/models.test.ts`
Expected: FAIL — no export `statSum`.

- [ ] **Step 3: Implement**

`packages/shared/src/models/fieldSpec.ts`:
```ts
export type FieldType =
  | 'text'
  | 'number'
  | 'date'
  | 'select'
  /**
   * Searchable mutual-fund picker. Writes three keys rather than one —
   * `scheme_code` (the field's own key), plus `scheme_name` and `fund_house`
   * captured at selection so the row can name its fund without a lookup.
   */
  | 'fundSearch'

/** Describes one editable field of an entity (drives the add form). */
export interface FieldSpec {
  key: string
  label: string
  type?: FieldType
  required?: boolean
  /** For type 'select' (static options). */
  options?: readonly string[]
  /**
   * For a dynamic select: load option labels from the `name` column of this
   * table (e.g. 'accounts'). Stored value is the chosen name.
   */
  optionsTable?: string
  /**
   * Helper text under the field. For inputs whose correct value isn't
   * guessable from the label alone — an AMFI scheme code, a CoinGecko id.
   */
  hint?: string
  /**
   * Key of another field in the same form whose value this one varies with.
   * An investment's symbol means something different for a stock than for a
   * mutual fund, and the form should say which is wanted before it's typed
   * wrong rather than reject it after.
   */
  dependsOn?: string
  /** `dependsOn` value → helper text, falling back to `hint`. */
  hints?: Readonly<Record<string, string>>
  /**
   * Show this field only while `dependsOn` holds one of these values.
   * Undefined means always visible. A hidden field is never saved, so
   * switching type can't leave a stale figure behind on the row.
   */
  visibleWhen?: readonly string[]
  /**
   * Hide this field while `dependsOn` holds one of these values — the
   * complement of `visibleWhen`, for a field that suits every case but one
   * (an amount typed by hand everywhere except where an engine derives it).
   */
  hiddenWhen?: readonly string[]
  /**
   * Hide this field once the named field has any value at all.
   *
   * For two fields that answer the same question different ways: a total
   * worth, or a quantity times a price. Asking for both invites them to
   * disagree, and then something has to silently win.
   */
  hiddenWhenFilled?: string
  /**
   * Heading shown above this field, starting a group. Repeat the same string
   * on consecutive fields to keep them under one heading.
   */
  section?: string
}
```

`packages/shared/src/models/dashboardSpec.ts`:
```ts
import type { EventKind } from '../events/moduleEvent.js'

/** How one headline figure on a module dashboard is computed. */
export type StatKind =
  /** Sum of a numeric column across every row. */
  | 'sum'
  /** Sum of a numeric column across rows whose `status` is not 'settled'. */
  | 'outstanding'
  /** field / against, as a percentage clamped to 0–100. */
  | 'progress'
  /** (field − against) / against, signed. Return on capital. */
  | 'ratio'
  /**
   * How much of an original balance has been cleared: against − field,
   * summed, floored at zero per row. Read from the rows, not the ledger, and
   * therefore exact for balances already part-paid before the ledger existed.
   */
  | 'paidDown'
  /** Sum of ledger event amounts for a field, inside the selected range. */
  | 'eventSum'
  /** Number of rows. */
  | 'count'

/** One figure in a module dashboard's stat row. */
export interface StatSpec {
  kind: StatKind
  label: string
  field?: string
  against?: string
  eventKinds?: readonly EventKind[]
  /**
   * Column read when `field` is absent on a row — for columns added after rows
   * already existed, such as `total_invested`, whose predecessor
   * `invested_amount` held the same figure.
   */
  fallback?: string
  /** Column read when `against` is absent on a row. */
  againstFallback?: string
}

export const statSum = (
  field: string,
  label: string,
  opts?: { fallback?: string },
): StatSpec => ({
  kind: 'sum',
  label,
  field,
  ...(opts?.fallback !== undefined ? { fallback: opts.fallback } : {}),
})

export const statOutstanding = (field: string, label: string): StatSpec => ({
  kind: 'outstanding',
  label,
  field,
})

export const statProgress = (field: string, against: string, label: string): StatSpec => ({
  kind: 'progress',
  label,
  field,
  against,
})

export const statRatio = (
  field: string,
  against: string,
  label: string,
  opts?: { againstFallback?: string },
): StatSpec => ({
  kind: 'ratio',
  label,
  field,
  against,
  ...(opts?.againstFallback !== undefined
    ? { againstFallback: opts.againstFallback }
    : {}),
})

export const statEventSum = (
  field: string,
  label: string,
  opts?: { kinds?: readonly EventKind[] },
): StatSpec => ({
  kind: 'eventSum',
  label,
  field,
  eventKinds: opts?.kinds ?? ['increment'],
})

/**
 * `field` is the balance still outstanding, `against` the amount originally
 * owed. Rows with no `against` column report nothing paid, which is right: a
 * debt that has never been paid against carries no original figure.
 */
export const statPaidDown = (field: string, against: string, label: string): StatSpec => ({
  kind: 'paidDown',
  label,
  field,
  against,
})

export const statCount = (label: string): StatSpec => ({ kind: 'count', label })

/** The shape a module's chart takes. */
export type ChartKind =
  /** Combined balance of one field over time, read from the ledger. */
  | 'cumulative'
  /** Two cumulative lines on shared axes (invested vs current value). */
  | 'dualCumulative'
  /**
   * Sum of a dated column per time bucket, read from the rows themselves —
   * for modules whose rows carry a `date`, which need no ledger.
   */
  | 'bars'

export interface ChartSpec {
  kind: ChartKind
  label: string
  field: string
  second?: string
  firstLabel?: string
  secondLabel?: string
}

export const chartCumulative = (field: string, label: string): ChartSpec => ({
  kind: 'cumulative',
  label,
  field,
})

export const chartDualCumulative = (
  field: string,
  second: string,
  opts: { label: string; firstLabel: string; secondLabel: string },
): ChartSpec => ({
  kind: 'dualCumulative',
  label: opts.label,
  field,
  second,
  firstLabel: opts.firstLabel,
  secondLabel: opts.secondLabel,
})

export const chartBars = (field: string, label: string): ChartSpec => ({
  kind: 'bars',
  label,
  field,
})

/** A per-row bar list under the chart — "Emergency fund, ₹1,20,000 · 60%". */
export interface BreakdownSpec {
  /** Column holding each row's magnitude. */
  value: string
  /**
   * Column holding the total that magnitude is measured against. When absent
   * the bars are proportional to the largest row instead of to a target.
   */
  of?: string
}

export const breakdownByRow = (spec: BreakdownSpec): BreakdownSpec => ({
  value: spec.value,
  ...(spec.of !== undefined ? { of: spec.of } : {}),
})

/**
 * Everything a module page's dashboard header shows. A module with no
 * `dashboard` renders no header, so this is purely additive.
 */
export interface DashboardSpec {
  stats: readonly StatSpec[]
  chart?: ChartSpec
  breakdown?: BreakdownSpec
}
```

`packages/shared/src/models/entityConfig.ts`:
```ts
import type { Json } from '../types.js'
import type { DashboardSpec } from './dashboardSpec.js'
import type { FieldSpec } from './fieldSpec.js'

/**
 * Per-module accent. Category colour survives the redesign only at icon-chip
 * size — the value itself is always the primary text colour. Direction of
 * money (positive/negative) is what keeps real colour.
 */
export type ModuleTone =
  | 'income'
  | 'expense'
  | 'savings'
  | 'invest'
  | 'debtor'
  | 'creditor'
  | 'bills'
  | 'loan'
  | 'alerts'

/**
 * Describes a whole entity screen: which table, how to render rows, and the
 * fields used to create a new one. Adding a new module = adding one of these.
 */
export interface EntityConfig {
  table: string
  title: string
  /**
   * Icon *name*, not a component. Each frontend resolves it — the backend
   * needs this config too, and it must not import a UI library to read it.
   */
  icon: string
  tone: ModuleTone
  fields: readonly FieldSpec[]
  titleOf: (r: Json) => string
  subtitleOf?: (r: Json) => string
  trailingOf?: (r: Json) => string
  readOnly?: boolean
  /** Defaults to 'created_at'. */
  orderBy?: string

  /**
   * If set, rows get an "add amount" action that increments this numeric
   * column by a user-entered value (e.g. savings contributions).
   */
  incrementField?: string
  /**
   * Optional second column that the same "add amount" also increments (e.g. an
   * investment contribution raises both invested and current value).
   */
  incrementAlsoField?: string
  incrementLabel?: string
  /**
   * A column tracking the running total of `incrementField`: seeded equal to it
   * when the row is created and grown by every "add amount" action. Maintained
   * automatically (not a typed form field), so it can't drift.
   */
  cumulativeIncrementField?: string

  /**
   * If set, rows get an action that OVERWRITES this numeric column with a
   * user-entered value. Unlike `incrementField` this replaces rather than adds.
   */
  setField?: string
  setLabel?: string

  /**
   * If set, rows get a "payment" action that REDUCES this numeric column by a
   * user-entered amount (e.g. paying down a creditor or loan balance).
   */
  decrementField?: string
  decrementLabel?: string
  /**
   * Verb on the dialog's confirm button. Defaults to "Pay", which is right for
   * a debt and wrong for a savings withdrawal — the same dialog serves both,
   * so the module says which word it wants.
   */
  decrementConfirm?: string

  /**
   * If set (with `decrementField`), one period of interest at this annual-%
   * column is accrued onto the balance before the payment is subtracted.
   */
  interestRateField?: string
  /**
   * If set, the "add payment" dialog shows a due-date picker (pre-filled from
   * this column) and writes the chosen date back to it.
   */
  dueDateField?: string
  /**
   * For the "add payment" action: true = money comes IN to the chosen account
   * (debtor repays you); false = money goes OUT (you pay a creditor/loan).
   */
  paymentInflow?: boolean
  /**
   * If true, the create form shows an optional account picker and records the
   * initial `amount` as a cash movement against that account: money OUT for
   * what you lent (debtors), money IN for what you borrowed (creditors).
   * Direction is the opposite of `paymentInflow`. Creation only — edits don't
   * re-post a movement, so balances aren't double-counted.
   */
  principalAccount?: boolean
  /**
   * If set, the create form shows an OPTIONAL "paid from account" picker. When
   * an account is chosen, the value in this numeric field is recorded as money
   * OUT of that account (e.g. cash spent to buy an investment). Creation only.
   */
  principalAccountField?: string

  /**
   * Status column (`open` / `partial` / `settled`) for settle-able modules.
   * When set, payments move the status automatically and the row menu gains
   * "Mark as settled" / "Reopen".
   */
  statusField?: string
  /**
   * Column holding the full original amount owed, captured at creation so the
   * row can show "paid X of Y" as the balance is paid down part by part.
   */
  originalAmountField?: string
  /**
   * Column recording the account that closed the debt — where the money was
   * received (debtor) or paid from (creditor).
   */
  settledAccountField?: string
  /**
   * If set, each payment is logged as a row here (a per-person installment
   * ledger). Rows are tagged with `parent_id` and `parent_type`.
   */
  paymentsTable?: string

  /** If true, the screen shows an export menu (CSV / PDF). */
  exportable?: boolean
  /**
   * If true, the screen shows a date-range filter row (Today/Week/Month/Year/
   * All/Custom). Filters and exports use the row's `date` field.
   */
  dateFiltered?: boolean
  /**
   * If true, rows carrying a symbol and a quantity are repriced from the market
   * when the screen opens and on pull-to-refresh. Rows without both are left
   * alone, so enabling this never disturbs a hand-kept module.
   */
  liveTracked?: boolean
  /**
   * If true, rows can be sold back: units come off the holding and the proceeds
   * land in a chosen account.
   */
  redeemable?: boolean
  /**
   * Tables holding child rows keyed by `parent_id` on this row. They are
   * deleted with it — an installment ledger whose parent is gone is
   * unreachable data that nothing will ever clean up.
   */
  cascadeTables?: readonly string[]
  /**
   * Extra keys written on creation only, derived from what was typed. For
   * values that are the app's business rather than the user's.
   */
  seedOnCreate?: (values: Json) => Json

  /**
   * Dashboard header shown above the list. Undefined means no header.
   *
   * The range chips appear whenever this is set *or* `dateFiltered` is — but
   * they only filter the list when `dateFiltered` is true. Savings goals, loans
   * and bills carry no `date` column, so filtering their rows by range would
   * blank the page; on those modules the range moves the dashboard alone.
   */
  dashboard?: DashboardSpec
}
```

Append to `packages/shared/src/index.ts`:
```ts
export * from './models/fieldSpec.js'
export * from './models/dashboardSpec.js'
export * from './models/entityConfig.js'
```

- [ ] **Step 4: Run the tests**

Run: `npx vitest run test/models.test.ts`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(shared): port field, dashboard and entity spec models"
```

---

### Task 6: Registry — the four simple modules

Transcribes `income`, `expenses`, `bills`, `transfers` from
[`lib/features/registry.dart`](../../../lib/features/registry.dart) lines 67–127, 421–447, 485–510.

**Files:**
- Create: `packages/shared/src/registry/income.ts`
- Create: `packages/shared/src/registry/expenses.ts`
- Create: `packages/shared/src/registry/bills.ts`
- Create: `packages/shared/src/registry/transfers.ts`
- Create: `packages/shared/src/registry/helpers.ts`
- Test: `packages/shared/test/registry.simple.test.ts`

**Interfaces:**
- Consumes: `EntityConfig`, stat/chart builders (Task 5), `money`/`prettyDate` (Task 2).
- Produces: `income`, `expenses`, `bills`, `transfers` — each `EntityConfig`.
  `helpers.ts` produces `joinParts(parts: (string | null | undefined)[], sep?: string): string`,
  used by every `subtitleOf` that drops empty segments before joining with ` · `.

- [ ] **Step 1: Write the failing test**

`packages/shared/test/registry.simple.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import { income, expenses, bills, transfers } from '../src/index.js'

describe('income', () => {
  it('targets the income table, ordered and filtered by date', () => {
    expect(income.table).toBe('income')
    expect(income.orderBy).toBe('date')
    expect(income.dateFiltered).toBe(true)
    expect(income.exportable).toBe(true)
  })

  it('asks for amount, source, account, note and date', () => {
    expect(income.fields.map((f) => f.key)).toEqual([
      'amount', 'source', 'account', 'note', 'date',
    ])
  })

  it('requires an amount and a date', () => {
    const required = income.fields.filter((f) => f.required).map((f) => f.key)
    expect(required).toEqual(['amount', 'date'])
  })

  it('loads account options from the accounts table', () => {
    const account = income.fields.find((f) => f.key === 'account')!
    expect(account.type).toBe('select')
    expect(account.optionsTable).toBe('accounts')
  })

  it('titles a row by its source, falling back to "Income"', () => {
    expect(income.titleOf({ source: 'Salary' })).toBe('Salary')
    expect(income.titleOf({})).toBe('Income')
  })

  it('subtitles with the date and account, dropping absent parts', () => {
    expect(income.subtitleOf!({ date: '2026-05-22', account: 'HDFC' }))
      .toBe('22 May 2026 · HDFC')
    expect(income.subtitleOf!({ date: '2026-05-22' })).toBe('22 May 2026')
  })

  it('trails the formatted amount', () => {
    expect(income.trailingOf!({ amount: 45000 })).toBe('₹45,000')
  })

  it('charts spending as bars with a total and a count', () => {
    expect(income.dashboard!.stats.map((s) => s.label)).toEqual(['Total', 'Entries'])
    expect(income.dashboard!.chart).toEqual({ kind: 'bars', label: 'Income', field: 'amount' })
  })
})

describe('expenses', () => {
  it('mirrors income but titles by payee and charts "Spending"', () => {
    expect(expenses.table).toBe('expenses')
    expect(expenses.titleOf({ payee: 'Airtel' })).toBe('Airtel')
    expect(expenses.titleOf({})).toBe('Expense')
    expect(expenses.dashboard!.chart!.label).toBe('Spending')
  })

  it('asks for amount, payee, account, note and date', () => {
    expect(expenses.fields.map((f) => f.key)).toEqual([
      'amount', 'payee', 'account', 'note', 'date',
    ])
  })
})

describe('bills', () => {
  it('has no chart — a bill is a template, not a balance', () => {
    expect(bills.dashboard!.chart).toBeUndefined()
    expect(bills.dashboard!.breakdown).toEqual({ value: 'amount' })
  })

  it('offers the four billing frequencies', () => {
    const freq = bills.fields.find((f) => f.key === 'frequency')!
    expect(freq.options).toEqual(['weekly', 'monthly', 'quarterly', 'yearly'])
  })

  it('subtitles with frequency, status and due day', () => {
    expect(bills.subtitleOf!({ frequency: 'monthly', status: 'paid', due_day: 5 }))
      .toBe('monthly · paid · day 5')
    expect(bills.subtitleOf!({ frequency: 'monthly' })).toBe('monthly · due · day -')
  })
})

describe('transfers', () => {
  it('requires both accounts and the amount', () => {
    const required = transfers.fields.filter((f) => f.required).map((f) => f.key)
    expect(required).toEqual(['from', 'to', 'amount'])
  })

  it('titles a row as from → to', () => {
    expect(transfers.titleOf({ from: 'HDFC', to: 'Cash' })).toBe('HDFC → Cash')
    expect(transfers.titleOf({})).toBe('? → ?')
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest run test/registry.simple.test.ts`
Expected: FAIL — no export `income`.

- [ ] **Step 3: Implement**

`packages/shared/src/registry/helpers.ts`:
```ts
/**
 * Join subtitle segments with ` · `, dropping the empty ones.
 *
 * Every module's subtitle is a list of optional parts; without this each one
 * grows its own filter, and the one that forgets renders a leading separator.
 */
export function joinParts(
  parts: readonly (string | null | undefined)[],
  sep = ' · ',
): string {
  return parts.filter((p): p is string => p !== null && p !== undefined && p !== '').join(sep)
}
```

`packages/shared/src/registry/income.ts`:
```ts
import { money } from '../format/money.js'
import { prettyDate } from '../format/dates.js'
import type { EntityConfig } from '../models/entityConfig.js'
import { chartBars, statCount, statSum } from '../models/dashboardSpec.js'
import { num } from '../types.js'
import { joinParts } from './helpers.js'

export const income: EntityConfig = {
  table: 'income',
  title: 'Income',
  icon: 'south_west',
  tone: 'income',
  orderBy: 'date',
  exportable: true,
  dateFiltered: true,
  fields: [
    { key: 'amount', label: 'Amount', type: 'number', required: true },
    { key: 'source', label: 'Source' },
    { key: 'account', label: 'Account (optional)', type: 'select', optionsTable: 'accounts' },
    { key: 'note', label: 'Note' },
    { key: 'date', label: 'Date', type: 'date', required: true },
  ],
  titleOf: (r) => String(r.source ?? 'Income'),
  subtitleOf: (r) =>
    joinParts([
      prettyDate(r.date === null || r.date === undefined ? null : String(r.date)),
      r.account === null || r.account === undefined ? null : String(r.account),
    ]),
  trailingOf: (r) => money(num(r.amount)),
  dashboard: {
    stats: [statSum('amount', 'Total'), statCount('Entries')],
    chart: chartBars('amount', 'Income'),
  },
}
```

`packages/shared/src/registry/expenses.ts`:
```ts
import { money } from '../format/money.js'
import { prettyDate } from '../format/dates.js'
import type { EntityConfig } from '../models/entityConfig.js'
import { chartBars, statCount, statSum } from '../models/dashboardSpec.js'
import { num } from '../types.js'
import { joinParts } from './helpers.js'

export const expenses: EntityConfig = {
  table: 'expenses',
  title: 'Expenses',
  icon: 'north_east',
  tone: 'expense',
  orderBy: 'date',
  exportable: true,
  dateFiltered: true,
  fields: [
    { key: 'amount', label: 'Amount', type: 'number', required: true },
    { key: 'payee', label: 'Payee' },
    { key: 'account', label: 'Account (optional)', type: 'select', optionsTable: 'accounts' },
    { key: 'note', label: 'Note' },
    { key: 'date', label: 'Date', type: 'date', required: true },
  ],
  titleOf: (r) => String(r.payee ?? 'Expense'),
  subtitleOf: (r) =>
    joinParts([
      prettyDate(r.date === null || r.date === undefined ? null : String(r.date)),
      r.account === null || r.account === undefined ? null : String(r.account),
    ]),
  trailingOf: (r) => money(num(r.amount)),
  dashboard: {
    stats: [statSum('amount', 'Total'), statCount('Entries')],
    chart: chartBars('amount', 'Spending'),
  },
}
```

`packages/shared/src/registry/bills.ts`:
```ts
import { money } from '../format/money.js'
import type { EntityConfig } from '../models/entityConfig.js'
import { breakdownByRow, statCount, statSum } from '../models/dashboardSpec.js'
import { num } from '../types.js'

export const bills: EntityConfig = {
  table: 'bills',
  title: 'Bill Payment',
  icon: 'receipt_long',
  tone: 'bills',
  fields: [
    { key: 'name', label: 'Bill name', required: true },
    { key: 'amount', label: 'Amount', type: 'number', required: true },
    { key: 'due_day', label: 'Due day (1–31)', type: 'number' },
    {
      key: 'frequency',
      label: 'Frequency',
      type: 'select',
      options: ['weekly', 'monthly', 'quarterly', 'yearly'],
    },
  ],
  titleOf: (r) => String(r.name ?? ''),
  subtitleOf: (r) =>
    `${String(r.frequency ?? '')} · ${String(r.status ?? 'due')} · day ${String(r.due_day ?? '-')}`,
  trailingOf: (r) => money(num(r.amount)),
  // No chart: a bill is a recurring template, not a balance, so nothing about
  // it moves over time. Figures and a breakdown are the honest maximum.
  dashboard: {
    stats: [statSum('amount', 'Commitment'), statCount('Bills')],
    breakdown: breakdownByRow({ value: 'amount' }),
  },
}
```

`packages/shared/src/registry/transfers.ts`:
```ts
import { money } from '../format/money.js'
import { prettyDate } from '../format/dates.js'
import type { EntityConfig } from '../models/entityConfig.js'
import { chartBars, statCount, statSum } from '../models/dashboardSpec.js'
import { num } from '../types.js'

export const transfers: EntityConfig = {
  table: 'transfers',
  title: 'Transfers',
  icon: 'swap_horiz',
  tone: 'debtor',
  orderBy: 'date',
  fields: [
    { key: 'from', label: 'From account', type: 'select', optionsTable: 'accounts', required: true },
    { key: 'to', label: 'To account', type: 'select', optionsTable: 'accounts', required: true },
    { key: 'amount', label: 'Amount', type: 'number', required: true },
    { key: 'date', label: 'Date', type: 'date' },
    { key: 'note', label: 'Note' },
  ],
  titleOf: (r) => `${String(r.from ?? '?')} → ${String(r.to ?? '?')}`,
  subtitleOf: (r) =>
    prettyDate(r.date === null || r.date === undefined ? null : String(r.date)),
  trailingOf: (r) => money(num(r.amount)),
  dashboard: {
    stats: [statSum('amount', 'Moved'), statCount('Transfers')],
    chart: chartBars('amount', 'Transfers'),
  },
}
```

Append to `packages/shared/src/index.ts`:
```ts
export * from './registry/helpers.js'
export { income } from './registry/income.js'
export { expenses } from './registry/expenses.js'
export { bills } from './registry/bills.js'
export { transfers } from './registry/transfers.js'
```

- [ ] **Step 4: Run the tests**

Run: `npx vitest run test/registry.simple.test.ts`
Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(shared): transcribe income, expenses, bills and transfers configs"
```

---

### Task 7: Registry — savings and loans

Transcribes `savings` (registry.dart:129–172) and `loans` (registry.dart:449–483). These are the first two with balance-moving actions.

**Files:**
- Create: `packages/shared/src/registry/savings.ts`
- Create: `packages/shared/src/registry/loans.ts`
- Test: `packages/shared/test/registry.balances.test.ts`

**Interfaces:**
- Consumes: everything from Task 5 and 6.
- Produces: `savings`, `loans` — each `EntityConfig`.

- [ ] **Step 1: Write the failing test**

`packages/shared/test/registry.balances.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import { savings, loans } from '../src/index.js'

describe('savings', () => {
  it('targets savings_goals', () => {
    expect(savings.table).toBe('savings_goals')
    expect(savings.dateFiltered).toBeUndefined()
  })

  it('can be both fed and spent from the same column', () => {
    expect(savings.incrementField).toBe('saved_amount')
    expect(savings.decrementField).toBe('saved_amount')
    expect(savings.incrementLabel).toBe('Add to savings')
    expect(savings.decrementLabel).toBe('Withdraw')
  })

  it('says "Withdraw" on the confirm button, not "Pay"', () => {
    expect(savings.decrementConfirm).toBe('Withdraw')
  })

  it('treats a withdrawal as money coming in to the account', () => {
    expect(savings.paymentInflow).toBe(true)
  })

  it('reports progress as a clamped percentage', () => {
    expect(savings.trailingOf!({ saved_amount: 600, target_amount: 1000 })).toBe('60%')
    expect(savings.trailingOf!({ saved_amount: 1500, target_amount: 1000 })).toBe('100%')
    expect(savings.trailingOf!({ saved_amount: 500, target_amount: 0 })).toBe('0%')
    expect(savings.trailingOf!({})).toBe('0%')
  })

  it('subtitles as saved of target', () => {
    expect(savings.subtitleOf!({ saved_amount: 2500, target_amount: 10000 }))
      .toBe('Saved ₹2,500 of ₹10,000')
  })

  it('separates contributed from withdrawn in the ledger stats', () => {
    const labels = savings.dashboard!.stats.map((s) => s.label)
    expect(labels).toEqual(['Saved', 'Target', 'Of target', 'Contributed', 'Withdrawn'])
    const withdrawn = savings.dashboard!.stats.find((s) => s.label === 'Withdrawn')!
    expect(withdrawn.eventKinds).toEqual(['decrement'])
  })

  it('breaks down each goal against its target', () => {
    expect(savings.dashboard!.breakdown).toEqual({
      value: 'saved_amount',
      of: 'target_amount',
    })
  })
})

describe('loans', () => {
  it('accrues interest before a payment is subtracted', () => {
    expect(loans.decrementField).toBe('outstanding')
    expect(loans.interestRateField).toBe('interest_rate')
  })

  it('does not treat a loan payment as money in', () => {
    expect(loans.paymentInflow).toBeUndefined()
  })

  it('offers only active and closed as statuses', () => {
    const status = loans.fields.find((f) => f.key === 'status')!
    expect(status.options).toEqual(['active', 'closed'])
  })

  it('titles by lender and subtitles with status and EMI', () => {
    expect(loans.titleOf({ lender: 'HDFC' })).toBe('HDFC')
    expect(loans.subtitleOf!({ status: 'active', emi: 12500 })).toBe('active · EMI ₹12,500')
    expect(loans.subtitleOf!({})).toBe('active · EMI ₹0')
  })

  it('measures paid-down against the original principal', () => {
    const paid = loans.dashboard!.stats.find((s) => s.label === 'Paid')!
    expect(paid).toEqual({
      kind: 'paidDown',
      label: 'Paid',
      field: 'outstanding',
      against: 'principal',
    })
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest run test/registry.balances.test.ts`
Expected: FAIL — no export `savings`.

- [ ] **Step 3: Implement**

`packages/shared/src/registry/savings.ts`:
```ts
import { money } from '../format/money.js'
import type { EntityConfig } from '../models/entityConfig.js'
import {
  breakdownByRow,
  chartCumulative,
  statEventSum,
  statProgress,
  statSum,
} from '../models/dashboardSpec.js'
import { num, numOr } from '../types.js'

export const savings: EntityConfig = {
  table: 'savings_goals',
  title: 'Savings',
  icon: 'savings',
  tone: 'savings',
  fields: [
    { key: 'name', label: 'Goal name', required: true },
    { key: 'target_amount', label: 'Target amount', type: 'number', required: true },
    { key: 'saved_amount', label: 'Saved so far', type: 'number' },
    { key: 'target_date', label: 'Target date', type: 'date' },
  ],
  incrementField: 'saved_amount',
  incrementLabel: 'Add to savings',
  // The way back out. Same machinery as a debtor repaying you: reduce the
  // balance, and the money lands IN the chosen account rather than leaving it.
  // Without this a goal could only ever be fed, never spent — which is not
  // what saving is for.
  decrementField: 'saved_amount',
  decrementLabel: 'Withdraw',
  decrementConfirm: 'Withdraw',
  paymentInflow: true,
  titleOf: (r) => String(r.name ?? ''),
  subtitleOf: (r) =>
    `Saved ${money(num(r.saved_amount))} of ${money(num(r.target_amount))}`,
  trailingOf: (r) => {
    const target = numOr(r.target_amount)
    const saved = numOr(r.saved_amount)
    const pct = target > 0 ? Math.min(100, Math.max(0, (saved / target) * 100)) : 0
    return `${pct.toFixed(0)}%`
  },
  dashboard: {
    stats: [
      statSum('saved_amount', 'Saved'),
      statSum('target_amount', 'Target'),
      statProgress('saved_amount', 'target_amount', 'Of target'),
      statEventSum('saved_amount', 'Contributed'),
      statEventSum('saved_amount', 'Withdrawn', { kinds: ['decrement'] }),
    ],
    chart: chartCumulative('saved_amount', 'Savings growth'),
    breakdown: breakdownByRow({ value: 'saved_amount', of: 'target_amount' }),
  },
}
```

`packages/shared/src/registry/loans.ts`:
```ts
import { money } from '../format/money.js'
import type { EntityConfig } from '../models/entityConfig.js'
import {
  breakdownByRow,
  chartCumulative,
  statPaidDown,
  statSum,
} from '../models/dashboardSpec.js'
import { num } from '../types.js'

export const loans: EntityConfig = {
  table: 'loans',
  title: 'Loan',
  icon: 'request_quote',
  tone: 'loan',
  fields: [
    { key: 'lender', label: 'Lender / Bank', required: true },
    { key: 'principal', label: 'Principal amount', type: 'number', required: true },
    { key: 'outstanding', label: 'Outstanding balance', type: 'number', required: true },
    { key: 'interest_rate', label: 'Interest rate (%)', type: 'number' },
    { key: 'emi', label: 'Monthly EMI', type: 'number' },
    { key: 'start_date', label: 'Start date', type: 'date' },
    { key: 'status', label: 'Status', type: 'select', options: ['active', 'closed'] },
    { key: 'note', label: 'Note' },
  ],
  decrementField: 'outstanding',
  decrementLabel: 'Add payment',
  interestRateField: 'interest_rate',
  titleOf: (r) => String(r.lender ?? ''),
  subtitleOf: (r) => `${String(r.status ?? 'active')} · EMI ${money(num(r.emi))}`,
  trailingOf: (r) => money(num(r.outstanding)),
  dashboard: {
    stats: [
      statSum('outstanding', 'Outstanding'),
      statSum('emi', 'Monthly EMI'),
      statPaidDown('outstanding', 'principal', 'Paid'),
    ],
    chart: chartCumulative('outstanding', 'Outstanding'),
    breakdown: breakdownByRow({ value: 'outstanding', of: 'principal' }),
  },
}
```

Append to `packages/shared/src/index.ts`:
```ts
export { savings } from './registry/savings.js'
export { loans } from './registry/loans.js'
```

- [ ] **Step 4: Run the tests**

Run: `npx vitest run test/registry.balances.test.ts`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(shared): transcribe savings and loans configs"
```

---

### Task 8: Registry — debtors and creditors

Transcribes `debtors` (registry.dart:345–383) and `creditors` (385–419), plus the shared `_settlementSubtitle` helper (registry.dart:45–61).

**Files:**
- Create: `packages/shared/src/registry/settlement.ts`
- Create: `packages/shared/src/registry/debtors.ts`
- Create: `packages/shared/src/registry/creditors.ts`
- Test: `packages/shared/test/registry.settlement.test.ts`

**Interfaces:**
- Consumes: Task 5–7.
- Produces:
  - `settlementSubtitle(opts: { received: boolean }): (r: Json) => string`
  - `debtors`, `creditors` — each `EntityConfig`.

- [ ] **Step 1: Write the failing test**

`packages/shared/test/registry.settlement.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import { debtors, creditors, settlementSubtitle } from '../src/index.js'

describe('settlementSubtitle', () => {
  const received = settlementSubtitle({ received: true })
  const paid = settlementSubtitle({ received: false })

  it('shows part-by-part progress while open', () => {
    expect(received({ status: 'partial', original_amount: 1000, amount: 400 }))
      .toBe('partial · paid ₹600 of ₹1,000')
  })

  it('includes the due date when set', () => {
    expect(received({ status: 'open', original_amount: 1000, amount: 1000, due_date: '2026-06-01' }))
      .toBe('open · paid ₹0 of ₹1,000 · due 1 Jun 2026')
  })

  it('defaults status to open', () => {
    expect(received({ original_amount: 500, amount: 500 })).toBe('open · paid ₹0 of ₹500')
  })

  it('falls back to amount when no original was captured', () => {
    expect(received({ status: 'open', amount: 750 })).toBe('open · paid ₹0 of ₹750')
  })

  it('names where the money was received once settled', () => {
    expect(received({ status: 'settled', settled_account: 'HDFC' }))
      .toBe('settled · received in HDFC')
  })

  it('names where the money was paid from once settled', () => {
    expect(paid({ status: 'settled', settled_account: 'HDFC' }))
      .toBe('settled · paid from HDFC')
  })

  it('says only "settled" when no account was recorded', () => {
    expect(received({ status: 'settled' })).toBe('settled')
  })
})

describe('debtors', () => {
  it('takes money out of your account when you lend', () => {
    expect(debtors.principalAccount).toBe(true)
    expect(debtors.paymentInflow).toBe(true)
  })

  it('tracks settlement state and an original amount', () => {
    expect(debtors.statusField).toBe('status')
    expect(debtors.originalAmountField).toBe('original_amount')
    expect(debtors.settledAccountField).toBe('settled_account')
  })

  it('logs payments to debt_payments and cascades them on delete', () => {
    expect(debtors.paymentsTable).toBe('debt_payments')
    expect(debtors.cascadeTables).toEqual(['debt_payments'])
  })

  it('does not require a due date', () => {
    expect(debtors.fields.find((f) => f.key === 'due_date')!.required).toBeUndefined()
  })

  it('reads received from the rows, not the ledger', () => {
    const stat = debtors.dashboard!.stats.find((s) => s.label === 'Received')!
    expect(stat.kind).toBe('paidDown')
  })
})

describe('creditors', () => {
  it('puts money into your account when you borrow', () => {
    expect(creditors.principalAccount).toBe(true)
    expect(creditors.paymentInflow).toBeUndefined()
  })

  it('requires a due date, unlike debtors', () => {
    expect(creditors.fields.find((f) => f.key === 'due_date')!.required).toBe(true)
  })

  it('labels the cleared figure "Paid"', () => {
    expect(creditors.dashboard!.stats.map((s) => s.label))
      .toEqual(['Outstanding', 'Paid', 'People'])
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest run test/registry.settlement.test.ts`
Expected: FAIL — no export `settlementSubtitle`.

- [ ] **Step 3: Implement**

`packages/shared/src/registry/settlement.ts`:
```ts
import { prettyDate } from '../format/dates.js'
import { money } from '../format/money.js'
import { num, numOr, type Json } from '../types.js'
import { joinParts } from './helpers.js'

/**
 * Subtitle for a settle-able debt row.
 *
 * While open/partial it shows how much has been paid down of the original
 * (part-by-part progress) plus the due date. Once settled it shows the account
 * the money was received in (debtor) or paid from (creditor), per `received`.
 */
export function settlementSubtitle(opts: { received: boolean }): (r: Json) => string {
  return (r) => {
    const status = String(r.status ?? 'open')
    if (status === 'settled') {
      const acct = String(r.settled_account ?? '')
      const where =
        acct === '' ? '' : opts.received ? `received in ${acct}` : `paid from ${acct}`
      return joinParts(['settled', where])
    }
    const original = num(r.original_amount) ?? numOr(r.amount)
    const remaining = numOr(r.amount)
    const due = prettyDate(
      r.due_date === null || r.due_date === undefined ? null : String(r.due_date),
    )
    const paid = `paid ${money(original - remaining)} of ${money(original)}`
    return joinParts([status, paid, due === '' ? '' : `due ${due}`])
  }
}
```

`packages/shared/src/registry/debtors.ts`:
```ts
import { money } from '../format/money.js'
import type { EntityConfig } from '../models/entityConfig.js'
import {
  breakdownByRow,
  chartCumulative,
  statCount,
  statOutstanding,
  statPaidDown,
} from '../models/dashboardSpec.js'
import { num } from '../types.js'
import { settlementSubtitle } from './settlement.js'

export const debtors: EntityConfig = {
  table: 'debtors',
  title: 'Debtors',
  icon: 'person_add_alt',
  tone: 'debtor',
  fields: [
    { key: 'person_name', label: 'Person', required: true },
    { key: 'contact', label: 'Contact' },
    { key: 'amount', label: 'Amount owed to you', type: 'number', required: true },
    { key: 'due_date', label: 'Due date', type: 'date' },
    { key: 'note', label: 'Note' },
  ],
  decrementField: 'amount',
  decrementLabel: 'Add payment',
  dueDateField: 'due_date',
  paymentInflow: true, // debtor repaying you = money in
  principalAccount: true, // lending them = money out of your account
  statusField: 'status',
  originalAmountField: 'original_amount',
  settledAccountField: 'settled_account',
  paymentsTable: 'debt_payments',
  cascadeTables: ['debt_payments'],
  titleOf: (r) => String(r.person_name ?? ''),
  subtitleOf: settlementSubtitle({ received: true }),
  trailingOf: (r) => money(num(r.amount)),
  dashboard: {
    stats: [
      statOutstanding('amount', 'Outstanding'),
      // Read from the rows, not the ledger: balances part-paid before the
      // ledger existed would otherwise report ₹0 beside a row that plainly
      // says money came in.
      statPaidDown('amount', 'original_amount', 'Received'),
      statCount('People'),
    ],
    chart: chartCumulative('amount', 'Owed to you'),
    breakdown: breakdownByRow({ value: 'amount' }),
  },
}
```

`packages/shared/src/registry/creditors.ts`:
```ts
import { money } from '../format/money.js'
import type { EntityConfig } from '../models/entityConfig.js'
import {
  breakdownByRow,
  chartCumulative,
  statCount,
  statOutstanding,
  statPaidDown,
} from '../models/dashboardSpec.js'
import { num } from '../types.js'
import { settlementSubtitle } from './settlement.js'

export const creditors: EntityConfig = {
  table: 'creditors',
  title: 'Creditors',
  icon: 'person_remove_alt_1',
  tone: 'creditor',
  fields: [
    { key: 'person_name', label: 'Person', required: true },
    { key: 'contact', label: 'Contact' },
    { key: 'amount', label: 'Amount you owe', type: 'number', required: true },
    { key: 'due_date', label: 'Due date', type: 'date', required: true },
    { key: 'note', label: 'Note' },
  ],
  decrementField: 'amount',
  decrementLabel: 'Add payment',
  dueDateField: 'due_date',
  principalAccount: true, // borrowing from them = money into your account
  statusField: 'status',
  originalAmountField: 'original_amount',
  settledAccountField: 'settled_account',
  paymentsTable: 'debt_payments',
  cascadeTables: ['debt_payments'],
  titleOf: (r) => String(r.person_name ?? ''),
  subtitleOf: settlementSubtitle({ received: false }),
  trailingOf: (r) => money(num(r.amount)),
  dashboard: {
    stats: [
      statOutstanding('amount', 'Outstanding'),
      statPaidDown('amount', 'original_amount', 'Paid'),
      statCount('People'),
    ],
    chart: chartCumulative('amount', 'You owe'),
    breakdown: breakdownByRow({ value: 'amount' }),
  },
}
```

Append to `packages/shared/src/index.ts`:
```ts
export * from './registry/settlement.js'
export { debtors } from './registry/debtors.js'
export { creditors } from './registry/creditors.js'
```

- [ ] **Step 4: Run the tests**

Run: `npx vitest run test/registry.settlement.test.ts`
Expected: PASS, 15 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(shared): transcribe debtors and creditors configs"
```

---

### Task 9: Registry — investment

Transcribes `investment` (registry.dart:174–343), its `_investmentSubtitle` (24–39), and the `_priceableTypes` / `_sipOnly` constants (13, 17). The largest config: 14 fields across three sections, with `visibleWhen` / `hiddenWhen` / `hiddenWhenFilled` conditionals.

**Files:**
- Create: `packages/shared/src/registry/investment.ts`
- Test: `packages/shared/test/registry.investment.test.ts`

**Interfaces:**
- Consumes: Task 5–8, plus `investmentValue` (Task 4), `quantityText`/`ago` (Task 2).
- Produces:
  - `const PRICEABLE_TYPES: readonly string[]` — `['stock','fund','mf','crypto','gold']`
  - `const SIP_ONLY: readonly string[]` — `['sip']`
  - `investmentSubtitle(r: Json, now?: Date): string`
  - `investment: EntityConfig`

- [ ] **Step 1: Write the failing test**

`packages/shared/test/registry.investment.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import { investment, investmentSubtitle, PRICEABLE_TYPES, SIP_ONLY } from '../src/index.js'

describe('investmentSubtitle', () => {
  const now = new Date(2026, 7, 16, 12, 0, 0)

  it('reports price, quantity and the age of that price for a live row', () => {
    const r = {
      type: 'stock',
      last_price: 1250,
      quantity: 10,
      price_at: new Date(2026, 7, 16, 10, 0, 0).toISOString(),
    }
    expect(investmentSubtitle(r, now)).toBe('stock · ₹1,250 × 10 · 2h ago')
  })

  it('omits the age when no timestamp was recorded', () => {
    expect(investmentSubtitle({ type: 'crypto', last_price: 100, quantity: 0.35 }, now))
      .toBe('crypto · ₹100 × 0.35')
  })

  it('falls back to total invested when there is no live price', () => {
    expect(investmentSubtitle({ type: 'fd', total_invested: 50000 }, now))
      .toBe('fd · total invested ₹50,000')
  })

  it('falls back to invested_amount for rows predating total_invested', () => {
    expect(investmentSubtitle({ type: 'fd', invested_amount: 20000 }, now))
      .toBe('fd · total invested ₹20,000')
  })

  it('ignores a zero quantity — that is not a priced holding', () => {
    expect(investmentSubtitle({ type: 'mf', last_price: 42, quantity: 0, total_invested: 500 }, now))
      .toBe('mf · total invested ₹500')
  })
})

describe('investment config', () => {
  it('is live-tracked, redeemable, and cascades its SIP ledger', () => {
    expect(investment.liveTracked).toBe(true)
    expect(investment.redeemable).toBe(true)
    expect(investment.cascadeTables).toEqual(['sip_installments'])
  })

  it('grows invested and current value together, and tracks the running total', () => {
    expect(investment.incrementField).toBe('invested_amount')
    expect(investment.incrementAlsoField).toBe('current_value')
    expect(investment.cumulativeIncrementField).toBe('total_invested')
  })

  it('debits an account for what was paid in', () => {
    expect(investment.principalAccountField).toBe('invested_amount')
  })

  it('offers eight investment types', () => {
    const type = investment.fields.find((f) => f.key === 'type')!
    expect(type.options).toEqual(['stock', 'fund', 'fd', 'mf', 'sip', 'crypto', 'gold', 'other'])
  })

  it('hides the money fields for a SIP — the engine owns them', () => {
    for (const key of ['invested_amount', 'current_value']) {
      const f = investment.fields.find((x) => x.key === key)!
      expect(f.dependsOn).toBe('type')
      expect(f.hiddenWhen).toEqual(SIP_ONLY)
    }
  })

  it('hides current value once a quantity is given', () => {
    expect(investment.fields.find((f) => f.key === 'current_value')!.hiddenWhenFilled)
      .toBe('quantity')
  })

  it('shows holding fields only for priceable types', () => {
    for (const key of ['quantity', 'market_price', 'symbol']) {
      expect(investment.fields.find((f) => f.key === key)!.visibleWhen).toEqual(PRICEABLE_TYPES)
    }
  })

  it('gives per-type hints for the symbol field', () => {
    const symbol = investment.fields.find((f) => f.key === 'symbol')!
    expect(symbol.hints!.mf).toBe('AMFI scheme code, e.g. 120503')
    expect(symbol.hints!.crypto).toBe('CoinGecko id, e.g. bitcoin or ethereum (not BTC)')
  })

  it('shows the schedule only for a SIP, and requires its three key fields', () => {
    const schedule = investment.fields.filter((f) => f.section === 'Schedule')
    expect(schedule.map((f) => f.key)).toEqual([
      'scheme_code', 'sip_amount', 'sip_frequency', 'sip_day', 'sip_account', 'sip_start_date',
    ])
    for (const f of schedule) expect(f.visibleWhen).toEqual(SIP_ONLY)
    expect(schedule.filter((f) => f.required).map((f) => f.key))
      .toEqual(['scheme_code', 'sip_amount', 'sip_start_date'])
  })

  it('searches AMFI for the fund', () => {
    expect(investment.fields.find((f) => f.key === 'scheme_code')!.type).toBe('fundSearch')
  })

  it('seeds a cash boundary only for a SIP', () => {
    expect(investment.seedOnCreate!({ type: 'stock' })).toEqual({})
    const seeded = investment.seedOnCreate!({ type: 'sip' })
    expect(seeded.sip_active).toBe(true)
    expect(String(seeded.cash_from)).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })

  it('trails the same figure net worth uses', () => {
    expect(investment.trailingOf!({ current_value: 1200 })).toBe('₹1,200')
    expect(investment.trailingOf!({ invested_amount: 800 })).toBe('₹800')
  })

  it('falls back to invested_amount in both invested stats', () => {
    const invested = investment.dashboard!.stats.find((s) => s.label === 'Invested')!
    expect(invested.fallback).toBe('invested_amount')
    const ret = investment.dashboard!.stats.find((s) => s.label === 'Return')!
    expect(ret.againstFallback).toBe('invested_amount')
  })

  it('charts invested against value on shared axes', () => {
    expect(investment.dashboard!.chart).toEqual({
      kind: 'dualCumulative',
      label: 'Invested vs value',
      field: 'invested_amount',
      second: 'current_value',
      firstLabel: 'Invested',
      secondLabel: 'Value',
    })
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest run test/registry.investment.test.ts`
Expected: FAIL — no export `investment`.

- [ ] **Step 3: Implement**

`packages/shared/src/registry/investment.ts`:
```ts
import { ago, isoDate } from '../format/dates.js'
import { money } from '../format/money.js'
import { quantityText } from '../format/quantity.js'
import { investmentValue } from '../math/financeMath.js'
import type { EntityConfig } from '../models/entityConfig.js'
import {
  breakdownByRow,
  chartDualCumulative,
  statEventSum,
  statRatio,
  statSum,
} from '../models/dashboardSpec.js'
import { num, numOr, type Json } from '../types.js'
import { joinParts } from './helpers.js'

/**
 * Investment types a price can be looked up for. Mirrors the keys of the quote
 * service's default sources — a type absent from both is simply manual.
 */
export const PRICEABLE_TYPES = ['stock', 'fund', 'mf', 'crypto', 'gold'] as const

/**
 * The SIP engine owns a `sip` row's symbol, units and invested total, so the
 * form neither asks for them nor lets them be edited.
 */
export const SIP_ONLY = ['sip'] as const

/**
 * Subtitle for an investment row.
 *
 * Live rows trade "total invested" for the unit price, the quantity it was
 * multiplied by, and the age of that price — a live figure with no visible age
 * is indistinguishable from a stale one. Everything else reads as before.
 */
export function investmentSubtitle(r: Json, now?: Date): string {
  const type = String(r.type ?? '')
  const price = num(r.last_price)
  const quantity = num(r.quantity)
  const rawAt = r.price_at
  const at =
    rawAt === null || rawAt === undefined ? null : new Date(String(rawAt))
  const validAt = at !== null && !Number.isNaN(at.getTime()) ? at : null

  if (price !== null && quantity !== null && quantity > 0) {
    return joinParts([
      type,
      `${money(price)} × ${quantityText(quantity)}`,
      validAt === null ? null : ago(validAt, now),
    ])
  }
  return `${type} · total invested ${money(numOr(r.total_invested ?? r.invested_amount))}`
}

export const investment: EntityConfig = {
  table: 'investments',
  title: 'Investment',
  icon: 'trending_up',
  tone: 'invest',
  fields: [
    { key: 'name', label: 'Name', required: true },
    {
      key: 'type',
      label: 'Type',
      type: 'select',
      options: ['stock', 'fund', 'fd', 'mf', 'sip', 'crypto', 'gold', 'other'],
    },
    // --- Money ---
    // A SIP derives both of these from its installment ledger, so it must not
    // offer them for typing — the engine would overwrite whatever went in,
    // which is worse than never asking.
    {
      key: 'invested_amount',
      label: 'Invested',
      type: 'number',
      required: true,
      section: 'Money',
      dependsOn: 'type',
      hiddenWhen: SIP_ONLY,
      hint: 'What you put in',
    },
    // Hidden once a quantity is given: the holding is then described as units
    // times a price, and asking for the total as well invites the two to
    // disagree.
    {
      key: 'current_value',
      label: 'Current value',
      type: 'number',
      section: 'Money',
      dependsOn: 'type',
      hiddenWhen: SIP_ONLY,
      hiddenWhenFilled: 'quantity',
      hint: 'What it is worth today — or fill in the holding below instead and let it be worked out',
    },
    // --- Holding: units, and where the price comes from ---
    {
      key: 'quantity',
      label: 'Quantity held',
      type: 'number',
      section: 'Holding',
      dependsOn: 'type',
      visibleWhen: PRICEABLE_TYPES,
      hint: 'Shares, units, coins or grams — the price is multiplied by this',
      hints: {
        stock: 'Number of shares',
        mf: 'Units held (not rupees)',
        fund: 'Units held (not rupees)',
        crypto: 'Coins held, e.g. 0.35',
        gold: 'Grams held',
      },
    },
    // A price you keep yourself, for holdings the app cannot or should not
    // fetch — an unlisted fund, or your jeweller's gold rate rather than
    // international spot. Overrides the symbol when both are present.
    {
      key: 'market_price',
      label: 'Current market price',
      type: 'number',
      section: 'Holding',
      dependsOn: 'type',
      visibleWhen: PRICEABLE_TYPES,
      hint: 'Price of one unit today — leave blank to fetch it live',
      hints: {
        stock: "Today's share price — leave blank to fetch it live",
        mf: "Today's NAV — leave blank to fetch it live",
        fund: "Today's NAV — leave blank to fetch it live",
        crypto: 'Price of one coin — leave blank to fetch it live',
        gold: 'Your rate per gram — overrides international spot',
      },
    },
    {
      key: 'symbol',
      label: 'Symbol (for live prices)',
      section: 'Holding',
      dependsOn: 'type',
      visibleWhen: PRICEABLE_TYPES,
      hint: 'Leave blank to keep updating this row by hand',
      hints: {
        stock: 'NSE ticker, e.g. RELIANCE — add .BO for a BSE listing',
        mf: 'AMFI scheme code, e.g. 120503',
        fund: 'AMFI scheme code, e.g. 120503',
        crypto: 'CoinGecko id, e.g. bitcoin or ethereum (not BTC)',
        gold: "Type 'gold' — priced per gram in INR",
      },
    },
    // --- SIP: the schedule, from which units and value are derived. ---
    {
      key: 'scheme_code',
      label: 'Fund',
      type: 'fundSearch',
      required: true,
      section: 'Schedule',
      dependsOn: 'type',
      visibleWhen: SIP_ONLY,
      hint: 'Search AMFI by name',
    },
    {
      key: 'sip_amount',
      label: 'Amount per installment',
      type: 'number',
      required: true,
      section: 'Schedule',
      dependsOn: 'type',
      visibleWhen: SIP_ONLY,
    },
    {
      key: 'sip_frequency',
      label: 'Frequency',
      type: 'select',
      options: ['monthly', 'weekly', 'quarterly'],
      section: 'Schedule',
      dependsOn: 'type',
      visibleWhen: SIP_ONLY,
    },
    {
      key: 'sip_day',
      label: 'Debit day',
      type: 'number',
      section: 'Schedule',
      dependsOn: 'type',
      visibleWhen: SIP_ONLY,
      hint: 'Day of the month (1–31); for weekly, 1 = Monday … 7 = Sunday',
    },
    // Which account the mandate draws from. With it set, each installment
    // debits the account as it falls due — the way the real mandate does. Left
    // blank, the app asks before moving money instead of guessing.
    {
      key: 'sip_account',
      label: 'Debit from account',
      type: 'select',
      optionsTable: 'accounts',
      section: 'Schedule',
      dependsOn: 'type',
      visibleWhen: SIP_ONLY,
      hint: 'Installments from today onward come out of this account',
    },
    {
      key: 'sip_start_date',
      label: 'First installment',
      type: 'date',
      required: true,
      section: 'Schedule',
      dependsOn: 'type',
      visibleWhen: SIP_ONLY,
      hint: 'Earlier installments are filled in automatically',
    },
  ],
  incrementField: 'invested_amount',
  incrementAlsoField: 'current_value',
  // Total amount invested = running sum of every contribution (seeded from the
  // first investment, grown by each "Add investment").
  cumulativeIncrementField: 'total_invested',
  incrementLabel: 'Add investment',
  setField: 'current_value',
  setLabel: 'Update current value',
  principalAccountField: 'invested_amount',
  liveTracked: true,
  redeemable: true,
  cascadeTables: ['sip_installments'],
  // A SIP's cash boundary: installments dated before the row was created are
  // history and post no cash movement, because those debits were already
  // recorded by hand. Everything from today onward asks first.
  seedOnCreate: (v) =>
    v.type !== 'sip' ? {} : { cash_from: isoDate(new Date()), sip_active: true },
  titleOf: (r) => String(r.name ?? ''),
  // A live row reports the price it was valued at and how fresh that is — the
  // figure on the right is only trustworthy if you can see its age. Rows
  // without live tracking keep showing what they always did.
  subtitleOf: (r) => investmentSubtitle(r),
  // The same rule net worth uses, so the row and the total can never disagree
  // about what a holding is worth.
  trailingOf: (r) => money(investmentValue(r)),
  dashboard: {
    stats: [
      // Rows created before `total_invested` existed carry the same figure in
      // `invested_amount` — the substitution dashboardSnapshot makes.
      statSum('total_invested', 'Invested', { fallback: 'invested_amount' }),
      statSum('current_value', 'Current value'),
      statRatio('current_value', 'total_invested', 'Return', {
        againstFallback: 'invested_amount',
      }),
      statEventSum('invested_amount', 'Added'),
    ],
    chart: chartDualCumulative('invested_amount', 'current_value', {
      label: 'Invested vs value',
      firstLabel: 'Invested',
      secondLabel: 'Value',
    }),
    breakdown: breakdownByRow({ value: 'current_value' }),
  },
}
```

Append to `packages/shared/src/index.ts`:
```ts
export { investment, investmentSubtitle, PRICEABLE_TYPES, SIP_ONLY } from './registry/investment.js'
```

- [ ] **Step 4: Run the tests**

Run: `npx vitest run test/registry.investment.test.ts`
Expected: PASS, 19 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(shared): transcribe the investment config"
```

---

### Task 10: Registry index and the Dart equivalence test

The mitigation named in the spec's risk section. Parses the Dart registry and asserts the TypeScript one matches it table by table, field by field — a mistyped `hiddenWhenFilled` produces working UI with wrong data, and nothing else would catch it.

**Files:**
- Create: `packages/shared/src/registry/index.ts`
- Modify: `packages/shared/src/index.ts`
- Test: `packages/shared/test/registry.index.test.ts`
- Test: `packages/shared/test/registry.equivalence.test.ts`

**Interfaces:**
- Consumes: Tasks 6–9.
- Produces:
  - `const modules: readonly EntityConfig[]` — sidebar order
  - `moduleByTable(table: string): EntityConfig | undefined`
  - `const DART_REGISTRY_PATH` — absolute path to the Flutter source, so the
    equivalence test skips cleanly (with a printed reason) when the Flutter repo
    isn't checked out beside this one.

- [ ] **Step 1: Write the failing tests**

`packages/shared/test/registry.index.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import { modules, moduleByTable } from '../src/index.js'

describe('modules', () => {
  it('lists the nine sidebar modules in order', () => {
    expect(modules.map((m) => m.table)).toEqual([
      'income',
      'expenses',
      'savings_goals',
      'investments',
      'debtors',
      'creditors',
      'bills',
      'loans',
      'transfers',
    ])
  })

  it('gives every module a title, icon, tone and at least one field', () => {
    for (const m of modules) {
      expect(m.title).not.toBe('')
      expect(m.icon).not.toBe('')
      expect(m.tone).not.toBe('')
      expect(m.fields.length).toBeGreaterThan(0)
    }
  })

  it('finds a module by table', () => {
    expect(moduleByTable('investments')!.title).toBe('Investment')
    expect(moduleByTable('nope')).toBeUndefined()
  })

  it('names a decrementConfirm wherever "Pay" would be the wrong verb', () => {
    // Savings is the one module whose decrement is not a debt payment.
    const withdrawals = modules.filter((m) => m.decrementConfirm !== undefined)
    expect(withdrawals.map((m) => m.table)).toEqual(['savings_goals'])
  })

  it('gives every settle-able module an original amount and a payments table', () => {
    for (const m of modules.filter((x) => x.statusField !== undefined)) {
      expect(m.originalAmountField).toBeDefined()
      expect(m.paymentsTable).toBeDefined()
      expect(m.cascadeTables).toContain(m.paymentsTable!)
    }
  })
})
```

`packages/shared/test/registry.equivalence.test.ts`:
```ts
import { readFileSync, existsSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { modules, DART_REGISTRY_PATH } from '../src/index.js'

/**
 * Guards the transcription from the Flutter source. A wrong flag here is a
 * silent data bug — the UI still renders, it just saves the wrong thing — so
 * this compares against the Dart file rather than trusting the hand-copy.
 *
 * Skipped (loudly) when the Flutter repo is not present, so CI without it
 * still passes rather than failing for an unrelated reason.
 */
const available = existsSync(DART_REGISTRY_PATH)
const maybe = available ? describe : describe.skip

if (!available) {
  console.warn(`registry equivalence: skipped, ${DART_REGISTRY_PATH} not found`)
}

maybe('registry matches the Dart source', () => {
  const dart = readFileSync(DART_REGISTRY_PATH, 'utf8')

  it('declares the same tables', () => {
    const tables = [...dart.matchAll(/table:\s*'([^']+)'/g)].map((m) => m[1])
    expect(new Set(tables)).toEqual(new Set(modules.map((m) => m.table)))
  })

  it('declares the same field keys per module', () => {
    // Each `static final <name> = EntityConfig(` block runs to the next one.
    const blocks = dart.split(/static final \w+ = EntityConfig\(/).slice(1)
    for (const block of blocks) {
      const table = /table:\s*'([^']+)'/.exec(block)?.[1]
      if (table === undefined) continue
      const config = modules.find((m) => m.table === table)
      expect(config, `no TS config for table ${table}`).toBeDefined()

      const fieldsStart = block.indexOf('fields: const [')
      const fieldsEnd = block.indexOf('titleOf:')
      const fieldsSrc = block.slice(fieldsStart, fieldsEnd)
      const keys = [...fieldsSrc.matchAll(/FieldSpec\(\s*\n?\s*'([^']+)'/g)].map((m) => m[1])

      expect(config!.fields.map((f) => f.key), `field keys for ${table}`).toEqual(keys)
    }
  })

  it('declares the same required fields per module', () => {
    const blocks = dart.split(/static final \w+ = EntityConfig\(/).slice(1)
    for (const block of blocks) {
      const table = /table:\s*'([^']+)'/.exec(block)?.[1]
      if (table === undefined) continue
      const config = modules.find((m) => m.table === table)!

      const fieldsSrc = block.slice(
        block.indexOf('fields: const ['),
        block.indexOf('titleOf:'),
      )
      // Split on FieldSpec boundaries so `required: true` is attributed to the
      // field it belongs to rather than to the whole block.
      const specs = fieldsSrc.split('FieldSpec(').slice(1)
      const required = specs
        .filter((s) => /required:\s*true/.test(s))
        .map((s) => /'([^']+)'/.exec(s)?.[1])
        .filter((k): k is string => k !== undefined)

      expect(
        config.fields.filter((f) => f.required === true).map((f) => f.key),
        `required fields for ${table}`,
      ).toEqual(required)
    }
  })

  it('carries the same boolean flags per module', () => {
    const flags: Array<[keyof (typeof modules)[number], string]> = [
      ['exportable', 'exportable'],
      ['dateFiltered', 'dateFiltered'],
      ['liveTracked', 'liveTracked'],
      ['redeemable', 'redeemable'],
      ['paymentInflow', 'paymentInflow'],
      ['principalAccount', 'principalAccount'],
    ]
    const blocks = dart.split(/static final \w+ = EntityConfig\(/).slice(1)
    for (const block of blocks) {
      const table = /table:\s*'([^']+)'/.exec(block)?.[1]
      if (table === undefined) continue
      const config = modules.find((m) => m.table === table)!
      for (const [tsKey, dartKey] of flags) {
        const inDart = new RegExp(`${dartKey}:\\s*true`).test(block)
        expect(config[tsKey] === true, `${table}.${String(tsKey)}`).toBe(inDart)
      }
    }
  })

  it('names the same action columns per module', () => {
    const cols = [
      'incrementField', 'incrementAlsoField', 'cumulativeIncrementField',
      'setField', 'decrementField', 'interestRateField', 'dueDateField',
      'principalAccountField', 'statusField', 'originalAmountField',
      'settledAccountField', 'paymentsTable', 'orderBy',
    ] as const
    const blocks = dart.split(/static final \w+ = EntityConfig\(/).slice(1)
    for (const block of blocks) {
      const table = /table:\s*'([^']+)'/.exec(block)?.[1]
      if (table === undefined) continue
      const config = modules.find((m) => m.table === table)!
      for (const key of cols) {
        const m = new RegExp(`\\b${key}:\\s*'([^']+)'`).exec(block)
        expect(config[key], `${table}.${key}`).toBe(m?.[1])
      }
    }
  })
})
```

- [ ] **Step 2: Run them and watch them fail**

Run: `npx vitest run test/registry.index.test.ts test/registry.equivalence.test.ts`
Expected: FAIL — no export `modules`.

- [ ] **Step 3: Implement**

`packages/shared/src/registry/index.ts`:
```ts
import type { EntityConfig } from '../models/entityConfig.js'
import { bills } from './bills.js'
import { creditors } from './creditors.js'
import { debtors } from './debtors.js'
import { expenses } from './expenses.js'
import { income } from './income.js'
import { investment } from './investment.js'
import { loans } from './loans.js'
import { savings } from './savings.js'
import { transfers } from './transfers.js'

/**
 * Central registry of every feature module. The dashboard grid and the generic
 * entity screen are both driven by these configs — to add a module, add an
 * entry here (and a matching table in Supabase).
 *
 * Note: Alerts and Accounts are not generic CRUD modules; each has its own
 * screen.
 */
export const modules: readonly EntityConfig[] = [
  income,
  expenses,
  savings,
  investment,
  debtors,
  creditors,
  bills,
  loans,
  transfers,
]

export function moduleByTable(table: string): EntityConfig | undefined {
  return modules.find((m) => m.table === table)
}

/**
 * The Flutter registry this one was transcribed from. Read only by the
 * equivalence test, which skips when the Flutter repo isn't checked out.
 */
export const DART_REGISTRY_PATH =
  '/home/stacx-24/gn/accounts_management/lib/features/registry.dart'
```

Append to `packages/shared/src/index.ts`:
```ts
export * from './registry/index.js'
```

- [ ] **Step 4: Run the whole suite**

Run: `cd /home/stacx-24/gn/accounts_ts/packages/shared && npx vitest run && npx tsc --noEmit`
Expected: all test files PASS; `tsc` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(shared): registry index plus Dart equivalence guard"
```

---

### Task 11: `packages/tokens`

Ports `AppColors.light` / `AppColors.dark`, `ModuleTone`, and `AppTheme`'s radii and spacing from [`lib/core/theme.dart`](../../../lib/core/theme.dart) (455 lines). One source, two outputs: CSS custom properties for `apps/web`, a plain object for `apps/mobile`.

**Files:**
- Create: `packages/tokens/package.json`
- Create: `packages/tokens/tsconfig.json`
- Create: `packages/tokens/vitest.config.ts`
- Create: `packages/tokens/src/colors.ts`
- Create: `packages/tokens/src/tone.ts`
- Create: `packages/tokens/src/layout.ts`
- Create: `packages/tokens/src/contrast.ts`
- Create: `packages/tokens/src/css.ts`
- Create: `packages/tokens/src/index.ts`
- Test: `packages/tokens/test/tokens.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `interface Palette { bg; surface; border; textPrimary; textSecondary; accent; accentText; buttonFill; onButtonFill; onAccent; positive; negative; chipAlpha }`
  - `const lightPalette: Palette`, `const darkPalette: Palette`
  - `const moduleTones: Record<ModuleToneName, { light: string; dark: string }>`
  - `const radii = { card: 12, control: 10, chip: 8, fab: 16 }`
  - `const layout = { rowHeight: 64, screenPad: 20 }`
  - `const fonts = { sans: 'Inter', serif: 'SourceSerif4' }`
  - `contrastRatio(a: string, b: string): number`
  - `paletteToCss(p: Palette, selector: string): string`

- [ ] **Step 1: Write the failing test**

`packages/tokens/test/tokens.test.ts`:
```ts
import { describe, expect, it } from 'vitest'
import {
  lightPalette,
  darkPalette,
  moduleTones,
  radii,
  layout,
  fonts,
  contrastRatio,
  paletteToCss,
} from '../src/index.js'

describe('palettes', () => {
  it('is ivory on clay in light', () => {
    expect(lightPalette.bg).toBe('#F5F1EB')
    expect(lightPalette.accent).toBe('#C15F3C')
    expect(lightPalette.buttonFill).toBe('#B85536')
  })

  it('is warm dark in dark, where one clay serves fill and text alike', () => {
    expect(darkPalette.bg).toBe('#1A1917')
    expect(darkPalette.accent).toBe('#D97757')
    expect(darkPalette.accentText).toBe(darkPalette.accent)
    expect(darkPalette.buttonFill).toBe(darkPalette.accent)
  })

  it('needs less tint on the lighter ground', () => {
    expect(lightPalette.chipAlpha).toBe(0.12)
    expect(darkPalette.chipAlpha).toBe(0.16)
  })
})

describe('contrast — the traps encoded in the token names', () => {
  it('rounds to the ratios asserted in UI_REDESIGN.md §2', () => {
    expect(contrastRatio('#FFFFFF', '#000000')).toBeCloseTo(21, 1)
    expect(contrastRatio('#F5F1EB', '#F5F1EB')).toBeCloseTo(1, 5)
  })

  it('light accent fails AA as text, which is why accentText exists', () => {
    expect(contrastRatio(lightPalette.accent, lightPalette.bg)).toBeLessThan(4.5)
    expect(contrastRatio(lightPalette.accentText, lightPalette.bg)).toBeGreaterThanOrEqual(4.5)
  })

  it('buttonFill carries its own label, which the accent would not', () => {
    expect(contrastRatio(lightPalette.onButtonFill, lightPalette.buttonFill))
      .toBeGreaterThanOrEqual(4.5)
  })

  it('body text clears AA on both grounds', () => {
    expect(contrastRatio(lightPalette.textPrimary, lightPalette.bg)).toBeGreaterThanOrEqual(4.5)
    expect(contrastRatio(darkPalette.textPrimary, darkPalette.bg)).toBeGreaterThanOrEqual(4.5)
  })

  it('secondary text clears AA on both grounds', () => {
    expect(contrastRatio(lightPalette.textSecondary, lightPalette.bg)).toBeGreaterThanOrEqual(4.5)
    expect(contrastRatio(darkPalette.textSecondary, darkPalette.bg)).toBeGreaterThanOrEqual(4.5)
  })

  it('dark accent clears AA as text, so one token serves both roles', () => {
    expect(contrastRatio(darkPalette.accent, darkPalette.bg)).toBeGreaterThanOrEqual(4.5)
  })
})

describe('module tones', () => {
  it('covers all nine categories in both brightnesses', () => {
    expect(Object.keys(moduleTones)).toEqual([
      'income', 'expense', 'savings', 'invest',
      'debtor', 'creditor', 'bills', 'loan', 'alerts',
    ])
    for (const [name, tone] of Object.entries(moduleTones)) {
      expect(tone.light, name).toMatch(/^#[0-9A-F]{6}$/)
      expect(tone.dark, name).toMatch(/^#[0-9A-F]{6}$/)
    }
  })

  it('matches the Flutter values', () => {
    expect(moduleTones.income).toEqual({ light: '#2F6B4F', dark: '#7FB08A' })
    expect(moduleTones.invest).toEqual({ light: '#5B4B8A', dark: '#A99BD4' })
  })
})

describe('layout tokens', () => {
  it('uses radii smaller than stock Material, which reads more editorial', () => {
    expect(radii).toEqual({ card: 12, control: 10, chip: 8, fab: 16 })
  })

  it('keeps row height and screen padding', () => {
    expect(layout).toEqual({ rowHeight: 64, screenPad: 20 })
  })

  it('names the two bundled faces', () => {
    expect(fonts).toEqual({ sans: 'Inter', serif: 'SourceSerif4' })
  })
})

describe('paletteToCss', () => {
  const css = paletteToCss(lightPalette, ':root')

  it('emits kebab-cased custom properties under the given selector', () => {
    expect(css).toContain(':root {')
    expect(css).toContain('--color-bg: #F5F1EB;')
    expect(css).toContain('--color-text-primary: #1F1E1C;')
  })

  it('emits the numeric token without a unit', () => {
    expect(css).toContain('--chip-alpha: 0.12;')
  })
})
```

- [ ] **Step 2: Create the package and run the test to watch it fail**

`packages/tokens/package.json`:
```json
{
  "name": "@accounts/tokens",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": { ".": "./src/index.ts" },
  "scripts": {
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "build:css": "tsx src/build-css.ts"
  }
}
```

`packages/tokens/tsconfig.json`:
```json
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": { "rootDir": ".", "outDir": "dist" },
  "include": ["src", "test"]
}
```

`packages/tokens/vitest.config.ts`:
```ts
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: { include: ['test/**/*.test.ts'], environment: 'node' },
})
```

Run: `cd /home/stacx-24/gn/accounts_ts && npm install && cd packages/tokens && npx vitest run`
Expected: FAIL — cannot resolve `../src/index.js`.

- [ ] **Step 3: Implement**

`packages/tokens/src/colors.ts`:
```ts
/**
 * Design tokens for the Accounflow redesign — "paper, one accent, serif for
 * statements". Ivory ground, clay interaction, borders instead of shadows.
 *
 * Every colour here was contrast-checked against the surface it sits on; see
 * UI_REDESIGN.md §2, and the assertions in test/tokens.test.ts. Two traps are
 * encoded in the token names:
 *
 *  - `accent` fails AA as *text* on light (4.16:1). Use it only for fills —
 *    FAB, focus ring, selection tint. For clay text use `accentText`.
 *  - White on `accent` is only 4.23:1, so filled buttons use `buttonFill`
 *    (#B85536, 4.78:1 with white) rather than the accent itself.
 */
export interface Palette {
  bg: string
  surface: string
  border: string
  textPrimary: string
  textSecondary: string
  /** Fills only — never text on light. See the doc comment above. */
  accent: string
  /** Clay used as text (links, text-button labels). */
  accentText: string
  /** Filled-button background; darker than `accent` so its label passes AA. */
  buttonFill: string
  onButtonFill: string
  /** Glyph colour on top of an `accent` fill (the FAB). */
  onAccent: string
  positive: string
  negative: string
  /** Opacity for module-tinted icon chips — lighter ground needs less. */
  chipAlpha: number
}

export const lightPalette: Palette = {
  bg: '#F5F1EB',
  surface: '#FFFDFA',
  border: '#E4DDD2',
  textPrimary: '#1F1E1C',
  textSecondary: '#6B655C',
  accent: '#C15F3C',
  accentText: '#A44B2C',
  buttonFill: '#B85536',
  onButtonFill: '#FFFDFA',
  onAccent: '#FFFDFA',
  positive: '#2F6B4F',
  negative: '#8C2F26',
  chipAlpha: 0.12,
}

export const darkPalette: Palette = {
  bg: '#1A1917',
  surface: '#232120',
  border: '#35322E',
  textPrimary: '#EDE9E3',
  textSecondary: '#A39C92',
  // On the warm dark ground clay clears AA at 5.14:1, so one token serves
  // fill, text, and button alike.
  accent: '#D97757',
  accentText: '#D97757',
  buttonFill: '#D97757',
  onButtonFill: '#1F1E1C',
  onAccent: '#1F1E1C',
  positive: '#7FB08A',
  negative: '#E08A7D',
  chipAlpha: 0.16,
}
```

`packages/tokens/src/tone.ts`:
```ts
/**
 * Per-module accent. Category colour survives the redesign only at icon-chip
 * size — the value itself is always `textPrimary`. Direction of money
 * (positive/negative) is what keeps real colour.
 */
export type ModuleToneName =
  | 'income' | 'expense' | 'savings' | 'invest'
  | 'debtor' | 'creditor' | 'bills' | 'loan' | 'alerts'

export interface Tone {
  light: string
  dark: string
}

export const moduleTones: Record<ModuleToneName, Tone> = {
  income: { light: '#2F6B4F', dark: '#7FB08A' },
  expense: { light: '#8C2F26', dark: '#E08A7D' },
  savings: { light: '#2C6E6B', dark: '#6FB3AF' },
  invest: { light: '#5B4B8A', dark: '#A99BD4' },
  debtor: { light: '#3A5F8A', dark: '#8FB3DE' },
  creditor: { light: '#8A3A5F', dark: '#DE8FB3' },
  bills: { light: '#8A5A22', dark: '#D9A867' },
  loan: { light: '#6B4F3A', dark: '#BFA08A' },
  alerts: { light: '#4A4A7A', dark: '#9A9AD4' },
}
```

`packages/tokens/src/layout.ts`:
```ts
/** Radii — smaller than stock Material, which reads more editorial. */
export const radii = { card: 12, control: 10, chip: 8, fab: 16 } as const

export const layout = { rowHeight: 64, screenPad: 20 } as const

/**
 * Bundled as static font files (not a web font service) so the app renders
 * offline and never fetches a typeface at first paint.
 */
export const fonts = { sans: 'Inter', serif: 'SourceSerif4' } as const
```

`packages/tokens/src/contrast.ts`:
```ts
/**
 * WCAG relative luminance and contrast ratio.
 *
 * Present so the palette's accessibility claims are asserted by a test rather
 * than by a comment. A token whose ratio silently drifts below 4.5 is exactly
 * the kind of regression nobody notices until someone can't read a label.
 */
function channel(v: number): number {
  const s = v / 255
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
}

function luminance(hex: string): number {
  const h = hex.replace('#', '')
  const r = Number.parseInt(h.slice(0, 2), 16)
  const g = Number.parseInt(h.slice(2, 4), 16)
  const b = Number.parseInt(h.slice(4, 6), 16)
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

export function contrastRatio(a: string, b: string): number {
  const la = luminance(a)
  const lb = luminance(b)
  const [hi, lo] = la > lb ? [la, lb] : [lb, la]
  return (hi + 0.05) / (lo + 0.05)
}
```

`packages/tokens/src/css.ts`:
```ts
import type { Palette } from './colors.js'
import { layout, radii } from './layout.js'
import { moduleTones } from './tone.js'

const kebab = (s: string): string => s.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)

/**
 * Render a palette as CSS custom properties.
 *
 * `apps/web` consumes the generated file; `apps/mobile` imports the objects
 * directly. Neither hand-maintains a second copy of a colour — a token that
 * exists twice is a token that will eventually disagree with itself.
 */
export function paletteToCss(p: Palette, selector: string): string {
  const lines: string[] = []
  for (const [key, value] of Object.entries(p)) {
    const name = key === 'chipAlpha' ? '--chip-alpha' : `--color-${kebab(key)}`
    lines.push(`  ${name}: ${value};`)
  }
  for (const [name, tone] of Object.entries(moduleTones)) {
    lines.push(`  --tone-${name}: ${selector.includes('dark') ? tone.dark : tone.light};`)
  }
  for (const [name, value] of Object.entries(radii)) {
    lines.push(`  --radius-${name}: ${value}px;`)
  }
  for (const [name, value] of Object.entries(layout)) {
    lines.push(`  --${kebab(name)}: ${value}px;`)
  }
  return `${selector} {\n${lines.join('\n')}\n}\n`
}
```

`packages/tokens/src/index.ts`:
```ts
export * from './colors.js'
export * from './tone.js'
export * from './layout.js'
export * from './contrast.js'
export * from './css.js'
```

- [ ] **Step 4: Run the tests**

Run: `cd /home/stacx-24/gn/accounts_ts/packages/tokens && npx vitest run && npx tsc --noEmit`
Expected: PASS, 15 tests; `tsc` prints nothing.

- [ ] **Step 5: Run the whole workspace and commit**

Run: `cd /home/stacx-24/gn/accounts_ts && npm test`
Expected: both packages pass.

```bash
git add -A && git commit -m "feat(tokens): port the design token set with contrast assertions"
```

---

## Self-review

**Spec coverage.** This plan covers the spec's `packages/shared` (models, registry, math, events, format) and `packages/tokens` in full, plus the monorepo scaffold. Not covered here, by design — each needs its own plan: `packages/api-client`, `packages/logic`, `apps/api`, `apps/web`, `apps/mobile`, and the `sipMath` / `moduleMetrics` modules of `shared` (they depend on the SIP and dashboard work in later phases, and land with them).

**Deviation from the spec.** npm workspaces instead of pnpm — pnpm is not installed. Recorded in Global Constraints.

**Deferred within `shared`.** `math/sipMath.ts` and `math/moduleMetrics.ts` are listed in the spec's folder tree but are not in this plan: `sipMath` is meaningless without the SIP engine's installment model (phase 13) and `moduleMetrics` needs the dashboard range logic (phase 11). Both arrive with the phase that gives them a consumer, rather than being written blind here.

**Next plans, in order.** (1) `packages/api-client` + `packages/logic`; (2) `apps/api` foundation and domain actions; (3) `apps/web`; (4) `apps/mobile`.
