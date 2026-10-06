# StreetFoodOS — iOS app (App Store)

Thin **WKWebView shell** around the StreetFoodOS web app, with a native offline page cache and a Bluetooth hardware bridge (Star mPOP print + cash drawer). The product itself lives in the web layer; this repo holds only the native shell.

**Source of truth:** `docs/proposals/2026-10-06_ios-app-offline.md` in the main `StreetFoodOS` repo (private) — ratified 06/10/2026; P0–P5 build plan.

**Status (06/10/2026):** **P0 ✅** — XcodeGen spec, WKWebView shell sources and CI (GitHub Actions: `Build check` + `TestFlight` workflows) are in and green; **first TestFlight build uploaded** (App Store Connect, Apple processing) — the pipeline is proven end-to-end. Repo lives in the `cervomorph` org.

## Ground rules

- **No Swift rewrite** — native code stays thin; all UI logic stays in the web layer (same model as `StreetFoodOS-Android`).
- Builds run on **cloud macOS CI only** (no Mac on the dev box). Provider flagged: GitHub Actions default, Codemagic alternative.
- **Secrets never touch the repo** — the App Store Connect API key (`.p8`) lives in CI secrets only.

## Build pipeline

- **Build check** — compile-only run (signing disabled) on every push to `main`.
- **TestFlight** — manual dispatch (or `v*` tag): archive → cloud signing → upload. Needs the `ASC_*` repo secrets (App Store Connect API key); cloud signing requires the key to have the Admin role.
