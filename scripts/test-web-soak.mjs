/* POLLY_PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node /absolute/path/to/polly/scripts/test-web-soak.mjs
   Real 60-minute run, three independent browser tabs, real loopback HTTP faults. No accelerated clock. */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { writeFile, readFile, readdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { startStatusServer, instrumentBrowser } from "./web/status-server.mjs";
const { chromium }=await import(process.env.POLLY_PLAYWRIGHT || "playwright");
const reportPath=process.env.POLLY_SOAK_REPORT || "/tmp/polly-phase4-soak.json";
const duration=3600000;
const shutdown=new AbortController();
process.once("SIGTERM",()=>shutdown.abort());
process.once("SIGINT",()=>shutdown.abort());
const delay=ms=>sleep(ms,undefined,{signal:shutdown.signal});
async function assetHash(){const dir=fileURLToPath(new URL("../Packages/PollyWeb/Sources/PollyWeb/Public/",import.meta.url));const hash=createHash("sha256");for(const file of (await readdir(dir)).sort())if(/\.(mjs|html|css)$/.test(file))hash.update(file).update(await readFile(dir+file));return hash.digest("hex");}
const server=await startStatusServer();let browser,awake;
const report={startedAt:new Date().toISOString(),durationMs:0,assetHash:await assetHash(),samples:[],switches:[],errors:[],passed:false};
try {
  if(process.platform === "darwin")awake=spawn("/usr/bin/caffeinate",["-i","-w",String(process.pid)],{stdio:"ignore"});
  browser=await chromium.launch();report.browser=browser.version();
  const tabs=[];
  for(const [width,height,reducedMotion] of [[1920,1080,"no-preference"],[1280,720,"no-preference"],[3840,2160,"reduce"]]) {
    const context=await browser.newContext({viewport:{width,height},reducedMotion});await context.addInitScript(instrumentBrowser);
    const page=await context.newPage();page.on("pageerror",e=>report.errors.push(e.message));
    const cdp=await context.newCDPSession(page);await cdp.send("Performance.enable");
    server.setMode("many");await page.goto(server.url);await page.waitForFunction(()=>document.querySelectorAll(".problem").length === 107);
    tabs.push({context,page,cdp,width});
  }
  const modes=["many","critical","partial-critical","quiet","stale-green","auth","503","redirect","invalid-json","invalid-shape","hang","slow","offline","restart","many"];
  let mode="many",lastSwitch=-1;
  const started=performance.now();
  async function sample(){
    const measurements=[];
    for(const {page,cdp,width} of tabs){
      await cdp.send("HeapProfiler.collectGarbage");
      const metrics=await cdp.send("Performance.getMetrics");
      const heap=metrics.metrics.find(m=>m.name === "JSHeapUsedSize").value;
      const dom=await page.evaluate(()=>({...pollyTestMetrics(),nodes:document.querySelectorAll("*").length,rows:document.querySelectorAll(".problem:not([hidden])").length,state:document.querySelector("#dashboard").dataset.state,connected:document.querySelector("#connection").dataset.connected,notice:document.querySelector("#notice").textContent}));
      assert.equal(dom.maxRequests,1);assert.ok(dom.maxTimers<=3,`Timer stack: ${dom.maxTimers}`);assert.ok(dom.nodes<6000,`DOM growth: ${dom.nodes}`);assert.ok(heap<50000000,`Heap growth: ${heap}`);assert.ok(dom.rows<=(width===1280?5:8));
      measurements.push({width,heap,...dom});
    }
    report.durationMs=performance.now()-started;report.samples.push({elapsedMs:report.durationMs,mode,tabs:measurements});
    await writeFile(reportPath,JSON.stringify(report,null,2));
    console.log(`${Math.floor(report.durationMs/60000)}m ${mode}:`,measurements.map(m=>`${m.width}=${m.state}, timers ${m.timers}/${m.maxTimers}, requests ${m.active}/${m.maxRequests}, heap ${(m.heap/1048576).toFixed(2)} MiB`).join("; "));
  }
  await sample();
  while(performance.now()-started<duration){
    const slot=Math.floor((performance.now()-started)/120000);
    if(slot !== lastSwitch){
      lastSwitch=slot;mode=modes[slot%modes.length];
      for(const {context} of tabs)await context.setOffline(false);
      server.setMode(mode === "offline" || mode === "restart" ? "many" : mode);
      if(mode === "offline") {for(const {context} of tabs)await context.setOffline(true);}
      if(mode === "restart") {await server.stop();await delay(12000);await server.listen();}
      report.switches.push({elapsedMs:performance.now()-started,mode});
      // Wait past timeout/retry, then inspect what was actually rendered by the fetch cycle.
      await delay(22000);
      for(const {page} of tabs){
        const state=await page.locator("#dashboard").getAttribute("data-state");
        if(["auth","503","redirect","invalid-json","invalid-shape","hang","offline"].includes(mode)){assert.equal(state,"disconnected");assert.match(await page.locator("#notice").textContent(),/old data/);}
        else {assert.equal(await page.locator("#connection").getAttribute("data-connected"),"true");if(mode === "stale-green")assert.equal(state,"partial");if(mode === "quiet")assert.equal(state,"ok");if(mode === "partial-critical"){assert.match(await page.locator("#notice").textContent(),/1 of 2/);assert.equal(await page.locator("#mascot").getAttribute("data-mood"),"critical");}}
      }
    }
    await sample();await delay(Math.min(30000,Math.max(0,duration-(performance.now()-started))));
  }
  for(const {context} of tabs)await context.setOffline(false);
  server.setMode("many");await delay(22000);await sample();
  const first=report.samples[0].tabs,last=report.samples.at(-1).tabs;
  report.heapGrowthBytes=last.map((m,i)=>m.heap-first[i].heap);
  assert.ok(report.heapGrowthBytes.every(n=>n<10000000));assert.ok(report.durationMs>=duration);assert.equal(await assetHash(),report.assetHash,"Assets changed during soak");assert.equal(server.stats.redirects,0);assert.deepEqual(report.errors,[]);
  report.passed=true;report.endedAt=new Date().toISOString();report.server=server.stats;await writeFile(reportPath,JSON.stringify(report,null,2));
  console.log("✅ 60-minute soak passed",{durationMs:report.durationMs,samples:report.samples.length,heapGrowthBytes:report.heapGrowthBytes});
} catch(error){report.failure=error.stack;await writeFile(reportPath,JSON.stringify(report,null,2));throw error;}
finally{await browser?.close();await server.stop();awake?.kill();}
