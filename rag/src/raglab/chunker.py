"""Line-preserving, boundary-aware chunks with exact citation ranges."""

import hashlib
import re
from pathlib import PurePosixPath

from .models import Chunk
from .settings import MAX_CHUNK_CHARS, OVERLAP_LINES


_BOUNDARY = re.compile(
    r"^(?:"
    r"#{1,6}\s+|"
    r"---\s*$|"
    r"apiVersion:\s*|"
    r"(?:async\s+)?def\s+|"
    r"class\s+|"
    r"func\s+|"
    r"type\s+\w+\s+(?:struct|interface)\b|"
    r"(?:export\s+)?(?:async\s+)?function\s+|"
    r"(?:resource|module|data|variable|output)\s+\"|"
    r"(?:public|private|protected|internal)\s+(?:class|interface|record)\s+"
    r")"
)


_LANGUAGE_BY_SUFFIX = {
    ".c": "c",
    ".cc": "cpp",
    ".cpp": "cpp",
    ".cs": "csharp",
    ".go": "go",
    ".h": "c-header",
    ".hcl": "hcl",
    ".html": "html",
    ".java": "java",
    ".js": "javascript",
    ".json": "json",
    ".jsx": "javascript",
    ".kt": "kotlin",
    ".kts": "kotlin",
    ".md": "markdown",
    ".proto": "protobuf",
    ".ps1": "powershell",
    ".py": "python",
    ".rb": "ruby",
    ".rs": "rust",
    ".sh": "shell",
    ".sql": "sql",
    ".tf": "terraform",
    ".toml": "toml",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".xml": "xml",
    ".yaml": "yaml",
    ".yml": "yaml",
}


def language_for_path(path: str) -> str:
    parsed = PurePosixPath(path)
    if parsed.name == "Dockerfile":
        return "dockerfile"
    if parsed.name == "Jenkinsfile":
        return "groovy"
    if parsed.name == "Makefile":
        return "make"
    return _LANGUAGE_BY_SUFFIX.get(parsed.suffix.lower(), "text")


def _candidate_end(lines: list[str], start: int, max_chars: int) -> int:
    size = 0
    end = start

    while end < len(lines):
        next_size = size + len(lines[end]) + 1
        if end > start and next_size > max_chars:
            break
        size = next_size
        end += 1

    if end >= len(lines):
        return end

    halfway = start + max(1, (end - start) // 2)
    boundaries = [index for index in range(halfway, end) if _BOUNDARY.match(lines[index])]
    return boundaries[-1] if boundaries else end


def chunk_source(
    *,
    repository: str,
    commit_sha: str,
    path: str,
    text: str,
    max_chars: int = MAX_CHUNK_CHARS,
    overlap_lines: int = OVERLAP_LINES,
) -> list[Chunk]:
    """Split source while preserving stable, one-based line citations."""

    if max_chars < 256:
        raise ValueError("max_chars must be at least 256")
    if overlap_lines < 0:
        raise ValueError("overlap_lines must not be negative")

    lines = text.splitlines()
    chunks: list[Chunk] = []
    start = 0

    while start < len(lines):
        end = _candidate_end(lines, start, max_chars)
        if end <= start:
            end = start + 1

        content = "\n".join(lines[start:end]).strip()
        if content:
            chunks.append(
                Chunk(
                    repository=repository,
                    commit_sha=commit_sha,
                    path=path,
                    start_line=start + 1,
                    end_line=end,
                    language=language_for_path(path),
                    content=content,
                    content_sha256=hashlib.sha256(content.encode("utf-8")).hexdigest(),
                )
            )

        if end >= len(lines):
            break

        start = max(start + 1, end - overlap_lines)

    return chunks
