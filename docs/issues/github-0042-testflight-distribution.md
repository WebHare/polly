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

> Ik zie Polly nu in App Store Connect. De [TestFlight-run](https://github.com/WebHare/polly/actions/runs/44095549948) stopte bij het importeren van het distributiecertificaat. Laat je weten zodra de macOS-build in TestFlight klaarstaat? Dan test ik de installatie en controleer ik of Polly start.
