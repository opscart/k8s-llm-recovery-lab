"""Shared immutable records used by ingestion and retrieval."""

from dataclasses import dataclass


@dataclass(frozen=True)
class RepositorySnapshot:
    name: str
    root: str
    commit_sha: str


@dataclass(frozen=True)
class SourceDocument:
    repository: str
    commit_sha: str
    path: str
    text: str


@dataclass(frozen=True)
class Chunk:
    repository: str
    commit_sha: str
    path: str
    start_line: int
    end_line: int
    language: str
    content: str
    content_sha256: str

    @property
    def citation(self) -> str:
        short_sha = self.commit_sha[:12]
        return (
            f"[{self.repository}:{self.path}:"
            f"{self.start_line}-{self.end_line}@{short_sha}]"
        )
