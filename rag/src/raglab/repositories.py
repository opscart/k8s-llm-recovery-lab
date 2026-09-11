"""Read only tracked, clean, allowlisted repository snapshots."""

from __future__ import annotations

import json
import subprocess
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Iterator

from .models import RepositorySnapshot, SourceDocument
from .security import secret_pattern, sensitive_path
from .settings import (
    ALLOWED_FILENAMES,
    ALLOWED_SUFFIXES,
    EXCLUDED_DIRECTORIES,
    EXCLUDED_FILENAMES,
    MAX_FILE_BYTES,
)


@dataclass
class IngestionStats:
    indexed_files: int = 0
    indexed_bytes: int = 0
    skipped: Counter[str] = field(default_factory=Counter)


def _git(root: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


def load_repository_snapshots(
    config_path: Path, *, base_dir: Path
) -> list[RepositorySnapshot]:
    """Load and verify named repository roots from the local-only config."""

    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read repository config {config_path}: {error}") from error

    entries = config.get("repositories")
    if not isinstance(entries, list) or not entries:
        raise ValueError("repository config must contain a non-empty 'repositories' list")

    snapshots: list[RepositorySnapshot] = []
    names: set[str] = set()
    roots: set[Path] = set()

    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("each repository entry must be an object")

        name = entry.get("name")
        configured_path = entry.get("path")
        if not isinstance(name, str) or not name.strip():
            raise ValueError("each repository must have a non-empty name")
        if not isinstance(configured_path, str) or not configured_path.strip():
            raise ValueError(f"repository {name!r} must have a non-empty path")
        if name in names:
            raise ValueError(f"duplicate repository name: {name}")

        candidate = (base_dir / configured_path).resolve()
        if not candidate.is_dir():
            raise ValueError(f"repository path does not exist: {candidate}")

        try:
            root = Path(_git(candidate, "rev-parse", "--show-toplevel")).resolve()
            commit_sha = _git(root, "rev-parse", "HEAD")
            dirty = _git(root, "status", "--porcelain", "--untracked-files=no")
        except subprocess.CalledProcessError as error:
            detail = error.stderr.strip() or str(error)
            raise ValueError(f"could not inspect repository {candidate}: {detail}") from error

        if dirty:
            raise ValueError(
                f"repository {name!r} has tracked modifications; commit or stash them "
                "before creating an evidence-bearing index"
            )
        if root in roots:
            raise ValueError(f"repository root configured more than once: {root}")

        names.add(name)
        roots.add(root)
        snapshots.append(
            RepositorySnapshot(name=name, root=str(root), commit_sha=commit_sha)
        )

    return snapshots


def _tracked_paths(root: Path) -> list[str]:
    completed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return [item.decode("utf-8") for item in completed.stdout.split(b"\0") if item]


def _allowed_source(relative_path: str) -> bool:
    path = PurePosixPath(relative_path)
    lowered_parts = {part.lower() for part in path.parts[:-1]}
    lowered_name = path.name.lower()

    if lowered_parts & EXCLUDED_DIRECTORIES:
        return False
    if path.name in EXCLUDED_FILENAMES:
        return False
    if lowered_name.endswith((".min.js", ".min.css", ".map")):
        return False

    return path.name in ALLOWED_FILENAMES or any(
        lowered_name.endswith(suffix) for suffix in ALLOWED_SUFFIXES
    )


def iter_documents(
    snapshot: RepositorySnapshot, *, stats: IngestionStats
) -> Iterator[SourceDocument]:
    """Yield safe UTF-8 documents from the Git-tracked snapshot."""

    root = Path(snapshot.root)

    for relative_path in _tracked_paths(root):
        pure_path = PurePosixPath(relative_path)
        candidate = root / relative_path

        if candidate.is_symlink():
            stats.skipped["non-regular-file"] += 1
            continue

        path = candidate.resolve()
        if not path.is_relative_to(root) or not path.is_file():
            stats.skipped["non-regular-file"] += 1
            continue
        path_reason = sensitive_path(pure_path)
        if path_reason:
            stats.skipped[path_reason] += 1
            continue
        if not _allowed_source(relative_path):
            stats.skipped["unsupported-or-generated"] += 1
            continue

        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            stats.skipped["file-too-large"] += 1
            continue

        data = path.read_bytes()
        if b"\0" in data[:8192]:
            stats.skipped["binary"] += 1
            continue

        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            stats.skipped["non-utf8"] += 1
            continue

        if not text.strip():
            stats.skipped["empty"] += 1
            continue
        if max((len(line) for line in text.splitlines()), default=0) > 20_000:
            stats.skipped["generated-long-line"] += 1
            continue

        content_reason = secret_pattern(text)
        if content_reason:
            stats.skipped[f"secret-pattern:{content_reason}"] += 1
            continue

        stats.indexed_files += 1
        stats.indexed_bytes += size
        yield SourceDocument(
            repository=snapshot.name,
            commit_sha=snapshot.commit_sha,
            path=relative_path,
            text=text,
        )
