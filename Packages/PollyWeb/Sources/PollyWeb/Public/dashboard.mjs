import { mascots, icons } from "./design.mjs";
import { age, sourceLabel, statusNotice } from "./presentation.mjs";

// Only trusted, generated artwork goes through innerHTML. All API text uses textContent.
function setIcon(element, severity) {
  const known = Object.hasOwn(icons, severity) ? severity : "unknown";
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
    const ids = new Set(items.map(item => item.id));
    for (const [id, element] of cache) if (!ids.has(id)) { element.remove(); cache.delete(id); }
    items.forEach((item, index) => {
      if (!cache.has(item.id)) cache.set(item.id, make(item));
      const element = cache.get(item.id);
      update(element, item);
      // Do not detach stable rows: that loses focus in some browsers.
      if (container.children[index] !== element) container.insertBefore(element, container.children[index] ?? null);
    });
  }
  document.querySelectorAll("[data-icon]").forEach(element => setIcon(element, element.dataset.icon));
  mascot("unreachable");
  return {
    render(snapshot) {
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
      if (announcement !== lastAnnouncement) { text("announcement", announcement); lastAnnouncement = announcement; }
    },
    disconnected() {
      text("connection", "Connection lost · retrying");
      byID("connection").dataset.connected = "false";
      text("notice", "Connection to Polly lost. Displayed values are old data until connection is restored.");
      text("headline", "Polly has lost the connection");
      mascot("unreachable");
      text("announcement", "Connection to Polly lost. Displayed values are old data.");
    },
  };
}
