/* node --test /absolute/path/to/polly/scripts/web/design.test.mjs */
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { mascots, icons } from "../../Packages/PollyWeb/Sources/PollyWeb/Public/design.mjs";

const source = new URL("../../doc/design/polly-web/source/", import.meta.url);
const assets = new URL("../../Packages/PollyWeb/Sources/PollyWeb/Public/", import.meta.url);
const read = (base, name) => readFileSync(new URL(name, base), "utf8");
const hashes = {
  "Polly Design System.dc.html": "061de785163967b061f75ae565419b01ef404ed8c1e26574b298831b8a1a2e7f",
  "Polly Animations.dc.html": "2239499aba2df81bbbc694aacc4ea4a9b889a568f24ab0b4f41c9d348e7803c7",
  "Polly Animations.html": "b4f628280da395b0f33c04b219bfa90714d9613153a07a3f4b6fa12dbe5e57c7",
  "PollyMascot.dc.html": "906fce923ec5e71bc9c16509e45103d5713ae8db2d0bc19d8fc1324fdfd862c2",
  "StatusIcon.dc.html": "d89e524bb53567b77c7508f49837c6fae6d363e2c77d369301cc3f02edf8411c",
};
const css = read(assets, "design.css");
const restoreStyles = svg => svg.replace(/class="(design-\d+)"/g, (_, name) => {
  const rule = css.match(new RegExp(`\\.${name}\\{([^}]+)\\}`));
  assert.ok(rule, name);
  return `style="${rule[1]}"`;
});

test("five archived exports have their independently recorded hashes", () => {
  for (const [name, hash] of Object.entries(hashes))
    assert.equal(createHash("sha256").update(readFileSync(new URL(name, source))).digest("hex"), hash);
});

test("all four SVG trees, pivots and timings exactly reproduce the original export", () => {
  const original = [...read(source, "Polly Animations.dc.html").matchAll(/<svg viewBox="-24 -18 248 248"[\s\S]*?<\/svg>/g)].map(m => m[0]);
  assert.equal(original.length, 4);
  assert.deepEqual(Object.keys(mascots), ["ok", "warning", "critical", "unreachable"]);
  Object.values(mascots).forEach((svg, i) => assert.equal(restoreStyles(svg), original[i]));
  const keyframes = read(source, "Polly Animations.dc.html").split("\n").filter(l => l.startsWith("@keyframes"));
  assert.equal(keyframes.length, 15);
  for (const line of keyframes) assert.ok(css.includes(line), line);
  // A wrong joint must actually fail the independent source comparison.
  assert.notEqual(restoreStyles(mascots.ok).replace("104px", "105px"), original[0]);
});

test("every status shape comes from StatusIcon with semantic colors", () => {
  const originals = [...read(source, "StatusIcon.dc.html").matchAll(/<svg [\s\S]*?<\/svg>/g)].map(m => m[0]);
  assert.equal(originals.length, 4);
  Object.values(icons).forEach((svg, i) => assert.equal(restoreStyles(svg), originals[i]
    .replaceAll("{{fill}}", "var(--status-fill)").replaceAll("{{glyph}}", "var(--status-glyph)")));
});

test("fonts are bundled locally with all design weights and Latin coverage", () => {
  const fontCSS = read(assets, "fonts.css");
  for (const family of ["Bricolage Grotesque", "Figtree", "JetBrains Mono"]) {
    for (const weight of family === "Figtree" ? [400, 500, 600, 700] : family === "JetBrains Mono" ? [400, 500] : [700, 800]) {
      assert.ok([...fontCSS.matchAll(/@font-face\s*\{([^}]+)\}/g)].some(m => m[1].includes(`'${family}'`) && m[1].includes(`font-weight: ${weight};`) && m[1].includes("U+0000-00FF")));
    }
  }
  for (const [, path] of fontCSS.matchAll(/url\("([^\"]+)"\)/g)) {
    assert.ok(path.startsWith("fonts/"));
    assert.equal(readFileSync(new URL(path, assets)).subarray(0, 4).toString(), "wOF2");
  }
  assert.doesNotMatch(JSON.stringify({mascots, icons}) + css + fontCSS, /https?:|support\.js|<script|<x-dc|<dc-import|style=/);
});
