"""Raw entry -> normalized Offer, plus name-normalization helpers for matching."""
from __future__ import annotations

import re
from typing import Any, Optional

from .model import Offer

_DIGITS_ONLY = re.compile(r"[^0-9]")
_EAN_LENGTHS = {8, 12, 13, 14}


def _to_float(v: Any) -> Optional[float]:
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _strip(s: Any) -> str:
    return "" if s is None else str(s).strip()


def _clean_ean(code: Any) -> Optional[str]:
    """Return code as EAN only if it is a plausible barcode (8/12/13/14 digits)."""
    s = _strip(code)
    if not s:
        return None
    digits = _DIGITS_ONLY.sub("", s)
    if len(digits) in _EAN_LENGTHS and digits.isdigit():
        return digits
    return None


def offer_from_blink_dish(dish: dict, store_code: str, branch_id: str) -> Offer:
    """Map a Blink Co. `dish[]` entry to a normalized Offer."""
    ean = _clean_ean(dish.get("tp_product_code"))
    cat = " > ".join(
        _strip(dish.get(k))
        for k in ("category_name", "sub_category_name", "sub_sub_Category_name")
        if _strip(dish.get(k))
    )
    stock = dish.get("dish_branch_stock") or {}
    in_stock = None
    if isinstance(stock, dict) and "stock" in stock:
        in_stock = stock.get("stock") not in (None, 0)
    elif isinstance(stock, list) and stock:
        in_stock = stock[0].get("stock") not in (None, 0)

    offer = Offer(
        store_code=store_code,
        branch_id=branch_id,
        ext_product_id=str(dish.get("id") or ""),
        name=_strip(dish.get("name")),
        price=_to_float(dish.get("price")),
        base_price=_to_float(dish.get("base_price")) or _to_float(dish.get("price")),
        discount_price=_to_float(dish.get("discount_price")),
        brand=_strip(dish.get("brand_name")) or None,
        ean=ean,
        category_path=cat or None,
        description=_strip(dish.get("desc")) or None,
        slug=_strip(dish.get("slug")),
        url="",
        in_stock=in_stock,
    )
    offer.raw = {
        "id": dish.get("id"),
        "tp_product_code": dish.get("tp_product_code"),
        "restbrId": dish.get("restbrId"),
        "availability": dish.get("availability"),
        "status": dish.get("status"),
        "isdeal": dish.get("isdeal"),
        "stock": dish.get("stock"),
    }
    if dish.get("restId"):
        offer.raw["restId"] = dish.get("restId")
    return offer


def offer_from_blink_ssr_product(data: dict, store_code: str, url: str) -> Offer:
    """Map the product object embedded in a Blink SSR product page."""
    ean = _clean_ean(data.get("tp_product_code"))
    offer = Offer(
        store_code=store_code,
        branch_id=str(data.get("restbrId") or ""),
        ext_product_id=str(data.get("id") or ""),
        name=_strip(data.get("name")),
        price=_to_float(data.get("price")),
        base_price=_to_float(data.get("base_price")) or _to_float(data.get("price")),
        discount_price=_to_float(data.get("discount_price")),
        brand=_strip(data.get("brand_name")) or None,
        ean=ean,
        category_path=_strip(data.get("category_name")) or None,
        description=_strip(data.get("desc")) or None,
        slug=_strip(data.get("slug")),
        url=url,
        in_stock=None,
    )
    offer.raw = {
        "id": data.get("id"),
        "tp_product_code": data.get("tp_product_code"),
        "restbrId": data.get("restbrId"),
        "availability": data.get("availability"),
    }
    return offer


def offer_from_metro_repo(repo: dict, store_code: str, store_id: int, url: str) -> Offer:
    """Map a Metro `__NEXT_DATA__.props.pageProps.repo` object to an Offer.

    Price semantics (see DESIGN.md risk #3): the checkout price is taken from the
    configurable price field, default `sell_price`; `price` is treated as list price.
    """
    price = _to_float(repo.get("sell_price")) or _to_float(repo.get("price"))
    mrp = _to_float(repo.get("mrp_price")) or _to_float(repo.get("price"))
    sale = _to_float(repo.get("sale_price"))
    ean = _clean_ean(repo.get("product_code_app")) or _clean_ean(repo.get("article_mgb"))

    path = url.split("/detail/", 1)[1] if "/detail/" in url else ""
    category_path = "/".join(path.split("/")[:-2]) if path else None

    offer = Offer(
        store_code=store_code,
        branch_id=str(store_id),
        ext_product_id=str(repo.get("product_code_app") or repo.get("id") or ""),
        name=_strip(repo.get("product_name")),
        price=price,
        base_price=mrp,
        discount_price=(mrp - price) if (mrp and price and sale) else (sale or None),
        brand=_strip(repo.get("brand_name")) or None,
        ean=ean,
        quantity=None,
        unit=_strip(repo.get("unit_type")) or None,
        category_path=category_path,
        description=_strip(repo.get("description")) or None,
        slug=_strip(repo.get("seo_url_slug")),
        url=url,
        in_stock=bool(repo.get("available_stock")),
    )
    offer.raw = {
        "id": repo.get("id"),
        "product_code_app": repo.get("product_code_app"),
        "article_mgb": repo.get("article_mgb"),
        "price": repo.get("price"),
        "sell_price": repo.get("sell_price"),
        "sale_price": repo.get("sale_price"),
        "mrp_price": repo.get("mrp_price"),
        "storeId": repo.get("storeId"),
        "stock_type": repo.get("stock_type"),
        "is_offer": repo.get("is_offer"),
    }
    return offer


_WORD = re.compile(r"[a-z0-9]+")


def name_tokens(name: str) -> list[str]:
    """Normalize a product name to a sorted token list (for cross-store matching)."""
    low = _strip(name).lower()
    tokens = sorted(set(_WORD.findall(low)))
    return tokens


def canonical_name(name: str) -> str:
    """Collapse whitespace, lowercase — used for product identity fallback."""
    return " ".join(_strip(name).lower().split())


def slug_tokens(url: str) -> set[str]:
    """Content tokens from the tail of a product URL (slug segments only).

    Category path segments are excluded so a term like "olpers milk" cannot
    match "olpers cream" just because it sits in the milk category.
    """
    from urllib.parse import urlsplit

    segs = [s for s in urlsplit(url).path.split("/") if s]
    toks: set[str] = set()
    for seg in segs[-2:]:
        toks.update(t for t in _WORD.findall(seg.lower()) if not t.isdigit())
    return toks


def term_token_sets(terms: list[str]) -> list[set[str]]:
    """Tokenize watch terms; empty sets dropped, digits ignored."""
    out = []
    for term in terms:
        ts = {t for t in name_tokens(term) if not t.isdigit()}
        if ts:
            out.append(ts)
    return out


def matches_any_term(url: str, term_sets: list[set[str]]) -> bool:
    """True if the URL slug contains every token of any single watch term."""
    st = slug_tokens(url)
    return any(ts <= st for ts in term_sets)
