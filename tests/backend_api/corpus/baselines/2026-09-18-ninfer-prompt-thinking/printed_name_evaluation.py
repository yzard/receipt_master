"""Score image-reviewed printed names separately from user-managed product names."""

import argparse
import json
import unicodedata
from collections import Counter
from pathlib import Path


def normalized_name(value):
    """Ignore case/spacing/punctuation, never correct spelling or translate."""
    return "".join(
        char for char in unicodedata.normalize("NFKC", value).upper() if char.isalnum()
    )


def merchandise(lines):
    return [line for line in lines if line["kind"] in {"product", "other_adjustment"}]


def score_names(annotation, prediction):
    rows = annotation["rows"]
    names = [r["printed_name"] for r in rows if r["printed_name"] is not None]
    # Accept only explicitly reviewed text on the same physical item's continuation.
    # These are photograph transcriptions, never catalogue aliases or translations.
    continuations = {
        normalized_name(alternative): normalized_name(row["printed_name"])
        for row in rows
        if row["printed_name"] is not None
        for alternative in row.get("printed_continuations", [])
    }
    actual = [line["name"] for line in merchandise((prediction or {}).get("lines", []))]
    gold = Counter(map(normalized_name, names))
    guessed = Counter(
        continuations.get(normalized_name(name), normalized_name(name))
        for name in actual
    )
    matched = sum((gold & guessed).values())
    uncertain = len(rows) - len(names)
    return {
        "verified_names": len(names),
        "matched_names": matched,
        "uncertain_names": uncertain,
        "expected_rows": len(rows),
        "predicted_rows": len(actual),
        "row_count_correct": len(rows) == len(actual),
        "all_names_correct": gold == guessed if not uncertain else None,
        "missing_or_misread": list((gold - guessed).elements()),
        "unmatched_predictions": list((guessed - gold).elements()),
        "printed_names": names,
        "predicted_names": actual,
    }


def compare(annotations, predictions):
    cases = {case["id"]: case for case in predictions["cases"]}
    assert len(cases) == len(predictions["cases"]), "Duplicate predictions"
    assert set(cases) == {case["id"] for case in annotations["cases"]}, "Incomplete run"
    results = []
    for annotation in annotations["cases"]:
        case = cases[annotation["id"]]
        assert case["images"] == annotation["images"], "Different source photographs"
        result = score_names(annotation, case.get("prediction"))
        results.append({"id": annotation["id"], "store": annotation["store"], **result})
    matched = sum(r["matched_names"] for r in results)
    verified = sum(r["verified_names"] for r in results)
    clear = [r for r in results if r["all_names_correct"] is not None]
    clear_matched = sum(r["matched_names"] for r in clear)
    clear_predictions = sum(r["predicted_rows"] for r in clear)
    return {
        "normalization": "NFKC, uppercase, letters/digits only; explicitly photo-reviewed same-item continuation forms accepted; no spelling correction, translation, SKU stripping or catalogue alias lookup",
        "matching": "One-to-one exact normalized name multiset; duplicate printed rows count separately. Uncertain rows excluded from recall; receipts containing uncertain rows excluded from precision and whole-receipt exactness.",
        "summary": {
            "receipts": len(results),
            "matched_names": matched,
            "verified_names": verified,
            "name_recall": matched / verified,
            "clear_matched_names": clear_matched,
            "clear_predicted_names": clear_predictions,
            "clear_precision": (
                clear_matched / clear_predictions if clear_predictions else 0
            ),
            "fully_correct_receipts": sum(r["all_names_correct"] for r in clear),
            "fully_reviewable_receipts": len(clear),
            "correct_row_counts": sum(r["row_count_correct"] for r in results),
        },
        "cases": results,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotations", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compare(
        json.loads(args.annotations.read_text()),
        json.loads(args.predictions.read_text()),
    )
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["summary"], ensure_ascii=False))


if __name__ == "__main__":
    main()
