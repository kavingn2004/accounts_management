# Building the iPhone app (signed `.ipa`) via Codemagic

iOS apps can only be built on macOS. We use **Codemagic** (cloud macOS) so you
don't need a Mac. You have an Apple Developer account, so we build a **signed
`.ipa`** installable on your iPhone / submittable to the App Store.

## 1. Push this repo to GitHub
```powershell
# create an empty repo on github.com first (e.g. accounts_app), then:
cd C:\Users\kavin\code\accounts_app
git remote add origin https://github.com/<your-user>/accounts_app.git
git push -u origin main
```

## 2. Bundle identifier
The app's bundle id is **`com.kavin.accounts`** (set in iOS, Android, and
`codemagic.yaml`). Register it with Apple:
- Apple Developer → Certificates, IDs & Profiles → Identifiers → new **App ID**
  `com.kavin.accounts`.
- App Store Connect → Apps → **+** → create the app with that bundle id.

## 3. Create an App Store Connect API key (for signing)
Apple Developer / App Store Connect → Users and Access → **Integrations / Keys**
→ generate an **App Store Connect API key**. Note the **Issuer ID**, **Key ID**,
and download the **`.p8`** file.

## 4. Connect Codemagic
1. Sign up at https://codemagic.io and add the app from your GitHub repo.
2. Team settings → **Integrations → App Store Connect** → add the API key
   (Issuer ID, Key ID, `.p8`). Name it **`CodemagicAppStore`** so it matches
   `codemagic.yaml` (`integrations.app_store_connect: CodemagicAppStore`).

## 5. Run the build
- In Codemagic, start the **`ios-release`** workflow (defined in `codemagic.yaml`).
- It runs `flutter build ipa` with automatic signing and produces a signed
  **`.ipa`** as a build artifact.

## 6. Get it onto your iPhone
- **TestFlight (recommended):** set the workflow to publish to App Store
  Connect, then install via the TestFlight app. Or
- **Ad-hoc:** set `distribution_type: ad_hoc` in `codemagic.yaml`, register your
  iPhone's UDID in your Apple account, and install the `.ipa` directly.

> Tip: for a first smoke test without any Apple setup, run the **`ios-unsigned`**
> workflow — it confirms the app compiles on macOS (Simulator only, not
> installable on a device).

## 7. Ask on the phone (optional)

The web build reaches its language model at `/api`, a relative path served by
`netlify/functions/ask-llm.mjs`. A relative path means nothing on a phone, so
the iOS build has to be given the absolute one — otherwise Ask quietly answers
every question from its keyword router.

Add the define to both `flutter build ios` lines in `codemagic.yaml`:

```yaml
script: |
  flutter build ios --release --no-codesign \
    --dart-define=ASK_LLM_URL=https://your-site.netlify.app/api
```

Leave it out and Ask still works — it just never uses a model. Never add
`ASK_LLM_KEY`: an `.ipa` is as readable as a web bundle, which is the whole
reason the key lives in the proxy.
