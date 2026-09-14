"""Persist raw generation evidence before trust validation."""

from __future__ import annotations

import json
from pathlib import Path


def _write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _write_text(path: Path, value: str) -> None:
    path.write_text(value.rstrip() + "\n", encoding="utf-8")


def write_query_inputs(
    *,
    output_dir: Path,
    question: str,
    retrieval_question: str,
    incident: dict | None,
) -> None:
    """Preserve generation and retrieval inputs as separate evidence."""

    _write_text(output_dir / "question.txt", question)
    _write_text(output_dir / "retrieval-question.txt", retrieval_question)
    if incident is not None:
        _write_json(output_dir / "incident.json", incident)


def write_generation_evidence(
    *,
    output_dir: Path,
    question: str,
    retrieval_records: list[dict],
    payload: dict,
    response: dict,
    raw_answer: str,
    retrieval_question: str | None = None,
    incident: dict | None = None,
) -> None:
    """Persist an LLM exchange before deciding whether its answer is trusted."""

    _write_json(output_dir / "retrieval.json", retrieval_records)
    _write_json(output_dir / "request.json", payload)
    _write_json(output_dir / "response.json", response)
    _write_text(output_dir / "answer.raw.txt", raw_answer)
    write_query_inputs(
        output_dir=output_dir,
        question=question,
        retrieval_question=retrieval_question or question,
        incident=incident,
    )
