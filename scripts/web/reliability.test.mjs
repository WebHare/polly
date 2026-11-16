/* node --test /absolute/path/to/polly/scripts/web/reliability.test.mjs */
import test from "node:test";
import assert from "node:assert/strict";
import { SnapshotClock, validateSnapshot, createPoller, Pager } from "../../Packages/PollyWeb/Sources/PollyWeb/Public/reliability.mjs";
import { fixtures } from "./fixtures.mjs";

const copy = value => structuredClone(value);
test("API data is validated completely before replacing the last good snapshot", () => {
  for (const fixture of Object.values(fixtures)) assert.doesNotThrow(()=>validateSnapshot(fixture));
  for (const mutate of [s=>s.servers=null,s=>s.counts.critical="2",s=>s.servers[0].ageSeconds=-1,s=>s.generatedAt="invalid",s=>s.servers.push(s.servers[0]),s=>s.problems[0].output={},s=>s.problems[0].severity="healthy",s=>s.problems[0].serverID="missing",s=>s.problems.push(s.problems[0]),s=>s.staleAfterSeconds=0,s=>s.coverage.fresh=9,s=>s.problems[0].since="bad"]) {
    const value=copy(fixtures.critical); mutate(value); assert.throws(()=>validateSnapshot(value));
  }
});

test("fresh API timestamps cannot rejuvenate the same source measurement", () => {
  const clock = new SnapshotClock();
  clock.accept({snapshot:copy(fixtures.quiet), now:0});
  assert.equal(clock.current(137000).state,"ok");
  assert.equal(clock.current(138000).state,"partial");
  const repeated=copy(fixtures.quiet); repeated.generatedAt="2026-11-16T12:03:00Z";
  clock.accept({snapshot:repeated, now:180000});
  console.dir({observed:clock.current(180000).state, expected:"partial"});
  assert.equal(clock.current(180000).state,"partial");
  assert.equal(clock.current(180000).coverage.fresh,0);
  assert.equal(clock.current(180000).servers[0].ageSeconds,192);
  assert.notEqual(clock.current(180000).mood,"ok");
  const fresh=copy(repeated); fresh.servers.forEach(s=>{s.lastSuccessAt=fresh.generatedAt;s.ageSeconds=0;});
  clock.accept({snapshot:fresh,now:181000}); assert.equal(clock.current(181000).state,"ok");
});

test("partial and stale sources never erase another source's criticals",()=> {
  const clock=new SnapshotClock(); clock.accept({snapshot:copy(fixtures.critical),now:0});
  const old=clock.current(200000);
  assert.equal(old.problems.length,4); assert.equal(old.mood,"critical"); assert.equal(old.coverage.fresh,0);
  assert.equal(old.counts.critical,2); assert.equal(old.servers[0].stale,true);
});

function scheduler() {
  let now=0, sequence=0; const timers=new Map();
  return { now:()=>now, timers, setTimeout:(fn,ms)=>{ const id=++sequence;timers.set(id,{fn,at:now+ms});return id;}, clearTimeout:id=>timers.delete(id),
    async advance(ms) {for(let i=0;i<12;i++) await Promise.resolve(); const end=now+ms; for (;;) { const next=[...timers].sort((a,b)=>a[1].at-b[1].at)[0]; if(!next || next[1].at>end)break; now=next[1].at; timers.delete(next[0]); next[1].fn(); for(let i=0;i<12;i++) await Promise.resolve(); } now=end; }
  };
}
test("poller has one request, bounded timeout, automatic retry and no timers when hidden or stopped", async()=> {
  const time=scheduler(); let calls=0,active=0,maxActive=0,failures=0,rendered=0,hang=true;
  const poller=createPoller({...time,fetch:(_url,{signal})=> {calls++;active++;maxActive=Math.max(maxActive,active);return new Promise((resolve,reject)=>{
    signal.addEventListener("abort",()=>{active--;reject(new Error("aborted"));},{once:true});
    if(!hang){active--;resolve({ok:true,json:async()=>copy(fixtures.quiet)});}
  });},onSnapshot:()=>rendered++,onUnavailable:()=>failures++});
  poller.start(); await time.advance(9999); assert.equal(calls,1);assert.equal(active,1);
  await time.advance(1);assert.ok(failures>0);assert.equal(active,0);
  hang=false;await time.advance(5000);assert.equal(calls,2);assert.ok(rendered>0);
  poller.setVisible(false);assert.equal(time.timers.size,0);
  await time.advance(600000);assert.equal(calls,2);
  poller.setVisible(true);poller.setVisible(true);await time.advance(0);assert.equal(calls,3);
  assert.equal(maxActive,1);poller.stop();assert.equal(time.timers.size,0);
});

test("resume discards pre-hide answers and waits for a new fetch before healthy rendering", async()=> {
  const time=scheduler();let resolveBody, calls=0;const states=[];
  const poller=createPoller({...time,fetch:async()=>{calls++;return {ok:true,json:()=>new Promise(resolve=>{resolveBody=resolve;})};},onSnapshot:()=>states.push("healthy"),onUnavailable:()=>states.push("unverified")});
  poller.start();await time.advance(0);poller.setVisible(false);poller.setVisible(true);
  resolveBody(copy(fixtures.quiet));await time.advance(0);
  assert.equal(states.includes("healthy"),false);assert.equal(calls,2);
  resolveBody(copy(fixtures.quiet));await time.advance(0);assert.equal(states.at(-1),"healthy");poller.stop();
});

const problems = n=>Array.from({length:n},(_,i)=>({...fixtures.critical.problems[0],id:`p-${i}`,severity:i<3?"critical":i<70?"warning":"unknown"}));
test("TV pages retain server order with zero, one, eight, nine and 107 tied problems",()=> {
  for(const n of [0,1,8,9,107]) {const pager=new Pager(); const input=problems(n);pager.update({items:input,size:8});const seen=[];for(let i=0;i<pager.pages;i++){seen.push(...pager.visible.map(p=>p.id));pager.move(1);}assert.deepEqual(seen,input.map(p=>p.id));assert.equal(pager.pages,Math.max(1,Math.ceil(n/8)));}
});
test("page updates clamp indexes, preserve anchors, prioritize new criticals and support mobile",()=> {
  const pager=new Pager();const input=problems(107);pager.update({items:input,size:8});pager.move(5);const anchor=pager.visible[0].id;
  pager.update({items:input,size:8});assert.equal(pager.visible[0].id,anchor);
  pager.update({items:input.slice(0,9),size:8});assert.ok(pager.index<pager.pages);
  pager.move(1);pager.update({items:[{...input[0],id:"new-critical"},...input],size:8});assert.equal(pager.index,0);
  pager.move(1);pager.update({items:input,size:Infinity});assert.equal(pager.visible.length,107);assert.equal(pager.pages,1);
  pager.update({items:input,size:5});assert.equal(pager.visible.length,5);
});

test("repeated online/offline recovery cannot strand an earlier tick timer",async()=> {
  const time=scheduler();const poller=createPoller({...time,fetch:async()=>({ok:true,json:async()=>copy(fixtures.quiet)}),onSnapshot:()=>{},onUnavailable:()=>{}});
  poller.start();await time.advance(0);
  for(let i=0;i<5;i++){poller.retry();await time.advance(0);}
  console.dir({timersAfterReconnect:time.timers.size});
  assert.equal(time.timers.size,1);
  poller.setVisible(false);assert.equal(time.timers.size,0);poller.stop();
});

test("a completed request schedules the next read five seconds later, between age ticks",async()=> {
  const time=scheduler();let calls=0;
  const poller=createPoller({...time,fetch:()=>{calls++;return new Promise(resolve=>time.setTimeout(()=>resolve({ok:true,json:async()=>copy(fixtures.quiet)}),23));},onSnapshot:()=>{},onUnavailable:()=>{}});
  poller.start();await time.advance(5022);assert.equal(calls,1);await time.advance(1);
  console.dir({callsAtFiveSecondsAfterCompletion:calls});assert.equal(calls,2);poller.stop();await time.advance(23);
});
