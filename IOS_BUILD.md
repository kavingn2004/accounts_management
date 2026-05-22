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

## 2. Pick your bundle identifier
The app currently uses `com.example.accounts.accountsApp`. App Store needs a
unique ID under your own domain, e.g. `com.kavin.accounts`.
- Change it in `ios/Runner.xcodeproj/project.pbxproj` (all 3
  `PRODUCT_BUNDLE_IDENTIFIER` lines) **and** in `codemagic.yaml`
  (`ios_signing.bundle_identifier`).
- Register it: Apple Developer → Certificates, IDs & Profiles → Identifiers →
  new **App ID** with that bundle id.
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
