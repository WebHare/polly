# Polly

A Nagios monitor for macOS (menu bar), iPhone and iPad in Swift/SwiftUI. This file only holds what an agent
needs on top of the other documentation:

- `doc/requirements.md`: every expected feature, business rule, caveat and product decision (see
  [Requirements](#requirements)).
- `README.md`: the layout and the implementation and architecture decisions (project structure, libraries, how
  a backend is built).
- `DEVELOPERS.md`: building, running and testing the app and the mock server.

Read the relevant section before changing behaviour, and update it in the same change when a decision changes.

## Requirements

- All expected features, business rules, caveats and product decisions are recorded in
  [doc/requirements.md](doc/requirements.md).
  - Read it before changing behaviour, so a change doesn't silently break an earlier decision.
  - Update it in the same change whenever a feature, rule, caveat or decision is added, changed or dropped.
  - When the code and requirements.md disagree, treat it as a bug in one of the two and ask which is right
    instead of guessing.
- Write requirements.md mostly as indented bulleted lists of requirements / user stories:
  - One requirement per bullet, describing what the user can do or what the app must (not) do.
  - Nest bullets for details, rules, edge cases and caveats of their parent.
  - Add a short *why* to a bullet when the reason isn't obvious, so the decision can be revisited
    deliberately rather than by accident.
  - Describe behaviour, not implementation: no type names, file names or code unless the user can see them
    (such as `polly.yaml` keys).

## Rules

- **Logic lives in `Packages/PollyKit`, views in `App/`.** Anything with a branch, a sort or a format goes in
  the package with a test; the app targets stay views only.
- **Test first.** Write the failing test, watch it fail, then fix. `swift test --package-path Packages/PollyKit`.
- **The mock follows the real Nagios.** When a real server behaves differently, change `mock/nagios-mock.mjs`
  first, watch `MockIntegrationTests` fail, then fix the client.
- **Backends stay abstract.** `MonitorModel` and the views never mention CGI names, HTML or Nagios status
  values; that belongs behind `MonitorBackend`.
- **Commands are prepared, then submitted once.** Never retry a submit, and never treat HTTP 200 as success.
- **`project.yml` is the source of truth** for the Xcode project. After adding or removing files run
  `xcodegen generate` and commit `Polly.xcodeproj` too.
- **Versions stay below 1.0** until the owner explicitly approves a 1.0 release.
- **Releases:** add user-facing changes to `CHANGELOG.md`; before publishing, bump both version values in
  `project.yml`, date the matching changelog section and regenerate the Xcode project. See DEVELOPERS.md.
- **Commits:** `feat:` / `fix:` / `chore:` / `ci:` plus a sentence, as in `git log`.

## Workflow: don't break main

- **Never push to `main`.** Work on a branch, push the branch and open a pull request against `main`.
- **Enable auto-merge right after opening the pull request** (`gh pr merge --auto --merge <number>`), so it
  merges by itself once the build is green and nobody has to come back for it.
- **Merge only when the build is green.** The workflows in `.github/workflows/` run on every pull request; a
  red check means the pull request is not ready: fix it on the branch, never merge around it.
- Before opening the pull request, run what CI runs: `swift test --package-path Packages/PollyKit` and a macOS
  build, plus an iOS Simulator build when shared code changed.
- When `main` has moved on, merge it into the branch (no force push on a shared branch) and build again.

## Design

The macOS and iOS screens follow the Polly design. Colors, status icons, the mascot and the controls are in
`App/Shared/PollyDesign.swift`, with the extra iPhone colors in `App/iOS/PhoneDesign.swift`; use those
instead of system colors and SF Symbols for status.

- A part of the design that is drawn but does not work carries `PlaceholderTag()` and `.placeholderControl()`.
  Remove both in the change that makes it real; never ship a control that silently does nothing.
- The mascot drawings and the app icon in `App/Shared/Assets.xcassets` are generated from the design export.
  Regenerate them from the export rather than editing the files by hand.
- iOS has its own screens in `App/iOS` (Problems, Servers and Settings tabs); the command form,
  `ServerStateIcon` and the status pill colors are shared with macOS.

## Building and running locally

- Without the WebHare bv team certificate, build ad-hoc signed:
  `xcodebuild -project Polly.xcodeproj -scheme Polly -destination 'platform=macOS' CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build`.
  Do not change the signing settings in `project.yml` for this.
- `xcodegen generate` with a newer XcodeGen adds `compatibilityVersion = "Xcode 14.0";` and drops the
  `productRefGroup` line in `project.pbxproj`. Revert those two lines before committing.
- The app is sandboxed: settings are in
  `~/Library/Containers/nl.webhare.polly/Data/Library/Application Support/Polly/polly.yaml`. To run with test
  data, launch once, quit, write a server pointing at the mock with `passwordStorage: file`, and relaunch.
  Put the file back afterwards; it is the user's real configuration.
- Run the mock on a free port: `node mock/nagios-mock.mjs --port 8089 --no-rotate`, login `nagiosadmin` / `nagios`.
- A new or changed app icon may not show in the Dock until the bundle is registered again:
  `lsregister -f <path to Polly.app>` and restart the app.

## Testing against a real Nagios

Only read from a shared production monitor: status, check details, links and fetching the command forms.
Submitting an acknowledgement or a downtime is done against the mock or a Nagios you run yourself, never
against a server other people rely on, unless the user says so for that server.

## Verifying UI

A successful build does not prove a screen works. Check the changed screen in the running app, in light and
dark, and say in your report which screens you did not look at.
