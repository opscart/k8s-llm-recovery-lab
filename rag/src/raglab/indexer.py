"""Build an immutable dense-plus-FTS index from clean Git snapshots."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer

from .chunker import chunk_source
from .models import Chunk
from .repositories import IngestionStats, iter_documents, load_repository_snapshots
from .settings import EMBEDDING_BATCH_SIZE, EMBEDDING_MODEL, EMBEDDING_REVISION


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--base-dir",
        type=Path,
        default=Path.cwd(),
        help="Base for repository paths in the config (default: current directory)",
    )
    parser.add_argument("--batch-size", type=int, default=EMBEDDING_BATCH_SIZE)
    return parser


def _write_database(path: Path, chunks: list[Chunk]) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.executescript(
            """
            PRAGMA journal_mode=DELETE;
            PRAGMA synchronous=FULL;

            CREATE TABLE chunks (
                id INTEGER PRIMARY KEY,
                repository TEXT NOT NULL,
                commit_sha TEXT NOT NULL,
                path TEXT NOT NULL,
                start_line INTEGER NOT NULL,
                end_line INTEGER NOT NULL,
                language TEXT NOT NULL,
                content TEXT NOT NULL,
                content_sha256 TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE chunks_fts USING fts5(
                content,
                content='chunks',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );

            CREATE INDEX chunks_source
                ON chunks(repository, path, start_line, end_line);
            """
        )

        for chunk_id, chunk in enumerate(chunks, start=1):
            connection.execute(
                """
                INSERT INTO chunks(
                    id, repository, commit_sha, path, start_line, end_line,
                    language, content, content_sha256
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    chunk_id,
                    chunk.repository,
                    chunk.commit_sha,
                    chunk.path,
                    chunk.start_line,
                    chunk.end_line,
                    chunk.language,
                    chunk.content,
                    chunk.content_sha256,
                ),
            )
            connection.execute(
                "INSERT INTO chunks_fts(rowid, content) VALUES (?, ?)",
                (
                    chunk_id,
                    f"{chunk.repository} {chunk.path}\n{chunk.content}",
                ),
            )

        connection.commit()
    finally:
        connection.close()


def build_index(*, config: Path, output: Path, base_dir: Path, batch_size: int) -> None:
    config = config.resolve()
    output = output.resolve()
    base_dir = base_dir.resolve()

    if batch_size < 1:
        raise ValueError("batch size must be positive")
    if output.exists():
        raise ValueError(
            f"output already exists: {output}; preserve it and choose a new index path"
        )

    snapshots = load_repository_snapshots(config, base_dir=base_dir)
    stats = IngestionStats()
    chunks: list[Chunk] = []

    for snapshot in snapshots:
        print(f"Reading {snapshot.name}@{snapshot.commit_sha[:12]}")
        for document in iter_documents(snapshot, stats=stats):
            for chunk in chunk_source(
                repository=document.repository,
                commit_sha=document.commit_sha,
                path=document.path,
                text=document.text,
            ):
                chunks.append(chunk)

    if not chunks:
        raise ValueError("no indexable chunks were produced")

    print(f"Embedding {len(chunks)} chunks on CPU with {EMBEDDING_MODEL}")
    model = SentenceTransformer(
        EMBEDDING_MODEL,
        revision=EMBEDDING_REVISION,
        device="cpu",
        trust_remote_code=False,
    )
    embedding_inputs = [
        f"Repository: {chunk.repository}\nPath: {chunk.path}\n\n{chunk.content}"
        for chunk in chunks
    ]
    embeddings = model.encode(
        embedding_inputs,
        batch_size=batch_size,
        convert_to_numpy=True,
        normalize_embeddings=True,
        show_progress_bar=True,
    ).astype(np.float32, copy=False)

    if embeddings.ndim != 2 or embeddings.shape[0] != len(chunks):
        raise ValueError(f"unexpected embedding shape: {embeddings.shape}")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f"{output.name}.building-{os.getpid()}")
    if temporary.exists():
        raise ValueError(f"temporary index path already exists: {temporary}")
    temporary.mkdir()

    try:
        np.save(temporary / "embeddings.npy", embeddings, allow_pickle=False)
        _write_database(temporary / "chunks.sqlite3", chunks)

        manifest = {
            "schema_version": 1,
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
            "embedding_model": EMBEDDING_MODEL,
            "embedding_revision": EMBEDDING_REVISION,
            "embedding_dimension": int(embeddings.shape[1]),
            "chunk_count": len(chunks),
            "indexed_files": stats.indexed_files,
            "indexed_bytes": stats.indexed_bytes,
            "skipped": dict(sorted(Counter(stats.skipped).items())),
            "repositories": [
                {"name": snapshot.name, "commit_sha": snapshot.commit_sha}
                for snapshot in snapshots
            ],
            "config_sha256": hashlib.sha256(config.read_bytes()).hexdigest(),
        }
        (temporary / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, output)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise

    print(f"Index written: {output}")
    print(f"Chunks       : {len(chunks)}")
    print(f"Files        : {stats.indexed_files}")
    print(f"Skipped      : {sum(stats.skipped.values())}")


def main() -> None:
    args = _parser().parse_args()
    try:
        build_index(
            config=args.config,
            output=args.output,
            base_dir=args.base_dir,
            batch_size=args.batch_size,
        )
    except (OSError, ValueError, sqlite3.Error) as error:
        raise SystemExit(f"ERROR: {error}") from None


if __name__ == "__main__":
    main()
