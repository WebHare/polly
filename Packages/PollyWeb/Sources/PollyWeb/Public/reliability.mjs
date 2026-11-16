const finite = value => typeof value === "number" && Number.isFinite(value) && value >= 0;
const count = value => finite(value) && Number.isInteger(value);
const string = value => typeof value === "string";
const date = value => string(value) && Number.isFinite(Date.parse(value));
const optionalDate = value => value == null || date(value);
const unique = items => new Set(items.map(item=>item.id)).size === items.length;

// Validate the entire display contract before a malformed answer can replace known data.
export function validateSnapshot(s) {
  const valid = s && date(s.generatedAt) && finite(s.staleAfterSeconds) && s.staleAfterSeconds > 0
    && ["empty","paused","waiting","partial","unreachable","problems","ok"].includes(s.state)
    && ["ok","warning","critical","unreachable"].includes(s.mood) && string(s.headline)
    && s.coverage && count(s.coverage.active) && count(s.coverage.fresh) && s.coverage.fresh <= s.coverage.active
    && s.counts && ["hosts","hostsDown","services","critical","warning","unknown","pending"].every(key=>count(s.counts[key]))
    && Array.isArray(s.servers) && s.servers.every(server=>server && string(server.id) && server.id && string(server.name)
      && ["loading","ok","unreachable","paused"].includes(server.state) && typeof server.stale === "boolean"
      && (server.ageSeconds == null || finite(server.ageSeconds)) && optionalDate(server.lastSuccessAt) && optionalDate(server.lastAttemptAt)
      && (server.state !== "ok" || (finite(server.ageSeconds) && date(server.lastSuccessAt)))) && unique(s.servers)
    && s.coverage.active === s.servers.filter(server=>server.state !== "paused").length
    && Array.isArray(s.problems) && s.problems.every(p=>p && ["id","serverID","serverName","host","service","output","longOutput"].every(key=>string(p[key]))
      && p.id && s.servers.some(server=>server.id === p.serverID) && ["critical","warning","unknown"].includes(p.severity)
      && optionalDate(p.since) && typeof p.acknowledged === "boolean" && count(p.downtimeDepth)) && unique(s.problems);
  if (!valid) throw new Error("Invalid status snapshot");
  return s;
}

export class SnapshotClock {
  #snapshot;
  #received = 0;
  accept({snapshot, now}) {
    validateSnapshot(snapshot);
    const previous = new Map(this.current(now)?.servers.map(s=>[s.id,s]) ?? []);
    const servers = snapshot.servers.map(server=> {
      const old = previous.get(server.id);
      // A repeated (or older) source measurement cannot reset the monotonic age floor.
      const sameMeasurement = old?.lastSuccessAt && server.lastSuccessAt && Date.parse(server.lastSuccessAt) <= Date.parse(old.lastSuccessAt);
      const reportedAge = server.ageSeconds == null ? null : Math.max(server.ageSeconds, (Date.parse(snapshot.generatedAt)-Date.parse(server.lastSuccessAt))/1000);
      return {...server, ageSeconds:reportedAge == null ? null : Math.max(reportedAge, sameMeasurement ? old.ageSeconds ?? 0 : 0)};
    });
    this.#snapshot = {...snapshot,servers};
    this.#received = now;
  }
  current(now) {
    if (!this.#snapshot) return null;
    const s=this.#snapshot;
    const elapsed=Math.max(0,now-this.#received)/1000;
    const servers=s.servers.map(server=> {
      const ageSeconds=server.ageSeconds == null ? null : server.ageSeconds+elapsed;
      return {...server,ageSeconds,stale:server.state !== "paused" && (server.stale || ageSeconds == null || ageSeconds >= s.staleAfterSeconds)};
    });
    const fresh=servers.filter(server=>server.state === "ok" && !server.stale).length;
    const incomplete=s.state === "ok" && (!s.coverage.active || fresh !== s.coverage.active || s.counts.pending > 0);
    return {...s,servers,coverage:{...s.coverage,fresh},...(incomplete ? {state:"partial",mood:"unreachable",headline:"Polly is missing current data from some checks"} : {})};
  }
}

export function createPoller({fetch:request=globalThis.fetch, now=()=>performance.now(), setTimeout:schedule=globalThis.setTimeout, clearTimeout:cancel=globalThis.clearTimeout, onSnapshot, onUnavailable}) {
  const clock=new SnapshotClock();
  let running=false,visible=true,inFlight=null,timer=null,next=0,generation=0,verified=false;
  function show() { const snapshot=clock.current(now()); if(snapshot) onSnapshot(snapshot,{connected:verified}); if(!verified) onUnavailable(); }
  function arm(delay=1000) {cancel(timer);timer=null;if(running && visible)timer=schedule(tick,delay);}
  async function refresh() {
    const version=generation;
    const started=now();
    const controller=new AbortController();
    inFlight=controller;
    const timeout=schedule(()=>controller.abort(),10000);
    controller.signal.addEventListener("abort",()=>cancel(timeout),{once:true});
    try {
      const response=await request("/api/status",{cache:"no-store",redirect:"error",signal:controller.signal});
      if(!response.ok)throw new Error("Status unavailable");
      const snapshot=await response.json();
      if(version !== generation || controller.signal.aborted)return;
      clock.accept({snapshot,now:started});verified=true;show();
    } catch {
      if(version === generation){verified=false;show();}
    } finally {
      cancel(timeout);inFlight=null;
      if(version !== generation) { if(running && visible) arm(0); }
      else {next=now()+5000;arm();}
    }
  }
  function tick() {cancel(timer);timer=null;if(!running || !visible)return;show();if(!inFlight && now()>=next)void refresh();arm();}
  return {
    start() {if(running)return;running=true;verified=false;next=0;tick();},
    setVisible(value) {
      if(visible === value)return;
      visible=value;generation++;verified=false;cancel(timer);timer=null;inFlight?.abort();
      if(visible && running){next=0;show();tick();}
    },
    retry() {if(running && visible){verified=false;next=0;show();if(!inFlight)tick();}},
    stop() {running=false;generation++;cancel(timer);timer=null;inFlight?.abort();},
  };
}

export class Pager {
  #items=[];
  #size=8;
  #index=0;
  #pendingCritical=false;
  get index() {return this.#index;}
  get pages() {return Math.max(1,Math.ceil(this.#items.length/this.#size));}
  get visible() {return this.#size === Infinity ? this.#items : this.#items.slice(this.#index*this.#size,(this.#index+1)*this.#size);}
  update({items,size,heldID=null}) {
    const anchor=this.visible[0]?.id;
    const critical=new Set(this.#items.filter(p=>p.severity === "critical").map(p=>p.id));
    this.#pendingCritical ||= items.some(p=>p.severity === "critical" && !critical.has(p.id));
    this.#items=items;this.#size=size;
    const heldIndex=items.findIndex(p=>p.id === heldID);
    const anchorIndex=items.findIndex(p=>p.id === anchor);
    if(heldIndex>=0)this.#index=Math.floor(heldIndex/size);
    else if(this.#pendingCritical){this.#index=0;this.#pendingCritical=false;}
    else if(anchorIndex>=0)this.#index=Math.floor(anchorIndex/size);
    this.#index=Math.max(0,Math.min(this.#index,this.pages-1));
  }
  move(delta) {this.#index=(this.#index+delta%this.pages+this.pages)%this.pages;}
}
