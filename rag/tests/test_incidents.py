import json
import tempfile
import unittest
from pathlib import Path

from raglab.incidents import derive_retrieval_question, load_incident


def valid_incident():
    return {
        "schema_version": 1,
        "cluster": "lab",
        "observed_at": "2026-09-12T18:23:25Z",
        "namespace": "payments",
        "workload": {"kind": "Deployment", "name": "checkout-api"},
        "focus_pod": "checkout-api-abc",
        "classification": "Probe Failure",
        "severity": "critical",
        "container": {
            "name": "app",
            "state": "CrashLoopBackOff",
            "restart_count": 9,
        },
        "summary": "The liveness probe receives HTTP 404.",
        "events": [
            {"reason": "Unhealthy", "message": "HTTP probe failed: 404", "count": 9}
        ],
    }


class IncidentTests(unittest.TestCase):
    def _load(self, value):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "incident.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            return load_incident(path)

    def test_loads_strict_version_one_incident(self):
        loaded = self._load(valid_incident())
        self.assertEqual(loaded["workload"]["name"], "checkout-api")

    def test_rejects_unknown_fields_instead_of_silently_accepting_logs(self):
        value = valid_incident()
        value["logs"] = "sensitive application output"
        with self.assertRaisesRegex(ValueError, "unknown=.*logs"):
            self._load(value)

    def test_rejects_too_many_events(self):
        value = valid_incident()
        value["events"] = [
            {"reason": "BackOff", "message": "retry", "count": 1}
            for _ in range(21)
        ]
        with self.assertRaisesRegex(ValueError, "limit of 20"):
            self._load(value)

    def test_rejects_credential_patterns(self):
        value = valid_incident()
        value["summary"] = "token ghp_abcdefghijklmnopqrstuvwxyz123456"
        with self.assertRaisesRegex(ValueError, "credential pattern"):
            self._load(value)

    def test_retrieval_question_is_stable_and_excludes_event_details(self):
        value = valid_incident()
        question = derive_retrieval_question(value)
        self.assertIn("checkout-api", question)
        self.assertIn("livenessProbe", question)
        self.assertNotIn("404", question)
        self.assertNotIn(value["focus_pod"], question)

    def test_rejects_boolean_restart_count(self):
        value = valid_incident()
        value["container"]["restart_count"] = True
        with self.assertRaisesRegex(ValueError, "non-negative integer"):
            self._load(value)


if __name__ == "__main__":
    unittest.main()
