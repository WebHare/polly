/* POLLY_PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node /absolute/path/to/polly/scripts/test-web-lifecycle.mjs */
import assert from "node:assert/strict";
import { startStatusServer, instrumentBrowser } from "./web/status-server.mjs";
const { chromium }=await import(process.env.POLLY_PLAYWRIGHT || "playwright");
const server=await startStatusServer();let browser;
try {
  browser=await chromium.launch();const context=await browser.newContext();await context.addInitScript(instrumentBrowser);
  const page=await context.newPage();await page.goto(server.url);await page.waitForFunction(()=>document.querySelector("#connection").dataset.connected === "true");
  server.setMode("503");await page.waitForFunction(()=>document.querySelector("#connection").dataset.connected === "false");
  await page.evaluate(()=>{window.announcements=[];new MutationObserver(()=>announcements.push(document.querySelector("#announcement").textContent)).observe(document.querySelector("#announcement"),{childList:true,subtree:true,characterData:true});});
  await page.waitForTimeout(2200);
  console.dir({announcements:await page.evaluate(()=>announcements)});
  assert.deepEqual(await page.evaluate(()=>announcements),[],"An unchanged outage must not announce again every second");
  server.setMode("critical");await page.waitForFunction(()=>document.querySelector("#connection").dataset.connected === "true");
  await page.evaluate(()=>{Object.defineProperty(document,"hidden",{configurable:true,value:true});document.dispatchEvent(new Event("visibilitychange"));});
  await page.waitForTimeout(100);
  console.dir(await page.evaluate(()=>({metrics:pollyTestMetrics(),origins:pollyTestTimerOrigins()})));
  assert.equal((await page.evaluate(()=>pollyTestMetrics())).timers,0);
  server.setMode("slow");await page.evaluate(()=>{Object.defineProperty(document,"hidden",{configurable:true,value:false});document.dispatchEvent(new Event("visibilitychange"));});
  assert.equal(await page.locator("#connection").getAttribute("data-connected"),"false");
  await page.waitForFunction(()=>document.querySelector("#connection").dataset.connected === "true");
  await page.evaluate(()=>{window.dispatchEvent(new Event("pagehide"));window.dispatchEvent(new Event("pageshow"));});
  assert.equal(await page.locator("#connection").getAttribute("data-connected"),"false");
  await page.waitForFunction(()=>document.querySelector("#connection").dataset.connected === "true");
  console.log("✅ Lifecycle: quiet announcements, hidden/resume, restored page revalidation");
}finally{await browser?.close();await server.stop();}
