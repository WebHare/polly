/* Imported by scripts/test-web-reliability.mjs and scripts/test-web-soak.mjs. Loopback test server only. */
import http from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { fixtures } from "./fixtures.mjs";

export async function startStatusServer() {
  let mode="critical",fixed=null,port=0;
  const publicPath=process.env.POLLY_BASELINE_PUBLIC || fileURLToPath(new URL("../../Packages/PollyWeb/Sources/PollyWeb/Public/",import.meta.url));
  const stats={requests:0,active:0,maxActive:0,redirects:0};
  const server=http.createServer(async(req,res)=> {
    const path=new URL(req.url,"http://localhost").pathname;
    const send=(code,body,type="application/json")=>{res.writeHead(code,{"Content-Type":type,"Cache-Control":"no-store","Content-Security-Policy":"default-src 'self'; object-src 'none'; base-uri 'none'"});res.end(body);};
    if(path === "/redirect-target"){stats.redirects++;return send(200,"{}");}
    if(path === "/api/status") {
      stats.requests++;stats.active++;stats.maxActive=Math.max(stats.maxActive,stats.active);
      res.once("close",()=>stats.active--);
      if(mode === "auth")return send(401,"{}");
      if(mode === "503")return send(503,"{}");
      if(mode === "redirect"){res.writeHead(302,{Location:"/redirect-target"});return res.end();}
      if(mode === "invalid-json")return send(200,"{broken");
      if(mode === "invalid-shape")return send(200,JSON.stringify({...fixtures.quiet,servers:null}));
      if(mode === "hang")return;
      const state=mode === "slow" ? "critical" : mode;
      const data=structuredClone(fixtures[state] ?? fixtures.critical);
      const now=Date.now();data.generatedAt=new Date(now).toISOString();
      data.servers.forEach(s=>{s.lastAttemptAt=data.generatedAt;s.lastSuccessAt=new Date(fixed ?? now-12000).toISOString();if(s.ageSeconds != null)s.ageSeconds=fixed == null?12:Math.max(0,(now-fixed)/1000);});
      if(mode === "stale-green") {Object.assign(data,structuredClone(fixtures.quiet));data.generatedAt=new Date(now).toISOString();data.servers.forEach(s=>{s.lastSuccessAt=new Date(now-180000).toISOString();s.ageSeconds=180;});}
      if(mode === "many") {data.problems=Array.from({length:107},(_,i)=>({...fixtures.critical.problems[0],id:`p-${i}`,host:`web-${i}.example.com`,severity:i<3?"critical":i<70?"warning":"unknown"}));data.counts={...data.counts,critical:3,warning:67,unknown:37};}
      if(mode === "partial-critical") {data.servers[1].state="unreachable";data.coverage.fresh=1;}
      const body=JSON.stringify(data);
      if(mode === "slow") {const timer=setTimeout(()=>send(200,body),2000);res.once("close",()=>clearTimeout(timer));return;}
      return send(200,body);
    }
    if(!/^\/(?:[a-zA-Z0-9._-]+|fonts\/[a-zA-Z0-9._-]+)?$/.test(path) || path.includes(".."))return send(404,"{}");
    try {const data=await readFile(`${publicPath}${publicPath.endsWith("/")?"":"/"}${path === "/" ? "index.html" : path.slice(1)}`);const ext=path.split(".").at(-1);send(200,data,({mjs:"application/javascript",css:"text/css",woff2:"font/woff2"})[ext] || "text/html");}
    catch {send(404,"{}");}
  });
  async function listen(){await new Promise((resolve,reject)=>{server.once("error",reject);server.listen(port,"127.0.0.1",()=>{server.off("error",reject);port=server.address().port;resolve();});});}
  async function stop(){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
  await listen();
  return {url:`http://127.0.0.1:${port}`,stats,setMode(value){mode=value;},freeze(){fixed=Date.now()-12000;},unfreeze(){fixed=null;},stop,listen};
}

export function instrumentBrowser() {
  const timers=new Map();let active=0,maxRequests=0,requests=0,maxTimers=0;
  const set=window.setTimeout.bind(window),clear=window.clearTimeout.bind(window),request=window.fetch.bind(window);
  window.setTimeout=(fn,ms,...args)=>{const id=set(()=>{timers.delete(id);fn(...args);},ms);timers.set(id,new Error().stack);maxTimers=Math.max(maxTimers,timers.size);return id;};
  window.clearTimeout=id=>{timers.delete(id);clear(id);};
  window.fetch=async(...args)=> {active++;requests++;maxRequests=Math.max(maxRequests,active);try{return await request(...args);}finally{active--;}};
  window.pollyTestMetrics=()=>({timers:timers.size,maxTimers,active,maxRequests,requests});
  window.pollyTestTimerOrigins=()=>[...timers.values()];
}
