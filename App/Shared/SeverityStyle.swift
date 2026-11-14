import PollyKit

extension Severity {
    var label: String {
        switch self {
        case .ok: "OK"
        case .warning: "Warning"
        case .unknown: "Unknown"
        case .critical: "Critical"
        }
    }
}
