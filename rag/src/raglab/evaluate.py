"""Evaluate retrieval hit rate without starting or calling the LLM."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

from .retriever import HybridRetriever


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--questions", required=True, type=Path)
    parser.add_argument("--top-k", type=int, default=6)
    parser.add_argument("--candidate-count", type=int, default=40)
    parser.add_argument("--minimum-hit-rate", type=float, default=0.8)
    parser.add_argument("--output", type=Path)
    return parser


def _load_questions(path: Path) -> list[dict]:
    questions: list[dict] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"invalid JSON on {path}:{line_number}: {error}") from error

        if not isinstance(record.get("id"), str) or not record["id"]:
            raise ValueError(f"question on line {line_number} has no id")
        if not isinstance(record.get("question"), str) or not record["question"]:
            raise ValueError(f"question on line {line_number} has no question text")
        expected = record.get("expected_sources")
        if not isinstance(expected, list) or not expected or not all(
            isinstance(item, str) and item for item in expected
        ):
            raise ValueError(
                f"question on line {line_number} must have expected_sources"
            )
        questions.append(record)

    if not questions:
        raise ValueError("evaluation set is empty")
    return questions


def _matching_rank(paths: list[str], expected_sources: list[str]) -> int | None:
    for rank, path in enumerate(paths, start=1):
        if any(expected in path for expected in expected_sources):
            return rank
    return None


def evaluate(
    *,
    index: Path,
    questions_path: Path,
    top_k: int,
    candidate_count: int,
) -> dict:
    questions = _load_questions(questions_path)
    retriever = HybridRetriever(index)
    results: list[dict] = []

    try:
        for record in questions:
            retrieved = retriever.retrieve(
                record["question"],
                top_k=top_k,
                candidate_count=candidate_count,
            )
            paths = [result.chunk.path for result in retrieved]
            rank = _matching_rank(paths, record["expected_sources"])
            results.append(
                {
                    "id": record["id"],
                    "question": record["question"],
                    "expected_sources": record["expected_sources"],
                    "hit": rank is not None,
                    "first_matching_rank": rank,
                    "retrieved": [
                        {
                            "citation": result.chunk.citation,
                            "fused_score": result.fused_score,
                        }
                        for result in retrieved
                    ],
                }
            )
    finally:
        retriever.close()

    hits = sum(1 for result in results if result["hit"])
    reciprocal_ranks = [
        1.0 / result["first_matching_rank"]
        if result["first_matching_rank"] is not None
        else 0.0
        for result in results
    ]
    return {
        "question_count": len(results),
        "hits": hits,
        "hit_rate_at_k": hits / len(results),
        "mean_reciprocal_rank": sum(reciprocal_ranks) / len(results),
        "top_k": top_k,
        "results": results,
    }


def main() -> None:
    args = _parser().parse_args()
    try:
        if not 0.0 <= args.minimum_hit_rate <= 1.0:
            raise ValueError("minimum-hit-rate must be between 0 and 1")
        report = evaluate(
            index=args.index,
            questions_path=args.questions,
            top_k=args.top_k,
            candidate_count=args.candidate_count,
        )

        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

        print(f"questions={report['question_count']}")
        print(f"hits={report['hits']}")
        print(f"hit_rate_at_{report['top_k']}={report['hit_rate_at_k']:.3f}")
        print(f"mean_reciprocal_rank={report['mean_reciprocal_rank']:.3f}")
        if args.output:
            print(f"report={args.output}")

        if report["hit_rate_at_k"] < args.minimum_hit_rate:
            raise SystemExit(2)
    except (OSError, ValueError, json.JSONDecodeError, sqlite3.Error) as error:
        raise SystemExit(f"ERROR: {error}") from None


if __name__ == "__main__":
    main()
