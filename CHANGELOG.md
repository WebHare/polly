# Changelog

Changes in Polly, newest first. Add user-facing changes under `[Unreleased]`; move them to a dated version before publishing a release.

## [Unreleased]

### Added

- Linux support for the shared Nagios monitoring core. URL monitoring and Keychain remain Apple-only;
  a standalone web dashboard is not included yet.
- Edit a source: double-click it or use **Edit…** in its context menu on macOS; tap it on iPhone and iPad.
- Duplicate a source to add a similar one: **Duplicate…** in its context menu, or swipe right on iPhone and iPad.
- **Edit source…** on the "Polly can't reach" screen opens the form for that source.

### Changed

- Explain the ideas for shared on-call duties, escalation and billing in the macOS Team placeholder.
- The Nagios servers and URLs Polly watches are now called sources, so they can't be mistaken for the
  servers they monitor. `polly.yaml` lists them under `sources:`; an existing file is converted at startup.
- Polly on macOS is updated through TestFlight and the App Store; **Check for Updates…** is gone.
- The icon in front of a source now only turns red when Polly can't reach it. Critical, warning and
  unknown services and down hosts get a small icon next to their count in the source's status line instead.

- Open the macOS add-source form in a modal using Add above the source list.
- The source form asks for the URL before the name, and the example URL no longer looks filled in.

### Fixed

- Refresh immediately when returning to Polly on iPhone or iPad, and pause polling while inactive.
- Disable downtime presets when an edited start time does not match every possible server date format.
- A URL pasted with a username and password no longer keeps showing them in the URL field on macOS.
- **Add source** on macOS stayed disabled after entering a URL.

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
