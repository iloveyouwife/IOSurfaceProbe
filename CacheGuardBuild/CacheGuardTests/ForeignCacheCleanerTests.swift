import XCTest
@testable import CacheGuard

final class ForeignCacheCleanerTests: XCTestCase {
    func testDisallowsPathsOutsideApplicationDataContainer() {
        for forbidden in ["/", "/tmp", "/var/mobile", "/var/mobile/Library",
                          "/var/mobile/Containers/Data/Application/wrong"] {
            let snapshot = ForeignCacheCleaner.preview(container: forbidden)
            XCTAssertEqual(snapshot.accessibleScopes, 0)
            XCTAssertTrue(snapshot.files.isEmpty)
            let result = ForeignCacheCleaner.delete(snapshot)
            XCTAssertEqual(result.removed, 0)
        }
    }

    func testRefusesSyntheticTruncatedSnapshot() {
        let example = ForeignCacheCleaner.Snapshot(
            container: "/var/mobile/Containers/Data/Application/00000000-0000-4000-8000-000000000001",
            files: [], estimatedBytes: 0, accessibleScopes: 0,
            failures: 1, truncated: true
        )
        XCTAssertEqual(ForeignCacheCleaner.delete(example).removed, 0)
    }

    func testProtectsDatabasesAndCredentialLikeFilesEvenWithinCacheRoots() {
        for file in ["Chat.sqlite", "Chat.sqlite-wal", "History.db", "Cache.realm",
                     "Settings.plist", "MANIFEST-000001", "LOCK", "000023.ldb",
                     "passwords.keychain"] {
            XCTAssertTrue(ForeignCacheCleaner.isProtectedFile(file), file)
        }
        XCTAssertFalse(ForeignCacheCleaner.isProtectedFile("temporary-image.jpg"))
    }
}
