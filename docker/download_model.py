"""Download one immutable model snapshot at image build time."""
import argparse
import hashlib
import json
from pathlib import Path

from huggingface_hub import snapshot_download

parser = argparse.ArgumentParser()
parser.add_argument("--name", required=True)
parser.add_argument("--repository", required=True)
parser.add_argument("--revision", required=True)
args = parser.parse_args()
target = Path("/models") / args.name
snapshot_download(
    args.repository, revision=args.revision, local_dir=target,
    allow_patterns=["*.pdiparams", "*.yml", "*.json", "*.py", "*.safetensors", "*.txt", "*.jinja", "*.model", "LICENSE*", "README.md"],
)
files = {}
for path in sorted(target.iterdir()):
    if path.is_file():
        with path.open("rb") as stream:
            files[path.name] = hashlib.file_digest(stream, "sha256").hexdigest()
if not any(name.endswith((".safetensors", ".pdiparams")) for name in files):
    raise RuntimeError("Model weights missing")
(target / "manifest.json").write_text(json.dumps({"repository": args.repository, "revision": args.revision, "sha256": files}, indent=2) + "\n")
