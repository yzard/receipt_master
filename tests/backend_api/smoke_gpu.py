"""Explicit GPU integration check using a synthetic receipt, never user data."""

import argparse
import base64
import io
import json
import time
from pathlib import Path

from api_auth import client_key

import httpx
from PIL import Image, ImageDraw, ImageFont


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    photo = Image.new("RGB", (900, 800), "white")
    draw = ImageDraw.Draw(photo)
    font = ImageFont.load_default(size=32)
    for index, line in enumerate(
        [
            "TEST MARKET",
            "123 MAIN ST, BOSTON, MA",
            "2026-09-15 12:30",
            "Currency: USD",
            "MILK                 3.50",
            "BREAD                2.50",
            "SUBTOTAL             6.00",
            "TAX                  0.48",
            "TOTAL                6.48",
            "THANK YOU",
        ]
    ):
        draw.text((60, 40 + index * 65), line, font=font, fill="black")
    photo.save(args.output_dir / "synthetic-receipt.jpg")
    buffer = io.BytesIO()
    photo.save(buffer, format="JPEG", quality=95)
    headers = {"Authorization": "Bearer " + client_key(args.config)}
    models = httpx.get(args.url + "/v1/models", headers=headers, timeout=15, trust_env=False)
    models.raise_for_status()
    schema = json.loads(Path(__file__).with_name("receipt_schema.json").read_text())
    body = {
        "model": models.json()["data"][0]["id"],
        "store": False,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Extract the receipt with separate products and tax."},
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode(),
                            "detail": "high",
                        },
                    },
                ],
            }
        ],
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "receipt", "strict": True, "schema": schema},
        },
    }
    start = time.monotonic()
    response = httpx.post(
        args.url + "/v1/chat/completions",
        json=body,
        headers=headers,
        timeout=600,
        trust_env=False,
    )
    response.raise_for_status()
    result = response.json()
    (args.output_dir / "response.json").write_text(json.dumps(result, indent=2))
    parsed = json.loads(result["choices"][0]["message"]["content"])
    assert result["choices"][0]["finish_reason"] == "stop"
    assert parsed["store"] is None, parsed
    assert parsed["total"] == "6.48", parsed
    assert len(parsed["lines"]) == 3, parsed
    products = [line for line in parsed["lines"] if line["kind"] == "product"]
    assert len(products) == 2, parsed
    assert sorted(line["amount"] for line in products) == ["2.50", "3.50"], parsed
    assert any(line["kind"] == "tax" and line["amount"] == "0.48" for line in parsed["lines"]), parsed
    assert all(line["confidence"] is None for line in parsed["lines"])
    report = {
        "synthetic_gpu_inference": "passed",
        "elapsed_seconds": round(time.monotonic() - start, 2),
        "store": parsed["store"],
        "total": parsed["total"],
        "product_count": len(products),
    }
    (args.output_dir / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
