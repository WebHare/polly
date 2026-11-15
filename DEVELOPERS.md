# Developing Polly

How to build and run Polly and the mock Nagios server it is tested against. For what Polly does and why it
is built the way it is, see [README.md](README.md).

## Requirements

- Xcode 16 or later. Polly targets macOS 14+ and iOS 17+.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Node.js 18 or later, for the mock Nagios server. It has no npm dependencies.
- For VS Code: we think you need the
  [SweetPad](https://marketplace.visualstudio.com/items?itemName=sweetpad.sweetpad) extension to build, run
  and debug the app from VS Code.

If `xcode-select -p` points to the Command Line Tools instead of Xcode, prefix the `xcodebuild` commands
below with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

### Signing

Builds are signed with the WebHare bv team (`DEVELOPMENT_TEAM: MF6WPNPK5H` in `project.yml`). To let Xcode
create the signing certificate and profiles, add an Apple ID that is a member of that team in Xcode →
Settings → Accounts. Simulator builds don't need this.

## The Xcode project

`project.yml` is the source of truth. Regenerate `Polly.xcodeproj` after you add or remove files, or after
editing `project.yml`:

```sh
xcodegen generate
```

The generated project is committed, so you only need XcodeGen when the file list changes.

## 1. Start the mock Nagios server

```sh
node mock/nagios-mock.mjs                # http://localhost:8080, login nagiosadmin / nagios
```

The mock imitates a Nagios server, with made-up hosts and services that slowly rotate through
OK/WARNING/CRITICAL/UNKNOWN and host DOWN/UNREACHABLE. Leave it running in its own terminal. On startup it
prints the URL to add to Polly.

Options:

| Option | Default | |
|---|---|---|
| `--port` | `8080` | Port to listen on |
| `--interval` | `15` | Seconds between automatic status changes |
| `--user`, `--password` | `nagiosadmin`, `nagios` | Basic auth login |
| `--no-auth` | | Accept requests without a login |
| `--no-rotate` | | Start with automatic status changes paused |

While it runs, press keys in its terminal to change what Polly sees:

| Key | Effect |
|---|---|
| `w` / `c` / `u` | Put a random OK service into WARNING / CRITICAL / UNKNOWN |
| `d` / `r` | Mark a random host DOWN / UNREACHABLE |
| `o` | Everything OK |
| `n` | Do one rotation step now |
| space | Pause or resume automatic rotation |
| `x` | Offline mode: answer every request with HTTP 503 |
| `a` | Turn authentication on or off |
| `s` | Show the current state |
| `h` | Help |
| `q` | Quit |

Keyboard controls only work when the mock runs in a terminal, not when it is started with `&`.

## 2. Run the app

### macOS

In Xcode: open `Polly.xcodeproj`, choose the **Polly** scheme with **My Mac** as destination, and press Run.
In VS Code, use SweetPad.

From the command line:

```sh
xcodebuild -project Polly.xcodeproj -scheme Polly -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Debug/Polly.app
```

Polly is a menu bar app with no Dock icon, so look for its icon in the menu bar rather than for a window.
Open **Servers** from there to add a server.

### iPhone and iPad simulator

In Xcode: choose the **Polly** scheme with an iPhone or iPad simulator as destination, and press Run.

From the command line (use any simulator from `xcrun simctl list devices available`):

```sh
xcodebuild -project Polly.xcodeproj -scheme Polly -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath .build/DerivedData build
xcrun simctl boot "iPhone 16"; open -a Simulator
xcrun simctl install "iPhone 16" .build/DerivedData/Build/Products/Debug-iphonesimulator/Polly.app
xcrun simctl launch "iPhone 16" nl.webhare.polly
```

The simulator shares the Mac's network, so `localhost` reaches the mock there too. Polly only polls while
it is in the foreground on iOS.

## 3. Add the mock to Polly

Add a server and paste this URL:

```
http://nagiosadmin:nagios@localhost:8080/
```

Polly moves the username and password into their own fields. Use the URL the mock prints if you changed
the port or login, or leave out `nagiosadmin:nagios@` when the mock runs with `--no-auth`.

Besides the status, the mock serves the check page (`extinfo.cgi`) with action and notes links, and the
acknowledge and downtime forms (`cmd.cgi`) with their CSRF token and cookie, so acknowledging a problem or
scheduling downtime really changes the mock's state.

## Tests

Unit tests:

```sh
swift test --package-path Packages/PollyKit
```

`MockIntegrationTests` runs the real `NagiosClient` against the mock. The suite is skipped unless
`POLLY_MOCK_URL` is set. Start the mock with rotation paused, so that statuses don't change during a test:

```sh
node mock/nagios-mock.mjs --no-rotate &
POLLY_MOCK_URL=http://localhost:8080 swift test --package-path Packages/PollyKit --filter MockIntegrationTests
```

The tests put the mock into a known state through endpoints that need no login:

| Endpoint | Effect |
|---|---|
| `GET /mock/reset` | All hosts up, all services OK, no acknowledgements or downtimes, default `cmd.cgi` behaviour |
| `GET /mock/set?host=H&service=S&status=ok\|warning\|critical\|unknown` | Set one service's status |
| `GET /mock/config?csrf=on\|off&dateFormat=us\|iso8601` | Make `cmd.cgi` leave out the CSRF token or use ISO dates, like monitor.webhare.net |
| `/redirect/<path>` | Answers with a 302 redirect to `/<path>` |

`URLMonitorNetworkTests` checks real websites, including badssl.com's broken certificates. It is skipped
unless `POLLY_NETWORK_TESTS` is set:

```sh
POLLY_NETWORK_TESTS=1 swift test --package-path Packages/PollyKit --filter URLMonitorNetworkTests
```

CI runs the unit tests and builds the macOS app ([.github/workflows/build.yml](.github/workflows/build.yml),
see "Continuous integration" in the README), and checks that the iOS app compiles
([.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)). It doesn't run the mock integration tests
or the network tests, so run those locally when you change the client.

### Changing the mock

The mock is developed together with the client. When a real Nagios turns out to behave differently, first
change the mock to match, watch the integration tests fail, and then fix the client. To find out what a real
server sends, turn on `debugLog` (see "Debugging" in the README) and compare its requests and responses with
the mock's.
