"""Fetch pinned local matching weights at build time, never during startup."""

import hashlib
from pathlib import Path
from urllib.request import urlopen

root = Path('/models/logo-matching/hub/checkpoints')
root.mkdir(parents=True, exist_ok=True)
for name, remote, digest in [
    ('superpoint_v1.pth', 'superpoint_v1.pth', '52b6708629640ca883673b5d5c097c4ddad37d8048b33f09c8ca0d69db12c40e'),
    (
        'superpoint_lightglue_v0-1_arxiv.pth',
        'superpoint_lightglue.pth',
        '6ff7040d0a497fc6639337946d7538dae07428c18f77a067a0b5a960e7cc551a',
    ),
]:
    data = urlopen('https://github.com/cvg/LightGlue/releases/download/v0.1_arxiv/' + remote, timeout=120).read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise RuntimeError('Logo model checksum mismatch: ' + name)
    (root / name).write_bytes(data)
