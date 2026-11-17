#!/usr/bin/env python3
"""Run: python3 /absolute/path/to/polly/scripts/generate-dev-icon.py [--check]

Add the shared yellow DEV ribbon to the exported macOS icons. Requires rsvg-convert.
The release icons remain the source and are never rewritten.
"""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "App/Shared/Assets.xcassets"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = ASSETS / "AppIcon.appiconset"
    target = ASSETS / "AppIconDev.appiconset"
    contents = json.loads((source / "Contents.json").read_text())
    contents["images"] = [image for image in contents["images"] if image["idiom"] == "mac"]
    outputs = {"Contents.json": (json.dumps(contents, indent=2) + "\n").encode()}
    with tempfile.TemporaryDirectory(prefix="polly-dev-icon-") as temporary:
        for filename in sorted({image["filename"] for image in contents["images"]}):
            size = int(filename.removeprefix("mac-").removesuffix(".png"))
            encoded = base64.b64encode((source / filename).read_bytes()).decode()
            # Keep the export's Dock margins; the ribbon is clipped to its rounded tile.
            svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">
<image href="data:image/png;base64,{encoded}" width="{size}" height="{size}"/>
<g transform="scale({size / 1024})">
<defs><clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath></defs>
<g clip-path="url(#tile)"><g transform="translate(760 264) rotate(45)">
<rect x="-400" y="-66" width="800" height="132" fill="#FFD900"/>
<text x="0" y="0" dy="0.36em" text-anchor="middle" font-family="Helvetica" font-weight="700" font-size="92" fill="#1E2824">DEV</text>
</g></g></g></svg>'''
            rendered = Path(temporary) / filename
            subprocess.run(["rsvg-convert", "-o", str(rendered)], input=svg.encode(), check=True)
            outputs[filename] = rendered.read_bytes()
    if not args.check:
        target.mkdir(exist_ok=True)
    for filename, data in outputs.items():
        path = target / filename
        if args.check:
            assert path.is_file() and path.read_bytes() == data, f"Regenerate {path}"
        else:
            path.write_bytes(data)
    print(f"✅ {'Checked' if args.check else 'Generated'} {len(outputs) - 1} macOS DEV icons.")


if __name__ == "__main__":
    main()
