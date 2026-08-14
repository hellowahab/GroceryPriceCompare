"""Blink Co. ordering-platform adapter (Al Jadeed, Bin Hashim, Chase Up).

Primary: bulk `GET /api/menu` -> nested JSON (data[] -> all_section[] ->
all_sub_section[] -> dish[]).
Fallback: product sitemap + SSR product pages (`__NEXT_DATA__.prefetchedItem`).
Requires headers Rest-Id / App-name / Timezone.
"""
from __future__ import annotations

import json
import re
from typing import Any, Iterator, Optional

import httpx

from ..config import StoreCfg
from ..model import Offer
from ..normalize import offer_from_blink_dish, offer_from_blink_ssr_product
from .base import StoreAdapter

_SITEMAP_RE = re.compile(r"<loc>(.*?)</loc>")
_NEXT_DATA_RE = re.compile(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', re.S
)


def iter_dishes(node: Any) -> Iterator[dict]:
    """Recursively find dish entries anywhere in the menu JSON tree."""
    if isinstance(node, dict):
        if "tp_product_code" in node and "price" in node and "slug" in node and "name" in node:
            yield node
            return
        for value in node.values():
            yield from iter_dishes(value)
    elif isinstance(node, list):
        for value in node:
            yield from iter_dishes(value)


def extract_next_data(html: str) -> dict:
    m = _NEXT_DATA_RE.search(html)
    if not m:
        return {}
    try:
        return json.loads(m.group(1))
    except json.JSONDecodeError:
        return {}


class BlinkAdapter(StoreAdapter):
    platform = "blink"

    def __init__(self, cfg: StoreCfg, http: httpx.Client):
        super().__init__(cfg, http)
        self.headers = {
            "Rest-Id": str(cfg.rest_id or ""),
            "App-name": cfg.app_name or cfg.code,
            "Timezone": "Asia/Karachi",
        }

    def _menu_url(self, branch_id: str) -> str:
        return (
            f"{self.cfg.base_url}/api/menu"
            f"?restId={self.cfg.rest_id}&rest_brId={branch_id}&delivery_type=0"
        )

    def fetch_menu_bulk(self, branch_id: str) -> list[dict]:
        r = self.http.get(self._menu_url(branch_id), headers=self.headers)
        r.raise_for_status()
        return list(iter_dishes(r.json()))

    def _sitemap_urls(self) -> Iterator[str]:
        index = 1
        while True:
            url = f"{self.cfg.base_url}/sitemap-products/{index}.xml"
            r = self.http.get(url, headers=self.headers)
            if r.status_code == 404:
                break
            r.raise_for_status()
            locs = _SITEMAP_RE.findall(r.text)
            if not locs:
                break
            yield from locs
            index += 1

    def _crawl_sitemap(self) -> Iterator[dict]:
        for url in self._sitemap_urls():
            r = self.http.get(url, headers=self.headers)
            r.raise_for_status()
            data = extract_next_data(r.text)
            prefetched = (
                data.get("props", {}).get("pageProps", {}).get("prefetchedItem") or {}
            ).get("data")
            if isinstance(prefetched, list) and prefetched:
                yield prefetched[0]
            elif isinstance(prefetched, dict):
                yield prefetched

    def fetch_catalog(self, full: bool) -> Iterator[Offer]:
        for br in self.cfg.branches:
            dishes = None
            try:
                dishes = self.fetch_menu_bulk(br.ext_id)
            except httpx.HTTPStatusError:
                if not (full and self.cfg.menu_fetch in ("bulk_or_sitemap", "sitemap")):
                    continue
                dishes = list(self._crawl_sitemap())
            if dishes:
                for d in dishes:
                    yield offer_from_blink_dish(d, self.cfg.code, br.ext_id)

    def fetch_product(self, url: str) -> Optional[Offer]:
        r = self.http.get(url, headers=self.headers)
        r.raise_for_status()
        data = extract_next_data(r.text)
        prefetched = (
            data.get("props", {}).get("pageProps", {}).get("prefetchedItem") or {}
        ).get("data")
        if isinstance(prefetched, list) and prefetched:
            prefetched = prefetched[0]
        if not isinstance(prefetched, dict) or "name" not in prefetched:
            return None
        return offer_from_blink_ssr_product(prefetched, self.cfg.code, url)
