"""Metro (metro-online.pk, Sitecore Next.js) adapter.

sitemap.xml -> `/detail/{path}/{id}` product pages, each embedding the full
product in `__NEXT_DATA__.props.pageProps.repo`.
"""
from __future__ import annotations

import re
from typing import Iterator, Optional
from urllib.parse import urlsplit, urlunsplit

import httpx

from ..config import StoreCfg
from ..model import Offer
from ..normalize import offer_from_metro_repo
from .base import StoreAdapter
from .blink import extract_next_data

_SITEMAP_RE = re.compile(r"<loc>(.*?)</loc>")
# A raw '%' that is not part of a valid %XX escape (some sitemap URLs contain
# literal '%' in product slugs, e.g. "72%-100gm", which servers reject as 400).
_BAD_ESCAPE = re.compile(r"%(?![0-9a-fA-F]{2})")


def _fix_url(url: str) -> str:
    """Encode stray '%' as %25 while leaving valid %XX escapes untouched."""
    parts = urlsplit(url)
    path = _BAD_ESCAPE.sub("%25", parts.path)
    return urlunsplit(parts._replace(path=path))


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
            fixed = _fix_url(url)
            try:
                r = self.http.get(fixed)
                r.raise_for_status()
                repo = self._parse_product(r.text)
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code in (400, 403, 404, 405, 410):
                    print(f"skip {fixed}: HTTP {exc.response.status_code}")
                    continue
                raise
            if repo and repo.get("product_name"):
                yield offer_from_metro_repo(
                    repo, self.cfg.code, self.cfg.store_id or 0, fixed
                )

    def fetch_product(self, url: str) -> Optional[Offer]:
        fixed = _fix_url(url)
        r = self.http.get(fixed)
        r.raise_for_status()
        repo = self._parse_product(r.text)
        if not repo:
            return None
        return offer_from_metro_repo(repo, self.cfg.code, self.cfg.store_id or 0, fixed)
