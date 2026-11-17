/* Open /__test__/dom.html with scripts/preview-web.py. Real DOM, no imitation DOM library. */
import { fixtures } from "/__test__/fixtures.mjs";
const results = document.querySelector("#test-results");
const assert = (condition, message) => { if (!condition) throw new Error(message); };
try {
  const { createDashboard } = await import("/dashboard.mjs");
  const dashboard = createDashboard(document);
  let checked = 0;
  for (const [name, snapshot] of Object.entries(fixtures)) {
    dashboard.render(snapshot);
    assert(document.querySelector("h1").textContent === snapshot.headline, `${name}: headline`);
    assert(document.querySelectorAll(".problem").length === snapshot.problems.length, `${name}: problem count`);
    assert(document.querySelector("#mascot").dataset.mood === snapshot.mood, `${name}: mood`);
    assert(document.querySelector("#coverage").textContent.includes(`${snapshot.coverage.fresh} of ${snapshot.coverage.active}`), `${name}: coverage`);
    checked++;
  }
  dashboard.render(fixtures.long);
  assert(document.querySelector(".output-preview").textContent === fixtures.long.problems[0].output, "Nagios output stays literal");
  assert(!document.querySelector(".problem img, .problem script"), "XSS rendered as markup");
  const details = document.querySelector(".problem");
  const summary = details.querySelector("summary");
  details.open = true;
  summary.focus();
  dashboard.render({...fixtures.long,problems:[{...fixtures.long.problems[0],output:"Changed output"},...fixtures.long.problems.slice(1)]});
  assert(details === document.querySelector(".problem") && details.open, "Open details replaced");
  assert(document.activeElement === summary, "Keyboard focus lost on refresh");
  assert(details.querySelector(".output-preview").textContent === "Changed output", "Output did not update");
  dashboard.render({...fixtures.long,problems:[fixtures.long.problems[1],fixtures.long.problems[0],...fixtures.long.problems.slice(2)]});
  console.log("Reordered focus", document.activeElement?.tagName);
  assert(document.activeElement === summary, "Keyboard focus lost on reordered refresh");
  dashboard.render(fixtures.long);
  assert(document.activeElement === summary, "Keyboard focus lost when row moves earlier");
  dashboard.render({...fixtures.critical,coverage:{active:2,fresh:1},servers:fixtures.partial.servers});
  assert(document.querySelector("#notice").textContent.includes("1 of 2"), "Critical hides partial coverage");
  assert(document.querySelector("#sources").textContent.includes("Unreachable"), "Critical hides failed source");
  dashboard.disconnected();
  assert(document.querySelector("#connection").textContent.includes("Connection lost"), "Missing connection warning");
  assert(document.querySelectorAll(".problem").length === 4, "Lost last known problems");
  assert(document.querySelector("#mascot").dataset.mood !== "ok", "Disconnected healthy mascot");
  const many = {...fixtures.critical, problems:Array.from({length:107},(_,i)=>({...fixtures.critical.problems[0],id:`many-${i}`}))};
  dashboard.render(many);
  const pageSize = innerWidth < 1100 ? 107 : innerHeight <= 900 ? 5 : 8;
  console.log("TV pagination", {visible:document.querySelectorAll(".problem:not([hidden])").length, expected:pageSize});
  assert(document.querySelectorAll(".problem:not([hidden])").length === pageSize, "TV page size");
  if (innerWidth >= 1100) {
    assert(!document.querySelector("#pagination").hidden, "Missing page controls");
    document.querySelector("#next-page").click();
    assert(document.querySelector(".problem:not([hidden])").dataset.id === `many-${pageSize}`, "Next page skips or reorders problems");
    document.querySelector("#previous-page").click();
    assert(document.querySelector(".problem:not([hidden])").dataset.id === "many-0", "Previous page");
  } else assert(document.querySelector("#pagination").hidden, "Mobile must show a normal list");
  results.textContent = `PASS: ${checked} states; literal XSS; detail/focus preservation; partial critical; connection failure.`;
  results.dataset.result = "pass";
} catch (error) {
  results.textContent = `FAIL: ${error.message}`;
  results.dataset.result = "fail";
  throw error;
}
