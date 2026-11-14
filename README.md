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
