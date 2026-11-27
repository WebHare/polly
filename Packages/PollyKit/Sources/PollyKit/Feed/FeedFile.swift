import Foundation

/// A Polly feed in a JSON file on this Mac, written by a script or another program. Only on macOS: the file is
/// chosen with Browse…, which gives the sandboxed app a lasting permission to read it.
public enum FeedFile {
    /// The status of a feed file, or `FeedError.stale` when it hasn't changed for longer than `staleAfter`, as
    /// whatever writes it may have stopped.
    public static func status(from data: Data, modifiedAt: Date, now: Date, staleAfter: TimeInterval) throws -> ServerStatus {
        let age = now.timeIntervalSince(modifiedAt)
        if age > staleAfter { throw FeedError.stale(age: age, limit: staleAfter) }
        var status = try FeedDocument.status(from: data, statusCode: 200, fetchedAt: now)
        status.updatedAt = modifiedAt
        return status
    }

    /// Reads the file and its modification time, through the permission in `bookmark` when there is one.
    @Sendable public static func read(_ url: URL, bookmark: Data?) throws -> (Data, Date) {
        #if os(macOS)
        var target = url
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                target = resolved
            }
        }
        let scoped = target.startAccessingSecurityScopedResource()
        defer { if scoped { target.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: target)
            let modified = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .now
            return (data, modified)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw FeedError.file("The file \(url.path(percentEncoded: false)) doesn't exist (anymore).")
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw FeedError.file("Polly may not read this file. Choose it again with Browse… in the source's settings.")
        } catch {
            throw FeedError.file("Polly can't read the file: \(error.localizedDescription)")
        }
        #else
        throw FeedError.file("Feed files are only available in Polly for Mac.")
        #endif
    }

    #if os(macOS)
    /// The lasting permission to read a file the user just chose, to store with the source.
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    #endif
}
