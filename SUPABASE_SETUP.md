# Accounflow — Supabase + iPhone browser setup

This app can store data in **Supabase** (a hosted Postgres database) and run in
any browser, including **Safari on iPhone**. Each user signs in with email +
password and only ever sees their own data; the on-device PIN stays as a second
lock on top.

If Supabase isn't configured, the app falls back to the original on-device
storage with no login — so `flutter run` still works for local development.

---

## 1. Create the database tables

1. Open your Supabase project → **SQL Editor** → **New query**.
2. Paste the entire contents of [`supabase/schema.sql`](supabase/schema.sql)
   and click **Run**.

   > ⚠️ This drops the tables from the older `supabase/migrations/` files, which
   > used a different data model that doesn't match the app. Only run it on an
   > empty project (no data you care about).

This creates one table per module (accounts, income, expenses, …) with
Row-Level-Security so users are isolated from each other.

## 2. Allow sign-ups (and decide on email confirmation)

In Supabase → **Authentication → Providers → Email**:

- Make sure **Email** is enabled.
- For the smoothest first run, you can turn **"Confirm email" OFF** so a new
  account is usable immediately. If you leave it ON, after signing up you'll get
  a confirmation email and must click the link before signing in.

## 3. Get your two keys

Supabase → **Settings → API**:

- **Project URL** → e.g. `https://abcd1234.supabase.co`
- **anon public** key (a long `eyJ…` string)

Create a file named `supabase.env` in the project root (it's git-ignored) by
copying `supabase.env.example`, and fill in:

```
SUPABASE_URL=https://abcd1234.supabase.co
SUPABASE_ANON_KEY=eyJhbGciOi...your-anon-key...
```

## 4. Run it on your computer (Chrome)

```powershell
./tool/run_web.ps1
```

Sign up / sign in, set a PIN, and you're in. Data is now saved in Supabase.

## 5. Build the web app

```powershell
./tool/build_web.ps1
```

Output lands in `build/web/`. To preview it locally:

```powershell
cd build/web
python -m http.server 8080
```

…then open `http://localhost:8080`.

## 6. Open it on your iPhone

Safari needs an **HTTPS** URL to log in reliably and to "Add to Home Screen".
Two easy options:

- **Same Wi-Fi, quick test:** run the preview server above and visit
  `http://<your-computer-ip>:8080` from Safari. (Logging in over plain HTTP can
  be flaky; HTTPS is recommended.)
- **Proper hosting (recommended):** upload the `build/web` folder to any static
  host that gives you HTTPS, e.g. drag-and-drop it onto
  [Netlify Drop](https://app.netlify.com/drop), or use Vercel / Cloudflare
  Pages / GitHub Pages. You'll get a `https://…` URL.

Then on the iPhone:

1. Open the HTTPS URL in **Safari**.
2. Tap the **Share** button → **Add to Home Screen**.

It now behaves like an app icon. Because the same Supabase database backs every
device, signing in on your phone shows the same data as on your computer.

---

### Notes

- The two keys are passed at build time via `--dart-define` and are **not**
  committed to git (`supabase.env` is ignored).
- The Supabase **anon** key is safe to ship in a web app — your data is
  protected by Row-Level Security and the user's login, not by hiding the key.
- To go back to on-device-only mode, just run `flutter run` without the
  dart-defines (or without `supabase.env`).
