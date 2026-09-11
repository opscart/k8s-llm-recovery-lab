"""Evaluate multi-repository retrieval without starting or calling the LLM."""

from __future__ import annotations

import argparse
import json
import sqlite3
from collections import defaultdict
from pathlib import Path

from .evaluation import answerability_score, load_questions, matching_rank, rate
from .retriever import HybridRetriever
from .settings import DEFAULT_ANSWERABILITY_THRESHOLD


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--questions", required=True, type=Path)
    parser.add_argument("--top-k", type=int, default=6)
    parser.add_argument("--candidate-count", type=int, default=40)
    parser.add_argument("--minimum-hit-rate", type=float, default=0.85)
    parser.add_argument("--minimum-repository-hit-rate", type=float, default=0.80)
    parser.add_argument("--minimum-negative-pass-rate", type=float, default=1.0)
    parser.add_argument("--minimum-positive-answerability-rate", type=float, default=1.0)
    parser.add_argument("--maximum-cross-repository-top1-rate", type=float, default=0.20)
    parser.add_argument(
        "--minimum-answerable-score",
        type=float,
        default=DEFAULT_ANSWERABILITY_THRESHOLD,
    )
    parser.add_argument("--output", type=Path)
    return parser


def _validate_rate(name: str, value: float) -> None:
    if not 0.0 <= value <= 1.0:
        raise ValueError(f"{name} must be between 0 and 1")


def _repository_names(retriever: HybridRetriever) -> list[str]:
    repositories = retriever.manifest.get("repositories", [])
    names = [entry.get("name") for entry in repositories if isinstance(entry, dict)]
    if not names or not all(isinstance(name, str) and name for name in names):
        raise ValueError("index manifest has no valid repository names")
    if len(names) != len(set(names)):
        raise ValueError("index manifest contains duplicate repository names")
    return names


def evaluate(
    *,
    index: Path,
    questions_path: Path,
    top_k: int,
    candidate_count: int,
    answerability_threshold: float,
) -> dict:
    questions = load_questions(questions_path)
    retriever = HybridRetriever(index)
    results: list[dict] = []
    repository_counts: dict[str, dict[str, int]] = defaultdict(
        lambda: {"question_count": 0, "hits": 0, "top1_wrong_repository": 0}
    )

    try:
        indexed_repositories = _repository_names(retriever)
        indexed_set = set(indexed_repositories)

        for question in questions:
            unknown = set(question.expected_repositories) - indexed_set
            if unknown:
                raise ValueError(
                    f"question {question.identifier!r} expects repositories not in "
                    f"the index: {sorted(unknown)}"
                )

            retrieved = retriever.retrieve(
                question.question,
                top_k=top_k,
                candidate_count=candidate_count,
            )
            score = answerability_score(
                result.dense_similarity for result in retrieved
            )
            predicted_answerable = score >= answerability_threshold
            retrieved_sources = [
                (result.chunk.repository, result.chunk.path) for result in retrieved
            ]

            if question.expected_answerable:
                rank = matching_rank(retrieved_sources, question)
                hit = rank is not None
                top_repository = retrieved[0].chunk.repository if retrieved else None
                cross_repository_top1 = (
                    top_repository is not None
                    and top_repository not in question.expected_repositories
                )

                for repository in question.expected_repositories:
                    counts = repository_counts[repository]
                    counts["question_count"] += 1
                    counts["hits"] += int(hit)
                    counts["top1_wrong_repository"] += int(cross_repository_top1)

                result_record = {
                    "id": question.identifier,
                    "case_type": "positive",
                    "question": question.question,
                    "expected_repositories": list(question.expected_repositories),
                    "expected_sources": list(question.expected_sources),
                    "hit": hit,
                    "first_matching_rank": rank,
                    "predicted_answerable": predicted_answerable,
                    "answerability_score": score,
                    "cross_repository_top1": cross_repository_top1,
                }
            else:
                result_record = {
                    "id": question.identifier,
                    "case_type": "negative",
                    "question": question.question,
                    "expected_answerable": False,
                    "passed": not predicted_answerable,
                    "predicted_answerable": predicted_answerable,
                    "answerability_score": score,
                }

            result_record["retrieved"] = [
                {
                    "citation": result.chunk.citation,
                    "repository": result.chunk.repository,
                    "path": result.chunk.path,
                    "fused_score": result.fused_score,
                    "dense_similarity": result.dense_similarity,
                }
                for result in retrieved
            ]
            results.append(result_record)
    finally:
        retriever.close()

    positive = [result for result in results if result["case_type"] == "positive"]
    negative = [result for result in results if result["case_type"] == "negative"]
    positive_hits = sum(int(result["hit"]) for result in positive)
    negative_passes = sum(int(result["passed"]) for result in negative)
    positive_answerability_passes = sum(
        int(result["predicted_answerable"]) for result in positive
    )
    cross_repository_errors = sum(
        int(result["cross_repository_top1"]) for result in positive
    )
    reciprocal_ranks = [
        1.0 / result["first_matching_rank"]
        if result["first_matching_rank"] is not None
        else 0.0
        for result in positive
    ]

    repository_metrics: dict[str, dict] = {}
    for repository in indexed_repositories:
        counts = repository_counts[repository]
        repository_metrics[repository] = {
            **counts,
            "hit_rate_at_k": rate(counts["hits"], counts["question_count"]),
            "cross_repository_top1_rate": rate(
                counts["top1_wrong_repository"], counts["question_count"]
            ),
        }

    return {
        "schema_version": 2,
        "question_count": len(results),
        "positive_question_count": len(positive),
        "negative_question_count": len(negative),
        "hits": positive_hits,
        "hit_rate_at_k": rate(positive_hits, len(positive)),
        "negative_passes": negative_passes,
        "negative_pass_rate": rate(negative_passes, len(negative)),
        "positive_answerability_passes": positive_answerability_passes,
        "positive_answerability_rate": rate(
            positive_answerability_passes, len(positive)
        ),
        "mean_reciprocal_rank": (
            sum(reciprocal_ranks) / len(reciprocal_ranks)
            if reciprocal_ranks
            else None
        ),
        "cross_repository_top1_errors": cross_repository_errors,
        "cross_repository_top1_rate": rate(
            cross_repository_errors, len(positive)
        ),
        "answerability_threshold": answerability_threshold,
        "top_k": top_k,
        "index_repositories": retriever.manifest["repositories"],
        "repositories": repository_metrics,
        "results": results,
    }


def _gate(report: dict, args: argparse.Namespace) -> list[str]:
    failures: list[str] = []

    if report["positive_question_count"] == 0:
        failures.append("evaluation contains no positive questions")
    elif report["hit_rate_at_k"] < args.minimum_hit_rate:
        failures.append(
            f"overall hit rate {report['hit_rate_at_k']:.3f} is below "
            f"{args.minimum_hit_rate:.3f}"
        )

    for repository, metrics in report["repositories"].items():
        if metrics["question_count"] == 0:
            failures.append(f"repository {repository!r} has no positive questions")
        elif metrics["hit_rate_at_k"] < args.minimum_repository_hit_rate:
            failures.append(
                f"repository {repository!r} hit rate "
                f"{metrics['hit_rate_at_k']:.3f} is below "
                f"{args.minimum_repository_hit_rate:.3f}"
            )

    if report["negative_question_count"] == 0:
        failures.append("evaluation contains no negative questions")
    elif report["negative_pass_rate"] < args.minimum_negative_pass_rate:
        failures.append(
            f"negative pass rate {report['negative_pass_rate']:.3f} is below "
            f"{args.minimum_negative_pass_rate:.3f}"
        )

    if (
        report["positive_answerability_rate"] is not None
        and report["positive_answerability_rate"]
        < args.minimum_positive_answerability_rate
    ):
        failures.append(
            f"positive answerability rate "
            f"{report['positive_answerability_rate']:.3f} is below "
            f"{args.minimum_positive_answerability_rate:.3f}"
        )

    if (
        report["cross_repository_top1_rate"] is not None
        and report["cross_repository_top1_rate"]
        > args.maximum_cross_repository_top1_rate
    ):
        failures.append(
            f"cross-repository top-1 error rate "
            f"{report['cross_repository_top1_rate']:.3f} exceeds "
            f"{args.maximum_cross_repository_top1_rate:.3f}"
        )

    return failures


def _format_rate(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.3f}"


def _print_summary(report: dict) -> None:
    print(f"questions={report['question_count']}")
    print(f"positive_questions={report['positive_question_count']}")
    print(f"hits={report['hits']}")
    print(f"hit_rate_at_{report['top_k']}={_format_rate(report['hit_rate_at_k'])}")
    print(f"negative_questions={report['negative_question_count']}")
    print(f"negative_pass_rate={_format_rate(report['negative_pass_rate'])}")
    print(
        "positive_answerability_rate="
        f"{_format_rate(report['positive_answerability_rate'])}"
    )
    print(
        "cross_repository_top1_rate="
        f"{_format_rate(report['cross_repository_top1_rate'])}"
    )
    print(f"mean_reciprocal_rank={_format_rate(report['mean_reciprocal_rank'])}")
    for repository, metrics in report["repositories"].items():
        print(
            f"repository[{repository}].questions={metrics['question_count']} "
            f"hits={metrics['hits']} "
            f"hit_rate={_format_rate(metrics['hit_rate_at_k'])}"
        )


def main() -> None:
    args = _parser().parse_args()
    try:
        _validate_rate("minimum-hit-rate", args.minimum_hit_rate)
        _validate_rate("minimum-repository-hit-rate", args.minimum_repository_hit_rate)
        _validate_rate("minimum-negative-pass-rate", args.minimum_negative_pass_rate)
        _validate_rate(
            "minimum-positive-answerability-rate",
            args.minimum_positive_answerability_rate,
        )
        _validate_rate(
            "maximum-cross-repository-top1-rate",
            args.maximum_cross_repository_top1_rate,
        )
        _validate_rate("minimum-answerable-score", args.minimum_answerable_score)

        report = evaluate(
            index=args.index,
            questions_path=args.questions,
            top_k=args.top_k,
            candidate_count=args.candidate_count,
            answerability_threshold=args.minimum_answerable_score,
        )
        failures = _gate(report, args)
        report["gate"] = {
            "passed": not failures,
            "failures": failures,
            "thresholds": {
                "minimum_hit_rate": args.minimum_hit_rate,
                "minimum_repository_hit_rate": args.minimum_repository_hit_rate,
                "minimum_negative_pass_rate": args.minimum_negative_pass_rate,
                "minimum_positive_answerability_rate": (
                    args.minimum_positive_answerability_rate
                ),
                "maximum_cross_repository_top1_rate": args.maximum_cross_repository_top1_rate,
                "minimum_answerable_score": args.minimum_answerable_score,
            },
        }

        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

        _print_summary(report)
        print(f"gate={'PASS' if not failures else 'FAIL'}")
        if args.output:
            print(f"report={args.output}")
        for failure in failures:
            print(f"gate_failure={failure}")

        if failures:
            raise SystemExit(2)
    except (OSError, ValueError, json.JSONDecodeError, sqlite3.Error) as error:
        raise SystemExit(f"ERROR: {error}") from None


if __name__ == "__main__":
    main()
