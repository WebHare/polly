import PollyKit
import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .yellow
        case .unknown: .orange
        case .critical: .red
        }
    }

    var symbolName: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .ok: "OK"
        case .warning: "Warning"
        case .unknown: "Unknown"
        case .critical: "Critical"
        }
    }
}

/// One line per server: name, host/service counts or the error.
struct ServerStatusRow: View {
    let server: NagiosServer
    let state: MonitorModel.ServerState?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.headline)
                detail.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var indicator: some View {
        if !server.enabled {
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        } else {
            statusIndicator
        }
    }

    @ViewBuilder private var statusIndicator: some View {
        switch state {
        case .ok(let status):
            Image(systemName: status.severity.symbolName).foregroundStyle(status.severity.color)
        case .failed:
            Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.gray)
        case .loading, nil:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var detail: some View {
        if !server.enabled {
            Text("Monitoring paused")
        } else {
            statusDetail
        }
    }

    @ViewBuilder private var statusDetail: some View {
        switch state {
        case .ok(let s):
            Text("Hosts: \(s.hosts.up) up, \(s.hosts.down) down · Services: \(s.services.ok) ok, \(s.services.warning) warn, \(s.services.critical) crit")
        case .failed(let message):
            Text(message).lineLimit(2)
        case .loading, nil:
            Text(server.baseURL.absoluteString)
        }
    }
}
