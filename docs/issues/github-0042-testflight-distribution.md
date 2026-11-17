# Issue #42: TestFlight access and distribution

> GitHub: [WebHare/polly#42](https://github.com/WebHare/polly/issues/42)
> Date: 2026-11-17
> Status: Investigation done; reply drafted, not posted

## Summary

Wouter confirmed that Polly is visible in the existing WebHare App Store Connect account after [Arnold granted access](https://github.com/WebHare/polly/issues/42#issuecomment-6911581972). This makes internal TestFlight verification and, with the App Manager role, release management possible without handing those tasks back to Arnold.

## Current situation

[PR #67](https://github.com/WebHare/polly/pull/67) exported a signed macOS installer in a dry run. The [manual TestFlight workflow](https://github.com/WebHare/polly/blob/d2f69ed1841bec363d28ac90e14fb8df48089916/.github/workflows/testflight.yml) is in main, but its [first run](https://github.com/WebHare/polly/actions/runs/44095549948) failed on both platforms at `security import` with `SecKeychainItemImport: Unknown format in import.` Neither job got to the build or upload. The contents and password of the configured PKCS#12 were not inspected. The current build and review status in App Store Connect and the exact rights granted to Wouter were not verified.

## Approach

Keep the existing WebHare team, app record, bundle identifier and manual release workflow. Validate the CI PKCS#12 export and its password, then verify a macOS upload and installation through [internal TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/). App Store Connect app access does not fix CI signing. [Certificate and profile access](https://developer.apple.com/help/app-store-connect/manage-your-team/edit-access-to-apps) is team-wide. If the account can sign for development with the WebHare team in Xcode, its default signing can replace Wouter's local override; otherwise the working local override from [PR #79](https://github.com/WebHare/polly/pull/79) remains useful. Verify Keychain access after any change of signing identity.

Draft reply, not posted:

> Ik zie Polly nu in App Store Connect. Ik kijk zelf in TestFlight en test de macOS-build zodra ik die kan installeren. De laatste GitHub-run stopte bij het importeren van het distributiecertificaat. [GitHub Actions-run](https://github.com/WebHare/polly/actions/runs/44095549948)

## Deferred access verification

Apple sign-in returned HTTP 502 during browser checks. Wouter subsequently reported that neither email nor passkey sign-in worked, with the message “The email or phone number you entered doesn’t match the account on your device.” The initial account-mismatch explanation was withdrawn because the cause was unverified. Other users reported contemporaneous Apple Account and App Store Connect failures. A service incident remained plausible despite the official status page showing availability. Later verification must reassess service health and the account before drawing conclusions.

The follow-up was saved in TechNotes Inbox as “Handoff: Polly Apple-toegang en TestFlight controleren”, ID `cd8409bf-636a-447b-bb02-d63badcdd81c`, with the Polly working directory and a local handoff. It covers checking account rights, macOS TestFlight availability and whether the draft reply is still useful. No issue comment, Apple upload or release was performed.

## Verification

At session close, `swift test --package-path Packages/PollyKit` passed with 136 tests in 26 suites. The macOS build completed with ad-hoc signing. No application code changed. Authenticated Apple access and TestFlight installation remain unverified and are covered by the deferred note.
