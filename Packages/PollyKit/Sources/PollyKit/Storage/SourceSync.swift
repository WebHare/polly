import Foundation
import Yams

/// The part of a source that is shared through iCloud. Pause, the notification bell and the password stay on
/// each device; passwords travel through iCloud Keychain instead.
public struct SyncedSource: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: BackendKind
    public var baseURL: URL
    public var username: String
    public var enabled: Bool

    public init(_ server: NagiosServer) {
        id = server.id
        name = server.name
        kind = server.kind
        baseURL = server.baseURL
        username = server.username
        enabled = server.enabled
    }

    /// This source on a device: its shared fields, with the device's own pause and bell when it had the source.
    func applied(to local: NagiosServer?) -> NagiosServer {
        var server = local ?? NagiosServer(id: id, name: name, baseURL: baseURL, username: username)
        server.id = id
        server.name = name
        server.kind = kind
        server.baseURL = baseURL
        server.username = username
        server.enabled = enabled
        return server
    }

    /// The same system on another device, which may have been added there under another ID.
    func isSameSystem(as server: NagiosServer) -> Bool {
        kind == server.kind && baseURL == server.baseURL && username == server.username
    }

    // MARK: YAML

    static let version = 1

    /// The shared list as one YAML document, in list order.
    public static func render(_ sources: [SyncedSource]) -> String {
        var out = "version: \(version)\n"
        guard !sources.isEmpty else { return out + "sources: []\n" }
        out += "sources:\n"
        for source in sources {
            out += "  - id: \(source.id.uuidString.lowercased())\n"
            out += "    name: \(SettingsFile.scalar(source.name))\n"
            out += "    type: \(source.kind.rawValue)\n"
            out += "    url: \(SettingsFile.scalar(source.baseURL.absoluteString))\n"
            out += "    username: \(SettingsFile.scalar(source.username))\n"
            out += "    enabled: \(source.enabled)\n"
        }
        return out
    }

    public static func parse(_ yaml: String) throws -> [SyncedSource] {
        struct Raw: Decodable {
            struct Source: Decodable {
                var id: String
                var name: String
                var type: String
                var url: String
                var username: String
                var enabled: Bool
            }
            var version: Int
            var sources: [Source]
        }
        let raw: Raw
        do {
            raw = try YAMLDecoder().decode(Raw.self, from: yaml)
        } catch {
            throw SettingsFileError(message: "The source list in iCloud is not valid: \(error)")
        }
        // A newer Polly may share more than this one understands; leave its list alone rather than overwrite it.
        guard raw.version == version else {
            throw SettingsFileError(message: "The source list in iCloud has version \(raw.version); update Polly to sync it.")
        }
        return try raw.sources.map { entry in
            guard let id = UUID(uuidString: entry.id), let kind = BackendKind(rawValue: entry.type),
                  let url = URL(string: entry.url) else {
                throw SettingsFileError(message: "The source list in iCloud has an invalid source '\(entry.name)'.")
            }
            var source = SyncedSource(NagiosServer(id: id, name: entry.name, baseURL: url, username: entry.username))
            source.kind = kind
            source.enabled = entry.enabled
            return source
        }
    }
}

/// Merges this device's sources with the list in iCloud.
///
/// iCloud holds one list, and every device remembers the list as it last agreed with it (the base). Comparing
/// both sides with the base tells which side changed what, so a change made here while another device changed
/// something else is not lost when the list is written back.
public enum SourceSync {
    /// The iCloud key-value storage key of the shared list.
    public static let defaultKey = "sources"

    /// The explanation under the "Sync sources with iCloud" switch.
    public static func settingText(on: Bool, passwordStorage: PasswordStorage, error: String?) -> String {
        guard on else { return "Sources stay on this device." }
        var text = passwordStorage == .keychain
            ? "Sources and their passwords are shared with your other devices through iCloud."
            : "Sources are shared with your other devices through iCloud, but passwords in polly.yaml are not: enter them on each device."
        text += " Pausing a source and its notifications stay on each device."
        if let error { text += " Last sync failed: \(error)" }
        return text
    }

    public struct Merge: Equatable, Sendable {
        /// This device's sources after the merge.
        public var servers: [NagiosServer]
        /// Local sources that are the same system as one in iCloud, from their local ID to the ID in iCloud.
        public var renamed: [UUID: UUID]
        /// Local sources removed because another device deleted them.
        public var deleted: [UUID]
        /// The list to write to iCloud, or nil when iCloud already has it.
        public var upload: [SyncedSource]?
        /// The new base: what iCloud holds after the merge.
        public var base: [SyncedSource]
    }

    /// - Parameters:
    ///   - local: this device's sources.
    ///   - base: the list as this device last synced it; nil before its first sync.
    ///   - remote: the list in iCloud; nil when there is none yet.
    public static func merge(local: [NagiosServer], base: [SyncedSource]?, remote: [SyncedSource]?) -> Merge {
        guard let remote else {
            let list = local.map(SyncedSource.init)
            return Merge(servers: local, renamed: [:], deleted: [], upload: list, base: list)
        }
        var local = local
        var renamed: [UUID: UUID] = [:]
        if base == nil {
            // Joining: a source this device already has keeps its pause and bell under the ID from iCloud.
            let remoteIDs = Set(remote.map(\.id))
            for index in local.indices where !remoteIDs.contains(local[index].id) {
                if let match = remote.first(where: { source in
                    source.isSameSystem(as: local[index]) && !local.contains { $0.id == source.id }
                }) {
                    renamed[local[index].id] = match.id
                    local[index].id = match.id
                }
            }
        }

        let baseByID = Dictionary((base ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var kept: [UUID: NagiosServer] = [:]
        var deleted: [UUID] = []
        for source in remote {
            let old = baseByID[source.id]
            if let mine = localByID[source.id] {
                // Changed here only: keep it. Otherwise iCloud has the latest (both changed: the last write wins).
                let changedHere = old.map { SyncedSource(mine) != $0 } ?? false
                kept[source.id] = changedHere && source == old ? mine : source.applied(to: mine)
            } else if old == nil || source != old {
                // New in iCloud, or deleted here but changed elsewhere since.
                kept[source.id] = source.applied(to: nil)
            }
        }
        for mine in local where remoteByID[mine.id] == nil {
            if let old = baseByID[mine.id], SyncedSource(mine) == old {
                deleted.append(mine.id) // deleted elsewhere, unchanged here
            } else {
                kept[mine.id] = mine // new here, or changed here since another device deleted it
            }
        }

        let localOrder = local.map(\.id)
        let remoteOrder = remote.map(\.id)
        let baseOrder = (base ?? []).map(\.id)
        let primary = reordered(localOrder, from: baseOrder) && !reordered(remoteOrder, from: baseOrder)
            ? localOrder + remoteOrder : remoteOrder + localOrder
        var seen = Set<UUID>()
        let servers = primary.compactMap { id -> NagiosServer? in
            guard seen.insert(id).inserted else { return nil }
            return kept[id]
        }
        let list = servers.map(SyncedSource.init)
        return Merge(servers: servers, renamed: renamed, deleted: deleted, upload: list == remote ? nil : list,
                     base: list)
    }

    /// Whether the sources both lists have are in another order than in the base.
    private static func reordered(_ order: [UUID], from base: [UUID]) -> Bool {
        let common = Set(order).intersection(base)
        return order.filter(common.contains) != base.filter(common.contains)
    }
}

/// Where the shared list lives: iCloud key-value storage in the app, memory in tests.
public protocol CloudKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

#if canImport(Darwin)
extension NSUbiquitousKeyValueStore: CloudKeyValueStore {}
#endif
