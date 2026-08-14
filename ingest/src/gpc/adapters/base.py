"""Store adapter interface."""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Iterator, Optional

import httpx

from ..config import StoreCfg
from ..model import Offer


class StoreAdapter(ABC):
    platform = ""

    def __init__(self, cfg: StoreCfg, http: httpx.Client):
        self.cfg = cfg
        self.http = http

    @abstractmethod
    def fetch_catalog(self, full: bool) -> Iterator[Offer]:
        """Yield all current offers.

        `full=True` may perform an expensive complete crawl (sitemap stores);
        `full=False` should attempt only the cheap primary path and skip the rest.
        """
        raise NotImplementedError

    def fetch_product(self, url: str) -> Optional[Offer]:
        """Single-offer refresh for watchlist maintenance (optional)."""
        raise NotImplementedError
