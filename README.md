# Polly

A Nagios monitoring app for macOS (menu bar), iPhone and iPad, written in Swift/SwiftUI. It can also check
websites itself, without a monitoring system behind them.

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
                            NotificationPolicy, AddServerModel (add-server form logic)
.mcp.json                   Enables XcodeBuildMCP for Claude Code in this project
mock/nagios-mock.mjs        Mock Nagios server for testing (see below)
```

- Servers and settings are stored in one YAML file, `Application Support/Polly/polly.yaml`. On macOS
  that's `~/Library/Containers/nl.webhare.polly/Data/Library/Application Support/Polly/polly.yaml`.
  Passwords are kept in the keychain unless you turn that off, in which case they go into the YAML file.
  You can edit the file by hand while Polly isn't running.
- A server's status is read from `<base URL>/nagios/cgi-bin/statusjson.cgi`
  (`programstatus` for the connection test; `hostcount`, `servicecount` and `servicelist` for status).
- Adding a server tests the connection first; if that fails you can still choose **Add Anyway**.
- Click a problem to see the check output and to open the check on the server, open its action or notes
  link, acknowledge it or schedule downtime.
- The macOS and iOS screens follow the Polly design. Parts of it that are drawn but do not work yet carry an
  orange PLACEHOLDER or PROTOTYPE tag (recheck, downtime presets, poll interval, TLS switch, the Alerts pane).
- The bell next to a server turns local notifications for that server on or off (off by default).

## Requirements

- Xcode (16 or later), macOS 14+ / iOS 17+ deployment targets
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- For VS Code: we think you need to install the
  [SweetPad](https://marketplace.visualstudio.com/items?itemName=sweetpad.sweetpad) extension
  to build, run and debug the app from VS Code.

## Building

```sh
xcodegen generate                          # after adding/removing files or editing project.yml
open Polly.xcodeproj                       # or use SweetPad in VS Code

# command line (if xcode-select points to the Command Line Tools, prefix with
# DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer)
xcodebuild -project Polly.xcodeproj -scheme Polly -destination 'platform=macOS' build
(cd Packages/PollyKit && swift test)
```

Builds are signed with the WebHare bv team (`DEVELOPMENT_TEAM: MF6WPNPK5H` in `project.yml`). Add an Apple ID
that's a member of that team in Xcode → Settings → Accounts so Xcode can create the signing certificate and profiles.

## Continuous integration

`.github/workflows/build.yml` runs the PollyKit tests and builds a universal (arm64 + x86_64) Release build of
the macOS app on every push to `main` and every pull request. The result is attached to the run as a
`Polly-<version>-<run>.dmg` artifact.

Without signing secrets the app is **ad-hoc signed**. It runs, but macOS refuses to open it after downloading:
open it once via System Settings → Privacy & Security → **Open Anyway**, or run
`xattr -dr com.apple.quarantine /Applications/Polly.app`. Each build also counts as a new app for the keychain,
so expect keychain prompts after updating (or set `passwordStorage: file`).

With these repository secrets the app and DMG are signed with a **Developer ID** and notarized, so they open
without warnings:

| Secret                       | Contents                                                                |
| ---------------------------- | ----------------------------------------------------------------------- |
| `MACOS_CERTIFICATE_P12`      | base64 of the exported "Developer ID Application" certificate + key (.p12) |
| `MACOS_CERTIFICATE_PASSWORD` | password of that .p12                                                   |
| `NOTARY_API_KEY`             | base64 of an App Store Connect API key (.p8) with the Developer role    |
| `NOTARY_API_KEY_ID`          | that key's Key ID                                                       |
| `NOTARY_API_ISSUER_ID`       | the Issuer ID shown above the App Store Connect API keys list           |

Only the team's Account Holder can create a Developer ID Application certificate.

## Mock Nagios server

`mock/nagios-mock.mjs` is a dependency-free Node.js server that imitates `statusjson.cgi` with made-up
hosts and services that slowly rotate through OK/WARNING/CRITICAL/UNKNOWN and host DOWN/UNREACHABLE:

```sh
node mock/nagios-mock.mjs                # http://localhost:8080, login nagiosadmin / nagios
node mock/nagios-mock.mjs --port 9000 --interval 5 --no-auth
```

Add it in Polly as `http://nagiosadmin:nagios@localhost:8080/`. Press `h` in the terminal for keyboard
controls (force warning/critical/unknown, hosts down, all OK, pause rotation, simulate an outage, toggle auth).

Besides `statusjson.cgi` it serves `extinfo.cgi` (the check page with its action and notes links) and
`cmd.cgi` (the acknowledge and downtime forms, including the CSRF token and cookie), so commands really
change the mock's state. `/mock/reset` and `/mock/set?host=..&service=..&status=critical` put it in a known
state, `/mock/config?csrf=off&dateFormat=iso8601` switches to the variant without a CSRF token and with
ISO dates, and anything under `/redirect/` answers with a redirect.

The mock is developed together with the client. `MockIntegrationTests` runs the real `NagiosClient` against it:

```sh
node mock/nagios-mock.mjs --no-rotate &
POLLY_MOCK_URL=http://localhost:8080 swift test --package-path Packages/PollyKit --filter MockIntegrationTests
```

When a real Nagios turns out to behave differently, change the mock to match first, watch these tests
fail, and then fix the client.

`URLMonitorNetworkTests` checks real websites, including badssl.com's broken certificates. It is skipped
unless `POLLY_NETWORK_TESTS` is set:

```sh
POLLY_NETWORK_TESTS=1 swift test --package-path Packages/PollyKit --filter URLMonitorNetworkTests
```

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
  for the totals plus `servicelist` filtered to warning/critical/unknown with `details=true`, so we only
  transfer problem services, but do get `last_state_change` for the "how long" indicator.
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

- **One human-readable YAML file (`polly.yaml`)** for servers and settings. It started as SQLite, but a
  single commented file is easier to inspect, back up, diff and hand-edit, and the data is tiny.
- **Yams for reading, hand-written output for writing.** An encoder can't emit comments, a fixed key order
  or blank lines between servers. Strings are only quoted when YAML needs it (`"yes"`, `"a: b"`, leading
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
- **Signed with the WebHare bv team** rather than ad-hoc. Ad-hoc signatures change on every build, which
  makes macOS treat each build as a new app and re-prompt for keychain access.

### Tooling

- **No third-party runtime dependencies besides Yams**; the keychain is a system library.
- **Mock Nagios server in plain Node.js** (no npm install) so the UI can be exercised with realistic,
  changing data, including outages (HTTP 503) and authentication failures, without a real Nagios.
- **XcodeBuildMCP** is configured in `.mcp.json` so Claude Code can build and run the app; SweetPad is
  suggested for VS Code users.
