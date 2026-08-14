from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional


@dataclass
class Offer:
    """Normalized offer + current price for one store branch.

    `price` is the effective selling price; `base_price` the list/MRP price;
    `discount_price` the absolute discount when advertised.
    """
    store_code: str
    branch_id: str
    ext_product_id: str
    name: str
    price: Optional[float] = None
    base_price: Optional[float] = None
    discount_price: Optional[float] = None
    brand: Optional[str] = None
    ean: Optional[str] = None
    quantity: Optional[str] = None
    unit: Optional[str] = None
    category_path: Optional[str] = None
    description: Optional[str] = None
    slug: str = ""
    url: str = ""
    in_stock: Optional[bool] = None
    raw: dict[str, Any] = field(default_factory=dict)
