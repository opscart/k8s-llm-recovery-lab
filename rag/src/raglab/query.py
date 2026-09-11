"""Retrieve cited context locally and optionally ask the private vLLM endpoint."""

from __future__ import annotations

import argparse
import json
import sqlite3
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from .evaluation import answerability_score
from .prompting import build_context, build_request_payload, validate_citations
from .retriever import HybridRetriever, RetrievalResult
from .settings import DEFAULT_ANSWERABILITY_THRESHOLD


DEFAULT_MODEL = "qwen2.5-coder-14b-awq"
DEFAULT_ENDPOINT = "http://127.0.0.1:18000/v1"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", required=True, type=Path)
    question = parser.add_mutually_exclusive_group(required=True)
    question.add_argument("--question")
    question.add_argument("--question-file", type=Path)
    parser.add_argument("--top-k", type=int, default=6)
    parser.add_argument("--candidate-count", type=int, default=40)
    parser.add_argument("--max-context-chars", type=int, default=24_000)
    parser.add_argument("--retrieve-only", action="store_true")
    parser.add_argument(
        "--output-format",
        choices=("summary", "json"),
        default="summary",
        help="Retrieval-only output format (default: compact summary)",
    )
    parser.add_argument(
        "--minimum-answerable-score",
        type=float,
        default=DEFAULT_ANSWERABILITY_THRESHOLD,
    )
    parser.add_argument(
        "--allow-low-confidence",
        action="store_true",
        help="Call vLLM even when retrieval is below the answerability threshold",
    )
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--output-dir", type=Path)
    return parser


def _question(args: argparse.Namespace) -> str:
    if args.question is not None:
        return args.question.strip()
    return args.question_file.read_text(encoding="utf-8").strip()


def _result_record(result: RetrievalResult, *, include_content: bool) -> dict:
    record = {
        "chunk_id": result.chunk_id,
        "citation": result.chunk.citation,
        "repository": result.chunk.repository,
        "commit_sha": result.chunk.commit_sha,
        "path": result.chunk.path,
        "start_line": result.chunk.start_line,
        "end_line": result.chunk.end_line,
        "language": result.chunk.language,
        "content_sha256": result.chunk.content_sha256,
        "fused_score": result.fused_score,
        "dense_rank": result.dense_rank,
        "lexical_rank": result.lexical_rank,
        "dense_similarity": result.dense_similarity,
    }
    if include_content:
        record["content"] = result.chunk.content
    else:
        record["content_preview"] = result.chunk.content[:400]
    return record


def _post_json(url: str, payload: dict, timeout: int) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read(2_000).decode("utf-8", errors="replace")
        raise ValueError(f"vLLM returned HTTP {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise ValueError(f"could not reach vLLM: {error.reason}") from error


def _answer(response: dict) -> str:
    choices = response.get("choices", [])
    if not choices:
        raise ValueError("vLLM response contained no choices")
    answer = choices[0].get("message", {}).get("content", "").strip()
    if not answer:
        raise ValueError("vLLM returned an empty answer")
    return answer


def _write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _print_retrieval_summary(
    results: list[RetrievalResult], *, score: float, threshold: float
) -> None:
    decision = "yes" if score >= threshold else "no"
    print(f"retrieved={len(results)}")
    print(f"answerable={decision} score={score:.3f} threshold={threshold:.3f}")
    for rank, result in enumerate(results, start=1):
        dense = result.dense_similarity
        dense_text = "n/a" if dense is None else f"{dense:.3f}"
        print(
            f"{rank}. {result.chunk.citation} "
            f"dense={dense_text} fused={result.fused_score:.6f}"
        )


def _create_output_dir(configured: Path | None) -> Path:
    if configured is None:
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        configured = Path("results/rag/queries") / run_id
    configured.mkdir(parents=True, exist_ok=False)
    return configured


def main() -> None:
    args = _parser().parse_args()
    try:
        question = _question(args)
        if not question:
            raise ValueError("question must not be empty")
        if not 0.0 <= args.minimum_answerable_score <= 1.0:
            raise ValueError("minimum-answerable-score must be between 0 and 1")

        retriever = HybridRetriever(args.index)
        try:
            results = retriever.retrieve(
                question,
                top_k=args.top_k,
                candidate_count=args.candidate_count,
            )
        finally:
            retriever.close()

        score = answerability_score(
            result.dense_similarity for result in results
        )

        if args.retrieve_only:
            if args.output_format == "json":
                print(
                    json.dumps(
                        [
                            _result_record(result, include_content=False)
                            for result in results
                        ],
                        indent=2,
                    )
                )
            else:
                _print_retrieval_summary(
                    results,
                    score=score,
                    threshold=args.minimum_answerable_score,
                )
            return
        if not results:
            raise ValueError("retrieval returned no context")

        retrieval_records = [
            _result_record(result, include_content=True) for result in results
        ]

        if score < args.minimum_answerable_score and not args.allow_low_confidence:
            answer = (
                "Insufficient evidence: retrieval confidence "
                f"{score:.3f} is below the configured threshold "
                f"{args.minimum_answerable_score:.3f}. The LLM was not called."
            )
            output_dir = _create_output_dir(args.output_dir)
            _write_json(output_dir / "retrieval.json", retrieval_records)
            _write_json(
                output_dir / "decision.json",
                {
                    "called_llm": False,
                    "answerability_score": score,
                    "minimum_answerable_score": args.minimum_answerable_score,
                    "reason": "retrieval-below-threshold",
                },
            )
            (output_dir / "answer.txt").write_text(answer + "\n", encoding="utf-8")
            (output_dir / "question.txt").write_text(
                question + "\n", encoding="utf-8"
            )
            print(answer)
            print(f"\nEvidence directory: {output_dir}")
            return

        context = build_context(
            [(result.chunk.citation, result.chunk.content) for result in results],
            args.max_context_chars,
        )
        payload = build_request_payload(
            question=question,
            context=context,
            model=args.model,
        )
        url = args.endpoint.rstrip("/") + "/chat/completions"
        response = _post_json(url, payload, args.timeout)
        answer = _answer(response)
        validate_citations(
            answer,
            {result.chunk.citation for result in results},
        )

        output_dir = _create_output_dir(args.output_dir)

        _write_json(output_dir / "retrieval.json", retrieval_records)
        _write_json(
            output_dir / "decision.json",
            {
                "called_llm": True,
                "answerability_score": score,
                "minimum_answerable_score": args.minimum_answerable_score,
                "low_confidence_override": args.allow_low_confidence,
            },
        )
        _write_json(output_dir / "request.json", payload)
        _write_json(output_dir / "response.json", response)
        (output_dir / "answer.txt").write_text(answer + "\n", encoding="utf-8")
        (output_dir / "question.txt").write_text(question + "\n", encoding="utf-8")

        print(answer)
        print(f"\nEvidence directory: {output_dir}")
    except (OSError, ValueError, json.JSONDecodeError, sqlite3.Error) as error:
        raise SystemExit(f"ERROR: {error}") from None


if __name__ == "__main__":
    main()
