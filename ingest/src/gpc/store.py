"""SQLite persistence: schema, upserts, price-snapshot dedupe, batches."""
from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from .config import StoreCfg
from .model import Offer
from .normalize import canonical_name, name_tokens

_SCHEMA = """
CREATE TABLE IF NOT EXISTS store(
  code TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  base_url TEXT,
  config_json TEXT
);
CREATE TABLE IF NOT EXISTS branch(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  store_code TEXT NOT NULL REFERENCES store(code),
  ext_id TEXT NOT NULL,
  name TEXT,
  city TEXT,
  UNIQUE(store_code, ext_id)
);
CREATE TABLE IF NOT EXISTS product(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ean TEXT,
  brand TEXT,
  canonical_name TEXT NOT NULL,
  quantity TEXT,
  unit TEXT,
  category_path TEXT,
  search_tokens TEXT,
  UNIQUE(ean)
);
CREATE TABLE IF NOT EXISTS store_offer(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  store_code TEXT NOT NULL,
  branch_id INTEGER NOT NULL,
  ext_product_id TEXT NOT NULL,
  product_id INTEGER,
  name TEXT NOT NULL,
  slug TEXT,
  url TEXT,
  description TEXT,
  in_stock INTEGER,
  raw_json TEXT,
  UNIQUE(store_code, branch_id, ext_product_id)
);
CREATE TABLE IF NOT EXISTS price_snapshot(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  store_offer_id INTEGER NOT NULL,
  price REAL,
  base_price REAL,
  discount_price REAL,
  currency TEXT DEFAULT 'PKR',
  collected_at TEXT NOT NULL,
  batch_id INTEGER
);
CREATE INDEX IF NOT EXISTS idx_snapshot_offer ON price_snapshot(store_offer_id, id);
CREATE TABLE IF NOT EXISTS fetch_batch(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at TEXT,
  finished_at TEXT,
  status TEXT,
  stats_json TEXT
);
CREATE TABLE IF NOT EXISTS product_match(
  product_id INTEGER,
  store_code TEXT,
  store_offer_id INTEGER,
  confirmed INTEGER DEFAULT 0,
  PRIMARY KEY(product_id, store_offer_id)
);
CREATE TABLE IF NOT EXISTS watchlist(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  product_id INTEGER NOT NULL,
  qty INTEGER DEFAULT 1,
  target_price REAL,
  enabled INTEGER DEFAULT 1
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class Store:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self.path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.executescript(_SCHEMA)
        self.conn.commit()

    def close(self):
        self.conn.close()

    # ---- stores / branches ----
    def upsert_store(self, cfg: StoreCfg):
        import dataclasses

        self.conn.execute(
            "INSERT INTO store(code, name, platform, base_url, config_json) "
            "VALUES(?,?,?,?,?) "
            "ON CONFLICT(code) DO UPDATE SET "
            "name=excluded.name, platform=excluded.platform, "
            "base_url=excluded.base_url, config_json=excluded.config_json",
            (cfg.code, cfg.name, cfg.platform, cfg.base_url,
             json.dumps(dataclasses.asdict(cfg))),
        )

    def upsert_branch(self, store_code: str, ext_id: str, name: str, city: str = "") -> int:
        self.conn.execute(
            "INSERT INTO branch(store_code, ext_id, name, city) VALUES(?,?,?,?) "
            "ON CONFLICT(store_code, ext_id) DO UPDATE SET "
            "name=excluded.name, city=excluded.city",
            (store_code, ext_id, name, city),
        )
        row = self.conn.execute(
            "SELECT id FROM branch WHERE store_code=? AND ext_id=?",
            (store_code, ext_id),
        ).fetchone()
        return row["id"]

    # ---- batches ----
    def begin_batch(self) -> int:
        cur = self.conn.execute(
            "INSERT INTO fetch_batch(started_at, status) VALUES(?, 'running')",
            (_now(),),
        )
        self.conn.commit()
        return cur.lastrowid

    def end_batch(self, batch_id: int, status: str, stats: dict):
        self.conn.execute(
            "UPDATE fetch_batch SET finished_at=?, status=?, stats_json=? WHERE id=?",
            (_now(), status, json.dumps(stats), batch_id),
        )
        self.conn.commit()

    # ---- offers ----
    def _get_or_create_product(self, offer: Offer) -> int:
        if offer.ean:
            row = self.conn.execute(
                "SELECT id FROM product WHERE ean=?", (offer.ean,)
            ).fetchone()
            if row:
                return row["id"]
            cur = self.conn.execute(
                "INSERT INTO product(ean, brand, canonical_name, quantity, unit, "
                "category_path, search_tokens) VALUES(?,?,?,?,?,?,?)",
                (offer.ean, offer.brand, canonical_name(offer.name),
                 offer.quantity, offer.unit, offer.category_path,
                 json.dumps(name_tokens(offer.name))),
            )
            return cur.lastrowid
        name = canonical_name(offer.name)
        row = self.conn.execute(
            "SELECT id FROM product WHERE canonical_name=? ORDER BY id LIMIT 1",
            (name,),
        ).fetchone()
        if row:
            return row["id"]
        cur = self.conn.execute(
            "INSERT INTO product(ean, brand, canonical_name, quantity, unit, "
            "category_path, search_tokens) VALUES(NULL,?,?,?,?,?,?)",
            (offer.brand, name, offer.quantity, offer.unit, offer.category_path,
             json.dumps(name_tokens(offer.name))),
        )
        return cur.lastrowid

    def upsert_offer(self, offer: Offer, batch_id: int) -> int:
        product_id = self._get_or_create_product(offer)
        self.conn.execute(
            "INSERT INTO store_offer(store_code, branch_id, ext_product_id, product_id, "
            "name, slug, url, description, in_stock, raw_json) "
            "VALUES(?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(store_code, branch_id, ext_product_id) DO UPDATE SET "
            "product_id=excluded.product_id, name=excluded.name, slug=excluded.slug, "
            "url=excluded.url, description=excluded.description, "
            "in_stock=excluded.in_stock, raw_json=excluded.raw_json",
            (offer.store_code, offer.branch_id, offer.ext_product_id, product_id,
             offer.name, offer.slug, offer.url, offer.description,
             (1 if offer.in_stock else 0) if offer.in_stock is not None else None,
             json.dumps(offer.raw, ensure_ascii=False)[:4000]),
        )
        # lastrowid is unreliable on the ON CONFLICT DO UPDATE path; resolve by key.
        row = self.conn.execute(
            "SELECT id FROM store_offer WHERE store_code=? AND branch_id=? "
            "AND ext_product_id=?",
            (offer.store_code, offer.branch_id, offer.ext_product_id),
        ).fetchone()
        offer_id = row["id"]
        self._insert_snapshot_if_changed(offer_id, offer, batch_id)
        return offer_id

    def _insert_snapshot_if_changed(self, offer_id: int, offer: Offer, batch_id: int):
        last = self.conn.execute(
            "SELECT price, base_price, discount_price FROM price_snapshot "
            "WHERE store_offer_id=? ORDER BY id DESC LIMIT 1",
            (offer_id,),
        ).fetchone()
        current = (offer.price, offer.base_price, offer.discount_price)
        if last is not None and tuple(last) == current:
            return
        self.conn.execute(
            "INSERT INTO price_snapshot(store_offer_id, price, base_price, "
            "discount_price, collected_at, batch_id) VALUES(?,?,?,?,?,?)",
            (offer_id, offer.price, offer.base_price, offer.discount_price,
             _now(), batch_id),
        )

    def commit(self):
        self.conn.commit()

    # ---- watchlist ----
    def watchlist_offers(self, store_code: str) -> list[dict]:
        """Offers linked to watchlist products for a store (URLs for refresh)."""
        rows = self.conn.execute(
            "SELECT so.id, so.url FROM store_offer so "
            "JOIN watchlist w ON w.product_id = so.product_id "
            "WHERE so.store_code=? AND w.enabled=1 AND so.url != ''",
            (store_code,),
        ).fetchall()
        return [dict(r) for r in rows]
