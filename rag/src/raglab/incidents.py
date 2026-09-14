"""Validate bounded OpsCart incident evidence for repository-grounded diagnosis."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .security import secret_pattern


MAX_INCIDENT_BYTES = 32 * 1024
MAX_EVENTS = 20

_TOP_LEVEL_FIELDS = {
    "schema_version",
    "cluster",
    "observed_at",
    "namespace",
    "workload",
    "focus_pod",
    "classification",
    "severity",
    "container",
    "summary",
    "events",
}
_WORKLOAD_FIELDS = {"kind", "name"}
_CONTAINER_FIELDS = {"name", "state", "restart_count"}
_EVENT_FIELDS = {"reason", "message", "count"}


def _exact_fields(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    missing = sorted(expected - actual)
    unknown = sorted(actual - expected)
    if missing or unknown:
        raise ValueError(
            f"{label} fields do not match version 1 contract: "
            f"missing={missing}, unknown={unknown}"
        )


def _bounded_string(value: Any, label: str, maximum: int) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be a non-empty string")
    cleaned = value.strip()
    if len(cleaned) > maximum:
        raise ValueError(f"{label} exceeds {maximum} characters")
    return cleaned


def _nonnegative_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{label} must be a non-negative integer")
    return value


def load_incident(path: Path) -> dict[str, Any]:
    """Load a strict, size-bounded version-1 incident document."""

    raw = path.read_bytes()
    if len(raw) > MAX_INCIDENT_BYTES:
        raise ValueError(f"incident exceeds {MAX_INCIDENT_BYTES} bytes")
    try:
        text = raw.decode("utf-8")
        value = json.loads(text)
    except UnicodeDecodeError as error:
        raise ValueError("incident must be UTF-8") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid incident JSON: {error}") from error

    if not isinstance(value, dict):
        raise ValueError("incident must be a JSON object")
    if secret := secret_pattern(text):
        raise ValueError(f"incident contains a prohibited credential pattern: {secret}")

    _exact_fields(value, _TOP_LEVEL_FIELDS, "incident")
    if value["schema_version"] != 1:
        raise ValueError("schema_version must be 1")

    for field, maximum in (
        ("cluster", 253),
        ("observed_at", 64),
        ("namespace", 253),
        ("focus_pod", 253),
        ("classification", 128),
        ("severity", 32),
        ("summary", 2_000),
    ):
        value[field] = _bounded_string(value[field], field, maximum)

    workload = value["workload"]
    if not isinstance(workload, dict):
        raise ValueError("workload must be an object")
    _exact_fields(workload, _WORKLOAD_FIELDS, "workload")
    workload["kind"] = _bounded_string(workload["kind"], "workload.kind", 64)
    workload["name"] = _bounded_string(workload["name"], "workload.name", 253)

    container = value["container"]
    if not isinstance(container, dict):
        raise ValueError("container must be an object")
    _exact_fields(container, _CONTAINER_FIELDS, "container")
    container["name"] = _bounded_string(container["name"], "container.name", 253)
    container["state"] = _bounded_string(container["state"], "container.state", 128)
    container["restart_count"] = _nonnegative_integer(
        container["restart_count"], "container.restart_count"
    )

    events = value["events"]
    if not isinstance(events, list):
        raise ValueError("events must be an array")
    if len(events) > MAX_EVENTS:
        raise ValueError(f"events exceeds the limit of {MAX_EVENTS}")
    for index, event in enumerate(events):
        label = f"events[{index}]"
        if not isinstance(event, dict):
            raise ValueError(f"{label} must be an object")
        _exact_fields(event, _EVENT_FIELDS, label)
        event["reason"] = _bounded_string(event["reason"], f"{label}.reason", 128)
        event["message"] = _bounded_string(
            event["message"], f"{label}.message", 1_000
        )
        event["count"] = _nonnegative_integer(event["count"], f"{label}.count")

    return value


def derive_retrieval_question(incident: dict[str, Any]) -> str:
    """Build a stable code-search query without copying volatile event details."""

    classification = incident["classification"].lower()
    terms: list[str]
    if "probe" in classification:
        terms = ["livenessProbe", "readinessProbe", "httpGet", "probe configuration"]
    elif "image" in classification and "pull" in classification:
        terms = ["image", "imagePullSecrets", "registry", "deployment manifest"]
    elif "oom" in classification:
        terms = ["resources", "memory limit", "OOMKilled", "deployment manifest"]
    elif "crash" in classification:
        terms = ["container command", "args", "configuration", "deployment manifest"]
    else:
        terms = ["deployment manifest", "configuration", incident["classification"]]

    workload = incident["workload"]
    return (
        f"Find the source configuration for {workload['kind']} {workload['name']} "
        f"in namespace {incident['namespace']}. Inspect: {', '.join(terms)}."
    )
