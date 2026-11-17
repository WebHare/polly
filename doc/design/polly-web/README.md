# Polly web design sources

The five files in `source/` are byte-for-byte copies of Wouter's supplied
`Polly monitoring companion design (1)` export, imported on 16 November 2026. They are references, never
production pages. The generator checks the following independently recorded SHA-256 hashes:

| Export | SHA-256 |
| --- | --- |
| Polly Design System.dc.html | `061de785163967b061f75ae565419b01ef404ed8c1e26574b298831b8a1a2e7f` |
| Polly Animations.dc.html | `2239499aba2df81bbbc694aacc4ea4a9b889a568f24ab0b4f41c9d348e7803c7` |
| Polly Animations.html | `b4f628280da395b0f33c04b219bfa90714d9613153a07a3f4b6fa12dbe5e57c7` |
| PollyMascot.dc.html | `906fce923ec5e71bc9c16509e45103d5713ae8db2d0bc19d8fc1324fdfd862c2` |
| StatusIcon.dc.html | `d89e524bb53567b77c7508f49837c6fae6d363e2c77d369301cc3f02edf8411c` |

Run `python3 /absolute/path/to/polly/scripts/generate-web-design.py` to reproduce the assets, or add
`--check` to compare without writing. It extracts all four mascot SVG trees and 15 keyframes, turns inline
styles into external classes for CSP, and substitutes semantic colors in the original four status shapes.
The source SVG grouping, coordinates, transform origins, durations and easing stay unchanged. The Node
asset test reverses the class extraction and compares complete trees against the original export, not
against the generator's own output. A deliberately changed pivot must fail that comparison. Initial
extraction from the unmodified sources and the subsequent check produce identical bytes.

The authored `dashboard.css` holds semantic tokens and responsive layouts. Dark critical/unknown colors
follow the design-system palette specified in the dashboard contract; light green and purple are slightly
darker for contrast. A mascot's fixed illustration colors stay exactly as drawn. No generic center-origin
rule may be applied to the SVG groups.

## Fonts and licenses

All 11 WOFF2 files are extracted unchanged from the standalone animation bundle. The original 26 font-face
rules preserve family, weights and Unicode ranges, changing only the URLs to local files. No font download
is needed to regenerate. The bundled fonts were audited with fontTools 4.60.2:

- Bricolage Grotesque: weight axis 200–800, optical-size axis 12–96; UI requests 700/800.
- Figtree: weight axis 300–900; UI requests 400/500/600/700.
- JetBrains Mono: weight axis 400–800; UI requests 400/500.
- Each family includes a Latin subset covering every printable ASCII character; Latin extended and the
  other supplied subsets are also retained. CSS declares the original Unicode ranges. Other characters
  use the system fallback; no claim of universal language coverage is made.

The SIL Open Font License 1.1 and copyright statements are bundled beside the fonts. Original license
sources: [Bricolage Grotesque](https://github.com/google/fonts/blob/main/ofl/bricolagegrotesque/OFL.txt),
[Figtree](https://github.com/google/fonts/blob/main/ofl/figtree/OFL.txt),
[JetBrains Mono](https://github.com/google/fonts/blob/main/ofl/jetbrainsmono/OFL.txt).

No support.js, React, design custom elements, external font requests or bundler loader is shipped in the
public directory. The unmodified source archive naturally still contains those reference dependencies.
