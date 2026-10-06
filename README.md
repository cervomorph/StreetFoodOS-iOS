# StreetFoodOS — iOS app (App Store)

Thin **WKWebView shell** around the StreetFoodOS web app, with a native offline page cache and a Bluetooth hardware bridge (Star mPOP print + cash drawer). The product itself lives in the web layer; this repo holds only the native shell.

**Source of truth:** `docs/proposals/2026-10-06_ios-app-offline.md` in the main `StreetFoodOS` repo (private) — ratified 06/10/2026; P0–P5 build plan.

**Status (06/10/2026):** P0 groundwork — repo created; XcodeGen project spec, Swift sources and the CI pipeline land in the next build session. First milestone = first TestFlight build (proves the pipeline end-to-end).

## Ground rules

- **No Swift rewrite** — native code stays thin; all UI logic stays in the web layer (same model as `StreetFoodOS-Android`).
- Builds run on **cloud macOS CI only** (no Mac on the dev box). Provider flagged: GitHub Actions default, Codemagic alternative.
- **Secrets never touch the repo** — the App Store Connect API key (`.p8`) lives in CI secrets only.

## Not yet in this repo

- `project.yml` (XcodeGen), `Sources/` (app + bridges + offline cache), CI workflow, `Assets.xcassets` — P0 build session.
