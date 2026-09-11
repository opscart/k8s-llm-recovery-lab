"""Conservative exclusions applied before any source text reaches the index."""

import re
from pathlib import PurePosixPath

from .settings import SENSITIVE_FILENAMES, SENSITIVE_SUFFIXES


_SECRET_PATTERNS = (
    ("private-key", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b")),
    ("azure-storage-key", re.compile(r"\bAccountKey=[A-Za-z0-9+/=]{20,}")),
)


def sensitive_path(path: PurePosixPath) -> str | None:
    """Return an exclusion reason when a tracked path commonly contains secrets."""

    lowered_name = path.name.lower()
    if lowered_name in SENSITIVE_FILENAMES or lowered_name.startswith(".env."):
        return "sensitive-filename"

    if any(lowered_name.endswith(suffix) for suffix in SENSITIVE_SUFFIXES):
        return "sensitive-suffix"

    return None


def secret_pattern(text: str) -> str | None:
    """Return the first high-confidence credential pattern found in text."""

    for name, pattern in _SECRET_PATTERNS:
        if pattern.search(text):
            return name
    return None
