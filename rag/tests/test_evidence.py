import json
import tempfile
import unittest
from pathlib import Path

from raglab.evidence import write_generation_evidence


class GenerationEvidenceTests(unittest.TestCase):
    def test_generation_is_persisted_before_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            write_generation_evidence(
                output_dir=output_dir,
                question="What is configured?",
                retrieval_records=[{"citation": "[repo:a:1-2@0123456789ab]"}],
                payload={"model": "test-model"},
                response={"choices": [{"message": {"content": "raw"}}]},
                raw_answer="raw",
            )

            self.assertEqual(
                (output_dir / "answer.raw.txt").read_text(encoding="utf-8"),
                "raw\n",
            )
            self.assertFalse((output_dir / "answer.txt").exists())
            response = json.loads(
                (output_dir / "response.json").read_text(encoding="utf-8")
            )
            self.assertEqual(response["choices"][0]["message"]["content"], "raw")


if __name__ == "__main__":
    unittest.main()
