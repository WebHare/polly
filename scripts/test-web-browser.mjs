/* POLLY_PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node /absolute/path/to/polly/scripts/test-web-browser.mjs
   Uses installed Playwright, starts its own loopback fixture server, stops both in finally. */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { fixtures } from "./web/fixtures.mjs";
const { chromium } = await import(process.env.POLLY_PLAYWRIGHT || "playwright");
const output = process.env.POLLY_SCREENSHOTS || "/tmp/polly-browser-screens";
await mkdir(output, {recursive:true});
const server = spawn("python3", [fileURLToPath(new URL("./preview-web.py", import.meta.url))], {stdio:["ignore","pipe","pipe"]});
let browser;
try {
  const base = await new Promise((resolve, reject) => {
    const timeout = setTimeout(()=>reject(new Error("Preview did not start")),10000);
    server.once("exit", code=> { clearTimeout(timeout); reject(new Error(`Preview exited ${code}`)); });
    server.stdout.on("data", data=> { const match = String(data).match(/Preview: (http:\/\/127\.0\.0\.1:\d+)\//); if (match) { clearTimeout(timeout); resolve(match[1]); } });
  });
  browser = await chromium.launch();
  const page = await browser.newPage();
  const failures = [];
  const external = [];
  page.on("pageerror", error=>failures.push(error.message));
  page.on("request", request=> { if (!request.url().startsWith(base) && !request.url().startsWith("data:")) external.push(request.url()); });
  await page.goto(`${base}/__test__/dom.html`);
  await page.waitForFunction(()=>document.querySelector("#test-results").dataset.result);
  const result = await page.locator("#test-results").textContent();
  assert.ok(result.startsWith("PASS:"), result);
  console.log(result);
  const fits = async vertical => {
    const size = await page.evaluate(()=>({width:innerWidth,height:innerHeight,scrollWidth:document.documentElement.scrollWidth,bottom:document.querySelector("#sources").getBoundingClientRect().bottom}));
    console.log("Layout", size);
    assert.ok(size.scrollWidth <= size.width, "Horizontal overflow");
    if (vertical) assert.ok(size.bottom <= size.height, "Source strip outside TV viewport");
  };
  for (const [width,height,state] of [[1920,1080,"many"],[1280,720,"many"],[1728,873,"many"],[3840,2160,"many"],[1024,1366,"critical"],[390,844,"long"]]) {
    await page.setViewportSize({width,height});
    for (const reducedMotion of ["no-preference","reduce"]) {
      await page.emulateMedia({reducedMotion});
      await page.goto(`${base}/?state=${state}`);
      await page.locator(".problem").first().waitFor();
      await page.evaluate(()=>document.fonts.ready);
      for (const theme of ["dark","light"]) {
        if (theme === "light") await page.getByRole("button",{name:"Light theme",exact:true}).click();
        await fits(width >= 1100);
        const animations = await page.locator("#mascot").evaluate(el=>el.getAnimations({subtree:true}).length);
        assert.equal(animations > 0, reducedMotion !== "reduce");
        await page.screenshot({path:`${output}/${width}-${height}-${theme}-${reducedMotion}.png`});
      }
    }
  }
  await page.setViewportSize({width:1920,height:1080});
  await page.emulateMedia({reducedMotion:"no-preference"});
  for (const state of Object.keys(fixtures)) {
    await page.goto(`${base}/?state=${state}`);
    await page.waitForFunction(()=>document.querySelector("#connection").dataset.connected === "true");
    assert.equal(await page.locator("h1").textContent(), fixtures[state].headline);
    await fits(false);
  }
  await page.goto(`${base}/?state=long`);
  const summary = page.locator("summary").first();
  await summary.focus();
  await page.keyboard.press("Enter");
  assert.equal(await page.locator("details").first().getAttribute("open"), "");
  assert.ok((await page.locator(".full-output").first().textContent()).includes("<img src=x"));
  assert.equal(await page.locator(".problem img, .problem script").count(),0);
  assert.notEqual(await summary.evaluate(el=>getComputedStyle(el).outlineStyle),"none");
  await fits(false);
  await page.goto(`${base}/?state=warning`);
  await page.waitForFunction(()=>document.documentElement.dataset.motion === "on");
  const before = await page.locator("#mascot").evaluate(el=>el.getAnimations({subtree:true}).map(a=>a.currentTime));
  await page.waitForTimeout(250);
  const after = await page.locator("#mascot").evaluate(el=>el.getAnimations({subtree:true}).map(a=>a.currentTime));
  assert.ok(after.some((time,index)=>time > before[index]), "Animation does not advance");
  await page.getByRole("button",{name:"Motion on",exact:true}).click();
  assert.ok(await page.locator("#mascot").evaluate(el=>el.getAnimations({subtree:true}).every(a=>a.playState === "paused")));
  await page.getByRole("button",{name:"Motion off",exact:true}).click();
  await page.setViewportSize({width:390,height:500});
  await page.locator("#sources").scrollIntoViewIfNeeded();
  await page.waitForFunction(()=>document.documentElement.dataset.motion === "off");
  assert.deepEqual(external,[],"External asset requests");
  assert.deepEqual(failures,[],"Browser errors");
  console.log(`✅ Browser suite passed (${browser.version()}): viewport/theme/reduced-motion matrix, ${Object.keys(fixtures).length} fixtures, keyboard, XSS, moving and offscreen animations, no external requests.`);
} finally {
  await browser?.close();
  if (server.exitCode === null) { server.kill("SIGINT"); await once(server,"exit"); }
}
