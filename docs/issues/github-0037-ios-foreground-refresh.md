# Issue #37: Refresh on returning to the foreground

> GitHub: [unilynx/polly#37](https://github.com/unilynx/polly/issues/37)
> Date: 2026-11-15
> Status: verified locally, awaiting push approval

## Summary

iPhone and iPad could show stale status after returning to Polly because the existing polling interval continued. Polling now starts immediately when the app becomes active and stops while inactive.

## Problem

[PollyApp.swift](https://github.com/unilynx/polly/blob/main/App/Shared/PollyApp.swift) started polling at initialization without observing the app lifecycle. A regression test also demonstrated that stopping during a request restored the canceled loop's next-poll time. An interrupted refresh could replace the last known status after cancellation.

## Solution

The app observes the aggregate scene phase, so multiple iPad windows share one lifecycle decision. [MonitorModel.swift](https://github.com/unilynx/polly/blob/codex/37-ios-foreground-refresh/Packages/PollyKit/Sources/PollyKit/Monitoring/MonitorModel.swift) reuses its existing start/stop methods and ignores canceled refresh results and schedules. macOS still starts polling at launch.

[TransportTests.swift](https://github.com/unilynx/polly/blob/codex/37-ios-foreground-refresh/Packages/PollyKit/Tests/PollyKitTests/TransportTests.swift) covers stopping during a request, immediate refresh after resuming, repeated activation without duplicate polls, and preservation of notification baselines. The cancellation tests failed before the guards were added; the package suite passed (103 tests reported; opt-in mock and network suites skipped). Both macOS and iOS Simulator builds passed.

On the iPhone 17 Pro simulator (iOS 26), the Problems screen showed a new critical HTTP problem after returning from Settings in light mode, then the healthy overview after another return in dark mode. The wire log recorded the three status responses within 3.95 and 1.11 seconds of the foreground launch command, respectively, rather than waiting 60 seconds. No requests were logged during each background observation. The existing simulator configuration and log were restored and the local mock stopped. iPad, physical devices and the macOS UI were not inspected. No issue comment has been posted.
