import json
import tempfile
import unittest
from pathlib import Path

from candidate_json_format import adapt_report, decode_content


class CandidateFormatting(unittest.TestCase):
    def test_removes_only_whole_response_fence_and_preserves_values(self):
        text = '```json\n{"name":"错字", "amount":"-3.49"}\n```'
        value, formatting = decode_content(text)
        self.assertEqual(value, {"name": "错字", "amount": "-3.49"})
        self.assertEqual(formatting, "single_markdown_fence")
        self.assertEqual(decode_content('{"name":"错字"}')[1], "none")

    def test_does_not_repair_json_or_extract_from_prose(self):
        for text in [
            'Here is the result: {"a":1}',
            '```json\n{"a":}\n```',
            "{} {}",
            "[]",
            "```json\n{}\n```\nExtra text",
        ]:
            with self.assertRaises(ValueError):
                decode_content(text)

    def test_keeps_raw_failure_and_does_not_accept_truncated_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "a.response.json").write_text(
                json.dumps(
                    {
                        "choices": [
                            {"message": {"content": '```json\n{"lines":[]}\n```'}}
                        ]
                    }
                )
            )
            original = {
                "cases": [
                    {
                        "id": "a",
                        "finish_reason": "stop",
                        "failure": "JSON parse failure",
                    },
                    {"id": "b", "finish_reason": "length", "failure": "truncated"},
                ]
            }
            adapted = adapt_report(original, root)
            self.assertIn("failure", original["cases"][0])
            self.assertEqual(adapted["cases"][0]["raw_failure"], "JSON parse failure")
            self.assertNotIn("failure", adapted["cases"][0])
            self.assertNotIn("prediction", adapted["cases"][1])


if __name__ == "__main__":
    unittest.main()
