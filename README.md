# Polly

A Nagios monitoring app for macOS (menu bar), iPhone and iPad, written in Swift/SwiftUI. It can also check
websites itself, without a monitoring system behind them.

For a TV, browser or tablet, the standalone read-only **Polly web dashboard** runs on macOS or Linux.
Build it locally with Docker Compose or Swift; see [installation and upgrades](DEVELOPERS.md#linux-container-installation).
It monitors Nagios only, with separate viewer authentication and no command or configuration actions.

## Layout

```
project.yml                 XcodeGen spec – source of truth for Polly.xcodeproj
App/Shared/                 SwiftUI app code shared by all platforms
App/macOS/                  Menu bar UI + sandbox entitlements (macOS only)
App/iOS/                    iPhone/iPad UI: Problems, Servers and Settings tabs (iOS only)
Packages/PollyKit/          Platform-independent logic + unit tests
  Models/                   NagiosServer, ServerURLParser (splits user:pass@ out of pasted URLs)
  Storage/                  polly.yaml reader/writer (Yams), ServerStore, keychain CredentialStore, WireLog
  Nagios/                   NagiosClient: statusjson.cgi (status), extinfo.cgi (links), cmd.cgi (commands)
  URLCheck/                 URLMonitor: checks a URL's DNS, HTTP answer and certificate from the device
  Monitoring/               MonitorBackend (what a monitoring system has to offer), MonitorModel (polling),
                            NotificationPolicy, ServerFormModel (add/edit-server form logic)
.mcp.json                   Enables XcodeBuildMCP for Claude Code in this project
mock/nagios-mock.mjs        Mock Nagios server for testing (see DEVELOPERS.md)
```

- Sources (Nagios servers and URLs) and settings are stored in one YAML file, `Application Support/Polly/polly.yaml`. On macOS
  that's `~/Library/Containers/nl.webhare.polly/Data/Library/Application Support/Polly/polly.yaml`.
  Passwords are kept in the keychain unless you turn that off, in which case they go into the YAML file.
  You can edit the file by hand while Polly isn't running.
- A server's status is read from `<base URL>/nagios/cgi-bin/statusjson.cgi`
  (`programstatus` for the connection test; `hostcount`, `servicecount`, `servicelist` and `hostlist` for status).
- Adding a server tests the connection first; if that fails you can still choose **Add Anyway**.
- Click a problem to see the check output and to open the check on the server, open its action or notes
  link, acknowledge it or schedule downtime.
- The macOS and iOS screens follow the Polly design. Parts of it that are drawn but do not work yet carry an
  orange PLACEHOLDER or PROTOTYPE tag (recheck, downtime presets, poll interval, TLS switch, the Alerts pane).
- **About Polly** (macOS) and **Settings** (iOS) show the version and bundled changelog. Updates come from
  TestFlight and the App Store; the app has no updater of its own.
- The bell next to a server turns local notifications for that server on or off (off by default).

## Contributing

Found a bug or have an idea? Anyone is welcome to [file an issue](../../issues). If you'd like to contribute
code, please read [CONTRIBUTING.md](CONTRIBUTING.md) first. See [CHANGELOG.md](CHANGELOG.md) for what changed
per version.

## Development

See [DEVELOPERS.md](DEVELOPERS.md) for building and running the app, the mock Nagios server and the tests.

## Continuous integration

`.github/workflows/build.yml` tests PollyKit and PollyWeb on Linux amd64 and arm64 runners, including
real Nagios HTTP integration and a build/start/restart test of the production container. A pinned
Playwright/Chromium installation checks the dashboard, keyboard access, layouts and recovery. The required
macOS job fails if either Linux architecture or the browser job fails. It also tests both Swift packages,
real HTTP/source recovery, the iOS Simulator build and a universal macOS Release build.
The separate iOS workflow still builds for devices without signing.

The macOS `Polly-<version>-<run>.dmg` artifact is for testing, not distribution. Apple apps are distributed
through TestFlight and the App Store. CI does not publish web images or deploy the dashboard.

Without signing secrets the app is **ad-hoc signed**. It runs, but macOS refuses to open it after downloading:
open it once via System Settings → Privacy & Security → **Open Anyway**, or run
`xattr -dr com.apple.quarantine /Applications/Polly.app`. Each build also counts as a new app for the keychain,
so expect keychain prompts after updating (or set `passwordStorage: file`).

With these repository secrets and variables the app and DMG are signed with a **Developer ID** and notarized,
so they open without warnings. WebHare's portal (`webhare_portal`, `data/github-projects.yaml`) maintains them
for `WebHare/polly`, the same way as for `WebHare/agent-radar`; set them by hand only on a fork.

| Name                         | Kind     | Contents                                                                   |
| ---------------------------- | -------- | -------------------------------------------------------------------------- |
| `MACOS_CERTIFICATE_P12`      | secret   | base64 of the exported "Developer ID Application" certificate + key (.p12) |
| `MACOS_CERTIFICATE_PASSWORD` | secret   | password of that .p12                                                      |
| `NOTARY_API_KEY`             | secret   | base64 of an App Store Connect API key (.p8) with the Developer role       |
| `NOTARY_API_KEY_ID`          | variable | that key's Key ID                                                          |
| `NOTARY_API_ISSUER_ID`       | variable | the Issuer ID shown above the App Store Connect API keys list              |

Only the team's Account Holder can create a Developer ID Application certificate.

## Design decisions

Why things are the way they are, so they can be revisited deliberately rather than by accident.

### Project structure

- **One multiplatform SwiftUI target** (`supportedDestinations: [iOS, macOS]`) instead of separate iOS
  and macOS apps. The design pieces (colors, status icons, mascot, buttons, command form) are shared; the
  screens differ per platform and live in `App/macOS/` and `App/iOS/`, filtered per destination in
  `project.yml`.
- **All logic in a local Swift package (`PollyKit`)**, the app targets contain only views. This keeps the
  logic testable with plain `swift test`, without simulators or an app host.
- **XcodeGen (`project.yml`) as the source of truth** for the Xcode project. Hand-maintaining
  `project.pbxproj` is error-prone and merge-hostile. The generated project is still committed so the repo
  opens in Xcode without installing XcodeGen first.
- **Deployment targets macOS 14 / iOS 17**, the minimum for the `@Observable` macro used by the models.
- **Swift 6 language mode** with strict concurrency; UI-facing models are `@MainActor`.

### Linux core

- **PollyKit's Nagios path also runs on Linux**: parsing, HTTP transport, polling, summaries, settings and
  file/in-memory credential storage are shared with the native apps.
- **Apple-only functionality stays native**: URL monitoring (DNS/HTTP/certificate checks), Keychain,
  default Application Support storage and the long tooltip duration formatter. `makeBackend` throws for
  a URL server on Linux; it never substitutes a healthy result or a different backend.
- **Explicit storage on Linux**: supply a `ServerStore` with a chosen file or in-memory settings and a
  credential store. There is no Linux `makeDefault()` that might open the native app's settings.
- **Linux uses Swift 6.4.2**, with the upstream fix for the
  [URLSession cancellation deadlock](https://github.com/swiftlang/swift-corelibs-foundation/issues/5412)
  reproduced on Swift 6.2. Native apps still build with Apple Swift 6.2. The transport implementation stays
  shared; redirects, credentials, cookies and cancellation are checked over real HTTP.
- Run the reproducible Docker test command in [DEVELOPERS.md](DEVELOPERS.md#linux-tests) for the proven
  platform matrix and real HTTP integration.

### Web service

- **`Packages/PollyWeb` runs independently** on macOS and Linux. It serves the Polly dashboard, `/api/status`
  and `/healthz`. It has no write or proxy routes.
- **The dashboard is plain HTML/CSS/JavaScript.** Local fonts, original animated SVG poses and status shapes
  come from [the archived design exports](doc/design/polly-web/README.md). No frontend framework, Node
  runtime or external assets are needed in production. Source strings are inserted as text, and native
  disclosure rows preserve open details and keyboard focus on refresh, including reordered rows. TV pages
  follow server order, rotate every 15 seconds and pause for interaction, open details or reduced motion.
  Five rows fit compact screens; eight fit 1080p/4K. Phones/tablets use a normal list.
- **The browser fails visibly and recovers automatically.** One request at a time, a ten-second timeout,
  five seconds between attempts, and immediate revalidation on resume. Source age advances with a
  monotonic clock; receiving the same measurement again cannot make it fresh. Old values remain clearly
  marked during connection failures. No snapshot is stored persistently on the display.
- **Vapor stays outside the native dependency graph.** PollyWeb pins Vapor 4.122.3 and its own lockfile.
  swift-log is constrained to 1.8.0 because newer releases use a compiler attribute unavailable in Apple
  Swift 6.2. Linux uses the Swift 6.4.2 toolchain established by the core tests.
- **One `MonitorModel` polls for every viewer.** API reads only project its current state into a whitelisted
  `WebSnapshot` on the same actor. Completed attempt times, last successes and per-source age expose partial
  coverage; pending or 150-second-old data cannot produce an all-quiet result. Native summary behavior stays
  unchanged. Shutdown cancels and awaits polling.
- **Configuration is separate and read-only.** `POLLY_CONFIG` must name an explicit file with Nagios sources
  and `passwordStorage: file`. The service creates an in-memory store, disables traffic logging and
  notifications, and never opens the native default store or Keychain.
- **Loopback is the default.** Other binds require independent viewer Basic authentication using a bcrypt
  hash file; a validating server wrapper checks Vapor's final CLI address before opening the socket. The
  authenticator is paired with a guard over HTML, API and health, with a bounded failed-login budget.
- **The Linux image contains the executable, public resources and OS runtime libraries.** It runs as a
  non-root user with CA certificates, without Swift or Node. Compose mounts config and the viewer hash
  read-only, publishes only on host loopback and restarts unless explicitly stopped. A separate mock
  override is for testing; normal Compose runs Polly alone. No registry image is published.
- See [DEVELOPERS.md](DEVELOPERS.md#web-service) for startup, password hashing, runtime limits and real HTTP tests.

### Backends

- **`MonitorBackend` is the only thing the rest of the app knows about a monitoring system**: test the
  connection, fetch the status, and optionally links and commands (`capabilities`). Nagios is the first
  implementation. `MonitorModel` and the views never mention CGI names, HTML or Nagios status values, so
  another system (Icinga, or a plain "is this URL up" check) is a new type plus a case in `BackendKind`.
- **Each server has a `type` in `polly.yaml`** (`nagios`, also the default when the key is missing). An
  unknown type is an error rather than silently treated as Nagios.
- **Two types: `nagios` and `url`.** On iOS **Add** is a menu that picks the type; on macOS the Type control
  in the add-server card does. The form adapts its placeholder and explanation to it.
- **Commands are prepared, then submitted.** `prepareCommand` only reads what the server needs (for
  Nagios: its form); nothing changes on the server until `submit`, and a submit is never retried.

### Talking to Nagios

- **Only `statusjson.cgi`** (`<url>/nagios/cgi-bin/statusjson.cgi`), as that is Nagios Core's JSON API and
  needs nothing installed on the server. The user enters the base URL; the `/nagios/...` path is appended
  by the app.
- **Cheap queries.** The connection test uses `programstatus`. Status uses `hostcount` and `servicecount`
  for the totals plus `servicelist` filtered to warning/critical/unknown and `hostlist` filtered to
  down/unreachable, both with `details=true`, so we only transfer problems, but do get `last_state_change` for
  the "how long" indicator.
- **HTTP Basic auth sent with every request** instead of waiting for a 401 challenge first, which saves a
  round trip per request. 401/403 are reported as "check username and password".
- **Poll every 60 seconds**, all servers in parallel. Disabled servers are skipped, and a result that
  arrives after a server was disabled or deleted is discarded.
- **Plain `http://` is allowed** (`NSAllowsArbitraryLoads`) because internal Nagios servers often have no
  TLS. Self-signed certificates are not supported yet.
- **Redirects are refused**, because following one would send the Basic credentials to wherever it points.
- **An answer without data is an error, not "no problems".** The same goes for an installation with no
  hosts and no services at all: that is what Nagios shows an account that isn't allowed to see anything.
- **Links come from `extinfo.cgi`**, not from the JSON API: the check page has the action and notes URLs
  with their Nagios macros already expanded. Only `http(s)` links without embedded credentials are opened.
- **Acknowledge and downtime go through `cmd.cgi`**, the same form the web UI uses, including its CSRF
  token and cookie. HTTP 200 is not treated as success: only Nagios' own confirmation text is. "Accepted"
  means Nagios queued the command, not that the status has changed yet. Downtime start and end are typed in
  the server's own notation and time zone (prefilled by the server), as the app can't know that time zone.
- **Verified against a real Nagios as far as reading goes.** Status, check details, the check page and both
  command forms were read from a real server. That server sends no CSRF token, uses ISO dates and locks the
  author name, and the mock was changed to offer those variants. Actually submitting an acknowledgement or
  a downtime has only been done against the mock so far.

### Checking URLs

- **One host with three services**, so a URL fits the same status rows, problem list and notifications as a
  Nagios server: `DNS` (the host name resolves), `HTTP` (a GET of the URL answers below 400) and, for
  `https`, `Certificate`. The host counts as down when DNS or HTTP fails.
- **Checked from the device, on every poll.** There is no history, so URL problems show no age.
- **A failed DNS lookup skips the other checks** (counted as pending), so one outage isn't three problems.
- **The URL is kept as entered** (path and query included); only credentials and the fragment are removed.
- **Redirects are not followed**; a redirect is an answer, so the site is up.
- **The certificate is checked on a new connection every time** (a fresh `URLSession` per check), because a
  reused connection skips the TLS handshake. It must be trusted by the system for the host name, and the
  leaf and intermediates must stay valid for 14 more days, otherwise it is a warning. Expiry dates are read
  from the DER data, as Apple only offers them through an API on macOS.
- **An untrusted certificate doesn't hide whether the server answers**: the HTTP check continues anyway,
  unless a username or password is configured, which is never sent to a server with an untrusted
  certificate.
- **Optional Basic auth** for pages behind a login.

### Notifications

- **Per server and off by default.** They are local notifications decided by the app; nothing changes in
  the Nagios notification configuration.
- **The first successful poll is the baseline.** After that, new problems, severity changes and recoveries
  are bundled into one notification per server; a newer one replaces the older one.
- **Acknowledged problems and problems in scheduled downtime stay quiet**, as someone already knows.
- **Only while the app is polling.** On iOS that means while it is in the foreground; there is no push.

### Debugging

- **`debugLog: true`** (or the switch in the Servers window) writes every request and response to
  `polly-debug.log` next to `polly.yaml`, one JSON object per line, so an exchange that went wrong on a
  real server can be replayed and the mock corrected afterwards. The `Authorization` header is replaced
  and passwords never reach the file. At 5 MB the file is moved to `polly-debug.log.1` and started anew.

### Adding servers

- **Paste-friendly URL field.** Pasting `https://user:pass@host/...` moves the (percent-decoded) username
  and password into their own fields and strips them from the URL. A scheme-less host gets `https://`.
  Anything from `/nagios` onwards, query and fragment are removed, so pasting a link to the Nagios web UI
  just works.
- **Test before saving, but allow an override.** A failed connection test shows the error with
  **Retry** and **Add Anyway**: the server may be temporarily down or only reachable from another network.

### Storage

- **One human-readable YAML file (`polly.yaml`)** for sources and settings. It started as SQLite, but a
  single commented file is easier to inspect, back up, diff and hand-edit, and the data is tiny.
- **Yams for reading, hand-written output for writing.** An encoder can't emit comments, a fixed key order
  or blank lines between sources. Strings are only quoted when YAML needs it (`"yes"`, `"a: b"`, leading
  digits, ...), and a round-trip test guards against quoting mistakes.
- **Lenient reading, strict values.** Every key is optional so a minimal hand-written file loads, but an
  invalid value (e.g. an unknown `passwordStorage`) is an error. If the file can't be read the app runs with
  an in-memory store instead of overwriting the file.
- **Read at startup, rewritten after every change** (atomically, mode `0600` because it may contain
  passwords). Hand edits are therefore only picked up when Polly isn't running.
- **File order is display order**; new servers are appended. Reorder by editing the file.
- **Passwords in the keychain by default**, keyed by the server's UUID, so they aren't lying around in plain
  text. A setting moves them into the YAML file instead: debug builds used to trigger keychain prompts on
  every rebuild, and turning the keychain off guarantees it is never touched again. Switching moves all
  existing passwords and reads everything first, so a keychain failure doesn't leave a half-migrated state.
- **Window state is not a setting.** The menu panel size stays in `UserDefaults`; the Dock icon preference
  moved into `polly.yaml`.

### macOS UI

- **Menu bar app** (`MenuBarExtra`, `LSUIElement`), no Dock icon by default. A Dock icon can be turned on in
  the Servers window; clicking it opens that window.
- **The menu bar icon is Polly's head plus a count.** Critical is a red pill with Polly on its back; the other
  states are monochrome templates, so the warning triangle of the design is not yellow there.
- **Panel sizes to its content** up to about a quarter of the screen height, then scrolls. It can also be
  resized by dragging; that size is remembered and a "Fit" button returns to automatic sizing.
- **Each problem shows its age** ("3m", "2h", "3d", largest unit only, refreshed every minute), with the
  exact duration and local start time on hover. The age is time since the service's last state change, so
  a warning escalating to critical restarts it.
- **Per-server on/off switch** to pause monitoring without deleting the server; paused servers don't count
  towards the menu bar status.
- **Problem details and actions open inside the panel** (it slides to the detail) instead of in a sheet or a
  separate window: the menu bar panel closes as soon as it loses focus. On iOS a problem opens on its own
  screen, and acknowledge and downtime open in a sheet.

### Signing and sandbox

- **App Sandbox with only `network.client`** on macOS.
- **WebHare bv signing by default**, with an optional ignored `Local.xcconfig` for stable local macOS signing in both Debug and Release; see [Signing](DEVELOPERS.md#signing). Ad-hoc signatures change on every build, which makes macOS treat each build as a new app and re-prompt for Keychain access.

### Tooling

- **Yams for YAML**; the keychain is a system library.
- **No in-app updater.** Polly is distributed through TestFlight and the Mac App Store, which handle
  updates. Sparkle was used briefly in 0.2.0 and removed before any release was published.
- **fastlane for TestFlight uploads**, pinned in the `Gemfile`, with automatic signing through an App Store
  Connect API key so nobody has to export certificates.
- **Mock Nagios server in plain Node.js** (no npm install) so the UI can be exercised with realistic,
  changing data, including outages (HTTP 503) and authentication failures, without a real Nagios.
- **XcodeBuildMCP** is configured in `.mcp.json` so Claude Code can build and run the app; SweetPad is
  suggested for VS Code users.

## License

Copyright © 2026 WebHare b.v. Licensed under the GNU General Public License version 2. See [LICENSE](LICENSE).
