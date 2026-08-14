"""Metro (metro-online.pk, Sitecore Next.js) adapter.

sitemap.xml -> `/detail/{path}/{id}` product pages, each embedding the full
product in `__NEXT_DATA__.props.pageProps.repo`.
"""
from __future__ import annotations

import json
import re
from typing import Iterator, Optional

import httpx

from ..config import StoreCfg
from ..model import Offer
from ..normalize import offer_from_metro_repo
from .base import StoreAdapter
from .blink import extract_next_data

_SITEMAP_RE = re.compile(r"<loc>(.*?)</loc>")


class MetroAdapter(StoreAdapter):
    platform = "metro"

    def _sitemap_urls(self) -> list[str]:
        r = self.http.get(f"{self.cfg.base_url}/sitemap.xml")
        r.raise_for_status()
        return [u for u in _SITEMAP_RE.findall(r.text) if "/detail/" in u]

    def _parse_product(self, html: str) -> Optional[dict]:
        data = extract_next_data(html)
        return data.get("props", {}).get("pageProps", {}).get("repo")

    def fetch_catalog(self, full: bool) -> Iterator[Offer]:
        urls = self._sitemap_urls()
        for url in urls:
            r = self.http.get(url)
            r.raise_for_status()
            repo = self._parse_product(r.text)
            if repo and repo.get("product_name"):
                yield offer_from_metro_repo(
                    repo, self.cfg.code, self.cfg.store_id or 0, url
                )

    def fetch_product(self, url: str) -> Optional[Offer]:
        r = self.http.get(url)
        r.raise_for_status()
        repo = self._parse_product(r.text)
        if not repo:
            return None
        return offer_from_metro_repo(repo, self.cfg.code, self.cfg.store_id or 0, url)
