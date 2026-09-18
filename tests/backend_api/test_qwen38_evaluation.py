import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from qwen38_evaluation import prompt_for, request_for


class EvaluationContract(unittest.TestCase):
    def test_gold_values_never_enter_prompt_and_photos_are_verified(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            Image.new("RGB", (16, 24), "white").save(root / "photo.png")
            digest = hashlib.sha256((root / "photo.png").read_bytes()).hexdigest()
            case = {
                "expected": {
                    "store": "Costco",
                    "country": "US",
                    "currency": "USD",
                    "totalMinor": 87654321,
                    "lines": [{"rawName": "SECRET-GOLD-ANSWER"}],
                },
                "images": [{"path": "photo.png", "sha256": digest}],
            }
            request = request_for(case, root, "candidate", "schema", False)
            self.assertNotIn("SECRET-GOLD-ANSWER", json.dumps(request))
            self.assertNotIn("87654321", json.dumps(request))
            self.assertIn("Costco", request["messages"][1]["content"][0]["text"])
            self.assertEqual(request["response_format"]["type"], "json_schema")
            unconstrained = request_for(case, root, "candidate", "prompt", True)
            self.assertFalse(request["chat_template_kwargs"]["enable_thinking"])
            self.assertTrue(unconstrained["chat_template_kwargs"]["enable_thinking"])
            self.assertEqual(unconstrained["response_format"], {"type": "text"})
            self.assertIn(
                '"discount_target_index"', unconstrained["messages"][0]["content"]
            )
            self.assertNotIn("SECRET-GOLD-ANSWER", json.dumps(unconstrained))
            self.assertNotIn("87654321", json.dumps(unconstrained))
            case["images"][0]["sha256"] = "wrong"
            with self.assertRaisesRegex(ValueError, "Snapshot photo changed"):
                request_for(case, root, "candidate", "schema", False)

    def test_store_rules_are_scoped(self):
        self.assertIn("unindented", prompt_for("skyFOODS"))
        self.assertNotIn("SkyFoods has multiple layouts", prompt_for("Costco"))
        self.assertIn("ABOVE", prompt_for("Hualian"))
        self.assertIn("BELOW", prompt_for("99 Ranch"))


if __name__ == "__main__":
    unittest.main()
