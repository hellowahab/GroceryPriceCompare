"""CLI: run ingestion and export artifacts.

Examples:
  python -m gpc.cli run --store al_jadeed,chase_up            # blink bulk (cheap)
  python -m gpc.cli run --watchlist --store bin_hashim,metro  # watch-term targeted fetch
  python -m gpc.cli run --store bin_hashim,metro --full       # full crawls (manual)
  python -m gpc.cli export                                    # re-export artifacts
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .adapters.base import StoreAdapter
from .adapters.blink import BlinkAdapter
from .adapters.metro import MetroAdapter
from .artifact import write_artifacts
from .config import load_config
from .http import build_client
from .store import Store


def _adapter_for(cfg) -> StoreAdapter:
    if cfg.platform == "blink":
        return BlinkAdapter(cfg, build_client())
    if cfg.platform == "metro":
        return MetroAdapter(cfg, build_client())
    raise ValueError(f"unknown platform: {cfg.platform}")


def cmd_run(args) -> int:
    config = load_config()
    codes = args.store or list(config)
    if args.store:
        codes = [c.strip() for c in args.store.split(",") if c.strip()]
    unknown = [c for c in codes if c not in config]
    if unknown:
        print(f"unknown stores: {', '.join(unknown)}", file=sys.stderr)
        return 2

    db = Store(args.db)
    try:
        for cfg in (config[c] for c in codes):
            db.upsert_store(cfg)
            for b in cfg.branches:
                db.upsert_branch(cfg.code, b.ext_id, b.name, b.city)
        db.commit()

        batch_id = db.begin_batch()
        stats = {}
        for code in codes:
            cfg = config[code]
            adapter = _adapter_for(cfg)
            count = 0
            if args.watchlist:
                search = getattr(adapter, "search_catalog", None)
                if cfg.watch_terms and search:
                    # Targeted fetch: only products matching configured watch terms.
                    for offer in adapter.search_catalog(cfg.watch_terms):
                        db.upsert_offer(offer, batch_id)
                        count += 1
                else:
                    # Fallback: refresh previously stored watchlist URLs.
                    for row in db.watchlist_offers(code):
                        offer = adapter.fetch_product(row["url"])
                        if offer:
                            db.upsert_offer(offer, batch_id)
                            count += 1
            else:
                for offer in adapter.fetch_catalog(full=args.full):
                    db.upsert_offer(offer, batch_id)
                    count += 1
            stats[code] = {"offers": count}
            print(f"{code}: {count} offers")
        db.end_batch(batch_id, "ok", stats)
        db.commit()
    except Exception as exc:  # noqa: BLE001
        try:
            db.end_batch(batch_id, "failed", {"error": str(exc)})
            db.commit()
        except Exception:  # noqa: BLE001
            pass
        raise

    if args.export:
        write_artifacts(args.db, Path(args.export))
        print(f"artifacts -> {args.export}")
    return 0


def cmd_export(args) -> int:
    manifest = write_artifacts(args.db, Path(args.export))
    print(f"manifest: {manifest['date']} stores={list(manifest['stores'])}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="gpc")
    sub = parser.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("run", help="fetch offers from stores into the DB")
    run.add_argument("--store", help="comma-separated store codes (default: all)")
    run.add_argument("--full", action="store_true",
                     help="allow expensive full crawls for sitemap-based stores")
    run.add_argument("--watchlist", action="store_true",
                     help="fetch only products matching each store's watch_terms")
    run.add_argument("--db", default="data/gpc.db")
    run.add_argument("--export", help="artifact output dir (optional)")
    run.set_defaults(func=cmd_run)

    exp = sub.add_parser("export", help="re-export artifacts from the DB")
    exp.add_argument("--db", default="data/gpc.db")
    exp.add_argument("--export", default="data/artifacts")
    exp.set_defaults(func=cmd_export)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
