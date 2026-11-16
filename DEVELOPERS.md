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
native apps still depend only on PollyKit. Build with Apple Swift 6.2 or Linux Swift 6.4.2. The bundled
HTML/CSS/JavaScript dashboard uses the same-origin status API. Its fonts and artwork require no internet
connection. The browser uses one request at a time, a ten-second timeout and a five-second retry interval.
Hidden tabs stop polling and revalidate immediately on return. Source age advances monotonically between
answers and across repeated measurements; the display clock does not need to match the server clock.

TV pages contain eight rows (five at viewport heights up to 900px), preserve server order, and rotate every
15 seconds. Pointer/keyboard interaction pauses rotation until Resume. Open details, motion off, system
reduced motion and hidden tabs pause it too; Previous/Next remain available. Tablet/phone widths below
1100px show the full list. Use native browser fullscreen/kiosk controls on the chosen display device.

Copy [examples/polly-web.yaml](examples/polly-web.yaml) to a private location outside the checkout. Set its
Nagios URLs and credentials, use file permissions `600`, and leave `passwordStorage: file`. The service
reads the file at startup without rewriting it. Use `sources:` for the source list; the legacy `servers:`
key is accepted without rewriting, but do not combine both keys. Even paused sources must use `type: nagios`; URL monitoring
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
use the container and reverse-proxy examples below. Do not place passwords in URLs.

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

The final tested architecture/browser matrix is recorded under [Container verification](#container-verification).
The earlier core-only results above are historical. CI runs the service and image on native Linux amd64
and arm64 runners; it also guards the native macOS and iOS Simulator builds. Physical-device testing and
production deployment are separate from these software checks.

## Linux container installation

Requirements: Docker Engine with Compose v2 or later, Git, and an ordinary non-root operator account
that can run Docker. The runtime uses Swift 6.4.2 on Ubuntu 24.04. The Swift standard library is statically
linked; the compiler is absent from the final image, and Node is only a test dependency.
Build on the architecture you intend to run. Cross-compiling alone is not runtime verification.

Clone the source and build a commit-tagged local image (substitute your checkout path):

```sh
git clone https://github.com/unilynx/maggie.git /absolute/path/to/polly
```

```sh
export POLLY_REVISION=$(git -C /absolute/path/to/polly rev-parse HEAD)
export POLLY_IMAGE=polly-web:$POLLY_REVISION
docker build --build-arg REVISION="$POLLY_REVISION" --tag "$POLLY_IMAGE" /absolute/path/to/polly
```

The image label records the source revision. Build from a clean checkout; a revision label cannot describe
uncommitted changes. Base images and Swift dependencies are pinned; Ubuntu security packages are resolved
at build time, so record the resulting image ID too. No registry or release is needed.

Keep configuration and the viewer hash outside the checkout. Create a private directory, copy
[the example](examples/polly-web.yaml), and edit the Nagios URL/account there. These are the upstream
credentials, not the viewer account. Both files must be readable by the container UID. With an ordinary
non-root operator, retain ownership and use that UID/GID as below; do not make the files world-readable.
On a root-operated server, provision ownership for UID/GID 10001 instead.

```sh
umask 077
mkdir -p /absolute/private/polly
cp /absolute/path/to/polly/examples/polly-web.yaml /absolute/private/polly/polly.yaml
chmod 600 /absolute/private/polly/polly.yaml
```

Generate a separate viewer password hash without placing the password in argv or history. Python runs
on the operator's machine; it is not needed in the service image. Keep the same `POLLY_IMAGE` value from
the build, or use the explicit image tag in a new shell:

```sh
set -o pipefail
umask 077
python3 -c 'import getpass; print(getpass.getpass("Viewer password: "))' | docker run --rm -i "$POLLY_IMAGE" hash-password > /absolute/private/polly/viewer.hash
```

Start the service with read-only mounts. These environment values are paths and a username, never the
password or hash. Save them in a private operator shell file if desired; keep actual secret contents in
the mounted files. Non-root UID/GID mapping is necessary on Linux bind mounts: Compose does not remap file
ownership for you. Compose's required variables and `create_host_path: false` fail early on missing files.

```sh
export POLLY_CONFIG=/absolute/private/polly/polly.yaml
export POLLY_VIEWER_USERNAME=viewer
export POLLY_VIEWER_PASSWORD_HASH_FILE=/absolute/private/polly/viewer.hash
export POLLY_UID=$(id -u)
export POLLY_GID=$(id -g)
docker compose --file /absolute/path/to/polly/compose.yaml up --detach --no-build
```

Open `http://127.0.0.1:8088/` on that host and enter the viewer credentials. The default publish address is
host loopback even though Polly listens on `0.0.0.0` inside its isolated container. `localhost` inside the
container is not your host or another container. Use a reachable Nagios DNS name; the mock fixture uses
the Compose service name `mock`. Change the host port with `POLLY_PORT` when necessary.

### HTTPS and restart behavior

For another display on the LAN or internet, run a reverse proxy on the same host. The supplied
[examples/Caddyfile](examples/Caddyfile) terminates HTTPS and proxies to `127.0.0.1:8088`; replace
`polly.example.com` with your hostname, configure its DNS and permit the proxy's certificate/HTTPS ports.
Only the proxy should be reachable from viewers. Keep port 8088 unpublished on external interfaces.
Do not put the viewer password in the URL. A proxy in a different container requires its own shared
network and `polly:8088` backend, not `127.0.0.1`; the supplied example deliberately runs on the host.
Follow your proxy's service management for automatic restart. No host service is installed by this repo.

Compose uses `restart: unless-stopped`, a read-only root filesystem, no Linux capabilities and a small
writable temporary filesystem. Docker restarts the service after process exit or host restart unless an
operator stopped it. A failed health request alone does not trigger Docker restart. `/healthz` requires
viewer authentication; upstream Nagios failures do not fail process health, but a poll loop without a
completed round for 180 seconds does. Existing external monitoring can check it over HTTPS.

After a configuration or viewer-hash change, recreate the container so a file replaced atomically is
mounted again. Config is read only at startup. The service never rewrites the file or migrates native
application settings.

```sh
docker compose --file /absolute/path/to/polly/compose.yaml up --detach --no-build --force-recreate
```

### Upgrade and rollback

Record the currently running image before upgrading:

```sh
docker compose --file /absolute/path/to/polly/compose.yaml images
```

Keep that old tag/image locally. Fetch the desired source revision in your checkout, build a **new**
commit-tagged image with the earlier build command, set `POLLY_IMAGE` to it and recreate with the command
above. Check the rendered dashboard and authenticated `/api/status` and `/healthz`. For rollback, set
`POLLY_IMAGE` back to the recorded old tag and recreate again, with exactly the same config/hash mounts.
There is no database or configuration conversion in the web service. Do not prune the previous image
until the upgrade has been verified. No automatic update or registry publication is configured.

### Diagnosis

- **Startup exits or restarts repeatedly:** `docker compose --file /absolute/path/to/polly/compose.yaml logs --tail 50 polly` shows sanitized errors. Check absolute file paths, file ownership matching the configured non-root UID, valid YAML, `passwordStorage: file`, Nagios sources and the readable bcrypt hash. Do not paste raw configuration into tickets.
- **401:** the browser needs the viewer account, not Nagios credentials. Both HTML/assets and API/health are protected. **429:** wait 60 seconds after a burst of failed logins; correct the credentials in automated clients too.
- **Polly unreachable from another device:** loopback exposure is intentional. Check the HTTPS proxy, DNS and firewall. Never fix this by publishing plaintext Basic authentication on the LAN.
- **A source is unreachable:** check DNS, routing, Nagios credentials and TLS trust from the container network. Container `localhost` is not your host. Public CA certificates are included; for an internal CA, build a derived image that installs your public CA certificate into the system trust store. Never disable certificate validation.
- **Partial, stale or disconnected:** source failure and browser-to-Polly failure are distinct. Retained data is marked old; 150-second-old measurements cannot become healthy just because HTTP still answers. Check the source strip and the proxy/service logs. A proxy must not cache the status API.
- **Config edits have no effect:** recreate the container; a bind-mounted file replaced by an editor may still refer to the old inode until recreation.
- **Architecture or shared-library errors:** use a locally built image for your host architecture and the supplied runtime stage. Copying only the binary to an arbitrary Linux distribution omits required runtime libraries.

### Container verification

Install the pinned browser dependency with the commands in [Dashboard development and tests](#dashboard-development-and-tests), then run:

```sh
python3 /absolute/path/to/polly/scripts/test-container.py
```

The runner builds the final image, creates temporary private config/hash files, starts Compose with the
separate mock override and checks real HTTP from another container. It compares every served asset byte
with the checkout, checks auth/private routes/refused writes, non-root/read-only operation, real TLS CA
trust, restart and config preservation, then renders the actual service in Chromium light/dark. Its own
Compose containers/network are stopped in `finally`; the built image remains available for inspection.
It requires a running Docker engine and never stops an engine another task might be using.
`POLLY_TEST_IMAGE` sets the retained image tag; `POLLY_TEST_PLATFORM=linux/amd64` or `linux/arm64` selects the
build platform. Record `docker image inspect <tag>`'s ID/architecture with the test result; emulation is
reported as emulation, not native hardware coverage. No real monitor or production configuration is used.

For a manually running demo, use the same start instructions with a private copy of
[examples/polly-web.mock.yaml](examples/polly-web.mock.yaml) and add
`--file /absolute/path/to/polly/compose.mock.yaml` after the normal Compose file. The mock has no host
port and is absent from normal Compose. Stop your demo with `docker compose` using the same two files and
`down`. On macOS without Docker, use the Swift start and hashing commands in [Web service](#web-service).

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

### Dashboard development and tests

The production public directory is `Packages/PollyWeb/Sources/PollyWeb/Public`. Keep test fixtures and
original design exports outside it. The authenticated FileMiddleware serves only that bundled directory;
WOFF2 gets an explicit MIME type because Vapor 4.122.3 does not define one. Inline script/style is not
allowed by the production CSP. Generated SVG styles are external CSS classes, preserving the exact pivots.

Use absolute checkout paths in these commands:

```sh
python3 /absolute/path/to/polly/scripts/generate-web-design.py --check
node --test /absolute/path/to/polly/scripts/web/*.test.mjs
```

Omit `--check` to regenerate. The five original export hashes are verified before generation, and the
Node tests compare SVG trees, origins and animation timings directly to the archived source. See
[design provenance and fonts](doc/design/polly-web/README.md).

For manual inspection, start the loopback-only preview (Ctrl-C stops it):

```sh
python3 /absolute/path/to/polly/scripts/preview-web.py
```

The printed URL supports `?state=quiet`, `warning`, `critical`, `unknown`, `unreachable`, `empty`, `paused`,
`waiting`, `partial`, `long`, `five`, `eight`, `nine` and `many` (107 problems). `/__test__/dom.html` runs the actual DOM suite; the page must
say PASS. `/__test__/reference.html` shows the original animation SVG and CSS without executing the design
runtime. Only that development reference permits inline styles. These routes do not exist in PollyWeb.

The development-only npm lockfile pins Playwright 1.65.1 and its matching Chromium. Install from any
working directory (Linux CI adds `--with-deps` to the browser install for system packages):

```sh
npm --prefix /absolute/path/to/polly ci
node /absolute/path/to/polly/node_modules/playwright/cli.js install chromium
npm --prefix /absolute/path/to/polly test
npm --prefix /absolute/path/to/polly run test:browser
```

Individual runners also accept `POLLY_PLAYWRIGHT=/absolute/path/to/playwright/index.mjs` when using an
explicit external installation. CI uses the committed lockfile, never a floating `npx` package version.

It starts/stops its own preview, exercises the real DOM, keyboard focus, literal XSS output, motion controls,
reduced motion and offscreen pausing, and rejects external asset requests. The viewport matrix is
1920×1080, 1280×720, 1728×873, 3840×2160, 1024×1366 and 390×844 in both themes and motion preferences. Screenshots
are saved to `/tmp/polly-browser-screens`, or `POLLY_SCREENSHOTS`. Final distribution verification uses
Chromium 159.0.8154.6 via stable Playwright 1.65.1. The earlier 60-minute recovery soak used Chromium
158.0.8127.18 via Playwright 1.66.0-alpha-2026-11-09; it remains evidence for unchanged dashboard assets,
not a claim that the new browser completed that soak. Manual inspection also used desktop Chrome.

Recovery and long-running checks (each runner owns and stops its mock/service/browser in `finally`):

```sh
POLLY_PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node /absolute/path/to/polly/scripts/test-web-reliability.mjs
POLLY_PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node /absolute/path/to/polly/scripts/test-web-lifecycle.mjs
python3 /absolute/path/to/polly/scripts/test-web-upstream-faults.py
POLLY_PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node /absolute/path/to/polly/scripts/test-web-soak.mjs
```

The browser fault runner uses a real loopback HTTP status mock, not request interception: 401, 503,
redirect, malformed JSON/schema, slow/hanging replies, listener restart and browser offline/online.
It checks rendered status after recovery, manual/automatic pages, reduced motion and deterministic
visibility events. The lifecycle runner also checks unchanged screenreader announcements and restored-page
revalidation. The upstream runner uses the real Swift service and two Nagios mocks, including
source recovery after a real polling interval, service restarts and unchanged read-only configuration.
`GET /mock/config?fault=none|auth|503|redirect|invalid-json|slow|hang` changes only status responses;
control endpoints stay reachable, and `/mock/reset` clears the fault.

The soak takes at least 60 real minutes in three tabs (1080p, 720p and 4K/reduced motion). It changes
HTTP modes every two minutes, samples active/max timers and requests, DOM size and Chromium heap after
garbage collection, and fails on overlaps, timer growth, more than 10 MB retained heap growth, a failed
rendered-state assertion or an asset change during the run. The JSON report defaults to
`/tmp/polly-phase4-soak.json` (`POLLY_SOAK_REPORT` overrides it). On macOS it prevents idle sleep only
while the runner is alive. An interrupted or short run is not acceptance evidence. These are browser
and software measurements; they do not certify a physical TV, Safari or Firefox.
