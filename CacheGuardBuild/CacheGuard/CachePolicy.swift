import Foundation

/// A conservative policy: never scan arbitrary application/system containers.
/// Every deletion is revalidated against the original root and a source-specific rule.
enum CachePolicy {
    static let maxItemsPerScope = 10_000

    private static let cacheMarkers: Set<String> = [
        "cache", "caches", ".cache", "tmp", "temp", "temporary",
        "thumbnails", "thumbnail"
    ]
    private static let protectedDirectories: Set<String> = [
        "documents", "application support", "preferences", "keychain",
        "databases", "database", "accounts", "cookies", "sessions", "auth"
    ]
    private static let protectedExtensions: Set<String> = [
        "db", "sqlite", "sqlite3", "db-wal", "db-shm", "sqlite-wal",
        "sqlite-shm", "realm", "plist", "json", "key", "pem",
        "p12", "mobileconfig", "session", "cookies"
    ]

    static func isWithin(_ file: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        return filePath.hasPrefix(rootPath + "/")
    }

    static func isEligible(_ file: URL, root: URL, source: CleanSource) -> Bool {
        guard isWithin(file, root: root) else { return false }
        guard !protectedExtensions.contains(file.pathExtension.lowercased()) else { return false }

        if source == .chosenFolder {
            let relative = String(file.path.dropFirst(root.standardizedFileURL.path.count))
            let pieces = relative.split(separator: "/").map { String($0).lowercased() }
            guard !pieces.contains(where: { protectedDirectories.contains($0) }) else {
                return false
            }
            let rootIsCache = cacheMarkers.contains(root.lastPathComponent.lowercased())
            guard rootIsCache || pieces.contains(where: { cacheMarkers.contains($0) }) else {
                return false
            }
        }
        return true
    }
}
