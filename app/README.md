# Grocery Price Compare — Flutter app

Android client for `GroceryPriceCompare` (compare prices across Al Jadeed, Bin
Hashim, Chase Up and Metro, track a shopping list, and get notified when a
watched item's price drops).

## Bootstrap (required once, before first build)

This repo intentionally does **not** commit generated platform boilerplate
(`android/`, `ios/`, `linux/`, `windows/`, `web/`). To create it:

```sh
flutter create . --project-name grocery_price_compare --platforms android
```

Run this inside `app/`. It will generate the Android project, keeping
`lib/`, `pubspec.yaml`, `test/` and `analysis_options.yaml` as they are.

## Build

```sh
flutter pub get
flutter build apk --release
```

The APK will be at `build/app/outputs/flutter-apk/app-release.apk`.

## Run tests

```sh
flutter test
```

## How it works

- On first launch the app downloads the manifest and per-store product JSON
  (`products/<store>.json`) from GitHub Pages
  (`https://hellowahab.github.io/GroceryPriceCompare/`) and seeds a local
  SQLite cache (`gpc_local.db`).
- On subsequent syncs it applies nightly `deltas/<date>/<store>.json` to bring
  prices up to date without re-downloading the full catalog.
- When a delta shows a price drop for a watched item, an alert is recorded and
  surfaced in the app bar notification badge.

## Layout

- `lib/main.dart` — app shell, watchlist, compare, and browse screens.
- `lib/src/models.dart` — Manifest / Offer / WatchItem / PriceDrop.
- `lib/src/matching.dart` — store names + fuzzy name matching (token Jaccard).
- `lib/src/local_db.dart` — sqflite cache, delta application, alerts.
- `lib/src/sync_service.dart` — GitHub Pages HTTP sync.
- `lib/src/state.dart` — app state (ChangeNotifier).

## Notes

- Prices are in Pakistani Rupees (PKR).
- Requires network on first launch; works offline afterwards with cached data.
