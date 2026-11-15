# The Nagios protocol, as Polly understands it

How Polly talks to a Nagios Core server: which URLs it requests, what it sends, what it expects back and which
quirks it has run into. Nagios Core has no documented API for most of this. Status comes from its JSON CGI, but
check links and commands come from the HTML pages of the web interface, so this describes observed behaviour and
the source code, not a specification.

Sources:

1. **A real Nagios Core server** (monitor.webhare.net). Every read described here was checked against it: status,
   check details, the check page and both command forms.
2. **The Nagios Core source**, checked out in `nagioscore/` (git-ignored; get it with
   `git clone https://github.com/NagiosEnterprises/nagioscore.git nagioscore`). This document was checked against
   `master` after 4.5.14 (`98d275a`) and the tags back to 4.4.0. File references below are to that tree.
3. **The mock server**, [mock/nagios-mock.mjs](../mock/nagios-mock.mjs). It differs from Nagios in a few places;
   see [Where the mock differs](#where-the-mock-differs).

> **Not verified against a real server:** actually submitting an acknowledgement or a downtime (the `POST` to
> `cmd.cgi`). That has only been done against the mock and checked against the source.

When a real server turns out to behave differently from this document, update the mock first, then the client
(see "Changing the mock" in [DEVELOPERS.md](../DEVELOPERS.md)), and then this document.

## Overview

| What | Request | Answer |
|---|---|---|
| Connection test | `GET statusjson.cgi?query=programstatus` | JSON |
| Status | `GET statusjson.cgi?query=hostcount`, `servicecount` and `servicelist`, in parallel | JSON |
| Check page | `GET extinfo.cgi?type=2&host=…&service=…` | HTML, opened in the browser |
| Related link | the same `extinfo.cgi` page, read by Polly | HTML |
| Command form | `GET cmd.cgi?cmd_typ=34\|56&host=…&service=…` | HTML form (+ CSRF cookie on 4.5.12+) |
| Command | `POST cmd.cgi` | HTML confirmation or error |

All CGIs live under `<base URL>/nagios/cgi-bin/`. The user enters only the base URL (e.g.
`https://monitor.example.com`); Polly appends the path.

## Transport

- **Authentication**: HTTP Basic. Nagios itself doesn't authenticate; the web server in front of it does, and
  the CGIs trust `REMOTE_USER`. What a user may see and do is decided by `cgi.cfg` and the contact definitions
  for that user name.
  - Polly sends the `Authorization` header with every request instead of waiting for a `401` challenge, which
    saves a round trip.
  - A `401` (with `WWW-Authenticate: Basic realm="Nagios Access"`) or `403` means wrong credentials.
- **Redirects**: never followed. A `3xx` answer is an error, because following it would send the credentials to
  wherever it points. Typical cause: `http://` redirecting to `https://`, or a single sign-on page.
- **Caching**: every request bypasses caches. Timeout is 15 seconds.
- **Plain `http://`** is allowed; many internal Nagios servers have no TLS.
- **Query and form encoding** for `extinfo.cgi` and `cmd.cgi`: only `A-Z a-z 0-9 - . _ ~` are left unescaped;
  everything else is percent-encoded, including spaces as `%20`. The CGIs decode `+` as a space
  (`cgi/getcgi.c`), so a `+` in a service name must be sent as `%2B`. Polly also sorts the keys, which Nagios
  doesn't need but keeps logs comparable.

## statusjson.cgi

Nagios Core's JSON API (`cgi/statusjson.c`): `GET <base>/nagios/cgi-bin/statusjson.cgi?query=<query>&…`, sent
with `Accept: application/json`. It needs nothing installed besides Nagios itself (Nagios 4.4 or newer).

### Envelope

Every answer, success or failure, has the same envelope:

```json
{
  "format_version": 0,
  "result": {
    "query_time": 1731590000000,
    "cgi": "statusjson.cgi",
    "user": "nagiosadmin",
    "query": "servicecount",
    "query_status": "released",
    "program_start": 1731500000000,
    "last_data_update": 1731590000000,
    "type_code": 0,
    "type_text": "Success",
    "message": ""
  },
  "data": { … }
}
```

- `result.type_code` `0` is success. Errors come with HTTP `200` and a code from `include/jsonutils.h`: `1`
  memory allocation error, `2` file open/read error, `3` option invalid, `4` option missing, `5` option value
  missing, `6` option value invalid, `7` option ignored. `message` (or `type_text`) describes it.
- A success without `data` is treated as an error, never as "no problems".
- Polly only reads `type_code`, `type_text`, `message` and `data`.

### Values

- **Times** are milliseconds since the Unix epoch, but only to the second: Nagios prints the `time_t` with `000`
  appended (`cgi/jsonutils.c`, `json_time_t`). `0` means "never" (e.g. `last_check` of a check that hasn't run
  yet).
- **States** are bit values (`include/statusdata.h`), so they can be combined in filters:

  | Service | Value | | Host | Value |
  |---|---|---|---|---|
  | pending | 1 | | pending | 1 |
  | ok | 2 | | up | 2 |
  | warning | 4 | | down | 4 |
  | unknown | 8 | | unreachable | 8 |
  | critical | 16 | | | |

- **Enumerations** such as `status` and `state_type` are numbers by default. With `formatoptions=enumerate` they
  become text (`"critical"`, `"hard"`). Polly doesn't send `formatoptions`, so it gets numbers, but also accepts
  `"soft"`/`"hard"` for `state_type`.
- **Strings** are JSON-escaped by Nagios itself (`string_escape_pairs` in `cgi/jsonutils.c`). That table turns a
  bell character into `\a` and a vertical tab into `\v`, which are not valid JSON. A plugin output containing
  either makes the whole answer unreadable for a strict JSON parser, so Polly then reports "not valid
  statusjson.cgi output" for that server.

### query=programstatus (connection test)

The cheapest query. Polly only checks that a valid, successful envelope with `data` comes back; the contents
aren't used.

```json
"data": { "programstatus": { "version": "4.5.14", "nagios_pid": 1234, "program_start": 1731500000000, … } }
```

### query=hostcount and query=servicecount

Totals over everything the user may see:

```json
"data": { "count": { "up": 46, "down": 1, "unreachable": 0, "pending": 0 } }
"data": { "count": { "ok": 702, "warning": 3, "critical": 1, "unknown": 0, "pending": 8 } }
```

If both counts are all zeros, Polly reports an error. That is what Nagios shows a user who isn't authorized for
any host or service (see `authorized_for_all_hosts` and contact groups in `cgi.cfg`), and it must not look like a
healthy installation.

### query=servicelist (problems)

Polly asks only for problem services, with details:

```
statusjson.cgi?query=servicelist&servicestatus=warning%20critical%20unknown&details=true
```

- `servicestatus` takes state names separated by spaces; Nagios splits on `" "` after decoding, so `+` works too.
- With `details=true` each service is an object, nested by host name and service description:

```json
"data": {
  "selectors": { … },
  "servicelist": {
    "web01": {
      "HTTP": {
        "host_name": "web01",
        "description": "HTTP",
        "plugin_output": "CRITICAL - Socket timeout after 10 seconds ",
        "long_plugin_output": "line 2\\nline 3",
        "max_attempts": 3,
        "current_attempt": 3,
        "status": 16,
        "last_check": 1731589950000,
        "next_check": 1731590010000,
        "last_state_change": 1731589000000,
        "state_type": 1,
        "problem_has_been_acknowledged": false,
        "scheduled_downtime_depth": 0,
        …
      }
    }
  }
}
```

- Without `details=true` each service maps to just its status number (`"HTTP": 16`). Polly accepts both forms.
- Fields Polly uses (written by `json_status_service_details`):

  | Field | Meaning | Notes |
  |---|---|---|
  | `status` | service state (bit value) | only warning, unknown and critical become problems |
  | `plugin_output` | first line of the check output | surrounding whitespace is trimmed |
  | `long_plugin_output` | further output lines | Nagios keeps the newlines as a literal backslash-n, which arrives as `\\n` in JSON |
  | `last_state_change` | when the current state began | the problem's age; a warning that turns critical restarts it |
  | `last_check`, `next_check` | when the check last ran / runs next | `0` = never |
  | `state_type` | `0` soft, `1` hard | text with `formatoptions=enumerate` |
  | `current_attempt`, `max_attempts` | retry progress | shown as "SOFT 2/3" or "HARD 3/3" |
  | `problem_has_been_acknowledged` | someone acknowledged it | boolean |
  | `scheduled_downtime_depth` | number of downtimes the service is in | `0` = none |

- The other fields are ignored. Polly doesn't query `hostlist`; a host that is down is only visible in
  `hostcount` and through its services.

## extinfo.cgi (check page and related link)

```
GET <base>/nagios/cgi-bin/extinfo.cgi?host=web01&service=HTTP&type=2
```

`type=2` is the service information page (`DISPLAY_SERVICE_INFO` in `include/cgiutils.h`). Polly opens this URL
in the browser for **Open in Nagios**.

For **Related link**, Polly fetches the same page and looks for the service's action URL or notes URL
(`cgi/extinfo.c`). These are not taken from the JSON API (`objectjson.cgi`), because that returns them as
templates, while `extinfo.cgi` has already run them through `process_macros_r`. The links are images inside
anchors, recognized by their `alt`/`title` text:

```html
<A HREF='https://wiki.example.com/web01' TARGET='_blank'><img src='/nagios/images/action.gif' border=0
   alt='Perform Additional Actions On This Service' title='Perform Additional Actions On This Service'></A>
<A HREF='/nagios/docs/ping.html' TARGET='_blank'><img src='/nagios/images/notes.gif' border=0
   alt='View Additional Notes For This Service' title='View Additional Notes For This Service'></A>
```

- The action URL wins over the notes URL. A relative `HREF` is resolved against the `extinfo.cgi` URL.
- Nagios prints the URL **without HTML escaping**, inside single quotes. A `&` arrives as a bare `&`, and a URL
  containing `'` breaks the attribute. Polly decodes entities anyway, which only matters for a URL that literally
  contains something like `&amp;`.
- The link is refused when it still contains a `$` (a macro Nagios couldn't expand), isn't `http(s)`, has no
  host, or contains credentials.
- `TARGET` comes from `action_url_target` / `notes_url_target` in `cgi.cfg`, `_blank` by default; Polly ignores
  it.
- Errors are `<P><DIV CLASS='errorMessage'>…</DIV></P>` with "Error: Service Not Found!", "Error: Service Status
  Not Found!" or "It appears as though you do not have permission to view information for this service...".

## cmd.cgi (acknowledge and downtime)

Commands go through the same form the web interface uses (`cgi/cmd.c`), in two steps: fetch the form, then post
it. Nothing changes on the server until the post.

| Command | `cmd_typ` (`include/common.h`) |
|---|---|
| Acknowledge a service problem | `34` (`CMD_ACKNOWLEDGE_SVC_PROBLEM`) |
| Schedule downtime for a service | `56` (`CMD_SCHEDULE_SVC_DOWNTIME`) |

`cmd_mod` selects the step: `1` (`CMDMODE_REQUEST`, the default) shows the form, `2` (`CMDMODE_COMMIT`)
executes the command.

### Step 1: fetch the form

```
GET <base>/nagios/cgi-bin/cmd.cgi?cmd_typ=34&host=web01&service=HTTP
```

The answer is an HTML page with a form (`<form method='post' action='cmd.cgi'>`). Polly reads the `name` and
`value` of every `<input>`. As printed by `request_command_data` in 4.5.14:

```html
<form method='post' action='cmd.cgi'>
<INPUT TYPE='hidden' NAME='nagFormId' VALUE='1a2b3c4d5e6f'          ← CSRF token; note the missing '>'
<TABLE CELLSPACING=0 CELLPADDING=0 CLASS='optBox'>
<tr><td><INPUT TYPE='HIDDEN' NAME='cmd_typ' VALUE='34'><INPUT TYPE='HIDDEN' NAME='cmd_mod' VALUE='2'></td></tr>
…<INPUT TYPE='TEXT' NAME='host' VALUE='web01'>…
…<INPUT TYPE='TEXT' NAME='service' VALUE='HTTP'>…
…<INPUT TYPE='checkbox' NAME='sticky_ack' CHECKED>…                ← acknowledge only
…<INPUT TYPE='checkbox' NAME='send_notification' CHECKED>…         ← acknowledge only
…<INPUT TYPE='checkbox' NAME='persistent' >…                       ← acknowledge only
…<INPUT TYPE='TEXT' NAME='com_author' VALUE='Nagios Admin' READONLY DISABLED>…
…<INPUT TYPE='TEXT' NAME='com_data' VALUE='' SIZE=40>…
…<INPUT TYPE='TEXT' NAME='start_time' VALUE='11-15-2026 14:05:00'>…   ← downtime only
…<INPUT TYPE='TEXT' NAME='end_time' VALUE='11-15-2026 16:05:00'>…     ← downtime only
```

- **Check the form before using it.** `cmd_typ`, `cmd_mod=2`, `host` and `service` must echo what was asked
  for. A login page, "It appears as though you do not have permission to submit the command you requested..."
  (`authorized_for_read_only`) or any other page comes with HTTP `200` too, so the status code proves nothing.
  - The form doesn't prove permission for this service: `is_authorized_for_service_commands` is only checked at
    the commit, which then answers "Sorry, but you are not authorized to commit the specified command."
- **Author.** `com_author` is prefilled with the contact's alias, or the user name when there is no contact. With
  `lock_author_names=1` in `cgi.cfg` (the default) the field is read-only, and at the commit Nagios ignores
  whatever is posted and uses the alias or user name again. Polly prefills the author with this value, or with
  its own username when the form leaves it empty.
- **Comment.** `com_data` can be prefilled with a default from `cgi.cfg` (`CMT_ACKNOWLEDGE_SVC_PROBLEM=2,"text"`).
  Polly doesn't use that default yet; it starts with an empty comment.
- **Dates.** `start_time` and `end_time` are prefilled with now and now + 2 hours, in the server's `date_format`
  (`nagios.cfg`) and **in the server's time zone**, which Polly can't know. The formats, from `string_to_time`:

  | `date_format` | Notation | Seen on |
  |---|---|---|
  | `us` (default) | `MM-DD-YYYY HH:MM:SS` | mock |
  | `euro` | `DD-MM-YYYY HH:MM:SS` | |
  | `iso8601` | `YYYY-MM-DD HH:MM:SS` | monitor.webhare.net |
  | `strict-iso8601` | `YYYY-MM-DDTHH:MM:SS` | |

  - When parsing, both ISO variants accept a space or a `T` between date and time.
  - Nagios converts with `mktime` and `tm_isdst = -1`, so the server resolves its own DST.
  - Polly lets the user edit these strings and only checks that both parse in the notation of the prefilled
    start time and that the end is after the start. It never converts them.

#### The CSRF token

How it works depends on the Nagios version:

| Version | Who sets the `NagFormId` cookie | Hidden `nagFormId` input | Commit without a valid token |
|---|---|---|---|
| 4.2.0 – 4.5.11 | JavaScript in the web UI's `index.php` | only when the request carried the cookie | accepted when there is no cookie; refused when cookie and input differ |
| 4.5.12 | `cmd.cgi` itself (`Set-Cookie: NagFormId=…; SameSite=Strict`) | always | refused |
| 4.5.13 and later | `cmd.cgi` itself (4.5.14 adds `HttpOnly`) | always | refused, unless `cgi_cookie_fail_open=1` in `cgi.cfg` |

- So against 4.5.11 or older, Polly (which never loads `index.php`) gets no token and posts without one. That is
  what monitor.webhare.net does.
- On 4.5.12 and later the form request sets the cookie, and the post must carry both the cookie and the same
  value as the `nagFormId` field. The cookie has no `Path`, so it is scoped to `/nagios/cgi-bin/`.
- The hidden input is printed **without its closing `>`** (`printf("<INPUT TYPE='hidden' NAME='nagFormId'
  VALUE='%s'\n", …)` in every version). A parser looking for `<input …>` misses it or swallows the next tag;
  Polly reads each input up to the next `<`.
- A refused token is answered with a bare `<p>Error: Invalid or missing CSRF cookie!</p>`, not an
  `errorMessage` div.

### Step 2: post the command

```
POST <base>/nagios/cgi-bin/cmd.cgi
Content-Type: application/x-www-form-urlencoded
Referer: <the URL of the form from step 1>
Cookie: NagFormId=<token>                 ← when step 1 set it
Authorization: Basic …
```

- The URL has no query; the command is in the body only.
- Polly posts with the same URL session as the form request, so the cookie from step 1 is sent back.
- Nagios doesn't check the `Referer`; Polly sends it because a browser would.

Body for an **acknowledgement** (`cmd_typ=34`):

| Field | Value |
|---|---|
| `cmd_typ` | `34` |
| `cmd_mod` | `2` |
| `host`, `service` | the problem |
| `com_author` | author (replaced by Nagios when author names are locked) |
| `com_data` | comment |
| `sticky_ack` | `on`: stays acknowledged until the service is OK again, not just until the next state change |
| `send_notification` | `on` only when the user asks the server to notify its contacts; left out otherwise |
| `nagFormId` | the token, when the form had one |

`persistent` is left out, so the acknowledgement comment is removed when the acknowledgement ends.

Body for a **downtime** (`cmd_typ=56`): the same common fields (without `sticky_ack` and `send_notification`),
plus

| Field | Value |
|---|---|
| `start_time`, `end_time` | in the server's notation, as described above |
| `fixed` | `1`: a fixed window from start to end |
| `trigger` | `0`: not triggered by another downtime |
| `hours`, `minutes` | `2`, `0`: the form's defaults for the duration of a flexible downtime; passed on, but not used for a fixed one |

- Checkboxes are only checked for presence, so unchecked ones are left out entirely, as a browser would.
- Nagios writes the command as one semicolon-separated line to its external command file
  (`cmd_submitf`), e.g. `[1731590000] ACKNOWLEDGE_SVC_PROBLEM;web01;HTTP;2;0;0;Arnold;Looking into it`
  (sticky = `2`, notify, persistent, author, comment) or
  `SCHEDULE_SVC_DOWNTIME;web01;HTTP;<start>;<end>;1;0;7200;Arnold;Planned maintenance`.
  - Nagios replaces `;` in the comment with a space (`clean_comment_data`), but not in other fields. Polly
    refuses semicolons and control characters in host, service, author and comment before sending.

### The answer

Success, as printed by `commit_command_data`:

```html
<P><DIV CLASS='infoMessage'>Your command request was successfully submitted to Nagios for processing.<BR><BR>
Note: It may take a while before the command is actually processed.<BR><BR>
<A HREF='javascript:window.history.go(-2)'>Done</A></DIV></P>
```

- Polly accepts only a div with class `infoMessage` whose text starts with "Your command request was successfully
  submitted to Nagios for processing.". The form page itself also has an `infoMessage` ("Please enter all
  required information before committing the command."), so the class alone isn't enough.
- Polly reads the text right after the opening tag instead of matching `<div>(.*?)</div>`, which would stop at
  the wrong closing tag when the message is nested in another div (as the mock does).
- Everything else is a failure, all with HTTP `200`. The messages Polly can run into:

  | Message | Cause |
  |---|---|
  | `<p>Error: Invalid or missing CSRF cookie!</p>` | token missing or different from the cookie |
  | Comment was not entered | comment required (the default for both commands) and empty |
  | Author was not entered | author empty while names aren't locked |
  | Start or end time not valid | a time that doesn't parse in `date_format`, or end before start |
  | Sorry, but you are not authorized to commit the specified command. | no command permission for this service |
  | Sorry, but Nagios is currently not checking for external commands, so your command will not be committed! | `check_external_commands=0` |
  | Sorry Dave, I can't let you do that... | `use_authentication=0`: the CGIs refuse all commands |
  | An error occurred while attempting to commit your command for processing. | the command file couldn't be written |

- "Submitted" means Nagios wrote the command to its command file, not that it has been processed. The status
  changes on a later `statusjson.cgi` request.
- **Never retry a post.** A lost answer doesn't mean the command wasn't accepted, and a second post would
  acknowledge twice or schedule a second downtime.

## Known differences between servers

| | Nagios Core 4.5.14 defaults | monitor.webhare.net |
|---|---|---|
| CSRF token (`nagFormId` + cookie) | yes, required | none (4.5.11 or older) |
| `date_format` | `us` | `iso8601` |
| Author field | locked (`lock_author_names=1`) | locked |
| `state_type` in JSON | `0`/`1` | not recorded |

## Where the mock differs

The mock is close enough for Polly's parsers, but differs from Nagios in these places:

- The success message is wrapped in `<P><DIV ALIGN=CENTER>…</DIV></P>`; Nagios writes
  `<P><DIV CLASS='infoMessage'>…</DIV></P>` directly.
- Its error texts are its own ("Error: You must enter a comment!", "Error: End time must be after start time!"),
  and the CSRF error is an `errorMessage` div instead of a bare `<p>`.
- `csrf=on` behaves like 4.5.12+ (the CGI sets the cookie and requires the token), but sets the cookie with
  `Path=/` and without `SameSite`/`HttpOnly`. `csrf=off` behaves like 4.5.11 or older without a browser cookie.
- The author is always "Nagios Admin", whatever the user name.
- An unknown service on `extinfo.cgi` answers "This service does not have any status information associated with
  it." instead of "Error: Service Not Found!".
- An unsupported `statusjson.cgi` query answers `type_code` `3` with `type_text` "Option Missing"; in Nagios `3`
  is "option invalid" and `4` "option missing".

## Debugging an exchange

Turn on **Log server traffic** in Polly (or `debugLog: true` in `polly.yaml`). Every request and response is
written to `polly-debug.log` next to `polly.yaml`, one JSON object per line, with the `Authorization` header
replaced. Compare that with what the mock sends, and with the source in `nagioscore/`, to find where a real
server differs.
