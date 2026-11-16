# Polly requirements

What Polly does and the rules it follows. See [AGENTS.md](../AGENTS.md) for how to maintain this file.

## General

- Polly monitors Nagios servers and websites from macOS (menu bar), iPhone and iPad.
  - Requires macOS 14 / iOS 17 or later.
  - Polly polls straight from the device; nothing goes through a Polly server.
- A user can monitor two types of source:
  - Why "source" and not "server": the hosts Polly reports on are servers too, so "server" was ambiguous.
  - **Nagios server**: status is read from the server's Nagios installation (Nagios 4.4 or newer).
  - **URL**: Polly checks a website itself, with no monitoring system behind it.
  - Everywhere a source is shown, its type ("Nagios" or "URL") is shown next to its name.
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
  - iOS: **Add** (a menu: Nagios Server… / URL…) on the Sources tab, or **Add source…** in the empty states; the
    form opens as a sheet titled "Add Nagios Server" or "Add URL".
  - The URL placeholder and the explanation adapt to the type:
    - Nagios: the `statusjson.cgi` URL that will be read.
    - URL: that the host resolves, that the URL answers and (https only) that the certificate is valid for at
      least two more weeks.
  - The URL comes first in the form, before **Name**.
    - Why: the name, username and password are derived from the URL, so filling it in first fills the rest.
  - Example URLs in the URL field are shown as plain placeholder text, not as links.
    - Why: a link-colored placeholder looks like a URL that is already filled in.
  - **Name** is optional; it defaults to the URL's host name.
  - Username and password are never required. For a URL they are only needed for a page behind HTTP Basic
    authentication.
  - On macOS the form says where the password will be stored (keychain or `polly.yaml`).
- The URL field is paste-friendly:
  - Pasting `https://user:pass@host/...` moves the (percent-decoded) username and password into their own
    fields and removes them from the URL.
  - A URL without a scheme gets `https://`.
  - The fragment is always removed.
  - Nagios: query and anything from `/nagios` onwards are removed, so a pasted link to the Nagios web UI just
    works. The user enters the base URL; Polly appends `/nagios/cgi-bin/statusjson.cgi`.
  - URL: the path and query are kept as entered.
- Adding a source tests the connection first.
  - **Test connection** can also be run on its own before adding; changing the URL or type resets the result.
  - A failed test shows the error with **Add anyway** (and **Retry** on iOS).
    - Why: the server may be temporarily down or only reachable from another network.
  - For a URL, the test only fails on a critical problem; a certificate that expires soon doesn't block adding
    it.
- The user can edit a source: its type, name, URL, username and password.
  - macOS: double-click the source or choose **Edit…** in its context menu; the form opens as
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
- The user can duplicate a source to add a similar one without typing everything again.
  - macOS: **Duplicate…** in the context menu. iOS: **Duplicate…** in the context menu, or swipe right.
  - Opens the add form prefilled with the source's type, URL, username, password and bell; the name gets
    " copy" appended (or stays empty when it was just the host). The copy is a new source, switched on.
- New sources are added at the end of the list. The list order is the order in `polly.yaml`; reordering is done
  by editing the file.
- The user can delete a source (context menu; swipe left on iOS).
- The user can refresh one source (context menu) or all sources (menu bar panel, pull to refresh on iOS).
- Each source has an on/off switch to pause monitoring without deleting it.
  - A paused source shows "Monitoring paused", is not polled and doesn't count towards the overall status.
- Each source has a bell to turn notifications on or off (see [Notifications](#notifications)).
- Each source shows a one-line state:
  - "170 hosts, 1 down · 714 services, 1 crit, 3 warn", or "48 hosts up · 216 services OK" when all is well.
    - Each problem count ("1 down", "1 crit", "3 warn", "2 unknown") has a small status icon in front of it
      and is written in its status color.
  - "Unreachable · <error>" in red when it can't be read; its URL while it is loading for the first time.
- The icon in front of a source only says whether Polly can reach it: a green check when it answers,
  a red error icon when it can't be reached, a pause icon when it is paused, a spinner while loading.
  - Problems on the hosts and services it monitors never change that icon; they show in the state line.
    *Why:* a red icon for one critical service made healthy monitors look unreachable.

## Overview

The overview is the macOS menu bar panel and the iOS Problems tab. Both show the same summary of all enabled
sources.

- Problems (warning, critical and unknown services) of all sources are grouped by severity: critical, then
  warning, then unknown; newest first within a group.
  - Each problem shows host, service, its age and markers for acknowledged (ACK) and scheduled downtime.
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
  - "Polly has nothing to watch yet" without sources.
- Which screen is shown:
  - **Problems** when there is a problem or a host is down.
    - A host can be down while none of its services is listed as a problem; that still counts.
  - **Unreachable** when a source can't be read: its error, "Polly keeps trying every 60 s", **Retry now** and
    **Edit source…**.
  - **Waiting** while nothing has answered yet: "Waiting for the first answer", or how to resume when all
    sources are paused.
    - Why: nothing checked is not the same as nothing wrong; it must never look like "all is well".
  - **All quiet** with the number of hosts and services that are fine and when Polly checks again.
  - **Empty** without sources, with **Add source…**.
- A source that can't be reached counts as unreachable in the mood, even when other sources are fine.

## macOS menu bar

- Polly is a menu bar app with no Dock icon by default.
  - A Dock icon can be turned on in Settings; clicking it opens the Settings window.
- The menu bar icon is Polly's head plus a count when there is something to read.
  - Critical: a red pill with Polly on its back and the number of criticals (or hosts down, whichever is
    larger).
  - Warning: a warning triangle and the number of warnings.
  - Unreachable: a faded Polly with the number of unknowns, or "?".
  - Otherwise just Polly. The non-critical icons adapt to a light or dark menu bar.
- The panel shows the overview, the list of sources with their state, and **Refresh**, **Settings…** and
  **Quit**.
  - The footer says when the last check was ("Checked 14 s ago"), or "Retrying in 46 s" when unreachable.
  - It sizes to its content up to about a quarter of the screen height, then scrolls.
  - The user can resize it by dragging; that size is remembered, and **Fit** returns to automatic sizing.
- Clicking a problem slides the panel to its detail (see [Problem detail](#problem-detail)).
  - "‹ Problems" (or Escape) goes back; "2 of 6" with up/down buttons (or the arrow keys) steps through the
    problems without going back.
  - Why in the panel, not a window: the menu bar panel closes as soon as it loses focus.
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

- Shows the severity, its retry state ("SOFT 2/3" / "HARD 3/3"), ACK and DOWNTIME tags, service, host and the
  source with its type.
- Shows the check output and long output (selectable).
- Shows the duration with its start time, how long ago the last check was, and when the next check is.
  - A value the server didn't send is shown as "Unknown".
- Shows the actions the source type supports (Nagios: all of them; URL: none).
  - **Acknowledge…** (disabled when already acknowledged) and **Schedule downtime…**.
  - **Open in Nagios**: the check's page in the Nagios web UI.
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
  - A result that arrives after the source was paused or deleted is discarded.
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

## Notifications

- Notifications are per source and off by default.
  - Turning them on asks the system for permission; if it's refused, the user is told to allow notifications in
    the system settings.
  - Notifications enabled by hand in `polly.yaml` also ask for permission before the first notification.
- They are local notifications decided by Polly; the Nagios notification configuration is not touched.
- The first successful poll is the baseline and never notifies.
- After that, new problems, severity changes and recoveries are bundled into one notification per source.
  - At most five lines; beyond that the last line says "and N more".
  - A newer notification for a source replaces the older one.
  - Notifications are also shown while Polly is in the foreground.
- Acknowledged problems and problems in scheduled downtime don't notify, including when they recover during the
  downtime.
- A failed poll keeps the last known problems, so an outage of the monitoring server itself doesn't report every
  problem as new once it is back.
- Caveat: notifications only happen while Polly is polling. On iOS that is only while it is in the foreground;
  there is no push.

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
- The menu bar panel size is window state, not a setting, and is not stored in `polly.yaml`.

## Not built yet

Drawn from the design and tagged as such, but without function:

- **Recheck now** in the problem detail.
- **Notified** in the problem detail (Polly keeps no record of what it notified about).
- Other monitoring systems in the Type control (Icinga 2, Checkmk, Zabbix).
- Poll interval and "Verify TLS certificate" in the add-source form; the interval is fixed at 60 seconds.
- The Alerts pane (PROTOTYPE, nothing is saved or applied): filters (hide acknowledged, soft states, downtime,
  services on down hosts), notification rules and quiet hours.
- The Team pane remains labeled **PLACEHOLDER** and explains the ideas for a future version:
  - A shared on-call schedule, escalation to the next person if nobody acknowledges an alert, and
    central billing with Pro features for each team member.
  - The explanation makes clear that these features are not available yet and offers no working controls.
- The Account pane.

## Versions and updates

- The app shows its version and build number from the same values used to build it.
- **What's New** works offline and lists the changelog newest first.
  - Release builds show published version sections only; development builds also show unreleased entries.
- Polly is distributed through TestFlight and the App Store on macOS, iPhone and iPad.
  - The app never checks for or installs updates itself; Apple delivers them.
    - *Why:* Mac App Store apps may not update themselves, and Apple then handles signing and delivery.
