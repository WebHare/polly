import PollyKit
import SwiftUI

struct WhatsNewView: View {
    @Environment(\.pollyTheme) private var theme
    private let releases = AppRelease.releases()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("What's New").font(.system(size: 24, weight: .bold))
                Text(AppRelease.versionLabel(info: Bundle.main.infoDictionary ?? [:]))
                    .foregroundStyle(theme.muted)
                ForEach(releases, id: \.self) { release in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(release.version ?? "Unreleased").font(.system(size: 18, weight: .bold))
                        Text(release.date ?? "").foregroundStyle(theme.muted)
                        ForEach(release.sections, id: \.self) { section in
                            Text(section.title).font(.headline)
                            ForEach(section.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(theme.link)
                                    Text(item).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("release-\(release.version ?? "unreleased")")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .textSelection(.enabled)
        }
        .background(theme.window)
    }
}
