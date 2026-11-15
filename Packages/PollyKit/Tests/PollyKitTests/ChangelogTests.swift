/* swift test --package-path Packages/PollyKit --filter ChangelogTests */
import Foundation
import Testing
@testable import PollyKit

@Suite struct ChangelogTests {
    @Test func readsReleasesInFileOrderAndContinuedBullets() {
        let releases = Changelog.parse("""
        # Changelog
        Intro ignored.
        ## [Unreleased]
        ### Added
        - In development
        ## [0.2.0] - 2026-11-15
        ### Added
        - Updates
          with signed downloads.
        ### Fixed
        - Version number
        ## [0.1.0] - 2026-11-14
        ### Added
        - Monitoring
        """)
        #expect(releases.map(\.version) == [nil, "0.2.0", "0.1.0"])
        #expect(releases[1].date == "2026-11-15")
        #expect(releases[1].sections.map(\.title) == ["Added", "Fixed"])
        #expect(releases[1].sections[0].items == ["Updates with signed downloads."])
        #expect(Changelog.shown(releases, includeUnreleased: false).map(\.version) == ["0.2.0", "0.1.0"])
        #expect(Changelog.shown(releases, includeUnreleased: true).count == 3)
    }

    @Test func hidesEmptyReleases() {
        #expect(Changelog.parse("").isEmpty)
        #expect(Changelog.shown(Changelog.parse("## [Unreleased]\n### Added\n"), includeUnreleased: true).isEmpty)
    }

    @Test func versionUsesBundleMetadata() {
        #expect(AppRelease.versionLabel(info: ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "42"]) == "Version 0.2.0 (42)")
        #expect(AppRelease.versionLabel(info: [:]) == "Version ? (?)")
    }
}
