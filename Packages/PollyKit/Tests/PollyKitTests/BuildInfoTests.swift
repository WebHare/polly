/* swift test --package-path Packages/PollyKit --filter BuildInfoTests */
import Foundation
import Testing
@testable import PollyKit

@Suite struct BuildInfoTests {
    let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    let english = Locale(identifier: "en_GB")
    let built = ISO8601DateFormatter().date(from: "2026-11-27T13:05:00Z")!

    @Test func readsChannelVersionAndNumberFromTheInfoDictionary() {
        let info = BuildInfo(info: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "7",
            "PollyBuildChannel": "appstore",
        ], executableDate: built)
        #expect(info.channel == .appStore)
        #expect(info.version == "0.2.0")
        #expect(info.buildNumber == "7")
        #expect(info.buildDate == built)
    }

    @Test func missingOrUnknownChannelsCountAsLocal() {
        #expect(BuildInfo(info: [:]).channel == .local)
        #expect(BuildInfo(info: ["PollyBuildChannel": "nightly"]).channel == .local)
        #expect(BuildInfo(info: ["PollyBuildChannel": "local"]).channel == .local)
    }

    @Test func onlyLocalBuildsGetALineInLocalTime() {
        var info = BuildInfo(info: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "7",
            "PollyBuildChannel": "local",
        ], executableDate: built)
        #expect(info.localBuildLine(timeZone: amsterdam, locale: english) == "Local build 7 · 27 Nov 2026 at 14:05 · 0.2.0")
        info.channel = .appStore
        #expect(info.localBuildLine(timeZone: amsterdam, locale: english) == nil)
    }

    @Test func lineLeavesOutWhatIsUnknown() {
        #expect(BuildInfo(info: [:]).localBuildLine(timeZone: amsterdam, locale: english) == "Local build")
    }
}
