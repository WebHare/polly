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
acknowledge and downtime forms (`cmd.cgi`, for a service, a host and all services of a host) with their CSRF token
and cookie. Commands change the mock's state the way they change Nagios: a normal acknowledgement ends on the next
state change and a sticky one on recovery, and downtimes count in `scheduled_downtime_depth` while they are in
effect. Press `s` to see the acknowledgements and downtimes. What the mock leaves out is listed under "Where the
mock differs" in [doc/nagios-protocol.md](doc/nagios-protocol.md).

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
| `GET /mock/sethost?host=H&status=up\|down\|unreachable` | Set one host's status |
| `GET /mock/config?csrf=on\|off&dateFormat=us\|euro\|iso8601\|strict-iso8601` | `csrf=off` behaves like Nagios 4.5.11 and older (no CSRF token, as on monitor.webhare.net); `dateFormat` is Nagios' `date_format` (monitor.webhare.net uses `iso8601`) |
| `/redirect/<path>` | Answers with a 302 redirect to `/<path>` |

`URLMonitorNetworkTests` checks real websites, including badssl.com's broken certificates. It is skipped
unless `POLLY_NETWORK_TESTS` is set:

```sh
POLLY_NETWORK_TESTS=1 swift test --package-path Packages/PollyKit --filter URLMonitorNetworkTests
```

CI runs the unit tests and builds the macOS app ([.github/workflows/build.yml](.github/workflows/build.yml),
see "Continuous integration" in the README), and checks that the iOS app compiles
([.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)). Linux amd64 CI runs the full portable
suite and real HTTP mock integration with `scripts/test-linux.py`. Run the native mock integration and
external network tests locally when you change the client; those are not enabled in macOS CI.

### Changing the mock

The mock is developed together with the client. When a real Nagios turns out to behave differently, first
change the mock to match, watch the integration tests fail, and then fix the client. To find out what a real
server sends, turn on `debugLog` (see "Debugging" in the README) and compare its requests and responses with
the mock's. [doc/nagios-protocol.md](doc/nagios-protocol.md) describes what Polly sends and expects; update it
too.

### Linux tests

With Docker and Python 3 installed, run this from any directory (replace the checkout path):

```sh
python3 /absolute/path/to/polly/scripts/test-linux.py
```

The runner uses `swift:6.4.2-noble` and `node:22.14.0-bookworm-slim`, starts its own mock on an isolated
container network, waits for readiness, and runs the entire PollyKit suite with `POLLY_MOCK_URL` set. It
fails if the real HTTP integration suite did not pass, even if Swift exits successfully. No host port is
published. Its containers and network are removed in `finally`; on macOS it starts OrbStack only if stopped
and stops it again afterwards. Build artifacts remain in `.build/linux`.

Verified on Linux arm64 with Swift 6.4.2: 100 tests, none skipped, including all 12 real HTTP mock tests.
Swift 6.2.4 hit the upstream [concurrent cancellation deadlock](https://github.com/swiftlang/swift-corelibs-foundation/issues/5412);
6.4.2 includes the fix. The Apple builds remain on Swift 6.2. Linux's per-task redirect delegate is also
ignored, so Polly uses a short-lived session delegate there, retaining the supplied configuration and
cookie storage. This costs connection reuse; revisit it if polling becomes frequent.

Nagios parsing, credentials in requests, redirects, refused connections, commands, settings, polling,
summaries and certificate-date parsing are tested on both platforms. The concurrency stress test uses
real HTTP: Linux's custom URLProtocol implementation cannot reliably simulate concurrent delayed
callbacks or redirect callbacks.

Only these 14 tests require Apple APIs and are absent on Linux:

- `CertificateTests.untrustedCertificateIsInvalid`
- `URLKindTests.statusCountsOneHostWithAServicePerCheck` and `httpStatusCodes`
- `TransportTests.urlMonitorReportsAHealthySite`, `urlMonitorReportsServerErrorsAndSendsCredentials`,
  `urlMonitorDoesNotFollowRedirects` and `urlMonitorSkipsTheRestWhenDNSFails`
- `DNSResolverTests.resolvesLiteralAddressesWithoutANetwork` and `failsForAnInvalidName`
- All four `URLMonitorNetworkTests`: `healthySite`, `readsTheExpiryOfARealChain`,
  `brokenCertificatesStillShowWhetherTheServerAnswers` and `unresolvableHost`
- `ServerStoreTests.realKeychainRoundTrip`

Linux adds `BackendPlatformTests.unsupportedURLBackendFailsThroughEveryCaller`, which verifies the
explicit unsupported error in the factory, monitor and server form. Apple-only code also includes
Keychain storage, `ServerStore.makeDefault()` and the long localized duration formatter; Linux callers
must provide their own store configuration and use the portable compact duration format.

Native verification used macOS arm64, Swift 6.2 / Xcode 26.0.1: 109 tests executed with mock integration and
Keychain enabled, plus the four external URL checks separately. Both the universal macOS Release build
and iOS Simulator Release build pass. CI also verifies all 100 portable tests on Linux amd64 with Swift
6.4.2, including real HTTP mock integration. Physical iOS devices have not been verified.
The opt-in Keychain test uses a unique temporary service and deletes its own credentials:

```sh
POLLY_KEYCHAIN_TESTS=1 swift test --package-path /absolute/path/to/polly/Packages/PollyKit --filter realKeychainRoundTrip
```

## Web service

`Packages/PollyWeb` is a separate executable package. It uses Vapor 4.122.3 and its committed lockfile;
native apps still depend only on PollyKit. Build with Apple Swift 6.2 or Linux Swift 6.4.2. The start page is
intentionally small at this stage; the status API is ready for the dashboard.

Copy [examples/polly-web.yaml](examples/polly-web.yaml) to a private location outside the checkout. Set its
Nagios URLs and credentials, use file permissions `600`, and leave `passwordStorage: file`. The service
reads the file at startup without rewriting it. Even paused sources must use `type: nagios`; URL monitoring
and Keychain are unavailable to the service. Native traffic logging and notification settings are ignored.

Start on loopback from any directory, replacing the absolute paths:

```sh
POLLY_CONFIG=/absolute/path/to/polly.yaml swift run --package-path /absolute/path/to/polly/Packages/PollyWeb polly-web serve --hostname 127.0.0.1 --port 8088
```

Open `http://127.0.0.1:8088/`. `/api/status` returns display-only JSON; all timestamps are ISO 8601. It
distinguishes empty, paused, waiting, partial, unreachable, problems and OK. Per-server age increases
without changing the last source measurement. Data becomes stale at 150 seconds; pending checks and
incomplete coverage cannot produce OK. `/healthz` returns only a process/poller status; an upstream outage
does not fail liveness, but a poll loop without a completed round for 180 seconds does. Ctrl-C or SIGTERM
stops the listener and awaits cancellation of the poll loop.

### Viewer authentication

Create a bcrypt hash through stdin, with no password in shell history or process arguments. Build first,
then use Python's hidden terminal prompt (replace both paths). `pipefail` prevents a failed prompt or hash
command from being mistaken for a valid secret file:

```sh
swift build --package-path /absolute/path/to/polly/Packages/PollyWeb
set -o pipefail
umask 077
python3 -c 'import getpass; print(getpass.getpass("Viewer password: "))' | /absolute/path/to/polly/Packages/PollyWeb/.build/debug/polly-web hash-password > /absolute/path/to/viewer.hash
```

Passwords must contain 12 through 72 UTF-8 bytes without newlines. The command produces cost-12 bcrypt;
the service accepts costs 10 through 14. Extra command arguments and oversized stdin are rejected without
echoing the input. Set both authentication variables even for local testing:

```sh
POLLY_CONFIG=/absolute/path/to/polly.yaml POLLY_VIEWER_USERNAME=viewer POLLY_VIEWER_PASSWORD_HASH_FILE=/absolute/path/to/viewer.hash /absolute/path/to/polly/Packages/PollyWeb/.build/debug/polly-web serve --hostname 127.0.0.1 --port 8088
```

The browser asks for the viewer credentials, which are separate from the Nagios credentials. The same guard
protects HTML, API and health. Network binds (including `--bind` and `-H`) are refused without authentication.
For a network deployment, terminate HTTPS at a reverse proxy and keep Polly's internal HTTP port private;
the deployment/container examples follow in the distribution phase. Do not place passwords in URLs.

The single viewer account has a global budget of ten failures/in-flight attempts per 60 seconds and eight
concurrent password checks, avoiding unbounded tracking of spoofable client IPs. A burst can return 429
with `Retry-After: 60`. This also applies to health clients using the viewer credentials.

### Service tests

```sh
swift test --package-path /absolute/path/to/polly/Packages/PollyWeb
python3 /absolute/path/to/polly/scripts/test-web.py
python3 /absolute/path/to/polly/scripts/test-linux.py
```

`test-web.py` builds the server, starts two mocks on free loopback ports and checks real authenticated
requests, source aggregation, private paths, refused writes, final CLI bind validation and graceful shutdown.
It also checks password-input rejection, sanitized YAML errors and an unreachable source alongside a critical
source while process health stays OK.
The mock's `/mock/requests` endpoint proves that additional viewers do not cause additional Nagios requests.
The fixtures are read-only files; their contents are checked after running. Every process is stopped in
`finally`. Linux runs the same check inside the Swift container against two isolated Node containers,
installs Python only in that disposable test container and uses the committed dependency versions.
No production monitor is used.

The service stage was verified on macOS arm64 (Apple Swift 6.2) and Linux arm64 (Swift 6.4.2): 12 web
contract tests and the real HTTP/CLI checks on each. The shared core passed 115 native tests with mock and
Keychain enabled (four external URL checks skipped), and 106 Linux tests with mock integration. Universal
macOS Release and iOS Simulator Release builds also passed. The new service has not yet run in amd64 CI;
the earlier core-only amd64 result above remains the proven coverage for that platform.

The local CI workflow now runs PollyWeb tests on macOS and Linux plus the real HTTP tests on Linux. It will
be published with the single PR after the remaining local phases. The designed dashboard, physical-device
testing and production deployment are outside this stage.

## Versions, changelog and distribution

`project.yml` owns `MARKETING_VERSION` (currently 0.2.0) and `CURRENT_PROJECT_VERSION` (2).
Both platforms read those values from the built Info.plist. Bump both before each release, move the
`CHANGELOG.md` entries from `[Unreleased]` into a dated section for that version, then regenerate and commit
the Xcode project. Release builds hide unreleased notes; Debug builds include them.

Polly is distributed through TestFlight and the App Store on both macOS and iOS; Apple handles updates and the
app has no updater of its own. The macOS app therefore needs no sandbox exceptions beyond `network.client`.
The DMG that the **Build** workflow attaches to each run is for testing only. Do not publish DMGs, a GitHub
release or an update feed.

The 0.2.0 build briefly carried a Sparkle updater; it was removed before any release was published. Its EdDSA
key backup stays in 1Password but is not used; do not configure it as a GitHub secret.

Validate locally before a PR:

```sh
swift test --package-path Packages/PollyKit
python3 -m unittest discover -s scripts -p 'test_*.py'
xcodebuild -project Polly.xcodeproj -scheme Polly -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build
xcodebuild -project Polly.xcodeproj -scheme Polly -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData-iOS CODE_SIGNING_ALLOWED=NO build
```
