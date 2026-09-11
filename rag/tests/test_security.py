import unittest
from pathlib import PurePosixPath

from raglab.security import secret_pattern, sensitive_path


class SecurityTests(unittest.TestCase):
    def test_sensitive_paths(self) -> None:
        self.assertEqual(sensitive_path(PurePosixPath(".env")), "sensitive-filename")
        self.assertEqual(
            sensitive_path(PurePosixPath("certificates/client.key")),
            "sensitive-suffix",
        )
        self.assertIsNone(sensitive_path(PurePosixPath("src/secrets_manager.py")))

    def test_high_confidence_secret_patterns(self) -> None:
        self.assertEqual(
            secret_pattern("aws_access_key_id=AKIAABCDEFGHIJKLMNOP"),
            "aws-access-key",
        )
        self.assertEqual(
            secret_pattern("-----BEGIN OPENSSH PRIVATE KEY-----"),
            "private-key",
        )
        self.assertIsNone(secret_pattern("api_key = os.environ['API_KEY']"))


if __name__ == "__main__":
    unittest.main()
