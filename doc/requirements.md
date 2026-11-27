# Polly requirements

What Polly does and the rules it follows. See [AGENTS.md](../AGENTS.md) for how to maintain this file.

## General

- Polly monitors Nagios servers, websites and feeds from macOS (menu bar), iPhone and iPad.
  - Requires macOS 14 / iOS 17 or later.
  - Polly polls straight from the device; nothing goes through a Polly server.
- A user can monitor three types of source:
  - Why "source" and not "server": the hosts Polly reports on are servers too, so "server" was ambiguous.
  - **Nagios server**: status is read from the server's Nagios installation (Nagios 4.4 or newer).
  - **URL**: Polly checks a website itself, with no monitoring system behind it.
  - **Feed**: a server lists what needs attention (such as SLA tickets) in Polly's JSON feed format.
  - Everywhere a source is shown, its type ("Nagios", "URL" or "Feed") is shown next to its name.
- Polly never changes anything on a monitored server, except when the user explicitly confirms an
  acknowledgement or downtime.
- The screens follow the Polly design, in light and dark.
  - Polly's mascot reflects the overall mood: ok, warning, critical or unreachable.
  - Parts of the design that are drawn but don't work yet carry a PLACEHOLDER or PROTOTYPE tag and do nothing
    (see [Not built yet](#not-built-yet)). A control must never silently do nothing.

## Sources

- The user can add a source of either type.
  - macOS: **Add** above the source list opens the "Add a source" modal, with a Type control.
    - Cancel closes the modal without saving; adding successfully closes it and updates the list.
    - The form cannot be edited or dismissed while the connection test is running.
  - iOS: **Add** (a menu: Nagios Server… / URL… / Feed…) on the Sources tab, or **Add source…** in the empty
    states; the form opens as a sheet titled "Add Nagios Server", "Add URL" or "Add Feed".
  - The URL placeholder and the explanation adapt to the type:
    - Nagios: the `statusjson.cgi` URL that will be read.
    - URL: that the host resolves, that the URL answers and (https only) that the certificate is valid for at
      least two more weeks.
    - Feed: that it is a JSON feed in Polly's format, read from the URL as entered.
  - The URL comes first in the form, before **Name**.
    - Why: the name, username and password are derived from the URL, so filling it in first fills the rest.
  - Example URLs in the URL field are shown as plain placeholder text, not as links.
    - Why: a link-colored placeholder looks like a URL that is already filled in.
  - **Name** is optional; it defaults to the URL's host name.
  - Username and password are never required. For a URL they are only needed for a page behind HTTP Basic
    authentication.
  - "Sign in with" chooses **Username & password** (HTTP Basic) or **Custom header**, for every type of source.
    - With a custom header the user enters the header's name (such as `X-API-Key` or `Authorization`) and its
      value (such as the key, or `Bearer <token>`); the value is sent with every request instead of Basic
      authentication.
      - Why: feeds and proxies in front of a server often take an API key or bearer token, not a login.
    - The value is a secret: it is stored like a password (keychain or `polly.yaml`), never shown in the debug log,
      and the name is kept as `authHeader` in `polly.yaml`.
    - A name that isn't a valid header, or one the connection sets itself (such as `Host` or
      `Content-Length`), is refused with an explanation.
    - Pasting a URL with `user:pass@` switches back to username and password.
  - On macOS the form says where the password will be stored (keychain or `polly.yaml`).
- The URL field is paste-friendly:
  - Pasting `https://user:pass@host/...` moves the (percent-decoded) username and password into their own
    fields and removes them from the URL.
  - A URL without a scheme gets `https://`.
  - The fragment is always removed.
  - Nagios: query and anything from `/nagios` onwards are removed, so a pasted link to the Nagios web UI just
    works. The user enters the base URL; Polly appends `/nagios/cgi-bin/statusjson.cgi`.
  - URL and feed: the path and query are kept as entered.
- Adding a source tests the connection first.
  - **Test connection** can also be run on its own before adding; changing the URL or type resets the result.
  - A failed test shows the error with **Add anyway** (and **Retry** on iOS).
    - Why: the server may be temporarily down or only reachable from another network.
  - For a URL, the test only fails on a critical problem; a certificate that expires soon doesn't block adding
    it.
- The user can edit a source: its type, name, URL, username and password.
  - macOS: click the pencil next to the source or choose **Edit…** in its context menu; the form opens as
    the "Edit source" modal.
  - iOS: tap the source (not its bell or switch), swipe left and choose **Edit**, or **Edit…** in its context menu;
    the form opens as a sheet titled "Edit Nagios Server" or "Edit URL".
  - The form is the add form, prefilled, with **Save** instead of **Add**; the password field shows the current
    password.
  - The source keeps its place in the list, its switch and its bell.
  - Saving tests the connection first, like adding, with **Save anyway** when the test fails. When only the name
    changed, it saves without a test.
    - Why: renaming a source that is down must not need an override.
  - A name that equals the URL's host is shown empty, so it keeps following the URL when that changes.
  - After a change of URL or type the source's old state is forgotten and it is checked again right away; the
    first answer doesn't notify.
    - Why: it is a different system now; its problems are not changes of the old one's.
  - **Edit source…** on the Unreachable screen opens this form for the unreachable source (macOS: in the
    Settings window, on the Sources pane; iOS: on the Sources tab).
- On macOS, clicking a source in Settings opens its live status and problems without needing the menu bar icon.
  - The source list also shows the latest status or connection error.
  - The detail shows only this source, with host and service totals, problems grouped by severity, and the time of its last successful check.
  - Clicking a problem opens its check output and existing actions; **Refresh** checks this source again.
  - Loading, paused, disabled and unreachable sources are distinguished from a source with no problems.
- The user can duplicate a source to add a similar one without typing everything again.
  - macOS: **Duplicate…** in the context menu. iOS: **Duplicate…** in the context menu, or swipe right.
  - Opens the add form prefilled with the source's type, URL, username, password and bell; the name gets
    " copy" appended (or stays empty when it was just the host). The copy is a new source, switched on.
- A web page can offer an "Add to Polly" link (`polly-monitor://add?type=…&url=…`), described in
  [add-to-polly.md](add-to-polly.md), on macOS, iPhone and iPad.
  - It opens the add form filled in with the type, URL, name, username or sign-in header; macOS opens the
    Settings window on the Sources pane, iOS the Sources tab.
  - It never adds a source by itself: the user sees the form, enters the password or header value, tests and
    adds.
    - Why: any web page can open such a link.
  - A link with a password, token or other secret, or a URL with `user:password@`, is refused with an
    explanation.
    - Why: links end up in browser history, server logs and screenshots.
  - Only `http` and `https` URLs are accepted, so a web page can't point Polly at files on the computer.
  - Unknown types, invalid header names and links longer than 2048 characters are refused with the reason;
    unknown parameters are ignored.
  - When the user already has a source with the same type, URL and username, Polly shows it instead (macOS:
    its status; iOS: its edit form).
  - The scheme is `polly-monitor`, not `polly`, which other apps may claim.
  - Not handled yet: a page can't tell whether Polly is installed ([issue #90](https://github.com/WebHare/polly/issues/90)).
- New sources are added at the end of the list. The list order is the order in `polly.yaml`; reordering is done
  by editing the file.
- The user can delete a source (context menu; swipe left on iOS).
- The user can refresh one source (context menu) or all sources (menu bar panel, pull to refresh on iOS).
- Each source has an on/off switch in Settings to disable it without deleting it (`enabled: false` in
  `polly.yaml`).
  - A disabled source shows "Disabled" in Settings, is not polled and is left out of the overview completely, as
    if it wasn't configured.
- The user can pause a source: on macOS with **Check in Polly** in its detail in the menu bar panel (see
  [macOS menu bar](#macos-menu-bar)), or with **Pause** / **Resume** in its context menu in Settings and on
  iPhone and iPad.
  - Why both: disabling is a setting ("I don't want this source here"); pausing is for now ("stop bothering me
    about this one for a while") and stays visible, so it isn't forgotten.
  - A paused source is not polled, its problems are not listed or counted and it sends no notifications.
  - It stays in the overview's source list with a pause icon and "Paused since 15:30 · not checked" (with the
    date when it was paused on another day).
  - The pause is saved (`pausedSince` in `polly.yaml`) and survives a restart.
    - Why: quitting Polly must not quietly resume a source that was paused because it was noisy; the menu bar
      icon keeps it from being forgotten.
  - Resuming checks the source right away; that first answer doesn't notify, like a source that is turned on
    again.
  - Pausing only affects Polly on this device, not the monitoring system or other users.
  - A disabled source can't be paused; a source that is both is just disabled.
- Each source has a bell to turn notifications on or off (see [Notifications](#notifications)).
- Each source shows a one-line state:
  - "170 hosts, 1 down · 714 services, 1 crit, 3 warn", or "48 hosts up · 216 services OK" when all is well.
    - Each problem count ("1 down", "1 crit", "3 warn", "2 unknown") has a small status icon in front of it
      and is written in its status color.
  - "Unreachable · <error>" in red when it can't be read; its URL while it is loading for the first time.
- The icon in front of a source only says whether Polly can reach it: a green check when it answers,
  a red error icon when it can't be reached, a pause icon when it is paused, a minus icon when it is disabled,
  a spinner while loading.
  - Problems on the hosts and services it monitors never change that icon; they show in the state line.
    *Why:* a red icon for one critical service made healthy monitors look unreachable.

## Overview

The overview is the macOS menu bar panel and the iOS Problems tab. Both show the same summary of all enabled
sources that are not paused.

- Problems (warning, critical and unknown services, and hosts that are down or unreachable) of all sources are
  grouped by severity: critical, then warning, then unknown; newest first within a group.
  - Each problem shows host, service, its age and markers for acknowledged (ACK) and scheduled downtime.
  - A host that is down or unreachable is one critical problem: the host with "Host down" or "Host unreachable"
    instead of a service.
    - The problems of the services on that host are not listed, and don't count in the numbers per severity.
    - Why: one dead host makes all its services fail; one line says it, a dozen lines bury the rest.
    - On by default; "Hide services on hosts that are down" in the macOS Alerts pane (`hideServicesOnDownHosts`
      in `polly.yaml`) turns it off, so the services are listed next to their host again.
    - Only the services on that host on the same source are hidden; the same host name on another source is
      another host.
  - The age is "<1m", "3m", "2h", "3d" (largest unit only), refreshed every minute.
    - On macOS, hovering shows the exact duration and the local start time.
    - The age is the time since the service's last state change, so a warning escalating to critical restarts
      it.
    - URL problems show no age, as Polly keeps no history for them.
- Polly's headline says what is going on, worst first:
  - "Polly is squawking: N hosts down" / "Polly is squawking: N critical".
  - "Polly is fidgeting: N warnings".
  - "Polly is confused: N unknown".
  - "Polly can't reach <source>".
  - "Polly is checking your sources" before the first answer, or "Polly is not watching: all sources are
    paused".
  - "Polly is quiet. Go back to sleep." when everything answered and is fine.
  - "Polly has nothing to watch yet" without sources, or "Polly has nothing to watch: all sources are
    disabled".
- Which screen is shown:
  - **Problems** when there is a problem or a host is down.
    - A host can be down while none of its services is listed as a problem; that still counts.
  - **Unreachable** when a source can't be read: its error, "Polly keeps trying every 60 s", **Retry now** and
    **Edit source…**.
  - **Waiting** while nothing has answered yet: "Waiting for the first answer", or how to resume when all
    sources are paused.
    - Why: nothing checked is not the same as nothing wrong; it must never look like "all is well".
  - **All quiet** with the number of hosts and services that are fine and when Polly checks again.
  - **Empty** without sources, with **Add source…**; when every source is disabled, how to turn one on, with
    **Settings…** on macOS.
- A source that can't be reached counts as unreachable in the mood, even when other sources are fine.

## macOS menu bar

- Local macOS development builds are named **Polly DEV** and have a yellow **DEV** ribbon on their app icon, so they can be distinguished from the installed release.
  - They keep the same source settings; the label does not create a separate monitoring setup.
  - Release builds and iPhone/iPad builds keep the ordinary name and icon.
  - Developers can use a fixed local signing identity for both macOS development and local Release builds without changing the official WebHare signing defaults or iOS signing.
    - Rebuilding with the same signing identity preserves Keychain authorization; switching identity or distribution channel may require authorization again.
- Polly is a menu bar app with no Dock icon by default.
  - A Dock icon can be turned on in Settings; clicking it opens the Settings window.
- The menu bar icon is Polly's head plus a count when there is something to read.
  - Critical: a red pill with Polly on its back and the number of criticals (or hosts down, whichever is
    larger).
  - Warning: a warning triangle and the number of warnings.
  - Unreachable: a faded Polly with the number of unknowns, or "?".
  - Otherwise just Polly. The non-critical icons adapt to a light or dark menu bar.
  - When sources are paused, a pause sign and the number of paused sources follow, in every state; with a
    critical problem it sits outside the red pill.
    - When every source is paused there is nothing special: just Polly with the pause sign and number.
    - Why: a paused source is easy to forget; the icon is always in sight.
- The panel shows the overview, the list of sources with their state, and **Refresh**, **Settings…** and
  **Quit**.
  - It lists the enabled sources; disabled ones are left out, paused ones show their pause icon and line.
  - The footer says "Retrying in 46 s" when a source is unreachable, "Checking…", "Paused", "No sources" or
    "All sources disabled"; it
    doesn't say when the sources were last checked.
    - Why: with several sources one time for all of them says little, and an indicator that only matters when
      something is wrong doesn't belong in the footer. Each source's detail shows its own last refresh.
  - It sizes to its content up to about a quarter of the screen height, then scrolls.
  - The user can resize it by dragging; that size is remembered, and **Fit** returns to automatic sizing.
- Clicking a problem slides the panel to its detail (see [Problem detail](#problem-detail)).
  - "‹ Problems" (or Escape) goes back; "2 of 6" with up/down buttons (or the arrow keys) steps through the
    problems without going back.
  - Why in the panel, not a window: the menu bar panel closes as soon as it loses focus.
- Clicking a source slides the panel to the source detail; "‹ Back" (or Escape) goes back.
  - It shows the source's name, type, URL, state line, when Polly last refreshed it ("14 s ago", or "Failed
    1 min ago · last answer 10 min ago") and when it refreshes next.
  - **Check in Polly** pauses or resumes the source (see [Sources](#sources)).
    - Its text says that it only affects Polly on this device, so it can't be mistaken for the monitoring
      system's notification switch below it.
    - While paused: "Last refresh" keeps counting from the last answer before the pause, there is no next
      refresh, and the notification switch is greyed out with "Unknown while paused", as Polly doesn't read
      the status that holds it.
  - For a source whose monitoring system reports it (Nagios), a switch turns that system's own notifications
    on or off (see [Notifications on the monitoring system](#notifications-on-the-monitoring-system)).
- The Settings window has a sidebar with Sources, Alerts, Team, Account and About Polly.
  - **Sources**: the source list (switch, bell, edit, duplicate, refresh, delete), the Add button and the advanced
    settings (see [Settings and storage](#settings-and-storage)).
  - **About Polly**: version and build number and **What's New**.

## iPhone and iPad

- The app has three tabs: Problems, Sources and Settings.
- **Problems** shows the overview.
  - Filter chips per severity ("All N", "Critical 2", ...) limit the list to one severity.
  - An unreachable source is listed separately below the problems.
  - A button in the toolbar shows the number of sources and switches to the Sources tab.
  - Tapping a problem opens its detail; pull to refresh refreshes that problem's source.
    - When the source no longer reports the problem, the detail says "Problem resolved".
- **Sources** lists the sources with their state, switch and bell; add, edit, duplicate, refresh and delete them
  there.
- **Settings** has the password storage and debug log settings, the version and build number, and **What's New**.
- Polly only polls while the app is in the foreground.
  - It refreshes immediately when it becomes active again, without waiting for the polling interval.

## Problem detail

- Shows the severity ("DOWN" / "UNREACHABLE" for a host problem), its retry state ("SOFT 2/3" / "HARD 3/3"),
  ACK and DOWNTIME tags, service (or "Host down" / "Host unreachable"), host and the source with its type.
- Shows the check output and long output (selectable).
- Shows the duration with its start time, how long ago the last check was, and when the next check is.
  - A value the server didn't send is shown as "Unknown".
- Shows the deadline ("in 6d" / "2h overdue", with the date) and the extra facts a feed sends for an item.
- Shows the actions the source type supports (Nagios: all of them; URL: none; feed: only opening it).
  - **Acknowledge…** (disabled when already acknowledged) and **Schedule downtime…**.
  - **Open in Nagios**: the check's page in the Nagios web UI; the host's page for a host problem.
  - **Open in browser** (feed): the item's own page, or the feed's page when the item has none.
  - **Related link**: the action or notes link configured for the check.
  - If the password can't be read, the detail says why instead of showing no actions.
- The password is only read when a problem is opened.

## Acknowledge and downtime (Nagios)

- Commands are a two-step flow: the form is fetched from the server, then submitted only after the user
  confirms.
  - The form opens in the macOS panel, or as a sheet on iOS.
  - The form asks for author (prefilled by the server, or the username) and a required comment.
  - If the server doesn't return the expected form, the user is told to check their command permissions in the
    browser.
- A host problem is acknowledged and put in downtime as the host itself, not one of its services.
  - **Applies to** then offers "This host only" (the host's own downtime) or the host and all its services.
- An acknowledgement is sticky: it lasts until the service is OK again, also when a warning turns critical.
  - The user can ask the server to notify its contacts; off by default.
- A downtime is a fixed window from a start to an end time.
  - Start and end are in the server's own notation and time zone, prefilled by the server with now and now + 2
    hours. Polly never converts them.
    - Why: the server doesn't report its time zone or date notation.
  - Presets set the end, counted from the start: 30 min, 1 hour, 2 hours, until 09:00 tomorrow. **Custom…** means
    typing the end (and start) by hand. The preset that matches the current times is shown as selected.
    - Presets work only when Polly can tell the server's date notation from the prefilled times. When two
      notations fit (e.g. on 11-11 for US and European dates), a preset is only offered when both give the same
      result; otherwise it is disabled with an explanation.
    - Caveat: presets count in wall-clock time, so on the day the server's clock changes for DST the end can be
      an hour off.
  - **Applies to**: this service only (default), or the host and all its services.
    - The host option schedules two downtimes on the server: one for the host and one for all its services.
    - It is disabled when the server doesn't offer the host forms (e.g. no permission for host commands).
  - **Also acknowledge the current problem**: on by default; sends a sticky acknowledgement without notification
    after the downtime.
    - Not offered when the problem is already acknowledged or the server doesn't offer the acknowledge form.
  - All forms are fetched when the downtime form opens, one after the other, so nothing is posted before the user
    confirms and the CSRF token stays the same.
- A command is sent at most once per form and never retried automatically.
  - Why: a lost response doesn't prove the command wasn't accepted; a retry could acknowledge or schedule twice.
  - When not confirmed, the user is told to check the server in the browser before trying again.
  - A downtime with options takes several requests, sent in order: host, services, acknowledgement. When one
    isn't confirmed, the rest isn't sent, and the user is told which parts were accepted, which wasn't confirmed
    and which weren't sent.
- Success means Nagios' own confirmation text, not just HTTP 200.
  - "Accepted" means Nagios queued the command; the status changes once it has been processed. The server is
    refreshed right after.
  - Caveat: Nagios also says "accepted" for a command it then ignores, e.g. an acknowledgement of a service that
    became OK in the meantime.
- Caveat: actually submitting acknowledgements and downtimes has only been tested against the mock server.

## Nagios monitoring

- Every enabled source is polled every 60 seconds, all sources in parallel.
  - A result that arrives after the source was paused, disabled or deleted is discarded.
  - When a poll and a manual refresh overlap, the answer of the refresh started last wins, whichever arrives
    first.
  - A server that refuses the connection must not crash the app.
- Credentials are sent with every request (HTTP Basic).
  - Authentication failures are reported as "check the username and password".
- Redirects are refused, and the user is asked to enter the final URL.
  - Why: following a redirect would send the credentials to wherever it points.
- An answer without data is an error, never "no problems".
  - The same goes for an installation without any hosts or services: that's what Nagios shows an account that
    isn't allowed to see anything.
- **Related link** only opens `http(s)` links without embedded credentials.
- Plain `http://` servers are supported, as internal Nagios servers often have no TLS.
- Caveat: self-signed certificates are not supported yet.

## URL monitoring

- URL monitoring is available in the macOS, iPhone and iPad apps only. Linux monitoring supports Nagios;
  trying to monitor a URL on Linux returns an explicit unsupported-platform error.
- A URL is shown as one host with these services:
  - **DNS**: the host name resolves.
  - **HTTP**: a GET of the URL answers with a status below 400.
    - Redirects are not followed; a redirect is an answer, so the site is up.
    - Times out after 15 seconds; the output includes the response time.
  - **Certificate** (https only): the certificate is trusted by the system for the host name, and the
    certificate and its intermediates stay valid for at least 14 more days (otherwise a warning).
- The host counts as down when DNS or HTTP fails.
- A failed DNS lookup skips the other checks (counted as pending), so one outage isn't reported three times.
- URLs are checked from the device on every poll, using a new connection each time so the certificate is always
  seen. There is no history.
- An untrusted certificate doesn't hide whether the server answers: the HTTP check continues anyway.
  - Except when a username or password is configured: credentials are never sent to a server with an untrusted
    certificate, and HTTP reports that as the reason it didn't connect.

## Feeds

- A feed is a JSON document at a URL, in the format described in [feed-format.md](feed-format.md), that lists the
  items that need attention.
  - Why: things that aren't checks, such as SLA tickets in the WebHare portal, need attention too; the server
    that knows them publishes the list, and Polly needs no knowledge of tickets.
- The server decides what is wrong and how bad it is: every listed item is a problem with its own severity
  (critical, warning or unknown). Items that are fine are only counted.
  - Why: the deadlines and priorities are business rules of the server; when it raises an item's severity as a
    deadline nears, Polly notifies about it like any severity change.
- An item is shown like a service: its group where the host goes, its title where the service goes, its summary
  and details as the check output, its age since it got its current severity, and ACK when acknowledged.
- The source line counts with the feed's own word: "16 tickets OK", or "16 tickets, 1 crit, 1 warn". The
  all-quiet screen counts feed items separately from hosts and services ("10 hosts, 20 services and 16 items OK").
- Items are told apart by their id, so a renamed item is the same problem and doesn't notify again.
- Feeds are read-only: no acknowledgements, downtimes or monitoring notification switch.
- Only http and https links of a feed are opened; other links are ignored.
  - Why: a feed must not make Polly open files or other apps.
- A feed Polly can't use makes the source unreachable with the reason: not JSON, an unknown format version
  (asking the user to update Polly), a missing or invalid field (naming the item), a duplicate id, or the feed's
  own `error` message. An item with a mistake is not quietly left out.
- Redirects are not followed, so the credentials stay with the server that was entered.
- The web service does not support feeds yet; it stays Nagios-only.

## Notifications

- Notifications are per source and off by default.
  - Turning them on asks the system for permission; if it's refused, the user is told to allow notifications in
    the system settings.
  - Notifications enabled by hand in `polly.yaml` also ask for permission before the first notification.
- They are local notifications decided by Polly; the Nagios notification configuration is not touched.
- The first successful poll is the baseline and never notifies.
- After that, new problems, severity changes and recoveries are bundled into one notification per source.
  - A host going down notifies about the host only; its services failing with it don't notify, and services
    that drop out of the list because their host went down are not reported as recovered.
    - With "Hide services on hosts that are down" off, those services notify like any other problem.
  - At most five lines; beyond that the last line says "and N more".
  - A newer notification for a source replaces the older one.
  - Notifications are also shown while Polly is in the foreground.
- Acknowledged problems and problems in scheduled downtime don't notify, including when they recover during the
  downtime.
- A failed poll keeps the last known problems, so an outage of the monitoring server itself doesn't report every
  problem as new once it is back.
- Caveat: notifications only happen while Polly is polling. On iOS that is only while it is in the foreground;
  there is no push.

## Notifications on the monitoring system

- Every source line says "notifications off" (with a warning icon) when the monitoring system itself sends no
  notifications.
  - Why: once switched off it is easy to forget, and then nobody hears about problems.
- The source detail (macOS panel) has a switch for the monitoring system's own notifications (Nagios: the
  program-wide "notifications enabled" setting).
  - This is not Polly's bell: it turns off the notifications the monitoring system sends to all its contacts,
    for every host and service, not just the user's.
  - Its label ("Nagios notifications for everyone") and its text say that it affects every user of that
    monitoring system, whether it is on or off.
  - Turning it off asks for confirmation first, inside the panel, explaining that it affects everyone. Turning it
    on doesn't ask.
  - The command is sent once and never retried; a failure is shown under the switch.
  - Once Nagios accepts the command the switch shows the new position with "Turning off… waiting for Nagios to
    report the change" until the status agrees, at most 150 seconds; after that it shows what Nagios reports.
    - Why: Nagios applies the command and rewrites its status file only after a while
      (`status_update_interval`).
  - The switch is only shown when the source answers and reports the setting; it is disabled for a source
    type that can't change it.
  - The Nagios user needs `authorized_for_system_commands` in `cgi.cfg`; otherwise Nagios refuses the change
    and Polly shows its error.

## Settings and storage

- Sources and settings are stored in one human-readable YAML file, `polly.yaml`, in Polly's Application Support
  folder.
  - The file may be edited by hand while Polly isn't running; it is read at startup and rewritten after every
    change.
  - Every key is optional, but an invalid value (such as an unknown source `type`) is an error.
  - A source without `type` is a Nagios source.
  - Sources are listed under `sources:`. A file that still uses the old `servers:` key is rewritten with
    `sources:` once at startup; a file with both keys is an error.
  - If the file can't be read, Polly runs with in-memory settings and doesn't overwrite the file.
  - The file is only readable by the user, as it may contain passwords.
- Passwords are stored in the keychain by default.
  - A setting stores them unencrypted in `polly.yaml` instead, after which the keychain is never touched.
    - Why: debug builds triggered keychain prompts on every rebuild.
  - Switching moves all existing passwords; if reading them fails, nothing is moved.
- Settings (macOS: Advanced in the Sources pane; iOS: the Settings tab):
  - **Store passwords in Keychain**.
  - **Show Dock icon** (macOS only).
  - **Log server traffic**: writes every request and response to `polly-debug.log` next to `polly.yaml`, with
    **Show Log in Finder** on macOS.
    - Credentials never reach the log.
    - At 5 MB the log is moved to `polly-debug.log.1` and started anew.
- The sources follow the user's other devices through iCloud ("Sync sources with iCloud", on by default; in the
  Advanced settings on macOS and the Settings tab on iOS).
  - Shared: each source's name, type, URL, username, whether it is disabled, and the order of the list.
    Adding, editing, disabling, deleting and reordering (by editing `polly.yaml`) on one device shows on the
    others.
  - Not shared: pausing and the notification bell, which are per device, and the app settings (password
    storage, Dock icon, traffic log, this switch itself).
    - Why: pausing on the Mac shouldn't silence the phone, and a phone may want notifications a Mac doesn't.
    - A source that arrives from another device has its bell off.
  - Passwords stored in the keychain go to iCloud Keychain, so the other devices have them too. Passwords
    stored in `polly.yaml` are not shared; the source arrives without one.
    - Polly finds passwords in either place, so turning sync off or on never loses one; they move to match.
  - A device that joins merges its own sources with those in iCloud. A source with the same type, URL and
    username is the same source, so nothing is listed twice; it keeps this device's pause and bell, and the
    name from iCloud.
  - Changes on two devices to different sources are both kept. When both changed the same source, the change
    that reached iCloud last wins. A source that one device deleted and another changed is kept.
    - Why: a lost change is worse than a source that has to be deleted again.
  - A source that arrives, or that points at another server now, is checked right away; its first answer
    doesn't notify.
  - Turning sync off keeps this device's list as it is and stops sharing it; turning it on again merges like a
    joining device.
  - When syncing fails, the text under the switch says why. A list in iCloud written by a newer Polly is left
    alone.
  - Development builds share a list of their own, separate from the released app's.
  - Builds signed without iCloud (the Developer ID download, local builds without a profile) don't sync.
- The menu bar panel size is window state, not a setting, and is not stored in `polly.yaml`.

## Web service

- Operators can build and run a Linux container with Docker Compose, or start the service with Swift on macOS.
  - The container runs without root, a compiler or Node; public CA certificates are included.
  - Normal Compose runs only Polly, publishes on host loopback, mounts configuration and the viewer hash
    read-only, and restarts after a process or host restart unless explicitly stopped.
  - Other devices connect through an HTTPS reverse proxy; the internal HTTP port remains private.
  - Config and credentials stay outside the image. An upgrade or rollback replaces the image without
    changing configuration. Recreate the container after editing configuration or replacing secret files.
  - A separate mock setup is available for testing, with no published mock port or production credentials.
  - Images are built locally; no automatic updates, registry publication or production deployment are provided.
- A standalone web service can monitor Nagios on macOS and Linux without running the native app.
  - The dashboard uses Polly's own status shapes, fonts and four animated mascot poses, with dark as the
    default and a light-theme button. All artwork and fonts load locally; no CDN is required.
  - Separate figures show hosts down and critical, warning and unknown services. Source coverage and
    reachability remain visible alongside problems, including when another source is critical.
  - Empty configuration, all paused, waiting, unknown, partial coverage and unreachable sources have
    explicit messages and never use the healthy pose.
  - A viewer can expand any problem with a click, Enter or Space to read the full, literal Nagios output
    and long output. ACK and DOWNTIME are informational markers, not actions.
    - Long names and output wrap in details. Refreshing an unchanged row preserves focus and open details.
  - The layout scales for 1080p and 4K, becomes compact at 720p, and uses a vertical list on tablets/phones.
    - Eight collapsed rows fit at 1080p/4K; five are shown on compact screens up to 900 pixels high,
      including 720p. Wider screens show pages in the server-provided order, changing every 15 seconds.
    - A page counter and Previous, Next and Pause/Resume controls keep every problem reachable.
    - Pointer or keyboard interaction pauses automatic pages until Resume; open details, hidden tabs,
      paused motion and reduced-motion preferences also prevent automatic page changes.
    - Dataset changes keep the page valid. A new critical problem or one becoming critical brings the first page back
      on the next update, unless a focused/open row must be preserved; it is shown when that interaction ends.
    - Phones and tablets show the full vertical list, with no automatic page changes.
    - Use the browser/device fullscreen or kiosk mode for unattended displays; there is no app-specific
      fullscreen control or smart-TV API.
  - A viewer can pause mascot motion. System reduced-motion preferences stop the loops, as do a hidden
    browser tab or a mascot outside the viewport. Status remains understandable without motion.
  - The page reads current status every five seconds without triggering an upstream poll. A failed read
    immediately marks retained values as old data and shows a disconnected pose while retrying.
    - Only one request may run at a time; it times out after ten seconds, then retries after five seconds.
    - Hidden tabs stop polling. Returning to the tab or restoring the network requests new data immediately;
      retained data cannot give a healthy confirmation until a new, valid answer has been evaluated.
    - The browser counts source age using elapsed monotonic time, independent of its wall clock. A new
      API response carrying the same old source measurement never resets that age.
    - Malformed JSON or invalid display data is a connection failure; it cannot replace known data.
    - API failure, source failure and old source measurements stay visibly distinct. Partial coverage and
      source age remain visible alongside critical problems from other sources.
  - It has no acknowledgements, downtime actions, rechecks, configuration writes or arbitrary-URL proxy.
- The operator supplies a separate, absolute configuration path through `POLLY_CONFIG`.
  - The file is read once at startup and never rewritten. Restart to apply changes.
  - The list uses `sources:`. Legacy `servers:` is accepted without rewriting; combining both is an error.
  - Only `passwordStorage: file` and Nagios sources are accepted. Disabled entries are left out; paused
    entries are listed as paused. A source with `authHeader` sends its password in that header.
  - HTTP(S) addresses must have a host and contain no embedded credentials or fragment. Pasted Nagios UI
    paths are normalized using the same endpoint rules as the native form.
  - Missing or invalid files, duplicate server IDs and unsupported settings prevent startup with a message
    that does not quote the file's contents or passwords. An empty server list is allowed.
  - The service does not read native app settings or Keychain, send notifications or write traffic logs.
- Every viewer shares one poll loop, with about 60 seconds between completed rounds. Reading status never
  starts a new poll. Shutdown cancels and waits for the poll to stop.
- The public status includes names, states, counts, problems, acknowledgement/downtime markers and completed
  attempt/success times. It excludes upstream URLs, usernames, passwords, hashes and raw transport errors.
  - Known configured credentials are also removed from source-provided display text.
  - A server is loading, OK, unreachable or paused, with its last successful data's age and staleness.
  - Data is stale from 150 seconds onward. A fresh API response does not refresh its source measurement.
  - Healthy requires fresh data from every enabled source and no pending checks. Empty, paused, waiting,
    partial coverage and unreachable states cannot appear as healthy.
  - Problems from reachable sources stay visible when another source fails; coverage remains visible too.
- The default listener is `127.0.0.1:8088`. Listening outside loopback requires separate viewer credentials.
  - `POLLY_VIEWER_USERNAME` and `POLLY_VIEWER_PASSWORD_HASH_FILE` must be provided together. The secret file
    holds a bcrypt hash with cost 10 through 14. The password-hashing command accepts 12 through 72 UTF-8
    bytes through stdin, never a password argument.
  - When configured, authentication protects the start page, status API and health endpoint, including on
    loopback. Use HTTPS at a reverse proxy before network access and keep the internal HTTP port private.
  - The single viewer account has a shared budget of ten failed/in-flight login attempts per 60-second
    window and at most eight simultaneous password checks. Excess attempts receive HTTP 429 with Retry-After.
  - Only GET and HEAD are served. Configuration/secret files are not public assets. Responses are not cached,
    no cross-origin access is enabled, and HTTP errors do not echo request or upstream details.
- The health endpoint reveals only whether the process and poll loop are alive. Failed Nagios requests do
  not make the service unhealthy; no completed poll for 180 seconds does.

## Not built yet

Drawn from the design and tagged as such, but without function:

- **Recheck now** in the problem detail.
- **Notified** in the problem detail (Polly keeps no record of what it notified about).
- Other monitoring systems in the Type control (Icinga 2, Checkmk, Zabbix).
- Poll interval and "Verify TLS certificate" in the add-source form; the interval is fixed at 60 seconds.
- The Alerts pane (PROTOTYPE) apart from "Hide services on hosts that are down": the other filters (hide
  acknowledged, soft states, downtime), notification rules and quiet hours are not saved or applied.
- The Team pane remains labeled **PLACEHOLDER** and explains the ideas for a future version:
  - A shared on-call schedule, escalation to the next person if nobody acknowledges an alert, and
    central billing with Pro features for each team member.
  - The explanation makes clear that these features are not available yet and offers no working controls.
- The Account pane.

## Versions and updates

- The app shows its version and build number from the same values used to build it.
- A local build (built on a developer's machine) shows its build number, build date and time (in the local time
  zone) and version in a small line: at the bottom of the macOS panel, and under the version in Settings on
  iPhone and iPad.
  - *Why:* so a developer can see at a glance whether they are running an up-to-date local build or the App
    Store version.
  - TestFlight and App Store builds don't show this line.
  - The build date is when the app's program file was last built.
- **What's New** works offline and lists the changelog newest first.
  - Release builds show published version sections only; development builds also show unreleased entries.
- Polly is distributed through TestFlight and the App Store on macOS, iPhone and iPad.
  - The app never checks for or installs updates itself; Apple delivers them.
    - *Why:* Mac App Store apps may not update themselves, and Apple then handles signing and delivery.
