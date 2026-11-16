# Changelog

Changes in Polly, newest first. Add user-facing changes under `[Unreleased]`; move them to a dated version before publishing a release.

## [Unreleased]

### Added

- Edit a server: double-click it or use **Edit…** in its context menu on macOS; tap it on iPhone and iPad.
- Duplicate a server to add a similar one: **Duplicate…** in its context menu, or swipe right on iPhone and iPad.
- **Edit server…** on the "Polly can't reach" screen opens the form for that server.

### Changed

- Polly on macOS is updated through TestFlight and the App Store; **Check for Updates…** is gone.

- Open the macOS add-server form in a modal using Add above the server list.
- The server form asks for the URL before the name, and the example URL no longer looks filled in.

### Fixed

- Refresh immediately when returning to Polly on iPhone or iPad, and pause polling while inactive.
- Disable downtime presets when an edited start time does not match every possible server date format.
- A URL pasted with a username and password no longer keeps showing them in the URL field on macOS.
- **Add server** on macOS stayed disabled after entering a URL.

## [0.2.0] - 2026-11-15

### Added

- Read what's new from About Polly on macOS and Settings on iPhone and iPad, even when offline.
- Check for updates and install signed releases from within the macOS app.
- See the version and build number on both macOS and iOS.

### Fixed

- The displayed version now matches the version used to build the app.

## [0.1.0] - 2026-11-15

### Added

- Monitor Nagios servers and websites from the macOS menu bar, iPhone and iPad.
- Inspect problems, acknowledge them and schedule downtime, with presets and host-wide options.
- Receive optional notifications for new problems and recoveries.
