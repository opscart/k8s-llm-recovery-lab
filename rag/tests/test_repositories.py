import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from raglab.repositories import (
    IngestionStats,
    _allowed_source,
    iter_documents,
    load_repository_snapshots,
)


class RepositoryTests(unittest.TestCase):
    def _git(self, root: Path, *args: str) -> None:
        subprocess.run(
            ["git", "-C", str(root), *args],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _repository(self, parent: Path) -> tuple[Path, Path]:
        root = parent / "repo"
        root.mkdir()
        self._git(root, "init")
        self._git(root, "config", "user.email", "rag-test@example.invalid")
        self._git(root, "config", "user.name", "RAG Test")

        (root / "app.py").write_text("def healthy():\n    return True\n", encoding="utf-8")
        (root / "secret.pem").write_text(
            "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n",
            encoding="utf-8",
        )
        (root / "leak.txt").write_text(
            "token = AKIAABCDEFGHIJKLMNOP\n",
            encoding="utf-8",
        )
        self._git(root, "add", "app.py", "secret.pem", "leak.txt")
        self._git(root, "commit", "-m", "test snapshot")

        config = parent / "repos.json"
        config.write_text(
            json.dumps({"repositories": [{"name": "demo", "path": "repo"}]}),
            encoding="utf-8",
        )
        return root, config

    def test_source_allowlist(self) -> None:
        self.assertTrue(_allowed_source("src/main.go"))
        self.assertTrue(_allowed_source("Dockerfile"))
        self.assertFalse(_allowed_source("vendor/library.go"))
        self.assertFalse(_allowed_source("package-lock.json"))
        self.assertFalse(_allowed_source("assets/logo.png"))

    def test_ingestion_skips_sensitive_files_and_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            _, config = self._repository(base)
            snapshot = load_repository_snapshots(config, base_dir=base)[0]
            stats = IngestionStats()
            documents = list(iter_documents(snapshot, stats=stats))

            self.assertEqual([document.path for document in documents], ["app.py"])
            self.assertEqual(stats.skipped["sensitive-suffix"], 1)
            self.assertEqual(stats.skipped["secret-pattern:aws-access-key"], 1)

    def test_rejects_tracked_modifications(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, config = self._repository(base)
            (root / "app.py").write_text("changed = True\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "tracked modifications"):
                load_repository_snapshots(config, base_dir=base)


if __name__ == "__main__":
    unittest.main()
