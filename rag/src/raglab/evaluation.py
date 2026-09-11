"""Dependency-light evaluation schema and scoring helpers."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class EvaluationQuestion:
    identifier: str
    question: str
    expected_answerable: bool
    expected_repositories: tuple[str, ...]
    expected_sources: tuple[str, ...]


def load_questions(path: Path) -> list[EvaluationQuestion]:
    """Load a strict JSONL evaluation set and reject ambiguous labels."""

    questions: list[EvaluationQuestion] = []
    identifiers: set[str] = set()

    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"invalid JSON on {path}:{line_number}: {error}") from error

        identifier = record.get("id")
        question = record.get("question")
        expected_answerable = record.get("expected_answerable", True)
        expected_repositories = record.get("expected_repositories", [])
        expected_sources = record.get("expected_sources", [])

        if not isinstance(identifier, str) or not identifier:
            raise ValueError(f"question on line {line_number} has no id")
        if identifier in identifiers:
            raise ValueError(f"duplicate question id on line {line_number}: {identifier}")
        if not isinstance(question, str) or not question.strip():
            raise ValueError(f"question on line {line_number} has no question text")
        if not isinstance(expected_answerable, bool):
            raise ValueError(
                f"expected_answerable on line {line_number} must be boolean"
            )

        if expected_answerable:
            if not _nonempty_strings(expected_repositories):
                raise ValueError(
                    f"answerable question on line {line_number} must have "
                    "expected_repositories"
                )
            if len(expected_repositories) != 1:
                raise ValueError(
                    f"answerable question on line {line_number} must identify exactly "
                    "one expected repository"
                )
            if not _nonempty_strings(expected_sources):
                raise ValueError(
                    f"answerable question on line {line_number} must have expected_sources"
                )
        elif expected_repositories or expected_sources:
            raise ValueError(
                f"unanswerable question on line {line_number} must not declare "
                "expected repositories or sources"
            )

        identifiers.add(identifier)
        questions.append(
            EvaluationQuestion(
                identifier=identifier,
                question=question.strip(),
                expected_answerable=expected_answerable,
                expected_repositories=tuple(expected_repositories),
                expected_sources=tuple(expected_sources),
            )
        )

    if not questions:
        raise ValueError("evaluation set is empty")
    return questions


def _nonempty_strings(value: object) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(item, str) and bool(item) for item in value)
    )


def matching_rank(
    retrieved: Iterable[tuple[str, str]], question: EvaluationQuestion
) -> int | None:
    """Return the first exact repository-and-path match."""

    expected_repositories = set(question.expected_repositories)
    expected_sources = set(question.expected_sources)
    for rank, (repository, path) in enumerate(retrieved, start=1):
        if repository in expected_repositories and path in expected_sources:
            return rank
    return None


def answerability_score(dense_similarities: Iterable[float | None]) -> float:
    """Return the strongest available dense score, or -1 for no evidence."""

    scores = [score for score in dense_similarities if score is not None]
    return max(scores, default=-1.0)


def rate(numerator: int, denominator: int) -> float | None:
    """Return a rate while preserving 'not applicable' as None."""

    if denominator == 0:
        return None
    return numerator / denominator
