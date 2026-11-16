import { mascots, icons } from "./design.mjs";
import { age, sourceLabel, statusNotice } from "./presentation.mjs";
import { Pager } from "./reliability.mjs";

// Only trusted, generated artwork goes through innerHTML. All API text uses textContent.
function setIcon(element, severity) {
  const known = Object.hasOwn(icons, severity) ? severity : "unknown";
  if (element.dataset.icon === known && element.childElementCount) return;
  element.dataset.icon = known;
  element.className = `status-icon ${known}`;
  element.innerHTML = icons[known];
  element.setAttribute("aria-hidden", "true");
}

export function createDashboard(document) {
  const byID = id => document.getElementById(id);
  const text = (id, value) => { if (byID(id).textContent !== String(value)) byID(id).textContent = value; };
  const rows = new Map();
  const sources = new Map();
  let lastAnnouncement = "";
  let snapshot = null;
  let paused = false;
  let pageTimer = null;
  const pager = new Pager();
  const tv = matchMedia("(min-width: 1100px)");
  const compact = matchMedia("(max-height: 900px)");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  const heldRow = () => document.activeElement?.closest(".problem") ?? byID("problem-list").querySelector(".problem[open]");
  const size = () => tv.matches ? compact.matches ? 5 : 8 : Infinity;
  function pageControls() {
    byID("pagination").hidden = !tv.matches || pager.pages <= 1;
    text("page-number", `Page ${pager.index+1} of ${pager.pages}`);
    const details = Boolean(byID("problem-list").querySelector(".problem[open]"));
    const noMotion = reduced.matches || document.documentElement.dataset.motion === "off";
    const stopped = paused || details || noMotion || document.hidden || !tv.matches || pager.pages <= 1;
    text("pause-pages", details ? "Details open" : noMotion ? "Motion paused" : paused ? "Resume pages" : "Pause pages");
    byID("pause-pages").setAttribute("aria-pressed", String(stopped));
    byID("pause-pages").disabled = details || noMotion;
    if(stopped) { clearTimeout(pageTimer); pageTimer=null; }
    else if(pageTimer === null) pageTimer=setTimeout(()=> {pageTimer=null;pager.move(1);showPage();},15000);
  }
  function showPage() {
    const visible = new Set(pager.visible.map(p=>p.id));
    for(const [id,row] of rows) row.hidden = !visible.has(id);
    pageControls();
  }
  function updatePages() {
    if(!snapshot)return;
    pager.update({items:snapshot.problems,size:size(),heldID:heldRow()?.dataset.id});
    showPage();
  }
  function interact(event) {
    if(event.target.closest?.("#pause-pages"))return;
    paused=true;pageControls();
  }
  document.addEventListener("pointerdown",interact);
  document.addEventListener("keydown",interact);
  byID("problem-list").addEventListener("focusin",interact);
  byID("problem-list").addEventListener("toggle",updatePages,true);
  byID("pause-pages").addEventListener("click",()=> {paused=!paused;updatePages();});
  for(const [id,delta] of [["previous-page",-1],["next-page",1]]) byID(id).addEventListener("click",()=> {
    paused=true;
    for(const row of rows.values()) row.open=false;
    pager.move(delta);showPage();
  });
  for(const query of [tv,compact,reduced])query.addEventListener("change",updatePages);
  document.addEventListener("visibilitychange",pageControls);
  document.addEventListener("pollymotionchange",pageControls);
  window.addEventListener("pagehide",()=>{clearTimeout(pageTimer);pageTimer=null;});
  window.addEventListener("pageshow",pageControls);
  const node = (tag, className, value) => {
    const element = document.createElement(tag);
    element.className = className;
    if (value != null) element.textContent = value;
    return element;
  };
  function mascot(mood) {
    const known = Object.hasOwn(mascots, mood) ? mood : "unreachable";
    const target = byID("mascot");
    if (target.dataset.mood === known && target.childElementCount) return;
    target.innerHTML = mascots[known];
    target.dataset.mood = known;
  }
  function problemRow(problem) {
    const row = node("details", "problem");
    const summary = node("summary", "problem-summary");
    const status = node("span", "problem-status");
    status.append(node("span", "icon"), node("span", "severity"));
    const names = node("span", "problem-names");
    names.append(node("span", "host"), node("span", "service"));
    summary.append(status, names, node("span", "source-name"), node("span", "tags"), node("span", "age"), node("span", "output-preview"));
    const expanded = node("div", "problem-expanded");
    expanded.append(node("p", "full-name"), node("pre", "full-output"), node("pre", "long-output"));
    row.append(summary, expanded);
    row.dataset.id = problem.id;
    return row;
  }
  function updateRow(row, problem, now) {
    const put = (selector, value) => {
      const element = row.querySelector(selector);
      if (element.textContent !== value) element.textContent = value;
    };
    setIcon(row.querySelector(".problem-status > :first-child"), problem.severity);
    put(".severity", problem.severity);
    put(".host", problem.host);
    put(".service", problem.service);
    put(".source-name", problem.serverName);
    put(".age", age(problem.since ? (now - Date.parse(problem.since)) / 1000 : null));
    put(".output-preview", problem.output);
    put(".full-name", `${problem.host} · ${problem.service} · ${problem.serverName}`);
    put(".full-output", problem.output);
    put(".long-output", problem.longOutput);
    const tags = row.querySelector(".tags");
    tags.replaceChildren();
    if (problem.acknowledged) tags.append(node("span", "tag", "ACK"));
    if (problem.downtimeDepth > 0) tags.append(node("span", "tag", "DOWNTIME"));
  }
  function reconcile({ container, items, cache, make, update }) {
    const focused = document.activeElement;
    const ids = new Set(items.map(item => item.id));
    for (const [id, element] of cache) if (!ids.has(id)) { element.remove(); cache.delete(id); }
    items.forEach((item, index) => {
      if (!cache.has(item.id)) cache.set(item.id, make(item));
      const element = cache.get(item.id);
      update(element, item);
      // Do not detach stable rows: that loses focus in some browsers.
      if (container.children[index] !== element) container.insertBefore(element, container.children[index] ?? null);
    });
    // Moving a focused disclosure detaches it on browsers without state-preserving moves.
    if (focused?.isConnected && document.activeElement !== focused) focused.focus({preventScroll:true});
  }
  document.querySelectorAll("[data-icon]").forEach(element => setIcon(element, element.dataset.icon));
  mascot("unreachable");
  return {
    render(value, {connected=true}={}) {
      snapshot=value;
      text("headline", snapshot.headline);
      text("coverage", `${snapshot.coverage.fresh} of ${snapshot.coverage.active} active sources current · ${snapshot.counts.hosts} hosts · ${snapshot.counts.services} services`);
      text("connection", "Connected to Polly");
      byID("connection").dataset.connected = "true";
      byID("dashboard").dataset.state = snapshot.state;
      for (const key of ["hostsDown", "critical", "warning", "unknown"]) text(key, snapshot.counts[key]);
      text("notice", statusNotice(snapshot));
      mascot(snapshot.mood);
      const now = Date.parse(snapshot.generatedAt);
      reconcile({container:byID("problem-list"), items:snapshot.problems, cache:rows, make:problemRow, update:(row, problem)=>updateRow(row, problem, now)});
      updatePages();
      text("problem-total", `${snapshot.problems.length} service ${snapshot.problems.length === 1 ? "problem" : "problems"}`);
      byID("empty-message").hidden = snapshot.problems.length > 0;
      text("empty-message", snapshot.state === "ok" ? "All checks answered. Nothing needs your attention." : snapshot.counts.hostsDown ? "Hosts are down. No service problems were returned." : "No service problems to display. Check source status below.");
      reconcile({container:byID("sources"), items:snapshot.servers, cache:sources,
        make:()=> { const li = node("li", "source"); li.append(node("span", "icon"), node("strong", "source-title"), node("span", "source-status")); return li; },
        update:(li, server)=> {
          setIcon(li.firstElementChild, server.state === "ok" && !server.stale ? "ok" : "unknown");
          li.querySelector(".source-title").textContent = server.name;
          li.querySelector(".source-status").textContent = sourceLabel(server);
        }});
      const announcement = `${snapshot.headline}. ${statusNotice(snapshot)}`;
      if (connected && announcement !== lastAnnouncement) { text("announcement", announcement); lastAnnouncement = announcement; }
    },
    disconnected() {
      text("connection", "Connection lost · retrying");
      byID("connection").dataset.connected = "false";
      byID("dashboard").dataset.state = "disconnected";
      text("notice", "Connection to Polly lost or being rechecked. Displayed values are old data until a fresh answer arrives.");
      text("headline", "Polly has lost the connection");
      mascot("unreachable");
      lastAnnouncement = "Connection to Polly lost. Displayed values are old data.";
      text("announcement", lastAnnouncement);
    },
  };
}
