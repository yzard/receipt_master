"""Serial, read-only image-to-JSON candidate evaluation; never sends gold item values."""

import argparse
import base64
import hashlib
import io
import json
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[2]
PROMPTS = ROOT / "docker/defaults/prompt.toml"


def prompt_for(store):
    config = tomllib.loads(PROMPTS.read_text())
    normalize = lambda text: "".join(c for c in text.lower() if c.isalnum())
    parts = [row["prompt"] for row in config["general"]]
    for row in config.get("store", []):
        if normalize(store) in {
            normalize(name) for name in [row["name"], *row.get("aliases", [])]
        }:
            parts.append(row["prompt"])
            break
    return "\n\n".join(parts)


def request_for(case, image_root, model, output_mode, thinking):
    if output_mode not in {"schema", "prompt"}:
        raise ValueError("Unknown output mode")
    content = [
        {
            "type": "text",
            "text": json.dumps(
                {
                    "known_store": case["expected"]["store"],
                    "country": case["expected"]["country"],
                    "currency": case["expected"]["currency"],
                }
            ),
        }
    ]
    for source in case["images"]:
        data = (image_root / source["path"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != source["sha256"]:
            raise ValueError("Snapshot photo changed")
        with Image.open(io.BytesIO(data)) as raw:
            oriented = ImageOps.exif_transpose(raw).convert("RGB")
            encoded = io.BytesIO()
            oriented.save(encoded, format="PNG")
        content.append(
            {
                "type": "image_url",
                "image_url": {
                    "url": "data:image/png;base64,"
                    + base64.b64encode(encoded.getvalue()).decode()
                },
            }
        )
    schema = json.loads((ROOT / "src/backend_api/src/receipt_schema.json").read_text())
    prompt = prompt_for(case["expected"]["store"])
    if output_mode == "prompt":
        prompt += (
            "\nReturn exactly one JSON object matching this schema, without markdown fences:\n"
            + json.dumps(schema, ensure_ascii=False)
        )
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": content},
        ],
        "response_format": (
            {
                "type": "json_schema",
                "json_schema": {"name": "receipt", "strict": True, "schema": schema},
            }
            if output_mode == "schema"
            else {"type": "text"}
        ),
        "temperature": 0,
        "seed": 42,
        "max_tokens": 8192,
        "chat_template_kwargs": {"enable_thinking": thinking},
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--snapshot", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--output-mode", choices=["schema", "prompt"], required=True)
    p.add_argument("--thinking", choices=["on", "off"], required=True)
    args = p.parse_args()
    if urllib.parse.urlparse(args.url).hostname not in {"127.0.0.1", "localhost"}:
        raise ValueError("Only local inference is authorized")
    snapshot_bytes = args.snapshot.read_bytes()
    snapshot = json.loads(snapshot_bytes)
    args.output.mkdir(parents=True, exist_ok=True)
    report_file = args.output / "report.json"
    if report_file.exists():
        raise ValueError(
            "Use a new output directory; do not overwrite prior experiment"
        )
    report = {
        "model": args.model,
        "snapshot_sha256": hashlib.sha256(snapshot_bytes).hexdigest(),
        "temperature": 0,
        "seed": 42,
        "thinking": args.thinking == "on",
        "max_tokens": 8192,
        "output_mode": args.output_mode,
        "cases": [],
    }
    started = time.monotonic()
    for case in snapshot["cases"]:
        request = request_for(
            case,
            args.snapshot.parent,
            args.model,
            args.output_mode,
            args.thinking == "on",
        )
        (args.output / (case["id"] + ".prompt.txt")).write_text(
            request["messages"][0]["content"]
        )
        row = {"id": case["id"], "images": case["images"]}
        start = time.monotonic()
        try:
            req = urllib.request.Request(
                args.url.rstrip("/") + "/v1/chat/completions",
                json.dumps(request).encode(),
                {"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=600) as response:
                raw = response.read()
            (args.output / (case["id"] + ".response.json")).write_bytes(raw)
            result = json.loads(raw)
            row["usage"] = result.get("usage")
            row["timings"] = result.get("timings")
            choice = result["choices"][0]
            row["finish_reason"] = choice["finish_reason"]
            if choice["finish_reason"] != "stop":
                raise ValueError("Incomplete output: " + choice["finish_reason"])
            row["prediction"] = json.loads(choice["message"]["content"])
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as exc:
            row["failure"] = str(exc)
            if isinstance(exc, urllib.error.HTTPError):
                row["failure_body"] = exc.read().decode(errors="replace")
        row["duration_ms"] = round((time.monotonic() - start) * 1000)
        report["cases"].append(row)
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        report_file.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(
            case["id"],
            row["duration_ms"],
            row.get("failure", "JSON received"),
            flush=True,
        )


if __name__ == "__main__":
    main()
