import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How a request to a source authenticates: HTTP Basic with the username and password, or the password as the
/// value of a header of the user's choice (`X-API-Key: …`, `Authorization: Bearer …`).
public struct SourceCredentials: Equatable, Sendable {
    public var username: String
    public var password: String?
    /// When set, `password` is sent as this header and Basic authentication is not used.
    public var headerName: String?

    public init(username: String = "", password: String? = nil, headerName: String? = nil) {
        self.username = username
        self.password = password
        self.headerName = headerName
    }

    /// Whether anything secret goes out with a request.
    public var isEmpty: Bool {
        headerName == nil ? username.isEmpty && password == nil : password == nil
    }

    public func apply(to request: inout URLRequest) {
        if let headerName {
            if let password { request.setValue(password, forHTTPHeaderField: headerName) }
        } else if !username.isEmpty || password != nil {
            let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Why `name` can't be used as an authentication header; nil when it can.
    public static func problem(withHeaderName name: String) -> String? {
        if name.isEmpty { return "Enter the name of the header, such as Authorization or X-API-Key." }
        guard name.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
            return "A header name can't contain spaces, colons or other separators."
        }
        if reservedHeaders.contains(name.lowercased()) || name.lowercased().hasPrefix("proxy-") {
            return "\(name) is set by the connection itself and can't be used for authentication."
        }
        return nil
    }

    /// RFC 9110 `token` characters.
    private static let tokenCharacters = CharacterSet(charactersIn:
        "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let reservedHeaders: Set<String> = [
        "host", "content-length", "content-type", "connection", "keep-alive", "transfer-encoding", "te", "trailer",
        "upgrade", "accept", "cookie",
    ]
}
