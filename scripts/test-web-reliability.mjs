/* POLLY_PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node /absolute/path/to/polly/scripts/test-web-reliability.mjs */
import assert from "node:assert/strict";
import { startStatusServer, instrumentBrowser } from "./web/status-server.mjs";
const { chromium }=await import(process.env.POLLY_PLAYWRIGHT || "playwright");
const server=await startStatusServer();let browser;
try {
  browser=await chromium.launch();const context=await browser.newContext({viewport:{width:1920,height:1080}});
  await context.addInitScript(instrumentBrowser);
  const page=await context.newPage();
  const errors=[];page.on("pageerror",e=>errors.push(e.message));
  const connected=()=>page.waitForFunction(()=>document.querySelector("#connection").dataset.connected === "true");
  const lost=()=>page.waitForFunction(()=>document.querySelector("#connection").dataset.connected === "false");
  server.setMode("stale-green");await page.goto(server.url);await connected();
  console.log("Old source, new API answer:",await page.locator("#dashboard").getAttribute("data-state"));
  assert.equal(await page.locator("#dashboard").getAttribute("data-state"),"partial");
  assert.equal(await page.locator("#mascot").getAttribute("data-mood"),"unreachable");
  assert.match(await page.locator("#sources").textContent(),/Old data/);
  server.setMode("critical");await page.waitForFunction(()=>document.querySelector("#dashboard").dataset.state === "problems");
  for(const mode of ["auth","503","redirect","invalid-json","invalid-shape","hang"]) {
    server.setMode(mode);await lost();assert.match(await page.locator("#notice").textContent(),/old data/);
    assert.equal(await page.locator(".problem").count(),4);assert.notEqual(await page.locator("#mascot").getAttribute("data-mood"),"ok");
    server.setMode("critical");await connected();console.log(`✅ ${mode}: old values marked, recovered after fetch`);
  }
  assert.equal(server.stats.redirects,0,"Redirect was followed");
  server.setMode("slow");const before=server.stats.requests;await page.waitForTimeout(8000);await connected();assert.ok(server.stats.requests>before);
  await context.setOffline(true);await lost();await context.setOffline(false);await connected();console.log("✅ Browser network offline/online");
  await server.stop();await lost();await server.listen();await connected();console.log("✅ HTTP service restart");
  server.setMode("partial-critical");await page.waitForFunction(()=>document.querySelector("#notice").textContent.includes("1 of 2"));
  assert.equal(await page.locator("#mascot").getAttribute("data-mood"),"critical");
  assert.match(await page.locator("#sources").textContent(),/Unreachable/);
  server.setMode("many");await page.waitForFunction(()=>document.querySelectorAll(".problem").length === 107);
  assert.equal(await page.locator(".problem:visible").count(),8);
  await page.waitForFunction(()=>document.querySelector("#page-number").textContent === "Page 2 of 14",{},{timeout:20000});
  await page.getByRole("button",{name:"Next problem page",exact:true}).click();
  const manual=await page.locator("#page-number").textContent();await page.waitForTimeout(16000);assert.equal(await page.locator("#page-number").textContent(),manual);
  await page.getByRole("button",{name:"Resume pages",exact:true}).click();await page.waitForTimeout(16000);assert.notEqual(await page.locator("#page-number").textContent(),manual);
  await page.locator(".problem:visible summary").first().click();const held=await page.locator(".problem[open]").getAttribute("data-id");await page.waitForTimeout(16000);assert.equal(await page.locator(".problem[open]").getAttribute("data-id"),held);
  await page.locator(".problem[open] summary").click();await page.emulateMedia({reducedMotion:"reduce"});
  const reduced=await page.locator("#page-number").textContent();await page.waitForTimeout(16000);assert.equal(await page.locator("#page-number").textContent(),reduced);
  await page.getByRole("button",{name:"Next problem page",exact:true}).click();assert.notEqual(await page.locator("#page-number").textContent(),reduced);
  await page.setViewportSize({width:1024,height:1366});await page.waitForFunction(()=>document.querySelectorAll(".problem:not([hidden])").length === 107);assert.equal(await page.locator(".problem:visible").count(),107);
  // Dispatch visibility events deterministically; the soak also measures multiple live tabs.
  await page.evaluate(()=>{Object.defineProperty(document,"hidden",{configurable:true,value:true});document.dispatchEvent(new Event("visibilitychange"));});
  await page.waitForTimeout(100);const hiddenMetrics=await page.evaluate(()=>pollyTestMetrics());console.dir({hiddenMetrics,origins:await page.evaluate(()=>pollyTestTimerOrigins())});assert.equal(hiddenMetrics.timers,0);
  const requests=server.stats.requests;await page.waitForTimeout(6000);assert.equal(server.stats.requests,requests);
  server.setMode("slow");await page.evaluate(()=>{Object.defineProperty(document,"hidden",{configurable:true,value:false});document.dispatchEvent(new Event("visibilitychange"));});
  await lost();await connected();
  const metrics=await page.evaluate(()=>pollyTestMetrics());console.dir(metrics);
  assert.equal(metrics.maxRequests,1);assert.ok(metrics.maxTimers<=3);assert.deepEqual(errors,[]);
  console.log(`✅ Reliability browser suite passed (${browser.version()})`);
} finally {await browser?.close();await server.stop();}
