"""Fetch Mixkit-licensed free stock music for Palm6 loadscreen (not Drake)."""
from __future__ import annotations

import json
import re
import ssl
import urllib.request
from pathlib import Path

OUT = Path(__file__).resolve().parent
CTX = ssl.create_default_context()

# Mixkit free stock music download IDs (hip-hop / night / cinematic vibes).
# License: Mixkit Stock Music Free License — personal & commercial OK.
CANDIDATES = [
    # id, filename, display title
    (738, "01-bay-pulse.mp3", "Bay Pulse — Mixkit"),
    (725, "02-night-drive.mp3", "Night Drive — Mixkit"),
    (506, "03-soft-grid.mp3", "Soft Grid — Mixkit"),
    (861, "04-city-roll.mp3", "City Roll — Mixkit"),
    (856, "05-after-hours.mp3", "After Hours — Mixkit"),
    (508, "06-slow-lane.mp3", "Slow Lane — Mixkit"),
]


def get(url: str) -> bytes:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; Palm6Loadscreen/0.9.7)",
            "Accept": "*/*",
        },
    )
    with urllib.request.urlopen(req, context=CTX, timeout=60) as resp:
        return resp.read()


def resolve_mp3(download_id: int) -> str | None:
    """Hit Mixkit download modal endpoint and pull an mp3 URL."""
    modal = f"https://mixkit.co/free-stock-music/download/{download_id}/?context=item+grid"
    try:
        html = get(modal).decode("utf-8", "ignore")
    except Exception as exc:
        print(f"  modal fail {download_id}: {exc}")
        return None
    # Common patterns in Mixkit pages / JSON embeds
    patterns = [
        r'https://assets\.mixkit\.co/[^"\']+\.mp3',
        r'"download_url"\s*:\s*"(https:[^"]+\.mp3)"',
        r'data-download-url="(https:[^"]+)"',
        r'href="(https://[^"]+\.mp3)"',
    ]
    for pat in patterns:
        m = re.search(pat, html)
        if m:
            return m.group(1) if m.lastindex else m.group(0)
    # Dump a hint for debugging
    if "mp3" in html.lower():
        print(f"  modal {download_id}: has mp3 text but no URL match ({len(html)} bytes)")
    else:
        print(f"  modal {download_id}: no mp3 in page ({len(html)} bytes)")
    return None


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    playlist = []
    for did, fname, title in CANDIDATES:
        dest = OUT / fname
        if dest.exists() and dest.stat().st_size > 50_000:
            print(f"skip exists {fname}")
            playlist.append({"file": f"assets/music/{fname}", "title": title})
            continue
        print(f"resolve {did} -> {fname}")
        url = resolve_mp3(did)
        if not url:
            continue
        print(f"  GET {url[:90]}...")
        try:
            data = get(url)
        except Exception as exc:
            print(f"  download fail: {exc}")
            continue
        if len(data) < 20_000:
            print(f"  too small ({len(data)}) — skip")
            continue
        dest.write_bytes(data)
        print(f"  wrote {fname} ({len(data)} bytes)")
        playlist.append({"file": f"assets/music/{fname}", "title": title})

    (OUT / "playlist.json").write_text(json.dumps(playlist, indent=2), encoding="utf-8")
    print("done", len(playlist), "tracks")


if __name__ == "__main__":
    main()
