from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class BranchCfg:
    ext_id: str
    name: str = ""
    city: str = ""


@dataclass
class StoreCfg:
    code: str
    name: str
    platform: str
    base_url: str
    rest_id: Optional[int] = None
    app_name: Optional[str] = None
    store_id: Optional[int] = None
    menu_fetch: str = "bulk"
    branches: list[BranchCfg] = field(default_factory=list)

    def branch(self, ext_id: str) -> Optional[BranchCfg]:
        for b in self.branches:
            if b.ext_id == ext_id:
                return b
        return None


def load_config(path: Optional[Path] = None) -> dict[str, StoreCfg]:
    path = path or default_config_path()
    data = json.loads(path.read_text(encoding="utf-8"))
    stores = {}
    for s in data["stores"]:
        stores[s["code"]] = StoreCfg(
            code=s["code"],
            name=s["name"],
            platform=s["platform"],
            base_url=s["base_url"],
            rest_id=s.get("rest_id"),
            app_name=s.get("app_name"),
            store_id=s.get("store_id"),
            menu_fetch=s.get("menu_fetch", "bulk"),
            branches=[BranchCfg(**b) for b in s.get("branches", [])],
        )
    return stores


def default_config_path() -> Path:
    env = os.environ.get("GPC_CONFIG")
    if env:
        return Path(env)
    # ingest/src/gpc/config.py -> ingest/config/stores.json
    return Path(__file__).resolve().parents[2] / "config" / "stores.json"
