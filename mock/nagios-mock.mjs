#!/usr/bin/env node
// Mock Nagios server for testing Polly. No dependencies; needs Node 18+.
//
//   node mock/nagios-mock.mjs [--port 8080] [--interval 15] [--user nagiosadmin] [--password nagios] [--no-auth] [--no-rotate]
//
// Serves /nagios/cgi-bin/statusjson.cgi (programstatus, hostcount, servicecount, servicelist, hostlist)
// with made-up hosts/services that slowly rotate through OK/WARNING/CRITICAL/UNKNOWN and host DOWN/UNREACHABLE.
// Also serves /nagios/cgi-bin/extinfo.cgi (host and service pages with action/notes links) and /nagios/cgi-bin/cmd.cgi with
// the commands Polly uses: acknowledge a service problem (cmd_typ 34) or a host problem (33), schedule downtime for a host (55), a service
// (56) or all services of a host (86). Commands follow Nagios Core 4.5 (cgi/cmd.c, base/commands.c,
// common/downtime.c); see doc/nagios-protocol.md:
// - normal acknowledgements end on any state change (for a host: any change but DOWN <-> UNREACHABLE), sticky ones on recovery; acknowledging an OK service does nothing
// - downtimes are counted in scheduled_downtime_depth while in effect; fixed and flexible downtimes work, triggered
//   downtimes are ignored like a trigger that doesn't exist
// - the CSRF cookie is set once and reused (4.5.12+), or never set (csrf=off, like 4.5.11 and older)
// --no-rotate starts with automatic rotation paused.
//
// Mock-only, without auth:
//   GET /mock/reset                                       all hosts up, all services OK, no acks or downtimes
//   GET /mock/set?host=H&service=S&status=ok|warning|critical|unknown
//   GET /mock/sethost?host=H&status=up|down|unreachable
//   GET /mock/config?csrf=on|off&dateFormat=us|euro|iso8601|strict-iso8601   how cmd.cgi behaves (reset by /mock/reset)
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
const hosts = new Map(); // name -> { status, lastChange, ack }
// ack: null or { type: ACK.normal | ACK.sticky, author, comment }
const services = []; // { host, name, status, lastChange, lastCheck, ack }

for (const [host, names] of Object.entries(inventory)) {
  hosts.set(host, { status: HOST.up, lastChange: startedAt, ack: null });
  for (const name of names) {
    services.push({ host, name, status: SERVICE.ok, lastChange: startedAt, lastCheck: Date.now(), ack: null });
  }
}

const findService = (host, name) => services.find((s) => s.host === host && s.name === name);

// include/common.h
const ACK = { none: 0, normal: 1, sticky: 2 };

// Scheduled downtimes (common/downtime.c). service is null for a host downtime. A fixed downtime is in effect from
// start to end; a flexible one from the moment its host or service has a problem within start..end, for `duration`
// seconds (flexStart is set then).
// { id, host, service, start, end, fixed, duration, flexStart, author, comment }
const downtimes = [];
let nextDowntimeId = 1;

function downtimeInEffect(d, now = Date.now()) {
  if (d.fixed) return d.start <= now && now < d.end;
  return d.flexStart != null && now < d.flexStart + d.duration * 1000;
}

/// Drops downtimes that have ended, or flexible ones whose window passed without a problem.
function expireDowntimes(now = Date.now()) {
  for (let i = downtimes.length - 1; i >= 0; i--) {
    const d = downtimes[i];
    const over = d.fixed ? now >= d.end : d.flexStart != null ? now >= d.flexStart + d.duration * 1000 : now > d.end;
    if (over) {
      log(`\x1b[36mdowntime ${d.id} ended: ${d.host}${d.service ? ` / ${d.service}` : ""}\x1b[0m`);
      downtimes.splice(i, 1);
    }
  }
}

/// Nagios' scheduled_downtime_depth: the number of downtimes in effect for this host (service null) or service.
function downtimeDepth(host, service = null) {
  expireDowntimes();
  return downtimes.filter((d) => d.host === host && d.service === service && downtimeInEffect(d)).length;
}

/// Starts pending flexible downtimes of a host or service that just got a problem (check_pending_flex_*_downtime).
function startPendingFlexDowntimes(host, service, now = Date.now()) {
  for (const d of downtimes) {
    if (!d.fixed && d.flexStart == null && d.host === host && d.service === service && d.start <= now && now <= d.end) {
      d.flexStart = now;
      log(`\x1b[36mflexible downtime ${d.id} started: ${host}${service ? ` / ${service}` : ""}\x1b[0m`);
    }
  }
}

const state = {
  rotating: !opts["no-rotate"],
  offline: false, // respond with 503
  auth: !opts["no-auth"],
  requests: 0,
  fault: "none",
  // Both variants exist in the wild: monitor.webhare.net (4.5.11 or older) sends no nagFormId at all and uses ISO dates.
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
  log(`${color(status)}${svc.host} / ${svc.name}: ${from} -> ${SERVICE_NAME[status].toUpperCase()}\x1b[0m${why}`);
  // base/checks.c: a normal acknowledgement ends on any state change, a sticky one only on recovery.
  if (svc.ack && (svc.ack.type === ACK.normal || status === SERVICE.ok)) {
    svc.ack = null;
    log(`\x1b[36macknowledgement of ${svc.host} / ${svc.name} removed\x1b[0m`);
  }
  if (status !== SERVICE.ok) startPendingFlexDowntimes(svc.host, svc.name);
}

function setHost(name, status) {
  const host = hosts.get(name);
  if (host.status === status) return;
  const from = HOST_NAME[host.status];
  host.status = status;
  host.lastChange = Date.now();
  const c = status === HOST.up ? "\x1b[32m" : "\x1b[31m";
  log(`${c}host ${name}: ${from} -> ${HOST_NAME[status].toUpperCase()}\x1b[0m`);
  // base/checks.c: a sticky host acknowledgement ends on recovery; a normal one on any change, except between
  // DOWN and UNREACHABLE.
  if (host.ack && (status === HOST.up || (host.ack.type === ACK.normal && from === "up"))) {
    host.ack = null;
    log(`\x1b[36macknowledgement of host ${name} removed\x1b[0m`);
  }
  if (status !== HOST.up) startPendingFlexDowntimes(name, null);
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

// include/jsonutils.h
const RESULT = { success: 0, optionInvalid: 3, optionMissing: 4, optionValueInvalid: 6 };
const RESULT_TEXT = { 0: "Success", 3: "Option Invalid", 4: "Option Missing", 6: "Option Value Invalid" };

function envelope(query, data, typeCode = RESULT.success, message = "") {
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
      type_text: RESULT_TEXT[typeCode],
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
          ? {
              name,
              status: h.status,
              last_state_change: h.lastChange,
              last_check: Date.now() - Math.floor(Math.random() * 60_000),
              plugin_output: h.status === HOST.up ? "PING OK" : "PING CRITICAL - Packet loss = 100%",
              long_plugin_output: "",
              problem_has_been_acknowledged: h.ack != null,
              acknowledgement_type: h.ack?.type ?? ACK.none,
              scheduled_downtime_depth: downtimeDepth(name),
              state_type: 1,
              current_attempt: h.status === HOST.up ? 1 : 10,
              max_attempts: 10,
              next_check: Date.now() + 45_000,
            }
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
              problem_has_been_acknowledged: s.ack != null,
              acknowledgement_type: s.ack?.type ?? ACK.none,
              scheduled_downtime_depth: downtimeDepth(s.host, s.name),
              state_type: 1,
              current_attempt: 3,
              max_attempts: 3,
              next_check: Date.now() + 45_000,
            }
          : s.status;
      }
      return envelope(query, { selectors: {}, servicelist });
    }

    default:
      return query
        ? envelope(query, undefined, RESULT.optionValueInvalid, `The query '${query}' is not supported by the mock`)
        : envelope("", undefined, RESULT.optionMissing, "The query option is required");
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
const DATE_FORMATS = ["us", "euro", "iso8601", "strict-iso8601"];
// Server-local time in the configured Nagios date_format (get_time_string with SHORT_DATE_TIME).
function nagiosTime(d) {
  const [y, m, day] = [d.getFullYear(), pad(d.getMonth() + 1), pad(d.getDate())];
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  switch (state.dateFormat) {
    case "euro": return `${day}-${m}-${y} ${time}`;
    case "iso8601": return `${y}-${m}-${day} ${time}`;
    case "strict-iso8601": return `${y}-${m}-${day}T${time}`;
    default: return `${m}-${day}-${y} ${time}`;
  }
}

/// cmd.c string_to_time: the notation of date_format, read as server-local time. Both ISO variants accept a space
/// or a T. Returns NaN when it doesn't parse.
function parseNagiosTime(value) {
  const iso = state.dateFormat.includes("iso8601");
  const m = (iso ? /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)$/ : /^(\d\d)-(\d\d)-(\d{4}) (\d\d):(\d\d):(\d\d)$/).exec(value ?? "");
  if (!m) return NaN;
  const [year, month, day] = iso ? [m[1], m[2], m[3]] : state.dateFormat === "euro" ? [m[3], m[2], m[1]] : [m[3], m[1], m[2]];
  return new Date(year, month - 1, day, m[4], m[5], m[6]).getTime();
}

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
// Modelled on Nagios Core cgi/extinfo.c (show_host_info); only the parts Polly reads. The web hosts have an action URL.
function hostInfoPage(name) {
  const host = hosts.get(name);
  if (!host) return htmlPage("Extended Information", "extinfo", "<P><DIV CLASS='errorMessage'>Error: Host Not Found!</DIV></P>");
  const links = name.startsWith("web")
    ? `<TR><TD ALIGN='right'>
<A HREF='https://runbook.example.com/${name}?src=nagios&type=host' TARGET='_blank'><img src='/nagios/images/action.gif' border=0 alt='Perform Additional Actions On This Host' title='Perform Additional Actions On This Host'></A>
</TD><TD>Extra Actions</TD></TR>`
    : "";
  const label = HOST_NAME[host.status].toUpperCase();
  return htmlPage(
    "Extended Information",
    "extinfo",
    `<table border=0 width=100%>
<tr>
<td align=left valign=top width=33%>
<DIV CLASS='infoBox'>
<DIV CLASS='infoBoxTitle'>Host Information</DIV>
Last Updated: ${esc(new Date().toString())}<BR>
</DIV>
</td>
<td align=center valign=top width=33%>
<DIV CLASS='data'>Host</DIV>
<DIV CLASS='dataTitle'>${esc(name)}</DIV>
</td>
<td align=right valign=bottom width=33%>
<TABLE BORDER='0'>
${links}
</TABLE>
</td>
</tr>
</table>
<BR>
<DIV CLASS='dataTitle'>Host State Information</DIV>
<TABLE BORDER=0 CELLSPACING=0 CELLPADDING=0>
<TR><TD CLASS='dataVar'>Host Status:</TD><TD CLASS='dataVal'><DIV CLASS='host${label}'>&nbsp;&nbsp;${label}&nbsp;&nbsp;</DIV></TD></TR>
</TABLE>
`,
  );
}

function extinfoPage(params) {
  if (params.get("type") === "1") return hostInfoPage(params.get("host"));
  const svc = findService(params.get("host"), params.get("service"));
  if (params.get("type") !== "2" || !svc) {
    return htmlPage("Extended Information", "extinfo", "<P><DIV CLASS='errorMessage'>Error: Service Not Found!</DIV></P>");
  }
  const links = [];
  if (svc.name === "HTTP") {
    // Nagios prints the expanded URL without HTML escaping.
    const href = `https://runbook.example.com/${svc.host}/http?src=nagios&check=HTTP`;
    links.push(`<TR><TD ALIGN='right'>
<A HREF='${href}' TARGET='_blank'><img src='/nagios/images/action.gif' border=0 alt='Perform Additional Actions On This Service' title='Perform Additional Actions On This Service'></A>
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
<TR><TD CLASS='dataVar'>In Scheduled Downtime?</TD><TD CLASS='dataVal'><DIV CLASS='downtime${downtimeDepth(svc.host, svc.name) ? "ACTIVE" : "INACTIVE"}'>&nbsp;&nbsp;${downtimeDepth(svc.host, svc.name) ? "YES" : "NO"}&nbsp;&nbsp;</DIV></TD></TR>
</TABLE>
</TD></TR>
</TABLE>
</TD></TR>
</TABLE>
</DIV>
`,
  );
}

// ---------------------------------------------------------------------------------------------
// cmd.cgi, modelled on Nagios Core 4.5 cgi/cmd.c; the effects follow base/commands.c and common/downtime.c.

// include/common.h
const CMD = { ackHost: 33, ackService: 34, hostDowntime: 55, serviceDowntime: 56, hostServicesDowntime: 86 };
const CMD_TITLE = {
  [CMD.ackHost]: "acknowledge a host problem",
  [CMD.ackService]: "acknowledge a service problem",
  [CMD.hostDowntime]: "schedule downtime for a particular host",
  [CMD.serviceDowntime]: "schedule downtime for a particular service",
  [CMD.hostServicesDowntime]: "schedule downtime for all services for a particular host",
};
// The contact alias Nagios uses as author (lock_author_names=1, the default).
const AUTHOR = "Nagios Admin";

const row = (label, input, required = true) =>
  `<tr><td CLASS='${required ? "optBoxRequiredItem" : "optBoxItem"}'>${label}:</td><td><b>${input}</b></td></tr>`;

function commentRows() {
  return [
    row("Author (Your Name)", `<INPUT TYPE='TEXT' NAME='com_author' VALUE='${esc(AUTHOR)}' READONLY DISABLED>`),
    row("Comment", "<INPUT TYPE='TEXT' NAME='com_data' VALUE='' SIZE=40>"),
  ];
}

/// request_command_data: the form for one command. formId is the CSRF token, or null when there is none.
function commandForm(params, formId) {
  const cmd = Number(params.get("cmd_typ"));
  if (!CMD_TITLE[cmd]) return htmlPage("External Command Interface", "cmd", "<P><DIV CLASS='errorMessage'>Error: An invalid command was specified!</DIV></P>\n");
  const host = params.get("host") ?? "";
  const service = params.get("service") ?? "";
  // Nagios leaves the Host Name and Service rows of these forms unclosed; the parser has to cope.
  const rows = [`<tr><td CLASS='optBoxRequiredItem'>Host Name:</td><td><b><INPUT TYPE='TEXT' NAME='host' VALUE='${esc(host)}'></b></td></tr>`];
  if (cmd === CMD.ackService || cmd === CMD.ackHost) {
    if (cmd === CMD.ackService) rows.push(`<tr><td CLASS='optBoxRequiredItem'>Service:</td><td><b><INPUT TYPE='TEXT' NAME='service' VALUE='${esc(service)}'>`);
    rows.push(
      row("Sticky Acknowledgement", "<INPUT TYPE='checkbox' NAME='sticky_ack' CHECKED>", false),
      row("Send Notification", "<INPUT TYPE='checkbox' NAME='send_notification' CHECKED>", false),
      row("Persistent Comment", "<INPUT TYPE='checkbox' NAME='persistent' >", false),
      ...commentRows(),
    );
  } else {
    if (cmd === CMD.serviceDowntime) rows.push(`<tr><td CLASS='optBoxRequiredItem'>Service:</td><td><b><INPUT TYPE='TEXT' NAME='service' VALUE='${esc(service)}'>`);
    const now = new Date();
    rows.push(
      ...commentRows(),
      "<tr><td CLASS='optBoxItem'><br></td></tr>",
      `<tr><td CLASS='optBoxItem'>Triggered By:</td><td>\n<select name='trigger'>\n<option value='0'>N/A\n${downtimes
        .map((d) => `<option value='${d.id}'>ID: ${d.id}, ${d.service ? `Service '${esc(d.service)}' on host` : "Host"} '${esc(d.host)}' starting @ ${nagiosTime(new Date(d.start))}\n`)
        .join("")}</select>\n</td></tr>`,
      "<tr><td CLASS='optBoxItem'><br></td></tr>",
      row("Start Time", `<INPUT TYPE='TEXT' NAME='start_time' VALUE='${nagiosTime(now)}'>`),
      row("End Time", `<INPUT TYPE='TEXT' NAME='end_time' VALUE='${nagiosTime(new Date(now.getTime() + 7200_000))}'>`),
      row("Type", "<SELECT NAME='fixed'><OPTION VALUE=1>Fixed\n<OPTION VALUE=0>Flexible\n</SELECT>\n", false),
      `<tr><td CLASS='optBoxItem'>If Flexible, Duration:</td><td><table border=0><tr>
<td align=right><INPUT TYPE='TEXT' NAME='hours' VALUE='2' SIZE=2 MAXLENGTH=2></td>
<td align=left>Hours</td>
<td align=right><INPUT TYPE='TEXT' NAME='minutes' VALUE='0' SIZE=2 MAXLENGTH=2></td>
<td align=left>Minutes</td>
</tr></table>
</td></tr>`,
    );
    if (cmd === CMD.hostDowntime) {
      rows.push(row("Child Hosts", "<SELECT name='childoptions'><option value='0'>Do nothing with child hosts\n<option value='1'>Schedule triggered downtime for all child hosts\n<option value='2'>Schedule non-triggered downtime for all child hosts\n</SELECT>\n", false));
    }
  }
  return htmlPage(
    "External Command Interface",
    "cmd",
    `<P><DIV ALIGN=CENTER CLASS='cmdType'>You are requesting to ${CMD_TITLE[cmd]}</DIV></P>
<P>
<DIV ALIGN=CENTER>
<table border=0 width=90%>
<tr>
<td align=center valign=top>
<DIV ALIGN=CENTER CLASS='optBoxTitle'>Command Options</DIV>
<TABLE CELLSPACING=0 CELLPADDING=0 BORDER=1 CLASS='optBox'>
<TR><TD CLASS='optBoxItem'>
<form method='post' action='cmd.cgi'>
${formId ? `<INPUT TYPE='hidden' NAME='nagFormId' VALUE='${formId}'\n` : ""}<TABLE CELLSPACING=0 CELLPADDING=0 CLASS='optBox'>
<tr><td><INPUT TYPE='HIDDEN' NAME='cmd_typ' VALUE='${cmd}'><INPUT TYPE='HIDDEN' NAME='cmd_mod' VALUE='2'></td></tr>
${rows.join("\n")}
<tr><td CLASS='optBoxItem' COLSPAN=2></td></tr>
<tr><td CLASS='optBoxItem'></td><td CLASS='optBoxItem'><INPUT TYPE='submit' NAME='btnSubmit' VALUE='Commit'> <INPUT TYPE='reset' VALUE='Reset'></td></tr>
</table>
</form>
</TD></TR>
</TABLE>
</td>
</tr>
</table>
</DIV>
</P>
<P><DIV CLASS='infoMessage'>Please enter all required information before committing the command.<br>Required fields are marked in red.<br>Failure to supply all required values will result in an error.</DIV></P>`,
  );
}

const resultPage = (body) => htmlPage("External Command Interface", "cmd", body);
const errorPage = (message) => resultPage(`<P><DIV CLASS='errorMessage'>${esc(message)}</DIV></P>\n`);
const SUCCESS_PAGE = resultPage(
  "<P><DIV CLASS='infoMessage'>Your command request was successfully submitted to Nagios for processing.<BR><BR>\nNote: It may take a while before the command is actually processed.<BR><BR>\n<A HREF='javascript:window.history.go(-2)'>Done</A></DIV></P>",
);

/// commit_command_data: checks a posted command and, when it passes, hands it to the "core" (applyCommand).
/// Returns the HTML answer.
function commitCommand(fields, cookies) {
  // 4.5.12+: the token in the form must equal the NagFormId cookie. Older versions only compare when there is a cookie.
  const cookie = cookies.NagFormId;
  const formId = fields.get("nagFormId");
  const formIdOK = cookie ? formId === cookie : !state.csrf;
  if (!formIdOK) return resultPage("<p>Error: Invalid or missing CSRF cookie!</p>\n");

  const cmd = Number(fields.get("cmd_typ"));
  if (!CMD_TITLE[cmd]) return errorPage("Error: An invalid command was specified!");
  const hostName = fields.get("host") ?? "";
  const serviceName = fields.get("service") ?? "";
  // clean_comment_data: semicolons would split the external command.
  const comment = (fields.get("com_data") ?? "").replaceAll(";", " ");
  let error = null;
  if (comment.trim() === "") error = "Comment was not entered";

  // Authorization: the mock user may command everything that exists.
  const hostCommand = [CMD.ackHost, CMD.hostDowntime, CMD.hostServicesDowntime].includes(cmd);
  const authorized = hosts.has(hostName) && (hostCommand || findService(hostName, serviceName));
  if (!authorized) return errorPage("Sorry, but you are not authorized to commit the specified command.");

  const command = { cmd, host: hostName, service: serviceName, author: AUTHOR, comment };
  if (cmd === CMD.ackService || cmd === CMD.ackHost) {
    command.sticky = fields.has("sticky_ack");
    command.notify = fields.has("send_notification");
    command.persistent = fields.has("persistent");
  } else {
    command.start = parseNagiosTime(fields.get("start_time"));
    command.end = parseNagiosTime(fields.get("end_time"));
    command.fixed = Number(fields.get("fixed") ?? 0) > 0;
    command.trigger = Number(fields.get("trigger") ?? 0);
    command.duration = Number(fields.get("hours") ?? 0) * 3600 + Number(fields.get("minutes") ?? 0) * 60;
    // cmd.c only checks that both parse and that the end isn't before the start; the core is stricter.
    if (!error && (Number.isNaN(command.start) || Number.isNaN(command.end) || command.end < command.start)) error = "Start or end time not valid";
  }
  if (error) {
    log(`\x1b[31mcommand refused: ${error}\x1b[0m`);
    return errorPage(error);
  }
  applyCommand(command);
  return SUCCESS_PAGE;
}

/// What the Nagios core does with the external command. Like Nagios, it silently ignores what it can't use.
function applyCommand(c) {
  const what = c.service && c.cmd !== CMD.hostServicesDowntime && c.cmd !== CMD.ackHost ? `${c.host} / ${c.service}` : c.host;
  if (c.cmd === CMD.ackHost) {
    const host = hosts.get(c.host);
    // acknowledge_host_problem: there is nothing to acknowledge on a host that is up.
    if (host.status === HOST.up) return log(`\x1b[33mACKNOWLEDGE host ${what} ignored: the host is up\x1b[0m`);
    host.ack = { type: c.sticky ? ACK.sticky : ACK.normal, author: c.author, comment: c.comment };
    return log(`\x1b[36mACKNOWLEDGE host ${what} (${c.sticky ? "sticky" : "normal"}${c.notify ? ", notify" : ""}) by ${c.author}: ${c.comment}\x1b[0m`);
  }
  if (c.cmd === CMD.ackService) {
    const svc = findService(c.host, c.service);
    // acknowledge_service_problem: there is nothing to acknowledge on an OK service.
    if (svc.status === SERVICE.ok) return log(`\x1b[33mACKNOWLEDGE ${what} ignored: the service is OK\x1b[0m`);
    svc.ack = { type: c.sticky ? ACK.sticky : ACK.normal, author: c.author, comment: c.comment };
    return log(`\x1b[36mACKNOWLEDGE ${what} (${c.sticky ? "sticky" : "normal"}${c.notify ? ", notify" : ""}) by ${c.author}: ${c.comment}\x1b[0m`);
  }
  // cmd_schedule_downtime and downtime_add.
  const start = Math.floor(c.start / 1000) * 1000, end = Math.floor(c.end / 1000) * 1000;
  const duration = c.fixed ? (end - start) / 1000 : c.duration;
  if (c.trigger) return log(`\x1b[33mDOWNTIME ${what} ignored: triggered downtimes are not supported by the mock\x1b[0m`);
  if (start >= end) return log(`\x1b[33mDOWNTIME ${what} ignored: the end is not after the start\x1b[0m`);
  if (!c.fixed && !duration) return log(`\x1b[33mDOWNTIME ${what} ignored: a flexible downtime needs a duration\x1b[0m`);
  const targets =
    c.cmd === CMD.hostDowntime ? [[c.host, null]]
    : c.cmd === CMD.serviceDowntime ? [[c.host, c.service]]
    : services.filter((s) => s.host === c.host).map((s) => [s.host, s.name]);
  const now = Date.now();
  for (const [host, service] of targets) {
    const d = { id: nextDowntimeId++, host, service, start, end, fixed: c.fixed, duration, flexStart: null, author: c.author, comment: c.comment };
    // register_downtime: a flexible downtime starts at once when the host or service already has a problem.
    const problem = service ? findService(host, service).status !== SERVICE.ok : hosts.get(host).status !== HOST.up;
    if (!d.fixed && problem && start <= now && now <= end) d.flexStart = now;
    downtimes.push(d);
  }
  const scope = { [CMD.hostDowntime]: "host", [CMD.serviceDowntime]: "service", [CMD.hostServicesDowntime]: "all services of" }[c.cmd];
  log(`\x1b[36mDOWNTIME ${scope} ${what}, ${c.fixed ? "fixed" : `flexible ${duration} s`} ${nagiosTime(new Date(start))} - ${nagiosTime(new Date(end))} by ${c.author}: ${c.comment}\x1b[0m`);
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
  if (url.pathname === "/mock/requests") return [200, { requests: state.requests }];
  if (url.pathname === "/mock/reset") {
    for (const s of services) {
      setService(s, SERVICE.ok, " (mock/reset)");
      s.ack = null;
    }
    for (const [name, h] of hosts) {
      setHost(name, HOST.up);
      h.ack = null;
    }
    downtimes.length = 0;
    state.fault = "none";
    state.csrf = true;
    state.dateFormat = "us";
    return [200, { ok: true }];
  }
  if (url.pathname === "/mock/config") {
    const fault = url.searchParams.get("fault");
    if (fault && !["none", "auth", "503", "redirect", "invalid-json", "slow", "hang"].includes(fault)) return [400, { error: "Unknown fault" }];
    if (fault) state.fault = fault;
    const csrf = url.searchParams.get("csrf");
    const dateFormat = url.searchParams.get("dateFormat");
    if ((csrf && !["on", "off"].includes(csrf)) || (dateFormat && !DATE_FORMATS.includes(dateFormat))) {
      return [404, { error: `csrf must be on|off, dateFormat must be ${DATE_FORMATS.join("|")}` }];
    }
    if (csrf) state.csrf = csrf === "on";
    if (dateFormat) state.dateFormat = dateFormat;
    return [200, { ok: true, csrf: state.csrf, dateFormat: state.dateFormat, fault: state.fault }];
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
  if (url.pathname === "/mock/sethost") {
    const p = url.searchParams;
    const status = { up: HOST.up, down: HOST.down, unreachable: HOST.unreachable }[p.get("status")];
    if (!hosts.has(p.get("host"))) return [404, { error: `unknown host "${p.get("host")}"` }];
    if (!status) return [404, { error: `unknown status "${p.get("status")}"` }];
    setHost(p.get("host"), status);
    return [200, { ok: true, host: p.get("host"), status: HOST_NAME[status] }];
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

  if (cgi === "statusjson.cgi") {
    if (state.fault === "auth") return send(401, '{"error":"unauthorized"}');
    if (state.fault === "503") return send(503, '{"error":"unavailable"}');
    if (state.fault === "redirect") return send(302, '{"redirect":true}', { Location: "/redirect-target" });
    if (state.fault === "invalid-json") return send(200, "{broken");
    if (state.fault === "hang") return;
    if (state.fault === "slow") {
      const timer = setTimeout(() => send(200, handleQuery(url.searchParams)), 2000);
      res.once("close", () => clearTimeout(timer));
      return;
    }
    return send(200, handleQuery(url.searchParams));
  }
  if (cgi === "extinfo.cgi") return sendHTML(extinfoPage(url.searchParams));
  // cmd.cgi reads its variables from the query and from a POST body alike (getcgi.c).
  const cookies = parseCookies(req.headers.cookie);
  const fields = new URLSearchParams(url.search);
  if (req.method === "POST") for (const [k, v] of new URLSearchParams(await readBody(req))) fields.append(k, v);
  if (fields.get("cmd_mod") === "2") return sendHTML(commitCommand(fields, cookies));
  // set_cookie (4.5.12+): a new token only when the request doesn't carry one; it has no Path, so it is scoped to
  // /nagios/cgi-bin/. Older versions never set it and only echo a cookie the web UI's JavaScript set.
  let formId = cookies.NagFormId || null;
  const headers = {};
  if (state.csrf && !formId) {
    formId = randomBytes(8).toString("hex");
    headers["Set-Cookie"] = `NagFormId=${formId}; SameSite=Strict; HttpOnly`;
  }
  sendHTML(commandForm(fields, formId), headers);
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
  GET /mock/sethost?host=H&status=up|down|unreachable,
  GET /mock/config?csrf=on|off&dateFormat=${DATE_FORMATS.join("|")}, /redirect/<path> (302)
`);
}

function showState() {
  console.log(
    `\nrotation: ${state.rotating ? "on" : "paused"}  offline: ${state.offline}  auth: ${state.auth ? `${opts.user}:${opts.password}` : "off"}  csrf: ${state.csrf ? "on" : "off"}  dates: ${state.dateFormat}  requests: ${state.requests}`,
  );
  const marks = (host, service, ack) =>
    [ack ? `ACK${ack.type === ACK.sticky ? " (sticky)" : ""}` : "", downtimeDepth(host, service) ? `DOWNTIME ${downtimeDepth(host, service)}` : ""].filter(Boolean).join(" ");
  for (const [name, h] of hosts) {
    const hc = h.status === HOST.up ? "\x1b[32m" : "\x1b[31m";
    console.log(`  ${hc}${name} [${HOST_NAME[h.status]}]\x1b[0m ${marks(name, null, null)}`);
    for (const s of services.filter((s) => s.host === name)) {
      console.log(`      ${color(s.status)}${SERVICE_NAME[s.status].padEnd(8)}\x1b[0m ${s.name} ${marks(s.host, s.name, s.ack)}`);
    }
  }
  for (const d of downtimes) {
    console.log(`  downtime ${d.id}: ${d.host}${d.service ? ` / ${d.service}` : ""} ${nagiosTime(new Date(d.start))} - ${nagiosTime(new Date(d.end))} ${d.fixed ? "fixed" : `flexible ${d.duration} s`}${downtimeInEffect(d) ? " (in effect)" : ""}`);
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
