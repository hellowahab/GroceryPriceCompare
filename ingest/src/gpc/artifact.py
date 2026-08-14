"""Export a publishable static artifact set from the SQLite store.

Output layout (served via GitHub Pages):
  manifest.json
  index.sqlite
  products/{store_code}.json
  deltas/{date}/{store_code}.json
"""
from __future__ import annotations

import json
import shutil
import sqlite3
from datetime import date, datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1


def _last_price_by_offer(conn: sqlite3.Connection) -> dict[int, tuple]:
    """offer_id -> (price, base_price, discount_price, collected_at)."""
    rows = conn.execute(
        """
        SELECT ps.store_offer_id, ps.price, ps.base_price, ps.discount_price,
               ps.collected_at
        FROM price_snapshot ps
        JOIN (
            SELECT store_offer_id, MAX(id) AS mid
            FROM price_snapshot GROUP BY store_offer_id
        ) m ON m.store_offer_id = ps.store_offer_id AND ps.id = m.mid
        """
    ).fetchall()
    return {r["store_offer_id"]: tuple(r) for r in rows}


def _price_changes(conn: sqlite3.Connection) -> dict[int, tuple]:
    """offer_id -> (old_price, new_price) for offers seen in >=2 batches
    whose latest snapshot price differs from the previous one."""
    rows = conn.execute(
        """
        SELECT store_offer_id, price,
               COUNT(*) OVER (PARTITION BY store_offer_id) AS n,
               ROW_NUMBER() OVER (PARTITION BY store_offer_id ORDER BY id DESC) AS rn
        FROM price_snapshot
        ORDER BY store_offer_id, id ASC
        """
    ).fetchall()
    changes = {}
    for r in rows:
        if r["n"] < 2:
            continue
        if r["rn"] == 2:
            changes[r["store_offer_id"]] = (r["price"], None)
        elif r["rn"] == 1 and r["store_offer_id"] in changes:
            old, _ = changes[r["store_offer_id"]]
            if old != r["price"]:
                changes[r["store_offer_id"]] = (old, r["price"])
    return changes


def _new_offers(conn: sqlite3.Connection) -> set[int]:
    rows = conn.execute(
        """
        SELECT store_offer_id FROM price_snapshot
        GROUP BY store_offer_id HAVING COUNT(*) = 1
        """
    ).fetchall()
    return {r["store_offer_id"] for r in rows}


def write_artifacts(db_path: Path, out_dir: Path, run_date: date | None = None) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    run_date = run_date or datetime.now(timezone.utc).date()
    db_path = Path(db_path)

    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        last_price = _last_price_by_offer(conn)
        changes = _price_changes(conn)
        new_offers = _new_offers(conn)

        offers = conn.execute(
            "SELECT so.id, so.store_code, so.ext_product_id, so.name, so.slug, "
            "so.url, so.in_stock, so.product_id, p.brand, p.ean "
            "FROM store_offer so LEFT JOIN product p ON p.id = so.product_id"
        ).fetchall()

        per_store: dict[str, list[dict]] = {}
        for r in offers:
            price = last_price.get(r["id"])
            per_store.setdefault(r["store_code"], []).append(
                {
                    "offer_id": r["id"],
                    "ext_product_id": r["ext_product_id"],
                    "product_id": r["product_id"],
                    "name": r["name"],
                    "brand": r["brand"],
                    "ean": r["ean"],
                    "slug": r["slug"],
                    "url": r["url"],
                    "in_stock": r["in_stock"],
                    "price": price[1] if price else None,
                    "base_price": price[2] if price else None,
                    "discount_price": price[3] if price else None,
                    "collected_at": price[4] if price else None,
                }
            )

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "date": run_date.isoformat(),
        "stores": {},
    }

    products_dir = out_dir / "products"
    products_dir.mkdir(parents=True, exist_ok=True)
    for code, rows in per_store.items():
        with (products_dir / f"{code}.json").open("w", encoding="utf-8") as f:
            json.dump(rows, f, ensure_ascii=False)
        changed = sum(1 for r in rows if changes.get(r["offer_id"]))
        manifest["stores"][code] = {
            "offers": len(rows),
            "with_price": sum(1 for r in rows if r["price"] is not None),
            "changed": changed,
            "new": sum(1 for r in rows if r["offer_id"] in new_offers),
            "file": f"products/{code}.json",
        }

    delta_dir = out_dir / "deltas" / run_date.isoformat()
    delta_dir.mkdir(parents=True, exist_ok=True)
    for code, rows in per_store.items():
        deltas = []
        for r in rows:
            ch = changes.get(r["offer_id"])
            if ch:
                deltas.append(
                    {
                        "offer_id": r["offer_id"],
                        "old_price": ch[0],
                        "new_price": ch[1],
                        "in_stock": r["in_stock"],
                    }
                )
        with (delta_dir / f"{code}.json").open("w", encoding="utf-8") as f:
            json.dump(deltas, f, ensure_ascii=False)

    index_path = out_dir / "index.sqlite"
    # Checkpoint WAL so the copied file is a complete, standalone snapshot.
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    shutil.copy2(db_path, index_path)
    manifest["files"] = {
        "index_sqlite_bytes": index_path.stat().st_size,
        "deltas_dir": f"deltas/{run_date.isoformat()}/",
    }

    with (out_dir / "manifest.json").open("w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    return manifest
