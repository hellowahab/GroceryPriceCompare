from __future__ import annotations

import httpx

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)


def build_client(timeout: float = 45.0, retries: int = 3) -> httpx.Client:
    """Shared HTTP client: user-agent, timeouts, transport-level retries."""
    transport = httpx.HTTPTransport(retries=retries)
    return httpx.Client(
        timeout=httpx.Timeout(timeout),
        transport=transport,
        headers={"User-Agent": UA},
        follow_redirects=True,
    )
