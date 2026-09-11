import unittest

from raglab.chunker import chunk_source, language_for_path


class ChunkerTests(unittest.TestCase):
    def test_preserves_line_ranges_and_overlap(self) -> None:
        text = "\n".join(f"line {index}: {'x' * 40}" for index in range(1, 31))
        chunks = chunk_source(
            repository="demo",
            commit_sha="a" * 40,
            path="src/app.py",
            text=text,
            max_chars=300,
            overlap_lines=2,
        )

        self.assertGreater(len(chunks), 1)
        self.assertEqual(chunks[0].start_line, 1)
        self.assertEqual(chunks[-1].end_line, 30)
        self.assertLessEqual(chunks[1].start_line, chunks[0].end_line)
        self.assertTrue(all(chunk.content_sha256 for chunk in chunks))

    def test_prefers_source_boundaries_near_chunk_limit(self) -> None:
        text = "\n".join(
            [
                "header = True",
                f"x = '{'a' * 100}'",
                f"x = '{'b' * 100}'",
                "def second_function():",
                "    return 2",
                "tail = True",
            ]
        )
        chunks = chunk_source(
            repository="demo",
            commit_sha="b" * 40,
            path="app.py",
            text=text,
            max_chars=256,
            overlap_lines=0,
        )

        self.assertEqual(chunks[0].end_line, 3)
        self.assertEqual(chunks[1].start_line, 4)

    def test_language_detection(self) -> None:
        self.assertEqual(language_for_path("deploy/chart.yaml"), "yaml")
        self.assertEqual(language_for_path("Dockerfile"), "dockerfile")
        self.assertEqual(language_for_path("src/main.go"), "go")


if __name__ == "__main__":
    unittest.main()
