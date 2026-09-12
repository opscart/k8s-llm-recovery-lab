"""Persist raw generation evidence before trust validation."""

from __future__ import annotations

import json
from pathlib import Path


def _write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_generation_evidence(
    *,
    output_dir: Path,
    question: str,
    retrieval_records: list[dict],
    payload: dict,
    response: dict,
    raw_answer: str,
) -> None:
    """Persist an LLM exchange before deciding whether its answer is trusted."""

    _write_json(output_dir / "retrieval.json", retrieval_records)
    _write_json(output_dir / "request.json", payload)
    _write_json(output_dir / "response.json", response)
    (output_dir / "answer.raw.txt").write_text(
        raw_answer + "\n", encoding="utf-8"
    )
    (output_dir / "question.txt").write_text(question + "\n", encoding="utf-8")
