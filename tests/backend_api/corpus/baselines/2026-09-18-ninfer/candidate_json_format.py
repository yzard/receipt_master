"""Offline formatting-only adapter; preserve the original inference report verbatim."""

import argparse
import json
import re
from pathlib import Path


def decode_content(content):
    text = content.strip()
    fence = re.fullmatch(r"```(?:json)?[ \t]*\r?\n([\s\S]*?)\r?\n```", text)
    if fence:
        text = fence[1]
    value = json.loads(text)
    if not isinstance(value, dict):
        raise ValueError("Receipt output must be one JSON object")
    return value, "single_markdown_fence" if fence else "none"


def adapt_report(report, response_root):
    adapted = json.loads(json.dumps(report))
    for row in adapted["cases"]:
        if row.get("finish_reason") != "stop":
            continue
        response = json.loads(
            (response_root / (row["id"] + ".response.json")).read_text()
        )
        try:
            prediction, formatting = decode_content(
                response["choices"][0]["message"]["content"]
            )
        except (ValueError, TypeError, KeyError) as error:
            row["adaptation_failure"] = str(error)
            continue
        if "failure" in row:
            row["raw_failure"] = row.pop("failure")
        row["prediction"] = prediction
        row["formatting_removed"] = formatting
    adapted["adaptation"] = (
        "Remove only one whole-response Markdown JSON code fence; no field edits, inference retries, inferred values or JSON repairs"
    )
    return adapted


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = adapt_report(
        json.loads((args.input_dir / "report.json").read_text()), args.input_dir
    )
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(
        "Decoded",
        sum("prediction" in c for c in result["cases"]),
        "/",
        len(result["cases"]),
    )


if __name__ == "__main__":
    main()
