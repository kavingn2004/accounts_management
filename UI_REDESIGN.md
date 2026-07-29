# UI Redesign — Anthropic/Claude Visual Language

Design spec for restyling Accounflow from its current Material-blue theme to the
warm, editorial look of Anthropic's product surfaces: ivory paper, clay accent,
serif display type, restrained colour, generous space.

Status: **implemented** — 2026-07-29. Screens were rendered from this spec in
Claude Design (project `e0889163`, `Accounflow Redesign.dc.html`) and the app
was built against those renders. See §10 for where the built app deliberately
departs from the text below.
Date: 2026-07-29.

---

## 1. Why, and what stays

The app today is a stock Material 3 blue: `ColorScheme.fromSeed(#1565C0)`, a
saturated blue app bar in both light and dark, pure-white surfaces, and nine
independently-chosen module accent colours. It reads like a framework default —
functional, but with no point of view, and the nine accents fight each other on
the dashboard where six metric cards sit in one viewport.

**Unchanged by this redesign:** all data models, `finance_repository`, Supabase
schema, the `EntityConfig`/`FieldSpec` registry mechanism, routing, PIN/auth
logic. This is a presentation-layer change. `registry.dart` is touched only to
swap colour constants — its structure stays.

### Principles

1. **Paper, not glass.** Warm ivory ground, not white; borders instead of
   shadows. Depth comes from tone, not elevation.
2. **One accent.** Clay carries interaction — buttons, focus, selection. It is
   not decoration and never fills a card.
3. **Colour that means something.** Green/red survive only where they encode
   direction of money. Everything else desaturates.
4. **Serif for statements, sans for data.** Display serif on headings and
   headline figures; sans everywhere you scan or compare.
5. **Space is the layout tool.** Fewer rules and boxes, more whitespace.

---

## 2. Colour tokens

All ratios below were computed against the token backgrounds, not estimated.
Target is WCAG AA — 4.5:1 for normal text, 3:1 for large/bold text and UI
boundaries.

### Light

| Token | Hex | Use | Contrast |
|---|---|---|---|
| `bg` | `#F5F1EB` | scaffold | — |
| `surface` | `#FFFDFA` | cards, sheets, inputs | — |
| `border` | `#E4DDD2` | hairlines, card outlines | 1.33:1 vs surface (decorative) |
| `textPrimary` | `#1F1E1C` | headings, amounts | **16.4:1** |
| `textSecondary` | `#6B655C` | subtitles, labels, hints | **5.68:1** |
| `accent` | `#C15F3C` | fills, selection, focus ring | 4.16:1 — **fills only** |
| `accentText` | `#A44B2C` | clay used *as text* (links, TextButton) | **5.71:1** |
| `accentPressed` | `#AE4E30` | pressed/hover fill | — |
| `positive` | `#2F6B4F` | money in | **6.20:1** |
| `negative` | `#8C2F26` | money out, destructive | **8.11:1** |

> **Contrast trap — read this before implementing.** `accent #C15F3C` fails AA as
> text (4.16:1) *and* white-on-clay as a button label is only **4.23:1**, also a
> fail. Two rules follow, and they are not optional:
> - Clay as text → use `accentText #A44B2C`, never `accent`.
> - Filled buttons → the fill is **`#B85536`** (white label = **4.78:1**, passes),
>   not `#C15F3C`. `#C15F3C` is reserved for non-text fills: focus rings,
>   selection tints, the FAB, chart marks.

### Dark

Warm dark — brown-black, not neutral grey. The current dark theme's `#131419` is
cool-blue and clashes with a clay accent.

| Token | Hex | Use | Contrast |
|---|---|---|---|
| `bg` | `#1A1917` | scaffold | — |
| `surface` | `#232120` | cards, sheets, inputs | — |
| `border` | `#35322E` | hairlines | 1.26:1 vs surface (decorative) |
| `textPrimary` | `#EDE9E3` | headings, amounts | **13.3:1** |
| `textSecondary` | `#A39C92` | subtitles, labels | **5.90:1** |
| `accent` | `#D97757` | fills, selection, focus | **5.14:1** — safe as text here |
| `positive` | `#7FB08A` | money in | **6.47:1** |
| `negative` | `#E08A7D` | money out | **6.18:1** |

Dark filled buttons take `#D97757` with a **`#1F1E1C`** label (5.34:1), not white.

### Module accents

The nine saturated accents in `theme.dart:10-18` become nine **muted earth
tones**, and their role shrinks: they tint a 32px icon chip and nothing else. No
gradient banners, no coloured card fills, no coloured metric numbers.

| Module | Light | Dark | Light ratio |
|---|---|---|---|
| Income | `#2F6B4F` | `#7FB08A` | 6.20:1 |
| Expense | `#8C2F26` | `#E08A7D` | 8.11:1 |
| Savings | `#2C6E6B` | `#6FB3AF` | 5.83:1 |
| Investment | `#5B4B8A` | `#A99BD4` | 7.34:1 |
| Debtors | `#3A5F8A` | `#8FB3DE` | 6.50:1 |
| Creditors | `#8A3A5F` | `#DE8FB3` | 7.25:1 |
| Bills | `#8A5A22` | `#D9A867` | 5.80:1 |
| Loans | `#6B4F3A` | `#BFA08A` | 7.37:1 |
| Alerts | `#4A4A7A` | `#9A9AD4` | 8.11:1 |

All eighteen pass AA on their respective card backgrounds.

**The tension worth naming.** Anthropic's language is close to monochrome; a
finance app is not. A ledger where income and expense look alike is worse
design, whichever brand it wears. The resolution: *direction* of money keeps
colour (`positive`/`negative`, and only on amounts), *category* loses it
(muted chips at icon size). Income green and Expense red are deliberately the
same hues as `positive`/`negative` so the two systems reinforce rather than
compete.

---

## 3. Typography

No fonts are bundled today (`pubspec.yaml` declares no `fonts:` block) and
`google_fonts` is not a dependency. Add **static `.ttf` files under
`assets/fonts/`** — not `google_fonts`, which fetches over the network at first
paint. A finance app must render offline, and iOS review dislikes runtime font
fetches.

| Role | Face | Licence | Where |
|---|---|---|---|
| Display | **Source Serif 4** (Regular 400, Semibold 600) | OFL | screen titles, headline figures, empty-state lines |
| UI / data | **Inter** (Regular 400, Medium 500, Semibold 600) | OFL | everything else |

Both are metric-stable and ship Latin + the `₹` glyph.

### Scale

| Style | Face | Size / line / weight | Use |
|---|---|---|---|
| `displayLarge` | Serif | 32 / 38 / 600 | net-worth figure |
| `headlineMedium` | Serif | 24 / 30 / 600 | screen titles |
| `titleMedium` | Sans | 16 / 22 / 600 | card titles, row titles |
| `bodyMedium` | Sans | 14 / 20 / 400 | body, row subtitles |
| `labelSmall` | Sans | 12 / 16 / 500 | chips, captions, table headers |
| `numeric` | Sans | inherits, **tabular** | every money value |

**Tabular figures are mandatory on money.** Amount columns misalign without
them:

```dart
const TextStyle numeric = TextStyle(
  fontFamily: 'Inter',
  fontFeatures: [FontFeature.tabularFigures()],
);
```

Apply in `formatters.dart` at the point `money()` output is rendered, so no call
site can forget.

---

## 4. Shape, space, motion

- **Radius:** 12 cards/sheets, 10 buttons/inputs, 8 chips, 999 avatars. Down
  from the current 16 — smaller radii read more editorial, less "app-y".
- **Spacing scale:** 4, 8, 12, 16, 24, 32, 48. Screen padding 20; card padding
  16; gap between cards 12; section gap 32.
- **Borders over shadows.** Every card is `1px border` + `0 elevation`. The one
  exception is the FAB. Delete `_NetWorthBanner`'s `BoxShadow`
  (`dashboard_screen.dart:484`).
- **No gradients.** Two exist today — `_NetWorthBanner` (`:478`) and the drawer
  header (`app_drawer.dart:124`). Both become flat `surface` with a border.
- **Motion:** 120ms `easeOut` for state changes, 200ms for sheets. No bounce.

---

## 5. Components

### Card

```
┌─────────────────────────────────┐   surface #FFFDFA
│  Label            labelSmall    │   1px border #E4DDD2
│  ₹4,12,000        display/serif │   radius 12, padding 16
│  ▲ 4.2% vs last month           │   elevation 0
└─────────────────────────────────┘
```

### Metric card (`_MetricCard`, `dashboard_screen.dart:559`)

Currently takes a `color` and paints with it. New contract: the value is
`textPrimary` **always**; the module colour appears only in a 32px icon chip
(module colour at 12% alpha as chip fill, full colour as glyph). Deltas use
`positive`/`negative`.

### List row (`_buildRow`, `entity_screen.dart:717`)

Icon chip (32, module tint) · title `titleMedium` · subtitle `bodyMedium`
secondary · trailing amount `numeric`, right-aligned, `textPrimary`. Row height
64, hairline divider, no card per row.

### Buttons

| Variant | Light | Dark |
|---|---|---|
| Filled | fill `#B85536`, label white | fill `#D97757`, label `#1F1E1C` |
| Outlined | 1px `border`, label `textPrimary` | same |
| Text | label `accentText #A44B2C` | label `#D97757` |
| Destructive | fill `negative` | fill `negative` |

Height 48, radius 10. Replaces the blue `filledButtonTheme` at `theme.dart:58`.

### Input

Fill `surface`, 1px `border`, radius 10, label `textSecondary`. Focus: 1.5px
`accent` ring. Error: 1.5px `negative` + message in `negative`.

### App bar

The single biggest visual change. Today it is a solid blue bar with white text
in both modes (`theme.dart:39-44`). It becomes **transparent over `bg`**, title
in serif `headlineMedium` `textPrimary`, no elevation, no divider until scrolled
(then a 1px `border` hairline).

---

## 6. Screen-by-screen

**Login** (`login_screen.dart`) — ivory ground. Wallet glyph in clay. "Accounflow"
in serif 24/600. Inputs and the filled button per §5. The success message at
`:143` uses `AppTheme.cIncome` → becomes `positive`.

**Dashboard** (`dashboard_screen.dart`, 617 lines) — the heaviest edit.
- `_NetWorthBanner` (`:466`): gradient + shadow → flat `surface` card, 1px
  border, label `labelSmall` secondary, figure serif `displayLarge` 32.
- Six `_MetricCard`s: new contract above; grid gap 12.
- `_ChartCard` (`:256`): flat, bordered.
- `_BarChart` (`:282`): income `positive`, expense `negative`, `border` gridlines.
- `_ExpensePie` (`:363`): the five-colour list at `:37-41` → muted module tones.
- `_PeriodFilter` (`:224`): `ChoiceChip` `selectedColor` blue → `accent` at 12%
  alpha with `textPrimary` label; unselected transparent + border.

**Entity screens** (`entity_screen.dart`, 1356 lines) — highest leverage, every
module renders through it. Rows per §5; `_summaryBanner` (`:920`) flat; filter
bar (`:867`) chips per above; `_EntrySheet` (`:987`) gets 20px padding, serif
title, a drag handle, and radius-12 top corners. The two hardcoded
`AppTheme.cExpense` uses (`:180`, `:853`) are destructive actions → `negative`.

**Drawer** (`app_drawer.dart`) — gradient header (`:124`) → flat `surface` +
hairline. Nine module rows get muted icon chips. Selected row: `accent` 10%
tint, no blue.

**Accounts / Alerts / Profile** — token swap only (9, 3, and 13 `AppTheme.`
references respectively). No structural change.

---

## 7. Implementation order

76 `AppTheme.` references across 11 files, plus 20 `Colors.grey` and 18
`Colors.white` literals that must become tokens.

1. **Tokens + fonts.** Rewrite `theme.dart` (currently 86 lines → ~220). Add
   `assets/fonts/`, declare in `pubspec.yaml`. Keep the old constant *names*
   (`cIncome`, `primary`, …) pointing at new values so nothing breaks while the
   rest lands. App compiles and looks new after this step alone.
2. **Components.** New `lib/core/components.dart`: `AppCard`, `IconChip`,
   `MetricTile`, `MoneyText`. ~200 lines.
3. **Dashboard.** Port to the new components; delete gradients and shadows.
4. **Entity screens.** Rows, sheet, filter bar, summary banner.
5. **Drawer, login, accounts, alerts, profile.**
6. **Cleanup.** Delete the now-unused legacy aliases from step 1; replace every
   `Colors.grey`/`Colors.white` literal with a token; verify both themes.

Steps 1–2 are prerequisites; 3–5 are independent of each other.

### Verification

- `flutter analyze` clean.
- Both themes screenshotted on every screen — light *and* dark, since the dark
  palette shifts from cool to warm and regressions hide there.
- Confirm no `Colors.grey|white|blue` literals survive in `lib/features`.
- Spot-check the contrast pairs in §2 against the shipped build; the ratios
  above are computed, but only the built app proves the tokens were wired to the
  surfaces they were designed against.

---

## 8. Out of scope

Layout restructuring, navigation changes, new screens, responsive/tablet
breakpoints, animation work beyond the durations in §4, and any change to
business logic or the Supabase schema.

## 9. Open questions

1. **App icon and splash.** `pubspec.yaml` hardcodes `#0D47A1` blue for the
   adaptive icon background, iOS background, and web theme colour. The logo
   itself (`assets/icon/logo.png`) is blue. Out of scope above, but the app icon
   will visibly clash with the new palette — needs its own decision.
2. **Serif on Android.** Source Serif 4 adds ~400KB across weights. Acceptable,
   but if APK size matters, the display face could be dropped to serif-only-on-
   headline-figures rather than all titles.

---

## 10. As built — deltas from §1–§9

The design renders resolved several things this document left open, and one
decision changed outright.

1. **The period filter moved into the chart header.** It only ever affected the
   chart and the two period totals, so a free-floating chip row above the fold
   overstated its reach. It is now a bordered `Month ⌄` pill inside the
   "Income vs expense" card (`_PeriodPill`).
2. **Net worth and current worth share one card**, split by a vertical hairline
   — net worth in serif 30, current worth in serif 20 with a "Wallet + bank"
   caption. §6 described net worth alone.
3. **Six metric tiles in a 2-column grid**, not stacked pairs. "Invested" became
   the Investment tile's delta line rather than a seventh tile.
4. **`EntityConfig.color` became `EntityConfig.tone`** (`ModuleTone`). A flat
   `Color` cannot answer to two brightnesses; the enum resolves per-theme at
   paint time. `field_spec.dart` and all nine registry entries changed with it.
5. **Row overflow menus are conditional.** Design 1e shows Expenses, which has
   no actions beyond edit/delete, so its rows end at the amount. Modules that
   *do* have extra actions (payments, settling, top-ups) keep a muted
   `more_vert`; dropping it would have deleted working features to match a
   render of a module that never had them.
6. **`money()` now uses `en_IN` grouping** — the design's figures are lakh-
   grouped (`₹8,42,600`), which `NumberFormat.currency` did not do. Paise are
   shown only when an amount actually has them: the renders are whole rupees,
   but a ledger must not round money away silently.
7. **App icon: "ivory on clay."** Design 1i offered three directions and named
   this one, since it survives being shrunk to a notification badge.
   `pubspec.yaml` now carries `#F5F1EB` adaptive background, `#B85536` iOS and
   web theme colour. **The logo bitmap itself is still the old blue mark** —
   `assets/icon/logo.png` needs redrawing before release.

### Verified

- `flutter analyze` — **No issues found!**
- `flutter build web --release` succeeds with the bundled fonts.
- Login and the full component layer (cards, metric tiles, 64px rows, filter
  chips, settings rows, buttons, empty states, FAB) screenshotted in **both**
  themes and checked against the renders.
- ₹ renders in all five bundled faces; tabular figures align in amount columns.

### Known remaining

- `export_service.dart` still styles exported PDFs with `PdfColors.blue900`.
  That is a print palette the design does not cover, so it was left alone — but
  a PDF exported from the redesigned app will not look like it.
