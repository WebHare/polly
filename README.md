# Polly

Polly keeps an eye on your monitoring from the macOS menu bar, your iPhone and your iPad. It reads the status of
your Nagios servers, can check websites itself, and shows any list of things that need attention (tickets, merge
requests) that a server publishes as a [Polly feed](doc/feed-format.md). Problems of all
sources are listed together, worst first, and Polly's mood in the menu bar tells you at a glance whether
something needs attention.

Polly polls straight from your device every 60 seconds; nothing goes through a Polly server. It is available
through TestFlight and the App Store, which also deliver its updates.

## What Polly does

- One list of problems from all your sources, grouped by severity, each with its age. A host that is down is one
  problem, not one per service on it.
- Click a problem for the check output, to open the check on the server or its action and notes links, to
  acknowledge it or to schedule downtime (Nagios).
- Click a source in the menu bar panel to see when Polly last heard from it, to pause it for a while, or to turn
  the Nagios server's own notifications on or off for everyone.
- Local notifications per source when problems appear, change or recover. Off by default: turn them on with
  the bell next to the source.
- **About Polly** (macOS) and **Settings** (iOS) show the version and what's new.
- Parts of the design that are drawn but don't work yet carry an orange PLACEHOLDER or PROTOTYPE tag, such as
  recheck, the poll interval and most of the Alerts pane.

For a TV, browser or tablet there is also the read-only [Polly web dashboard](#web-dashboard).

## Sources

A source is something Polly watches. Add one with **Add** in the settings (macOS) or on the Sources tab (iOS),
and pick its type. Polly tests the connection before adding it; when that fails you can still choose
**Add anyway**, for a server that is only reachable from another network.

For every source:

- **Name** is optional; it defaults to the host name of the URL.
- **Sign in with** a username and password (HTTP Basic), or a **custom header** with a secret value, such as
  `X-API-Key` or `Authorization: Bearer <token>`. Both are optional. Pasting a URL with
  `https://user:password@host/` fills in the username and password for you.
- The **switch** in the settings disables a source without deleting it: Polly leaves it out completely.
- **Pausing** keeps a source in the list but stops checking it, for example during maintenance. The menu bar
  icon shows how many sources are paused, so you don't forget them.
- The **bell** turns notifications for that source on or off.

### Nagios server

Polly reads the status from Nagios Core's JSON interface, so nothing needs to be installed on the server.

- **Needs:** Nagios Core 4.4 or newer with its web interface (CGIs), and an account that can log in to it.
- **URL:** the address of the Nagios web interface, such as `https://monitor.example.com`. You can paste any
  link to the Nagios web UI; Polly keeps the base and reads
  `https://monitor.example.com/nagios/cgi-bin/statusjson.cgi`.
- **What you see:** hosts that are down or unreachable, and services in warning, critical or unknown state,
  with acknowledgements and scheduled downtime. The source line sums up the totals: "170 hosts, 1 down · 714
  services, 1 crit, 3 warn".
- **Acknowledge and schedule downtime** from the problem detail. Polly uses the same forms as the Nagios web
  interface, so the account needs permission for those commands. A command counts as done only when Nagios
  confirms it.
- **Nagios notifications for everyone** (in the source's detail) turns the server's own notifications on or
  off for all its contacts. The account needs `authorized_for_system_commands` in `cgi.cfg`.
- **Good to know:**
  - Plain `http://` works, as internal Nagios servers often have no TLS. Self-signed certificates don't work
    yet.
  - Redirects are not followed, because the password would go along. Enter the address the server redirects
    to instead.
  - An account that may not see any host or service gets an error rather than "all is well".

### URL

Polly checks a website itself, from your device. Use it for sites that no monitoring system watches.

- **URL:** the page to check, kept exactly as you enter it, including the path and query.
- **What Polly checks**, shown as one host with up to three services:
  - **DNS:** the host name resolves.
  - **HTTP:** the page answers with a status below 400 within 15 seconds. A redirect counts as an answer.
  - **Certificate** (https only): it is trusted for the host name, and it and its intermediates stay valid for
    at least 14 more days. Otherwise it's a warning.
- The host counts as down when DNS or HTTP fails. When DNS fails, the other checks are skipped, so one outage
  isn't reported three times.
- **Username and password** are only needed for a page behind HTTP Basic authentication. They are never sent
  to a server whose certificate isn't trusted.
- URL problems show no age: Polly keeps no history of them.
- URL checks are available in the macOS, iPhone and iPad apps, not in the web dashboard.

### Feed

A feed is a JSON document in Polly's own format that a server publishes: SLA tickets, open merge requests or
anything else that needs attention. Polly shows each item as a problem, next to those of your Nagios servers and
URLs.

- **URL:** the address of the feed, kept exactly as you enter it, including the path and query. Use a separate
  URL for each list (such as `?list=mine`), so each gets its own switch and bell in Polly.
- **Sign in** usually with a custom header, such as `X-API-Key` or `Authorization: Bearer <token>`.
- **What you see:** each item with its group (where Nagios shows the host), title, severity and age, and in the
  detail its deadline ("in 6d", "2h overdue"), summary, details, extra fields and a link to its page. The
  source line counts the items: "16 tickets, 1 crit, 1 warn".
- The server decides what is wrong and how bad it is; Polly shows the items and notifies when they change.
  Feeds are read-only: Polly can't acknowledge or snooze items.
- Redirects are not followed. A feed that breaks the format is refused as a whole, with the reason.
- Building a feed? See [doc/feed-format.md](doc/feed-format.md).

## "Add to Polly" links

Web applications can offer an **Add to Polly** button that opens Polly's add form, filled in. Polly never adds a
source from a link by itself, and a link never contains a password or token. To build such a button, see
[doc/add-to-polly.md](doc/add-to-polly.md).

## Settings file

Polly keeps its sources and settings in one file, `polly.yaml`. On macOS that is
`~/Library/Containers/nl.webhare.polly/Data/Library/Application Support/Polly/polly.yaml`. You can edit it
by hand while Polly isn't running, for example to reorder the sources:

```yaml
passwordStorage: keychain
sources:
  - name: Production
    type: nagios
    url: https://monitor.example.com
    username: alice
    enabled: true
    notifications: true

  - name: Website
    type: url
    url: https://www.example.com/
    username: ""
    enabled: true
    notifications: false
```

Passwords are kept in the keychain. Turn off **Store passwords in Keychain** to store them unencrypted in
`polly.yaml` instead.

## Web dashboard

The Polly web dashboard shows the same overview in a browser, for a TV on the wall or a tablet. It runs on
macOS or Linux, monitors Nagios servers only, is read-only (no acknowledgements, downtime or settings), and asks
viewers to log in when it is reachable from the network. See [installation and upgrades](DEVELOPERS.md#linux-container-installation).

## Contributing

Found a bug or have an idea? Anyone is welcome to [file an issue](../../issues). If you'd like to contribute
code, please read [CONTRIBUTING.md](CONTRIBUTING.md) first. See [CHANGELOG.md](CHANGELOG.md) for what changed
per version.

## Development

- [DEVELOPERS.md](DEVELOPERS.md): building and running the app, the mock Nagios server, the tests, continuous
  integration and releases.
- [doc/architecture.md](doc/architecture.md): how Polly is put together and why.
- [doc/requirements.md](doc/requirements.md): everything Polly must do.

## License

Copyright © 2026 WebHare b.v. Licensed under the GNU General Public License version 2. See [LICENSE](LICENSE).
