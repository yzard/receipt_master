import unittest

from printed_name_evaluation import compare, score_names


class PrintedNames(unittest.TestCase):
    def test_actual_printed_continuation_is_valid_but_invention_is_not(self):
        gold = {
            "rows": [
                {
                    "printed_name": "FAGE GREEK STRAINED YOGURT",
                    "printed_continuations": ["FAGE GREEK STRAINED YOGURT 2% MILK FAT"],
                }
            ]
        }
        prediction = {
            "lines": [
                {"kind": "product", "name": "FAGE GREEK STRAINED YOGURT 2% MILK FAT"}
            ]
        }
        self.assertTrue(score_names(gold, prediction)["all_names_correct"])
        prediction["lines"][0]["name"] += " ORGANIC"
        self.assertFalse(score_names(gold, prediction)["all_names_correct"])

    def test_duplicates_spelling_and_product_names(self):
        gold = {"rows": [{"printed_name": "6PK BATH TWL"}] * 2}
        prediction = {
            "lines": [
                {"kind": "product", "name": "6pk bath twl", "product_name": "浴巾"}
            ]
        }
        result = score_names(gold, prediction)
        self.assertEqual(result["matched_names"], 1)
        self.assertFalse(result["all_names_correct"])
        prediction["lines"][0]["name"] = "浴巾"
        self.assertEqual(score_names(gold, prediction)["matched_names"], 0)
        prediction["lines"][0]["name"] = "6PK BATH TOWEL"
        self.assertEqual(score_names(gold, prediction)["matched_names"], 0)

    def test_ambiguous_names_are_not_forced_correct_or_wrong(self):
        gold = {"rows": [{"printed_name": "SALMON"}, {"printed_name": None}]}
        prediction = {
            "lines": [
                {"kind": "product", "name": "SALMON"},
                {"kind": "product", "name": "UNKNOWN"},
            ]
        }
        result = score_names(gold, prediction)
        self.assertEqual(result["verified_names"], 1)
        self.assertEqual(result["matched_names"], 1)
        self.assertIsNone(result["all_names_correct"])
        self.assertTrue(result["row_count_correct"])

    def test_missing_predictions_do_not_vanish_from_denominator(self):
        annotation = {
            "id": "a",
            "store": "X",
            "images": [],
            "rows": [{"printed_name": "MILK"}],
        }
        result = compare(
            {"cases": [annotation]},
            {"cases": [{"id": "a", "images": [], "failure": "timeout"}]},
        )
        self.assertEqual(result["summary"]["name_recall"], 0)
        with self.assertRaisesRegex(AssertionError, "Incomplete"):
            compare({"cases": [annotation]}, {"cases": []})


if __name__ == "__main__":
    unittest.main()
