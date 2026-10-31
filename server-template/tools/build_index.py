#!/usr/bin/env python3
"""Generate index.json from songs/*.cho for the KOReader Songbook plugin.

Usage (from the repo root):  python3 tools/build_index.py
"updated" is a short content hash, so the plugin re-downloads a song
exactly when its file changes.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SONGS = ROOT / "songs"
DIRECTIVE = re.compile(r"^\s*\{\s*([\w-]+)\s*[:\s]\s*(.*?)\s*\}\s*$")
ALIASES = {"t": "title", "st": "subtitle"}
FIELDS = ("title", "artist", "key")


def read_meta(text: str) -> dict:
    meta = {}
    for line in text.splitlines():
        m = DIRECTIVE.match(line)
        if not m:
            continue
        name = ALIASES.get(m.group(1).lower(), m.group(1).lower())
        if name in FIELDS and name not in meta and m.group(2):
            meta[name] = m.group(2)
    return meta


def main() -> int:
    songs = []
    for path in sorted(SONGS.glob("*.cho")) + sorted(SONGS.glob("*.chopro")):
        raw = path.read_bytes()
        meta = read_meta(raw.decode("utf-8-sig"))
        if "title" not in meta:
            print(f"warning: {path.name} has no {{title}}", file=sys.stderr)
        songs.append({
            "id": path.stem,
            "title": meta.get("title", path.stem),
            **({"artist": meta["artist"]} if "artist" in meta else {}),
            **({"key": meta["key"]} if "key" in meta else {}),
            "file": f"songs/{path.name}",
            "updated": hashlib.sha1(raw).hexdigest()[:10],
        })
    songs.sort(key=lambda s: s["title"].casefold())
    out = ROOT / "index.json"
    out.write_text(json.dumps({"version": 1, "songs": songs}, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    print(f"index.json: {len(songs)} songs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
