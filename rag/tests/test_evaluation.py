import json
import tempfile
import unittest
from pathlib import Path

from raglab.evaluation import (
    answerability_score,
    load_questions,
    matching_rank,
    rate,
)


class EvaluationTests(unittest.TestCase):
    def _questions(self, records: list[dict]):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "questions.jsonl"
        path.write_text(
            "\n".join(json.dumps(record) for record in records) + "\n",
            encoding="utf-8",
        )
        return load_questions(path)

    def test_loads_positive_and_negative_cases(self):
        questions = self._questions(
            [
                {
                    "id": "positive",
                    "question": "Where is it configured?",
                    "expected_repositories": ["repo-a"],
                    "expected_sources": ["config.yaml"],
                },
                {
                    "id": "negative",
                    "question": "What is the travel policy?",
                    "expected_answerable": False,
                },
            ]
        )
        self.assertTrue(questions[0].expected_answerable)
        self.assertFalse(questions[1].expected_answerable)

    def test_rejects_duplicate_ids(self):
        record = {
            "id": "duplicate",
            "question": "Where?",
            "expected_repositories": ["repo-a"],
            "expected_sources": ["README.md"],
        }
        with self.assertRaisesRegex(ValueError, "duplicate question id"):
            self._questions([record, record])

    def test_rejects_sources_on_negative_case(self):
        with self.assertRaisesRegex(ValueError, "must not declare"):
            self._questions(
                [
                    {
                        "id": "negative",
                        "question": "Unknown?",
                        "expected_answerable": False,
                        "expected_sources": ["README.md"],
                    }
                ]
            )

    def test_rejects_ambiguous_positive_repository_label(self):
        with self.assertRaisesRegex(ValueError, "exactly one expected repository"):
            self._questions(
                [
                    {
                        "id": "ambiguous",
                        "question": "Where?",
                        "expected_repositories": ["repo-a", "repo-b"],
                        "expected_sources": ["README.md"],
                    }
                ]
            )

    def test_matching_rank_requires_repository_and_exact_path(self):
        question = self._questions(
            [
                {
                    "id": "source",
                    "question": "Where?",
                    "expected_repositories": ["repo-a"],
                    "expected_sources": ["docs/runbook.md"],
                }
            ]
        )[0]
        rank = matching_rank(
            [
                ("repo-b", "docs/runbook.md"),
                ("repo-a", "archive/docs/runbook.md"),
                ("repo-a", "docs/runbook.md"),
            ],
            question,
        )
        self.assertEqual(rank, 3)

    def test_score_and_rate_helpers(self):
        self.assertEqual(answerability_score([None, 0.4, 0.7]), 0.7)
        self.assertEqual(answerability_score([]), -1.0)
        self.assertEqual(rate(3, 4), 0.75)
        self.assertIsNone(rate(0, 0))


if __name__ == "__main__":
    unittest.main()
