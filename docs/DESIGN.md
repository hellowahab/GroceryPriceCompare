# Grocery Price Compare — Design

Personal, zero-cost Android price-comparison and recurring shopping assistant for
Pakistani supermarkets. Compares prices across **Al Jadeed**, **Bin Hashim**,
**Chase Up**, and **Metro**, tracks price history, and alerts on the user's
recurring shopping list.

## 1. Goals & non-goals

- **Goals**
  - Compare current prices for the same product across the 4 stores.
  - Maintain per-store price history (per branch / per store location).
  - Watchlist with recurring shopping items; alert on price drops.
  - Operate at **$0 cost** and degrade gracefully (no paid backend, no paid APIs).
- **Non-goals**
  - Placing orders / checkout integration.
  - Real-time prices (nightly is fine).
  - Coverage of every store nationwide (only the user's city/branch per store).

## 2. Stores & data sources (validated)

| Store | Host | Platform | rest_id | Branches | Full-catalog mechanism | Product count |
|---|---|---|---|---|---|---|
| Al Jadeed | aljadeed.pk | Blink Co. | 55232 | 5 | `GET /api/menu` (bulk, ~26 MB) | ~17,000 |
| Bin Hashim | binhashimonline.pk | Blink Co. | 55248 | 1 | `/api/menu` **500s** → sitemap + SSR product pages | ~10,000+ |
| Chase Up | chaseupgrocery.com | Blink Co. | 55525 | 15 | `GET /api/menu` (bulk, ~13.7 MB) | ~7,576 |
| Metro | metro-online.pk | Sitecore Next.js | — | per `storeId` | sitemap.xml → `/detail/{path}/{id}` SSR | ~10,875 |

Validation notes:
- Blink API calls require headers `Rest-Id`, `App-name` (e.g. `binhashimpharmacysupermarket`, `chaseup`); `Timezone: Asia/Karachi` optional. Without them → HTTP 400 `{"msg":"Please provide restaurant id!"}`.
- Blink menu JSON hierarchy: `data[]` (sections) → `all_section[]` → `all_sub_section[]` → `dish[]`. Prices are per branch (`restbrId`) and per `dishId`; `tp_product_code` carries the EAN barcode.
- Bin Hashim `/api/menu` returns HTTP 500 for all parameter variants probed (server-side). Its `menu-section` endpoint works, and product pages SSR full product data → sitemap crawl is the fallback.
- Metro detail pages embed the full product in `__NEXT_DATA__.props.pageProps.repo` with `price`, `sell_price`, `sale_price`, `mrp_price`, `brand_name`, `unit_type`, `available_stock`, `storeId`. `storeId` selects the store; prices vary per store.
- All four sources are **plain HTTP** (bulk JSON or SSR HTML). No browser needed; Playwright is a documented fallback only.

## 3. Deployment architecture (locked)

```
                    ┌────────────────────────────────────────────────────┐
                    │  GitHub Actions (cron, free tier)                  │
                    │                                                    │
  store sources ───►│  nightly: Blink full catalogs (1–2 req each)      │
  (plain HTTP)      │           + watchlist-only pages for Metro/BH      │
                    │  weekly:  Metro + Bin Hashim full sitemap crawls   │
                    └───────────────┬────────────────────────────────────┘
                                    │ normalized SQLite + JSON + deltas
                                    ▼
                    ┌────────────────────────────────────────────────────┐
                    │  gh-pages data branch (single-commit force-push)  │
                    │  served by GitHub Pages (static, free)            │
                    │  manifest.json · index.sqlite · products/{store}.json │
                    │  deltas/{date}/{store}.json                       │
                    └───────────────────────────────┬────────────────────┘
                                                    ▼
                    ┌────────────────────────────────────────────────────┐
                    │  Flutter app: local SQLite cache                   │
                    │  first-run: download index.sqlite                  │
                    │  subsequent: manifest + deltas merge               │
                    │  alerts computed client-side from local history   │
                    └────────────────────────────────────────────────────┘
```

### 3.1 Scheduler — GitHub Actions

| Workflow | Cron (UTC) | Work | Est. minutes/mo |
|---|---|---|---|
| `nightly` | `0 4 * * *` (~09:00 PKT) | Blink full catalogs (Al Jadeed, Chase Up, + Bin Hashim bulk retry) + watchlist-only refresh of Bin Hashim & Metro watchlist products | ~20–40 |
| `weekly` | `0 5 * * 0` | Bin Hashim + Metro full sitemap crawls (~22k pages, throttled) | ~120–240 |
| **Total** | | | ≤ **400 of 2,000 free** |

- Runner: `ubuntu-latest`. Python 3.12, `httpx` with retries/backoff and polite
  throttling (5–8 concurrent requests for page-based crawls).
- **No Playwright by default.** All sources are plain HTTP. Playwright is the
  documented fallback if a store starts client-rendering.

### 3.2 Artifact & hosting

- Normalized output is written to a dedicated `gh-pages` **data branch** as a
  **single commit, force-pushed** each run (branch deleted + recreated, or
  orphan-committed) so repository history stays small and Pages serves only the
  latest snapshot.
- Layout:
  ```
  manifest.json                 # schema_version, generated_at, per-store counts, sizes
  index.sqlite                  # full normalized snapshot (prices, offers, products, branches)
  products/{store_code}.json    # current offer + price rows per store (debug / fine-grained sync)
  deltas/{date}/{store_code}.json  # price changes since previous snapshot (app incremental sync)
  ```
- GitHub Pages is the default host (no extra account). Cloudflare Pages is an
  equivalent alternative via direct upload (`cloudflare/pages-action`) if preferred.
- Cost: **$0**. GitHub Actions free tier (2,000 min/mo), Pages static hosting.

### 3.3 Data size control

- Only *current prices* + *deltas* are published. Historical snapshots are
  reconstructed on-device from deltas; the app prunes its local history
  (e.g., keep changed-price points for 180 days, drop unchanged duplicates).
- Keeps the published `index.sqlite` ≈ 5–10 MB and app downloads tiny.

## 4. Adapter layer

```
StoreAdapter (abstract)
 ├── store_id: str
 ├── fetch_catalog() -> Iterator[RawEntry]     # streaming, resumable
 ├── raw_to_offer(entry) -> NormalizedOffer    # store schema -> canonical offer
 └── fetch_product(url) -> RawEntry            # single-product fetch (watchlist refresh)
```

### 4.1 BlinkAdapter — Al Jadeed, Bin Hashim, Chase Up

- Config per store: `rest_id`, `app_name`, `branch_ids` (user's nearest branch),
  `delivery_type=0`, headers `{Rest-Id, App-name, Timezone: Asia/Karachi}`.
- **Primary**: `GET {base}/api/menu?restId={r}&rest_brId={b}&delivery_type=0`
  → walk `data[] → all_section[] → all_sub_section[] → dish[]`.
- **Fallback** (Bin Hashim): `sitemap-products/{n}.xml` (3,000 URLs/page) →
  `GET /product/{slug}-{dishId}` → `__NEXT_DATA__.prefetchedItem.data[0]`.
  Full crawl ≈ 1 req/product; throttled; run weekly + watchlist-daily.
- **Bin Hashim bulk-retry policy**: try `/api/menu` every run (it may be
  transient); on 500 fall back to sitemap crawl.
- Branch policy: crawl only the user's branch per store to bound payloads
  (26 MB × branches would explode storage).

### 4.2 MetroAdapter — Metro

- `sitemap.xml` (3.1 MB, 12,787 URLs) → filter `/detail/` (grocery + `nf_shopping/detail`)
  → `GET /detail/{path}/{id}` → parse `__NEXT_DATA__.props.pageProps.repo`.
- `storeId` pinned to the user's Metro location (sample default was 10).
- Price mapping (**resolved on live data**): `sell_price` is the effective
  checkout price (sample: `sell_price=999`, `price=1999` list, `sale_price=1699`).
  `mrp_price`/`price` → `base_price`; `price - sell_price` → `discount_price`.

## 5. Normalized data model (SQLite)

```
store(id, code, name, platform, base_url, config_json)
branch(id, store_id, ext_id, name, city, lat, lng)              # rest_brId / storeId
product(id, brand, canonical_name, quantity, unit, ean, category_path, search_tokens)
store_offer(id, store_id, branch_id, ext_product_id, product_id?, name, slug, url,
            in_stock, raw_json)
price_snapshot(id, store_offer_id, price, base_price, discount_price, currency,
               collected_at, batch_id)                          # append-only history
fetch_batch(id, started_at, finished_at, status, per_store_stats_json)
watchlist(id, product_id, qty, target_price, enabled)
```

- `store_offer.product_id` is nullable until matched → ingestion never blocked by matching.
- `price_snapshot` append-only → history + drop alerts.

## 6. Cross-store matching

1. **EAN exact** — `tp_product_code` (Blink) vs Metro `product_code_app`/`article_mgb`
   (may be internal-only; Metro may lack real EANs → name matching).
2. **Name token matching** — normalize (case, brand stopwords, units), token sets,
   Jaccard/TF-IDF scoring with threshold → candidate list.
3. **User confirmation** — app shows candidates; confirmed pairs stored in
   `product_match` and reused (learning loop).

## 7. Risk register & validation checklist

| # | Risk | Mitigation | Status |
|---|---|---|---|
| 1 | Blink `/api/menu` blocked/geo-different from US GitHub runner | Early validation run from runner; `rest_brId` gates branch, IP not expected to matter | **validate first** |
| 2 | Bin Hashim `/api/menu` 500 | Retry each run; sitemap+SSR fallback designed | handled (verified single-product SSR parse) |
| 3 | Metro `sell_price` vs `sale_price` semantics | Resolved: `sell_price` is the effective price | **resolved** |
| 4 | Store HTML/API changes break parsers | Store `raw_json` per offer; schema-versioned parsers; fallback revalidation | by design |
| 5 | Artifact size / Pages quota | Deltas-only publishing + single-commit branch | by design |
| 6 | Rate limiting on page crawls | 5–8 concurrent, retry/backoff, robots.txt respected | by design |

## 8. Implementation phases

1. **Phase 1 — Ingest (this repo)**: Python package `ingest/` with adapters,
   normalizer, SQLite writer, artifact exporter, GH Actions workflows.
2. **Phase 2 — Validation on runner**: confirm payloads from `ubuntu-latest`
   (risk #1), confirm Metro price field (risk #3).
3. **Phase 3 — Flutter app**: local SQLite cache, manifest + delta sync,
   compare UI, watchlist, client-side alerts.

## 9. Repository layout

```
docs/DESIGN.md                  # this document
ingest/                         # Phase 1 ingestion pipeline (Python)
  pyproject.toml
  config/stores.json            # store/platform/branch configuration
  src/gpc/
    config.py                   # load stores.json
    model.py                    # normalized Offer dataclass
    http.py                     # shared httpx client (UA, retries)
    normalize.py                # raw entry -> Offer; name tokens
    store.py                    # SQLite schema + writer
    artifact.py                 # index.sqlite / products / deltas / manifest
    cli.py                      # run / export commands
    adapters/
      base.py                   # StoreAdapter ABC
      blink.py                  # Blink Co. (Al Jadeed, Bin Hashim, Chase Up)
      metro.py                  # Metro (Sitecore Next.js)
data/                           # gitignored: gpc.db + artifacts working copy
app/                            # Phase 3 Flutter app (later)
.github/workflows/
  nightly.yml                   # blink bulk catalogs + watchlist refresh
  weekly-full-crawl.yml         # Bin Hashim + Metro full crawls
```
