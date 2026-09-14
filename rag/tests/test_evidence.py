import json
import tempfile
import unittest
from pathlib import Path

from raglab.evidence import write_generation_evidence, write_query_inputs


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

    def test_incident_inputs_are_preserved_separately(self):
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            incident = {"schema_version": 1, "classification": "Probe Failure"}
            write_query_inputs(
                output_dir=output_dir,
                question="Diagnose safely",
                retrieval_question="Find livenessProbe",
                incident=incident,
            )

            self.assertEqual(
                (output_dir / "question.txt").read_text(encoding="utf-8"),
                "Diagnose safely\n",
            )
            self.assertEqual(
                (output_dir / "retrieval-question.txt").read_text(encoding="utf-8"),
                "Find livenessProbe\n",
            )
            self.assertEqual(
                json.loads((output_dir / "incident.json").read_text(encoding="utf-8")),
                incident,
            )

    def test_generation_evidence_keeps_incident_and_raw_answer(self):
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            write_generation_evidence(
                output_dir=output_dir,
                question="Diagnose",
                retrieval_question="Find manifest",
                incident={"schema_version": 1},
                retrieval_records=[],
                payload={},
                response={},
                raw_answer="raw answer",
            )
            self.assertTrue((output_dir / "incident.json").exists())
            self.assertEqual(
                (output_dir / "answer.raw.txt").read_text(encoding="utf-8"),
                "raw answer\n",
            )


if __name__ == "__main__":
    unittest.main()
