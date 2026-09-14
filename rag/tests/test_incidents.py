import json
import tempfile
import unittest
from pathlib import Path

from raglab.incidents import (
    derive_retrieval_question,
    load_incident,
    select_source_indices,
)


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


def valid_version_two_incident():
    value = valid_incident()
    value["schema_version"] = 2
    value["source"] = {
        "repository": "opscart-k8s-watcher",
        "path": "examples/failure-lab/manifests/probe-failure.yaml",
    }
    return value


class IncidentTests(unittest.TestCase):
    def _load(self, value):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "incident.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            return load_incident(path)

    def test_loads_strict_version_one_incident(self):
        loaded = self._load(valid_incident())
        self.assertEqual(loaded["workload"]["name"], "checkout-api")

    def test_loads_version_two_incident_with_source_identity(self):
        loaded = self._load(valid_version_two_incident())
        self.assertEqual(loaded["source"]["repository"], "opscart-k8s-watcher")
        self.assertEqual(
            loaded["source"]["path"],
            "examples/failure-lab/manifests/probe-failure.yaml",
        )

    def test_version_two_requires_source_identity(self):
        value = valid_incident()
        value["schema_version"] = 2
        with self.assertRaisesRegex(ValueError, "missing=.*source"):
            self._load(value)

    def test_version_one_rejects_source_identity(self):
        value = valid_version_two_incident()
        value["schema_version"] = 1
        with self.assertRaisesRegex(ValueError, "unknown=.*source"):
            self._load(value)

    def test_rejects_non_normalized_source_path(self):
        value = valid_version_two_incident()
        value["source"]["path"] = "../secrets.yaml"
        with self.assertRaisesRegex(ValueError, "repository-relative"):
            self._load(value)

        value = valid_version_two_incident()
        value["source"]["path"] = "manifests//deployment.yaml"
        with self.assertRaisesRegex(ValueError, "repository-relative"):
            self._load(value)

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

    def test_version_two_retrieval_question_includes_source_identity(self):
        value = valid_version_two_incident()
        question = derive_retrieval_question(value)
        self.assertIn("opscart-k8s-watcher", question)
        self.assertIn("examples/failure-lab/manifests/probe-failure.yaml", question)

    def test_normal_question_authorizes_all_retrieved_sources(self):
        status, indices = select_source_indices(
            None, [("repo-a", "a.yaml"), ("repo-b", "b.yaml")]
        )
        self.assertEqual(status, "not-applicable")
        self.assertEqual(indices, [0, 1])

    def test_version_one_cannot_authorize_repository_evidence(self):
        status, indices = select_source_indices(
            valid_incident(), [("opscart-k8s-watcher", "similar.yaml")]
        )
        self.assertEqual(status, "missing")
        self.assertEqual(indices, [])

    def test_similar_but_different_source_is_rejected(self):
        incident = valid_version_two_incident()
        status, indices = select_source_indices(
            incident,
            [
                ("opscart-k8s-watcher", "similar-probe.yaml"),
                ("different-repository", incident["source"]["path"]),
            ],
        )
        self.assertEqual(status, "not-retrieved")
        self.assertEqual(indices, [])

    def test_only_exact_repository_and_path_are_authorized(self):
        incident = valid_version_two_incident()
        status, indices = select_source_indices(
            incident,
            [
                ("opscart-k8s-watcher", "similar-probe.yaml"),
                (incident["source"]["repository"], incident["source"]["path"]),
            ],
        )
        self.assertEqual(status, "verified")
        self.assertEqual(indices, [1])

    def test_rejects_boolean_restart_count(self):
        value = valid_incident()
        value["container"]["restart_count"] = True
        with self.assertRaisesRegex(ValueError, "non-negative integer"):
            self._load(value)


if __name__ == "__main__":
    unittest.main()
