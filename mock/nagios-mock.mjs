#!/usr/bin/env node
// Mock Nagios server for testing Naggie. No dependencies; needs Node 18+.
//
//   node mock/nagios-mock.mjs [--port 8080] [--interval 15] [--user nagiosadmin] [--password nagios] [--no-auth]
//
// Serves /nagios/cgi-bin/statusjson.cgi (programstatus, hostcount, servicecount, servicelist, hostlist)
// with made-up hosts/services that slowly rotate through OK/WARNING/CRITICAL/UNKNOWN and host DOWN/UNREACHABLE.
// Press "h" in the terminal for keyboard controls.

import http from "node:http";
import { parseArgs } from "node:util";

const { values: opts } = parseArgs({
  options: {
    port: { type: "string", default: "8080" },
    interval: { type: "string", default: "15" },
    user: { type: "string", default: "nagiosadmin" },
    password: { type: "string", default: "nagios" },
    "no-auth": { type: "boolean", default: false },
  },
});

// statusjson.cgi bit values (nagios include/statusdata.h)
const SERVICE = { pending: 1, ok: 2, warning: 4, unknown: 8, critical: 16 };
const HOST = { pending: 1, up: 2, down: 4, unreachable: 8 };
const SERVICE_NAME = Object.fromEntries(Object.entries(SERVICE).map(([k, v]) => [v, k]));
const HOST_NAME = Object.fromEntries(Object.entries(HOST).map(([k, v]) => [v, k]));

const OUTPUT = {
  [SERVICE.ok]: "OK - all good",
  [SERVICE.warning]: "WARNING - threshold exceeded",
  [SERVICE.critical]: "CRITICAL - service not responding",
  [SERVICE.unknown]: "UNKNOWN - plugin timed out",
};

// ---------------------------------------------------------------------------------------------
// Fake inventory

const inventory = {
  "web1.example.com": ["PING", "HTTP", "HTTPS cert", "Disk /", "Load"],
  "web2.example.com": ["PING", "HTTP", "HTTPS cert", "Disk /", "Load"],
  "db1.example.com": ["PING", "PostgreSQL", "Disk /var", "Replication lag"],
  "mail.example.com": ["PING", "SMTP", "IMAP", "Mail queue"],
  "dns1.example.com": ["PING", "DNS"],
  "backup.example.com": ["PING", "Last backup", "Disk /backup"],
};

const startedAt = Date.now() - 3 * 86400_000;
const hosts = new Map(); // name -> { status, lastChange }
const services = []; // { host, name, status, lastChange, lastCheck }

for (const [host, names] of Object.entries(inventory)) {
  hosts.set(host, { status: HOST.up, lastChange: startedAt });
  for (const name of names) services.push({ host, name, status: SERVICE.ok, lastChange: startedAt, lastCheck: Date.now() });
}

const state = {
  rotating: true,
  offline: false, // respond with 503
  auth: !opts["no-auth"],
  requests: 0,
};

// ---------------------------------------------------------------------------------------------
// State changes

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

function setService(svc, status, why = "") {
  if (svc.status === status) return;
  const from = SERVICE_NAME[svc.status];
  svc.status = status;
  svc.lastChange = Date.now();
  log(`${color(status)}${svc.host} / ${svc.name}: ${from} -> ${SERVICE_NAME[status].toUpperCase()}\x1b[0m${why}`);
}

function setHost(name, status) {
  const host = hosts.get(name);
  if (host.status === status) return;
  const from = HOST_NAME[host.status];
  host.status = status;
  host.lastChange = Date.now();
  const c = status === HOST.up ? "\x1b[32m" : "\x1b[31m";
  log(`${c}host ${name}: ${from} -> ${HOST_NAME[status].toUpperCase()}\x1b[0m`);
}

/// One rotation step: mostly heal problems, sometimes create new ones.
function rotate() {
  const problems = services.filter((s) => s.status !== SERVICE.ok);
  const downHosts = [...hosts].filter(([, h]) => h.status !== HOST.up);

  if (downHosts.length && Math.random() < 0.3) return setHost(pick(downHosts)[0], HOST.up);
  if (problems.length && Math.random() < 0.45) {
    const svc = pick(problems);
    // Problems often escalate before recovering.
    if (svc.status === SERVICE.warning && Math.random() < 0.3) return setService(svc, SERVICE.critical, " (escalated)");
    return setService(svc, SERVICE.ok);
  }
  if (Math.random() < 0.08) return setHost(pick([...hosts.keys()]), Math.random() < 0.5 ? HOST.down : HOST.unreachable);

  const r = Math.random();
  setService(pick(services), r < 0.55 ? SERVICE.warning : r < 0.85 ? SERVICE.critical : SERVICE.unknown);
}

let timer = setInterval(() => state.rotating && rotate(), Number(opts.interval) * 1000);

// ---------------------------------------------------------------------------------------------
// statusjson.cgi

function envelope(query, data, typeCode = 0, message = "") {
  return {
    format_version: 0,
    result: {
      query_time: Date.now(),
      cgi: "statusjson.cgi",
      user: opts.user,
      query,
      query_status: "released",
      program_start: startedAt,
      last_data_update: Date.now(),
      type_code: typeCode,
      type_text: typeCode === 0 ? "Success" : "Option Missing",
      message,
    },
    data,
  };
}

function parseStatusFilter(value, table) {
  if (!value) return null;
  return new Set(value.split(/[\s+]+/).map((s) => table[s.toLowerCase()]).filter(Boolean));
}

function handleQuery(params) {
  const query = params.get("query");
  const details = params.get("details") === "true";

  switch (query) {
    case "programstatus":
      return envelope(query, {
        programstatus: { version: "4.5.0-mock", nagios_pid: process.pid, program_start: startedAt, enable_notifications: true },
      });

    case "hostcount": {
      const count = { up: 0, down: 0, unreachable: 0, pending: 0 };
      for (const h of hosts.values()) count[HOST_NAME[h.status]]++;
      return envelope(query, { count });
    }

    case "servicecount": {
      const count = { ok: 0, warning: 0, critical: 0, unknown: 0, pending: 0 };
      for (const s of services) count[SERVICE_NAME[s.status]]++;
      return envelope(query, { count });
    }

    case "hostlist": {
      const filter = parseStatusFilter(params.get("hoststatus"), HOST);
      const hostlist = {};
      for (const [name, h] of hosts) {
        if (filter && !filter.has(h.status)) continue;
        hostlist[name] = details
          ? { name, status: h.status, last_state_change: h.lastChange, plugin_output: h.status === HOST.up ? "PING OK" : "PING CRITICAL - Packet loss = 100%" }
          : h.status;
      }
      return envelope(query, { selectors: {}, hostlist });
    }

    case "servicelist": {
      const filter = parseStatusFilter(params.get("servicestatus"), SERVICE);
      const servicelist = {};
      for (const s of services) {
        if (filter && !filter.has(s.status)) continue;
        servicelist[s.host] ??= {};
        servicelist[s.host][s.name] = details
          ? {
              host_name: s.host,
              description: s.name,
              status: s.status,
              last_state_change: s.lastChange,
              last_check: Date.now() - Math.floor(Math.random() * 60_000),
              plugin_output: OUTPUT[s.status],
            }
          : s.status;
      }
      return envelope(query, { selectors: {}, servicelist });
    }

    default:
      return envelope(query ?? "", undefined, 3, query ? `Unsupported query '${query}' (mock)` : "The query option is required");
  }
}

function checkAuth(req) {
  if (!state.auth) return true;
  const header = req.headers.authorization ?? "";
  if (!header.startsWith("Basic ")) return false;
  const [user, ...rest] = Buffer.from(header.slice(6), "base64").toString().split(":");
  return user === opts.user && rest.join(":") === opts.password;
}

const server = http.createServer((req, res) => {
  state.requests++;
  const url = new URL(req.url, "http://localhost");
  const send = (code, body, headers = {}) => {
    res.writeHead(code, { "Content-Type": "application/json", ...headers });
    res.end(typeof body === "string" ? body : JSON.stringify(body, null, 1));
  };

  if (state.offline) return send(503, '{"error":"mock server is offline"}');
  if (url.pathname !== "/nagios/cgi-bin/statusjson.cgi") return send(404, '{"error":"not found"}');
  if (!checkAuth(req)) return send(401, '{"error":"unauthorized"}', { "WWW-Authenticate": 'Basic realm="Nagios Access"' });
  send(200, handleQuery(url.searchParams));
});

// ---------------------------------------------------------------------------------------------
// Terminal UI

function color(status) {
  return { [SERVICE.ok]: "\x1b[32m", [SERVICE.warning]: "\x1b[33m", [SERVICE.critical]: "\x1b[31m", [SERVICE.unknown]: "\x1b[35m" }[status] ?? "";
}

function log(msg) {
  const t = new Date().toLocaleTimeString();
  process.stdout.write(`\x1b[2m${t}\x1b[0m ${msg}\n`);
}

function help() {
  console.log(`
Keys:
  w / c / u   put a random OK service into WARNING / CRITICAL / UNKNOWN
  d / r       mark a random host DOWN / UNREACHABLE
  o           everything OK (all services and hosts)
  n           do one rotation step now
  space       pause / resume automatic rotation (every ${opts.interval}s)
  x           toggle offline mode (HTTP 503 for every request)
  a           toggle authentication (currently ${state.auth ? "on" : "off"})
  s           show current state
  h           this help
  q           quit
`);
}

function showState() {
  console.log(
    `\nrotation: ${state.rotating ? "on" : "paused"}  offline: ${state.offline}  auth: ${state.auth ? `${opts.user}:${opts.password}` : "off"}  requests: ${state.requests}`,
  );
  for (const [name, h] of hosts) {
    const hc = h.status === HOST.up ? "\x1b[32m" : "\x1b[31m";
    console.log(`  ${hc}${name} [${HOST_NAME[h.status]}]\x1b[0m`);
    for (const s of services.filter((s) => s.host === name)) {
      console.log(`      ${color(s.status)}${SERVICE_NAME[s.status].padEnd(8)}\x1b[0m ${s.name}`);
    }
  }
  console.log();
}

function forceRandomService(status) {
  const candidates = services.filter((s) => s.status === SERVICE.ok);
  if (!candidates.length) return log("no OK services left");
  setService(pick(candidates), status, " (manual)");
}

function forceRandomHost(status) {
  const candidates = [...hosts].filter(([, h]) => h.status === HOST.up);
  if (!candidates.length) return log("no UP hosts left");
  setHost(pick(candidates)[0], status);
}

const keys = {
  w: () => forceRandomService(SERVICE.warning),
  c: () => forceRandomService(SERVICE.critical),
  u: () => forceRandomService(SERVICE.unknown),
  d: () => forceRandomHost(HOST.down),
  r: () => forceRandomHost(HOST.unreachable),
  o: () => {
    for (const s of services) setService(s, SERVICE.ok, " (manual)");
    for (const name of hosts.keys()) setHost(name, HOST.up);
  },
  n: rotate,
  " ": () => log(`automatic rotation ${(state.rotating = !state.rotating) ? "resumed" : "paused"}`),
  x: () => log(`offline mode ${(state.offline = !state.offline) ? "ON (503)" : "off"}`),
  a: () => log(`authentication ${(state.auth = !state.auth) ? `on (${opts.user}:${opts.password})` : "off"}`),
  s: showState,
  h: help,
  "?": help,
  q: quit,
  "\u0003": quit, // Ctrl-C
};

function quit() {
  clearInterval(timer);
  server.close();
  process.stdin.setRawMode?.(false);
  process.exit(0);
}

server.listen(Number(opts.port), () => {
  const auth = state.auth ? `${encodeURIComponent(opts.user)}:${encodeURIComponent(opts.password)}@` : "";
  console.log(`Mock Nagios listening on http://localhost:${opts.port}/nagios/cgi-bin/statusjson.cgi`);
  console.log(`Add it to Naggie with:  http://${auth}localhost:${opts.port}/`);
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (key) => keys[key.toLowerCase()]?.());
    help();
  } else {
    console.log("(stdin is not a terminal: keyboard controls disabled)");
  }
});
