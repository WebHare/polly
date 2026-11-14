import Foundation

/// Debug log of everything sent to and received from the servers, one JSON object per line.
///
/// Credentials are never written: the `Authorization` value is replaced by `Basic <redacted>`. The file is
/// owner-only and is rotated to `<name>.1` once it grows beyond `maxBytes`. Thread-safe.
public final class WireLog: Sendable {
    public let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(fileURL: URL, maxBytes: Int = 5_000_000) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    /// Records one exchange. `status` and `body` are nil when no response arrived. Failures to write
    /// are ignored: a debug log must never break monitoring.
    public func record(request: URLRequest, status: Int?, body: Data?, error: String?) {
        var headers = request.allHTTPHeaderFields ?? [:]
        for (name, value) in headers where name.caseInsensitiveCompare("Authorization") == .orderedSame {
            headers[name] = value.hasPrefix("Basic ") ? "Basic <redacted>" : "<redacted>"
        }
        let entry: [String: Any] = [
            "time": Date().formatted(.iso8601),
            "method": request.httpMethod ?? "GET",
            "url": request.url?.absoluteString ?? "",
            "requestHeaders": headers,
            "requestBody": request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? NSNull(),
            "status": status ?? NSNull(),
            "responseBody": body.map { String(decoding: $0, as: UTF8.self) } ?? NSNull(),
            "error": error ?? NSNull(),
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        line.append(0x0A)

        lock.withLock {
            let fileManager = FileManager.default
            let path = fileURL.path(percentEncoded: false)
            if let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
                let rotated = fileURL.appendingPathExtension("1")
                try? fileManager.removeItem(at: rotated)
                try? fileManager.moveItem(at: fileURL, to: rotated)
            }
            if !fileManager.fileExists(atPath: path) {
                fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }
}
