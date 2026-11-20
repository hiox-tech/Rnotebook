#!/usr/bin/env python3
"""Verify pinned native editor dependencies without downloading or compiling."""
import hashlib
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
manifest = ROOT / 'ThirdParty/LanguageTools/manifest.sha256'
count = 0
for line in manifest.read_text().splitlines():
    digest, name = line.split('  ', 1)
    path = ROOT / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit('Language dependency missing or changed: ' + name)
    count += 1
print('Verified', count, 'pinned language-tool files')
