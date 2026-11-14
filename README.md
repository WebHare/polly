# Naggie

A Nagios monitoring app for macOS (menu bar), iPhone and iPad, written in Swift/SwiftUI.

## Layout

```
project.yml                 XcodeGen spec – source of truth for Naggie.xcodeproj
App/Shared/                 SwiftUI app code shared by all platforms
App/macOS/                  Menu bar UI + sandbox entitlements (macOS only)
Packages/NaggieKit/         Platform-independent logic + unit tests
  Models/                   NagiosServer, ServerURLParser (splits user:pass@ out of pasted URLs)
  Storage/                  naggie.yaml reader/writer (Yams), ServerStore, keychain CredentialStore
  Nagios/                   NagiosClient for /nagios/cgi-bin/statusjson.cgi
  Monitoring/               MonitorModel (polling), AddServerModel (add-server form logic)
.mcp.json                   Enables XcodeBuildMCP for Claude Code in this project
mock/nagios-mock.mjs        Mock Nagios server for testing (see below)
```

- Servers and settings are stored in one YAML file, `Application Support/Naggie/naggie.yaml`. On macOS
  that's `~/Library/Containers/nl.webhare.naggie/Data/Library/Application Support/Naggie/naggie.yaml`.
  Passwords are kept in the keychain unless you turn that off, in which case they go into the YAML file.
  You can edit the file by hand while Naggie isn't running.
- A server's status is read from `<base URL>/nagios/cgi-bin/statusjson.cgi`
  (`programstatus` for the connection test; `hostcount`, `servicecount` and `servicelist` for status).
- Adding a server tests the connection first; if that fails you can still choose **Add Anyway**.

## Requirements

- Xcode (16 or later), macOS 14+ / iOS 17+ deployment targets
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- For VS Code: we think you need to install the
  [SweetPad](https://marketplace.visualstudio.com/items?itemName=sweetpad.sweetpad) extension
  to build, run and debug the app from VS Code.

## Building

```sh
xcodegen generate                          # after adding/removing files or editing project.yml
open Naggie.xcodeproj                      # or use SweetPad in VS Code

# command line (if xcode-select points to the Command Line Tools, prefix with
# DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer)
xcodebuild -project Naggie.xcodeproj -scheme Naggie -destination 'platform=macOS' build
(cd Packages/NaggieKit && swift test)
```

Builds are signed with the WebHare bv team (`DEVELOPMENT_TEAM: MF6WPNPK5H` in `project.yml`). Add an Apple ID
that's a member of that team in Xcode → Settings → Accounts so Xcode can create the signing certificate and profiles.

## Mock Nagios server

`mock/nagios-mock.mjs` is a dependency-free Node.js server that imitates `statusjson.cgi` with made-up
hosts and services that slowly rotate through OK/WARNING/CRITICAL/UNKNOWN and host DOWN/UNREACHABLE:

```sh
node mock/nagios-mock.mjs                # http://localhost:8080, login nagiosadmin / nagios
node mock/nagios-mock.mjs --port 9000 --interval 5 --no-auth
```

Add it in Naggie as `http://nagiosadmin:nagios@localhost:8080/`. Press `h` in the terminal for keyboard
controls (force warning/critical/unknown, hosts down, all OK, pause rotation, simulate an outage, toggle auth).

## Design decisions

Why things are the way they are, so they can be revisited deliberately rather than by accident.

### Project structure

- **One multiplatform SwiftUI target** (`supportedDestinations: [iOS, macOS]`) instead of separate iOS
  and macOS apps. Most UI (server list, add-server form, status rows) is shared; macOS-only code lives in
  `App/macOS/` and is filtered per destination in `project.yml`.
- **All logic in a local Swift package (`NaggieKit`)**, the app targets contain only views. This keeps the
  logic testable with plain `swift test`, without simulators or an app host.
- **XcodeGen (`project.yml`) as the source of truth** for the Xcode project. Hand-maintaining
  `project.pbxproj` is error-prone and merge-hostile. The generated project is still committed so the repo
  opens in Xcode without installing XcodeGen first.
- **Deployment targets macOS 14 / iOS 17**, the minimum for the `@Observable` macro used by the models.
- **Swift 6 language mode** with strict concurrency; UI-facing models are `@MainActor`.

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

### Adding servers

- **Paste-friendly URL field.** Pasting `https://user:pass@host/...` moves the (percent-decoded) username
  and password into their own fields and strips them from the URL. A scheme-less host gets `https://`.
  Anything from `/nagios` onwards, query and fragment are removed, so pasting a link to the Nagios web UI
  just works.
- **Test before saving, but allow an override.** A failed connection test shows the error with
  **Retry** and **Add Anyway**: the server may be temporarily down or only reachable from another network.

### Storage

- **One human-readable YAML file (`naggie.yaml`)** for servers and settings. It started as SQLite, but a
  single commented file is easier to inspect, back up, diff and hand-edit, and the data is tiny.
- **Yams for reading, hand-written output for writing.** An encoder can't emit comments, a fixed key order
  or blank lines between servers. Strings are only quoted when YAML needs it (`"yes"`, `"a: b"`, leading
  digits, ...), and a round-trip test guards against quoting mistakes.
- **Lenient reading, strict values.** Every key is optional so a minimal hand-written file loads, but an
  invalid value (e.g. an unknown `passwordStorage`) is an error. If the file can't be read the app runs with
  an in-memory store instead of overwriting the file.
- **Read at startup, rewritten after every change** (atomically, mode `0600` because it may contain
  passwords). Hand edits are therefore only picked up when Naggie isn't running.
- **File order is display order**; new servers are appended. Reorder by editing the file.
- **Passwords in the keychain by default**, keyed by the server's UUID, so they aren't lying around in plain
  text. A setting moves them into the YAML file instead: debug builds used to trigger keychain prompts on
  every rebuild, and turning the keychain off guarantees it is never touched again. Switching moves all
  existing passwords and reads everything first, so a keychain failure doesn't leave a half-migrated state.
- **Window state is not a setting.** The menu panel size stays in `UserDefaults`; the Dock icon preference
  moved into `naggie.yaml`.
- **One-time import** of the old `naggie.sqlite` (renamed to `*.imported` afterwards) in
  `LegacySQLiteImport.swift`. Safe to delete once no old installs remain.

### macOS UI

- **Menu bar app** (`MenuBarExtra`, `LSUIElement`), no Dock icon by default. A Dock icon can be turned on in
  the Servers window; clicking it opens that window.
- **Severity shown by symbol shape plus a problem count**, because menu bar icons are rendered as
  monochrome templates, so colour can't be relied on.
- **Panel sizes to its content** up to about a quarter of the screen height, then scrolls. It can also be
  resized by dragging; that size is remembered and a "Fit" button returns to automatic sizing.
- **Each problem shows its age** ("3m", "2h", "3d", largest unit only, refreshed every minute), with the
  exact duration and local start time on hover. The age is time since the service's last state change, so
  a warning escalating to critical restarts it.
- **Per-server on/off switch** to pause monitoring without deleting the server; paused servers don't count
  towards the menu bar status.

### Signing and sandbox

- **App Sandbox with only `network.client`** on macOS.
- **Signed with the WebHare bv team** rather than ad-hoc. Ad-hoc signatures change on every build, which
  makes macOS treat each build as a new app and re-prompt for keychain access.

### Tooling

- **No third-party runtime dependencies besides Yams**; SQLite (only for the legacy import) and the
  keychain are system libraries.
- **Mock Nagios server in plain Node.js** (no npm install) so the UI can be exercised with realistic,
  changing data, including outages (HTTP 503) and authentication failures, without a real Nagios.
- **XcodeBuildMCP** is configured in `.mcp.json` so Claude Code can build and run the app; SweetPad is
  suggested for VS Code users.
