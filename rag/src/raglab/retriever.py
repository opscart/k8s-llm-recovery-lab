"""Hybrid dense and SQLite FTS retrieval with reciprocal-rank fusion."""

from __future__ import annotations

import json
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer

from .models import Chunk
from .settings import EMBEDDING_MODEL, EMBEDDING_REVISION, QUERY_PREFIX


_STOPWORDS = {
    "a",
    "an",
    "and",
    "are",
    "be",
    "for",
    "from",
    "how",
    "in",
    "is",
    "it",
    "of",
    "on",
    "or",
    "that",
    "the",
    "this",
    "to",
    "what",
    "when",
    "where",
    "which",
    "with",
}


@dataclass(frozen=True)
class RetrievalResult:
    chunk_id: int
    chunk: Chunk
    fused_score: float
    dense_rank: int | None
    lexical_rank: int | None
    dense_similarity: float | None


def _fts_query(question: str) -> str | None:
    tokens = [
        token
        for token in re.findall(r"[A-Za-z0-9_]{2,}", question.lower())
        if token not in _STOPWORDS
    ]
    unique_tokens = list(dict.fromkeys(tokens))[:24]
    if not unique_tokens:
        return None
    return " OR ".join(f'"{token}"' for token in unique_tokens)


class HybridRetriever:
    def __init__(self, index_dir: Path) -> None:
        self.index_dir = index_dir.resolve()
        manifest_path = self.index_dir / "manifest.json"
        database_path = self.index_dir / "chunks.sqlite3"
        embeddings_path = self.index_dir / "embeddings.npy"

        try:
            self.manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"could not read index manifest: {error}") from error

        if self.manifest.get("schema_version") != 1:
            raise ValueError("unsupported index schema version")
        if self.manifest.get("embedding_model") != EMBEDDING_MODEL:
            raise ValueError("index uses a different embedding model")
        if self.manifest.get("embedding_revision") != EMBEDDING_REVISION:
            raise ValueError("index uses a different embedding revision")

        try:
            self.embeddings = np.load(embeddings_path, mmap_mode="r", allow_pickle=False)
        except OSError as error:
            raise ValueError(f"could not read embeddings: {error}") from error

        expected_count = self.manifest.get("chunk_count")
        if self.embeddings.ndim != 2 or self.embeddings.shape[0] != expected_count:
            raise ValueError("embedding array does not match index manifest")

        database_uri = f"file:{database_path.as_posix()}?mode=ro"
        self.connection = sqlite3.connect(database_uri, uri=True)
        self.connection.row_factory = sqlite3.Row
        self.model = SentenceTransformer(
            EMBEDDING_MODEL,
            revision=EMBEDDING_REVISION,
            device="cpu",
            trust_remote_code=False,
            local_files_only=True,
        )

    def close(self) -> None:
        self.connection.close()

    def _dense_candidates(
        self, question: str, candidate_count: int
    ) -> tuple[list[int], dict[int, float]]:
        query_embedding = self.model.encode(
            [QUERY_PREFIX + question],
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=False,
        )[0].astype(np.float32, copy=False)

        similarities = np.asarray(self.embeddings @ query_embedding)
        limit = min(candidate_count, similarities.shape[0])
        if limit == 0:
            return [], {}

        indices = np.argpartition(similarities, -limit)[-limit:]
        ordered = indices[np.argsort(similarities[indices])[::-1]]
        chunk_ids = [int(index) + 1 for index in ordered]
        scores = {
            int(index) + 1: float(similarities[index])
            for index in ordered
        }
        return chunk_ids, scores

    def _lexical_candidates(self, question: str, candidate_count: int) -> list[int]:
        query = _fts_query(question)
        if query is None:
            return []

        rows = self.connection.execute(
            """
            SELECT rowid
            FROM chunks_fts
            WHERE chunks_fts MATCH ?
            ORDER BY bm25(chunks_fts)
            LIMIT ?
            """,
            (query, candidate_count),
        ).fetchall()
        return [int(row["rowid"]) for row in rows]

    def retrieve(
        self, question: str, *, top_k: int = 6, candidate_count: int = 40
    ) -> list[RetrievalResult]:
        if not question.strip():
            raise ValueError("question must not be empty")
        if top_k < 1 or candidate_count < top_k:
            raise ValueError("candidate_count must be at least top_k, and top_k must be positive")

        dense_ids, dense_scores = self._dense_candidates(question, candidate_count)
        lexical_ids = self._lexical_candidates(question, candidate_count)

        dense_ranks = {chunk_id: rank for rank, chunk_id in enumerate(dense_ids, start=1)}
        lexical_ranks = {
            chunk_id: rank for rank, chunk_id in enumerate(lexical_ids, start=1)
        }

        fused: dict[int, float] = {}
        for chunk_id, rank in dense_ranks.items():
            fused[chunk_id] = fused.get(chunk_id, 0.0) + 1.0 / (60 + rank)
        for chunk_id, rank in lexical_ranks.items():
            fused[chunk_id] = fused.get(chunk_id, 0.0) + 0.7 / (60 + rank)

        selected_ids = sorted(fused, key=fused.get, reverse=True)[:top_k]
        if not selected_ids:
            return []

        placeholders = ",".join("?" for _ in selected_ids)
        rows = self.connection.execute(
            f"SELECT * FROM chunks WHERE id IN ({placeholders})",
            selected_ids,
        ).fetchall()
        rows_by_id = {int(row["id"]): row for row in rows}

        results: list[RetrievalResult] = []
        for chunk_id in selected_ids:
            row = rows_by_id[chunk_id]
            chunk = Chunk(
                repository=row["repository"],
                commit_sha=row["commit_sha"],
                path=row["path"],
                start_line=int(row["start_line"]),
                end_line=int(row["end_line"]),
                language=row["language"],
                content=row["content"],
                content_sha256=row["content_sha256"],
            )
            results.append(
                RetrievalResult(
                    chunk_id=chunk_id,
                    chunk=chunk,
                    fused_score=fused[chunk_id],
                    dense_rank=dense_ranks.get(chunk_id),
                    lexical_rank=lexical_ranks.get(chunk_id),
                    dense_similarity=dense_scores.get(chunk_id),
                )
            )

        return results
