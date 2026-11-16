"""Run: python3 scripts/release_notes.py 0.2.0 CHANGELOG.md
or:  python3 scripts/release_notes.py --testflight 0.2.0 CHANGELOG.md"""
import re
import sys
from pathlib import Path


def release_notes(markdown: str, version: str) -> str:
    heading = rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}[ \t]*$"
    matches = list(re.finditer(heading, markdown, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(f'Expected one dated changelog section for version "{version}"')
    return _entries(markdown[matches[0].end():], version)


def testflight_notes(markdown: str, version: str) -> str:
    """'What to Test' text: the dated section for the version, or [Unreleased] for a beta of a version that
    is not dated yet. TestFlight shows plain text, so '### Added' becomes 'Added:' and emphasis is dropped."""
    try:
        notes = release_notes(markdown, version)
    except ValueError:
        match = re.search(r"^## \[Unreleased\][ \t]*$", markdown, re.MULTILINE)
        if not match:
            raise ValueError(f'No changelog section for version "{version}" and no [Unreleased] section')
        notes = _entries(markdown[match.end():], "Unreleased")
    text = re.sub(r"^### (.+?)[ \t]*$", r"\1:", notes, flags=re.MULTILINE)
    text = re.sub(r"\*\*|`", "", text)
    return re.sub(r"\n{2,}", "\n", text).strip() + "\n"


def _entries(rest: str, version: str) -> str:
    notes = re.split(r"^## ", rest, maxsplit=1, flags=re.MULTILINE)[0].strip()
    if not re.search(r"^- \S", notes, re.MULTILINE):
        raise ValueError(f'Changelog for version "{version}" has no entries')
    return notes + "\n"


if __name__ == "__main__":
    args = sys.argv[1:]
    select = release_notes
    if args and args[0] == "--testflight":
        select, args = testflight_notes, args[1:]
    print(select(Path(args[1]).read_text(), args[0]), end="")
