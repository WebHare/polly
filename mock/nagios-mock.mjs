#!/usr/bin/env node
// Mock Nagios server for testing Polly. No dependencies; needs Node 18+.
//
//   node mock/nagios-mock.mjs [--port 8080] [--interval 15] [--user nagiosadmin] [--password nagios] [--no-auth] [--no-rotate]
//
// Serves /nagios/cgi-bin/statusjson.cgi (programstatus, hostcount, servicecount, servicelist, hostlist)
// with made-up hosts/services that slowly rotate through OK/WARNING/CRITICAL/UNKNOWN and host DOWN/UNREACHABLE.
// Also serves /nagios/cgi-bin/extinfo.cgi (service page with action/notes links) and /nagios/cgi-bin/cmd.cgi
// (acknowledge = cmd_typ 34, schedule downtime = cmd_typ 56, with the NagFormId CSRF cookie).
// --no-rotate starts with automatic rotation paused.
//
// Mock-only, without auth:
//   GET /mock/reset                                       all hosts up, all services OK, no acks or downtimes
//   GET /mock/set?host=H&service=S&status=ok|warning|critical|unknown
//   GET /mock/config?csrf=on|off&dateFormat=us|iso8601    how cmd.cgi behaves (reset by /mock/reset)
//   /redirect/<path>                                      302 to /<path>
// Press "h" in the terminal for keyboard controls.

import http from "node:http";
import { randomBytes } from "node:crypto";
import { parseArgs } from "node:util";

const { values: opts } = parseArgs({
  options: {
    port: { type: "string", default: "8080" },
    interval: { type: "string", default: "15" },
    user: { type: "string", default: "nagiosadmin" },
    password: { type: "string", default: "nagios" },
    "no-auth": { type: "boolean", default: false },
    "no-rotate": { type: "boolean", default: false },
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
  for (const name of names) {
    services.push({ host, name, status: SERVICE.ok, lastChange: startedAt, lastCheck: Date.now(), acknowledged: false, downtime: null });
  }
}

const findService = (host, name) => services.find((s) => s.host === host && s.name === name);
const downtimeDepth = (svc) => (svc.downtime && Date.now() >= svc.downtime.start && Date.now() < svc.downtime.end ? 1 : 0);

const state = {
  rotating: !opts["no-rotate"],
  offline: false, // respond with 503
  auth: !opts["no-auth"],
  requests: 0,
  // Both variants exist in the wild: monitor.webhare.net sends no nagFormId at all and uses ISO dates.
  csrf: true,
  dateFormat: "us",
};

// ---------------------------------------------------------------------------------------------
// State changes

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

function setService(svc, status, why = "") {
  if (svc.status === status) return;
  const from = SERVICE_NAME[svc.status];
  svc.status = status;
  svc.lastChange = Date.now();
  if (status === SERVICE.ok) svc.acknowledged = false; // non-sticky and sticky acks both end on recovery
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
              // Nagios escapes newlines in long output as a literal backslash-n.
              long_plugin_output: `Checked ${s.name} on ${s.host}\\nResponse time 0.042s`,
              problem_has_been_acknowledged: s.acknowledged,
              scheduled_downtime_depth: downtimeDepth(s),
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

// ---------------------------------------------------------------------------------------------
// HTML CGIs (extinfo.cgi, cmd.cgi)

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/'/g, "&#39;").replace(/"/g, "&quot;");
const pad = (n) => String(n).padStart(2, "0");
// Server-local time in the configured Nagios date_format: us (MM-DD-YYYY) or iso8601 (YYYY-MM-DD).
function nagiosTime(d) {
  const [y, m, day] = [d.getFullYear(), pad(d.getMonth() + 1), pad(d.getDate())];
  const date = state.dateFormat === "iso8601" ? `${y}-${m}-${day}` : `${m}-${day}-${y}`;
  return `${date} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function parseNagiosTime(value) {
  const iso = state.dateFormat === "iso8601";
  const m = (iso ? /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)$/ : /^(\d\d)-(\d\d)-(\d{4}) (\d\d):(\d\d):(\d\d)$/).exec(value ?? "");
  if (!m) return NaN;
  const [year, month, day] = iso ? [m[1], m[2], m[3]] : [m[3], m[1], m[2]];
  return new Date(year, month - 1, day, m[4], m[5], m[6]).getTime();
}

const issuedFormIds = new Set();

// Modelled on the page frame of Nagios Core cgi/*.c (document_header); adjust when a real server differs.
function htmlPage(title, bodyClass, body) {
  return `<!DOCTYPE HTML PUBLIC '-//W3C//DTD HTML 4.01 Transitional//EN' 'http://www.w3.org/TR/html4/loose.dtd'>
<html>
<head>
<link rel="shortcut icon" href="/nagios/images/favicon.ico" type="image/ico">
<title>
${title}
</title>
<LINK REL='stylesheet' TYPE='text/css' HREF='/nagios/stylesheets/common.css'>
<LINK REL='stylesheet' TYPE='text/css' HREF='/nagios/stylesheets/${bodyClass}.css'>
</head>
<body CLASS='${bodyClass}'>

${body}
</body>
</html>
`;
}

// Modelled on Nagios Core cgi/extinfo.c (show_service_info and the action/notes links); adjust when a real server differs.
function extinfoPage(params) {
  const svc = findService(params.get("host"), params.get("service"));
  if (params.get("type") !== "2" || !svc) {
    return htmlPage("Extended Information", "extinfo", "<DIV CLASS='errorMessage'>This service does not have any status information associated with it.</DIV>\n");
  }
  const links = [];
  if (svc.name === "HTTP") {
    const href = `https://runbook.example.com/${svc.host}/http?src=nagios&check=HTTP`;
    links.push(`<TR><TD ALIGN='right'>
<A HREF='${esc(href)}' TARGET='_blank'><img src='/nagios/images/action.gif' border=0 alt='Perform Additional Actions On This Service' title='Perform Additional Actions On This Service'></A>
</TD><TD>Extra Actions</TD></TR>`);
  }
  if (svc.name === "PING") {
    links.push(`<TR><TD ALIGN='right'>
<A HREF='/nagios/docs/ping.html' TARGET='_blank'><img src='/nagios/images/notes.gif' border=0 alt='View Additional Notes For This Service' title='View Additional Notes For This Service'></A>
</TD><TD>Extra Notes</TD></TR>`);
  }
  const label = SERVICE_NAME[svc.status].toUpperCase();
  return htmlPage(
    "Extended Information",
    "extinfo",
    `<table border=0 width=100%>
<tr>
<td align=left valign=top width=33%>
<DIV CLASS='infoBox'>
<DIV CLASS='infoBoxTitle'>Service Information</DIV>
Last Updated: ${esc(new Date().toString())}<BR>
</DIV>
</td>
<td align=center valign=top width=33%>
<DIV CLASS='data'>Service</DIV>
<DIV CLASS='dataTitle'>${esc(svc.name)}</DIV>
<DIV CLASS='data'>On Host</DIV>
<DIV CLASS='dataTitle'>${esc(svc.host)}</DIV>
</td>
<td align=right valign=bottom width=33%>
<TABLE BORDER='0'>
${links.join("\n")}
</TABLE>
</td>
</tr>
</table>
<BR>
<DIV ALIGN=CENTER>
<TABLE BORDER=0 CELLPADDING=0 WIDTH=100%>
<TR><TD ALIGN=CENTER VALIGN=TOP CLASS='stateInfoPanel'>
<DIV CLASS='dataTitle'>Service State Information</DIV>
<TABLE BORDER=1 CELLSPACING=0 CELLPADDING=0>
<TR><TD>
<TABLE BORDER=0 CELLSPACING=0 CELLPADDING=0>
<TR><TD CLASS='dataVar'>Current Status:</TD><TD CLASS='dataVal'><DIV CLASS='service${label}'>&nbsp;&nbsp;${label}&nbsp;&nbsp;</DIV></TD></TR>
<TR><TD CLASS='dataVar' VALIGN='top'>Status Information:</TD><TD CLASS='dataVal'>${esc(OUTPUT[svc.status])}</TD></TR>
<TR><TD CLASS='dataVar'>In Scheduled Downtime?</TD><TD CLASS='dataVal'><DIV CLASS='downtime${downtimeDepth(svc) ? "ACTIVE" : "INACTIVE"}'>&nbsp;&nbsp;${downtimeDepth(svc) ? "YES" : "NO"}&nbsp;&nbsp;</DIV></TD></TR>
</TABLE>
</TD></TR>
</TABLE>
</TD></TR>
</TABLE>
</DIV>
`,
  );
}

// Modelled on Nagios Core cgi/cmd.c (request_command_data); adjust when a real server differs.
function commandForm(params, formId) {
  const cmd = params.get("cmd_typ");
  if (cmd !== "34" && cmd !== "56") return htmlPage("External Command Interface", "cmd", "<DIV CLASS='errorMessage'>Error: An invalid command was specified!</DIV>\n");
  const host = params.get("host") ?? "";
  const service = params.get("service") ?? "";
  const row = (label, input) => `<tr><td class='objectDescription descriptionleft'>${label}:</td><td align='left'>${input}</td></tr>`;
  const rows = [
    row("Host Name", `<INPUT TYPE='TEXT' NAME='host' VALUE='${esc(host)}'>`),
    row("Service", `<INPUT TYPE='TEXT' NAME='service' VALUE='${esc(service)}'>`),
  ];
  if (cmd === "34") {
    rows.push(
      row("Sticky Acknowledgement", "<INPUT TYPE='checkbox' NAME='sticky_ack' CHECKED>"),
      row("Send Notification", "<INPUT TYPE='checkbox' NAME='send_notification' CHECKED>"),
      row("Persistent Comment", "<INPUT TYPE='checkbox' NAME='persistent' >"),
    );
  }
  rows.push(
    row("Author (Your Name)", "<INPUT TYPE='TEXT' NAME='com_author' VALUE='Nagios Admin' READONLY DISABLED>"),
    row("Comment", "<INPUT TYPE='TEXT' NAME='com_data' VALUE='' SIZE=40>"),
  );
  if (cmd === "56") {
    const now = new Date();
    rows.push(
      row("Triggered By", "\n<SELECT name='trigger'>\n<OPTION VALUE='0'>N/A</OPTION>\n</SELECT>"),
      "<tr><td COLSPAN=2>&nbsp;</td></tr>",
      row("Start Time", `<INPUT TYPE='TEXT' NAME='start_time' VALUE='${nagiosTime(now)}'>`),
      row("End Time", `<INPUT TYPE='TEXT' NAME='end_time' VALUE='${nagiosTime(new Date(now.getTime() + 2 * 3600_000))}'>`),
      row("Type", "<SELECT NAME='fixed'>\n<OPTION VALUE=1>Fixed</OPTION>\n<OPTION VALUE=0>Flexible</OPTION>\n</SELECT>"),
      row(
        "If Flexible, Duration",
        "<table border=0><tr><td align=right><INPUT TYPE='TEXT' NAME='hours' VALUE='2' SIZE=2 MAXLENGTH=2></td><td align=left>Hours</td><td align=right><INPUT TYPE='TEXT' NAME='minutes' VALUE='0' SIZE=2 MAXLENGTH=2></td><td align=left>Minutes</td></tr></table>",
      ),
    );
  }
  const title = cmd === "34" ? "You are requesting to acknowledge a service problem" : "You are requesting to schedule downtime for a particular service";
  return htmlPage(
    "External Command Interface",
    "cmd",
    `<table cellpadding=0 cellspacing=0 border=0 width=100%>
<tr>
<td align=center valign=top width=50%>
<DIV CLASS='cmdType'>${title}</DIV>
</td>
</tr>
</table>
<div align='center'><form method='post' action='cmd.cgi'>
${formId ? `<INPUT TYPE='hidden' NAME='nagFormId' VALUE='${formId}'\n` : ""}<TABLE CELLSPACING=0 CELLPADDING=0 CLASS='optBox'>
<tr><td CLASS='boxFrame BoxWidth'>
<table cellspacing='2' cellpadding='0' class='contentTable'>
<tr CLASS='sectionHeader'><td COLSPAN='2'>Command Options</td></tr>
<tr><td width='50%'>
<INPUT TYPE='HIDDEN' NAME='cmd_typ' VALUE='${cmd}'><INPUT TYPE='HIDDEN' NAME='cmd_mod' VALUE='2'>
</td></tr>
${rows.join("\n")}
<tr><td COLSPAN=2>&nbsp;</td></tr>
<tr CLASS='sectionHeader'><td COLSPAN=2 class='buttonRow'><INPUT TYPE='submit' NAME='btnSubmit' VALUE='Commit' class='submitButton'>&nbsp;&nbsp;<INPUT TYPE='reset' VALUE='Reset'></td></tr>
</table>
</td></tr>
</TABLE>
</form>
</div>
`,
  );
}

/// Applies a POSTed command; returns the error text or null on success.
function runCommand(fields, cookies) {
  const formId = fields.get("nagFormId");
  if (state.csrf && (!formId || cookies.NagFormId !== formId || !issuedFormIds.has(formId))) return "Error: Invalid or missing CSRF cookie!";
  if (fields.get("cmd_mod") !== "2") return "Error: Invalid command mode!";
  const cmd = fields.get("cmd_typ");
  if (cmd !== "34" && cmd !== "56") return "Error: An invalid command was specified!";
  if (!hosts.has(fields.get("host"))) return "Error: You must enter a valid host name!";
  const svc = findService(fields.get("host"), fields.get("service"));
  if (!svc) return "Error: You must enter a valid service description!";
  // lock_author_names: whatever is posted, the command is recorded under the logged-in contact.
  const author = "Nagios Admin";
  const comment = fields.get("com_data")?.trim();
  if (!author) return "Error: You must enter a name for the author!";
  if (!comment) return "Error: You must enter a comment!";

  if (cmd === "34") {
    svc.acknowledged = true;
    log(`\x1b[36mACKNOWLEDGE ${svc.host} / ${svc.name} by ${author}: ${comment}\x1b[0m`);
  } else {
    const start = parseNagiosTime(fields.get("start_time"));
    const end = parseNagiosTime(fields.get("end_time"));
    if (Number.isNaN(start) || Number.isNaN(end)) return "Error: Invalid start or end time!";
    if (end <= start) return "Error: End time must be after start time!";
    svc.downtime = { start, end };
    log(`\x1b[36mDOWNTIME ${svc.host} / ${svc.name} ${fields.get("start_time")} - ${fields.get("end_time")} by ${author}: ${comment}\x1b[0m`);
  }
  return null;
}

// Modelled on Nagios Core cgi/cmd.c (commit_command_data result messages); adjust when a real server differs.
function commandResult(error) {
  const body = error
    ? `<DIV CLASS='errorMessage'>${esc(error)}</DIV><br>\n`
    : "<DIV CLASS='infoMessage'>Your command request was successfully submitted to Nagios for processing.<BR><BR>Note: It may take a while before the command is actually processed.<BR><BR><A HREF='javascript:window.history.go(-2)'>Done</A></DIV>\n";
  return htmlPage("External Command Interface", "cmd", `<P><DIV ALIGN=CENTER>\n${body}</DIV></P>\n`);
}

const parseCookies = (header = "") => Object.fromEntries(header.split(/;\s*/).filter(Boolean).map((c) => [c.slice(0, c.indexOf("=")), c.slice(c.indexOf("=") + 1)]));

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString();
}

// ---------------------------------------------------------------------------------------------
// Mock-only control endpoints (no auth)

function handleControl(url) {
  if (url.pathname === "/mock/reset") {
    for (const s of services) {
      setService(s, SERVICE.ok, " (mock/reset)");
      s.acknowledged = false;
      s.downtime = null;
    }
    for (const name of hosts.keys()) setHost(name, HOST.up);
    state.csrf = true;
    state.dateFormat = "us";
    return [200, { ok: true }];
  }
  if (url.pathname === "/mock/config") {
    const csrf = url.searchParams.get("csrf");
    const dateFormat = url.searchParams.get("dateFormat");
    if ((csrf && !["on", "off"].includes(csrf)) || (dateFormat && !["us", "iso8601"].includes(dateFormat))) {
      return [404, { error: "csrf must be on|off, dateFormat must be us|iso8601" }];
    }
    if (csrf) state.csrf = csrf === "on";
    if (dateFormat) state.dateFormat = dateFormat;
    return [200, { ok: true, csrf: state.csrf, dateFormat: state.dateFormat }];
  }
  if (url.pathname === "/mock/set") {
    const p = url.searchParams;
    const svc = findService(p.get("host"), p.get("service"));
    const status = { ok: SERVICE.ok, warning: SERVICE.warning, critical: SERVICE.critical, unknown: SERVICE.unknown }[p.get("status")];
    if (!svc) return [404, { error: `unknown host/service "${p.get("host")}" / "${p.get("service")}"` }];
    if (!status) return [404, { error: `unknown status "${p.get("status")}"` }];
    setService(svc, status, " (mock/set)");
    return [200, { ok: true, host: svc.host, service: svc.name, status: SERVICE_NAME[status] }];
  }
  return [404, { error: "not found" }];
}

// ---------------------------------------------------------------------------------------------
// Router

const server = http.createServer(async (req, res) => {
  state.requests++;
  const url = new URL(req.url, "http://localhost");
  const send = (code, body, headers = {}) => {
    res.writeHead(code, { "Content-Type": "application/json", ...headers });
    res.end(typeof body === "string" ? body : JSON.stringify(body, null, 1));
  };
  const sendHTML = (body, headers = {}) => send(200, body, { "Content-Type": "text/html; charset=utf-8", ...headers });

  if (state.offline) return send(503, '{"error":"mock server is offline"}');
  if (url.pathname.startsWith("/redirect/")) return send(302, '{"redirect":true}', { Location: url.pathname.slice("/redirect".length) + url.search });
  if (url.pathname.startsWith("/mock/")) return send(...handleControl(url));

  const cgi = url.pathname.startsWith("/nagios/cgi-bin/") ? url.pathname.slice("/nagios/cgi-bin/".length) : null;
  if (!["statusjson.cgi", "extinfo.cgi", "cmd.cgi"].includes(cgi)) return send(404, '{"error":"not found"}');
  if (!checkAuth(req)) return send(401, '{"error":"unauthorized"}', { "WWW-Authenticate": 'Basic realm="Nagios Access"' });

  if (cgi === "statusjson.cgi") return send(200, handleQuery(url.searchParams));
  if (cgi === "extinfo.cgi") return sendHTML(extinfoPage(url.searchParams));
  if (req.method === "POST") {
    const error = runCommand(new URLSearchParams(await readBody(req)), parseCookies(req.headers.cookie));
    if (error) log(`\x1b[31mcommand refused: ${error}\x1b[0m`);
    return sendHTML(commandResult(error));
  }
  if (!state.csrf) return sendHTML(commandForm(url.searchParams, null));
  const formId = randomBytes(16).toString("hex");
  issuedFormIds.add(formId);
  sendHTML(commandForm(url.searchParams, formId), { "Set-Cookie": `NagFormId=${formId}; Path=/` });
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
  space       pause / resume automatic rotation (every ${opts.interval}s, currently ${state.rotating ? "on" : "paused"})
  x           toggle offline mode (HTTP 503 for every request)
  a           toggle authentication (currently ${state.auth ? "on" : "off"})
  s           show current state
  h           this help
  q           quit

Without auth: GET /mock/reset, GET /mock/set?host=H&service=S&status=ok|warning|critical|unknown,
  GET /mock/config?csrf=on|off&dateFormat=us|iso8601, /redirect/<path> (302)
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
  console.log(`Add it to Polly with:  http://${auth}localhost:${opts.port}/`);
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (key) => keys[key.toLowerCase()]?.());
    help();
  } else {
    console.log("(stdin is not a terminal: keyboard controls disabled)");
  }
});
