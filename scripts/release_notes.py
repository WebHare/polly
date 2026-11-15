"""Run: python3 scripts/release_notes.py 0.2.0 CHANGELOG.md"""
import re
import sys
from pathlib import Path


def release_notes(markdown: str, version: str) -> str:
    heading = rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}[ \t]*$"
    matches = list(re.finditer(heading, markdown, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(f'Expected one dated changelog section for version "{version}"')
    notes = re.split(r"^## ", markdown[matches[0].end():], maxsplit=1, flags=re.MULTILINE)[0].strip()
    if not re.search(r"^- \S", notes, re.MULTILINE):
        raise ValueError(f'Changelog for version "{version}" has no entries')
    return notes + "\n"


if __name__ == "__main__":
    print(release_notes(Path(sys.argv[2]).read_text(), sys.argv[1]), end="")
