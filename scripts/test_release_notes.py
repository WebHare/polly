"""Run: python3 -m unittest discover -s scripts -p 'test_*.py'"""
import unittest
from release_notes import release_notes

class ReleaseNotesTests(unittest.TestCase):
    def test_selects_exact_version_without_unreleased_or_older_notes(self):
        source = "# Changelog\n## [Unreleased]\n- Secret future feature\n## [0.2.0] - 2026-11-15\n\n### Added\n\n- Updates\n\n## [0.1.0] - 2026-11-14\n- Old\n"
        self.assertEqual(release_notes(source, "0.2.0"), "### Added\n\n- Updates\n")

    def test_refuses_missing_empty_and_duplicate_versions(self):
        for source in ["", "## [0.2.0] - 2026-11-15\n", "## [0.2.0] - 2026-11-15\n- A\n## [0.2.0] - 2026-11-15\n- B"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                release_notes(source, "0.2.0")
