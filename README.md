# Accounts App

Personal accounts management for iOS & Android — income, expenses, savings,
investments, debtors, creditors, bills, and alerts. Built with **Flutter** +
**Supabase**, with email sign-in and an on-device numeric **PIN lock**.

## Stack

- **Flutter** (Material 3) — single codebase for iOS, Android, web
- **Supabase** — Postgres + Auth + Row Level Security
- **Riverpod** — state management
- **flutter_secure_storage** + **crypto** — PIN stored hashed in the OS keychain

## Project layout

```
supabase/migrations/
  0001_init.sql               tables + RLS (per-user isolation)
  0002_triggers_and_views.sql balance/status triggers + dashboard views
lib/
  core/        config, supabase client, theme, formatters
  services/    pin_service, riverpod providers
  data/        finance_repository (Supabase CRUD)
  models/      field_spec (drives generic forms)
  features/
    auth/      login, pin setup, pin lock, auth gate
    home/      app shell
    dashboard/ summary cards + module grid
    common/    EntityScreen (generic list + add, reused by all modules)
    registry.dart  one EntityConfig per module
```

## 1. Set up the database

In the Supabase SQL editor (or via the CLI), run, in order:

1. `supabase/migrations/0001_init.sql`
2. `supabase/migrations/0002_triggers_and_views.sql`

## 2. Run a local preview (web, fastest)

```powershell
# one-time, generates native + web folders without touching lib/
flutter create . --org com.example.accounts --project-name accounts_app
flutter pub get

flutter run -d chrome `
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

> Only the **anon** key goes in the app. Never ship the service_role key.

## 3. Build small release binaries

The biggest size levers are: few plugins (already lean), and these flags.

```powershell
# Android — per-ABI APKs (each ~8–12 MB vs one fat APK)
flutter build apk --release --split-per-abi `
  --obfuscate --split-debug-info=build/symbols `
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...

# Android — app bundle for Play Store (Google delivers per-device, smallest)
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols ...

# iOS
flutter build ipa --release --obfuscate --split-debug-info=build/symbols ...
```

Size notes:
- `--split-per-abi` avoids bundling every CPU architecture in one file.
- `--obfuscate --split-debug-info` strips debug symbols out of the binary.
- Icon tree-shaking is automatic in release builds (only used glyphs ship).
- No bundled images/fonts — UI uses Material icons only.

## Auth model

1. One-time **email** sign-up/sign-in creates the Supabase account; the session
   is cached on-device.
2. A 4–6 digit **PIN** (hashed in the keychain) unlocks the app each launch.
3. RLS ensures every query only ever returns the signed-in user's rows.
