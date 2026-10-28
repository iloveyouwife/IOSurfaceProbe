import XCTest
@testable import CacheGuard

final class CachePolicyTests: XCTestCase {
    func testOwnCacheWithinRoot() {
        let root = URL(fileURLWithPath: "/test/app/Library/Caches", isDirectory: true)
        XCTAssertTrue(CachePolicy.isEligible(
            root.appendingPathComponent("image.jpg"), root: root, source: .ownCaches
        ))
    }

    func testCannotDeleteOutsideRoot() {
        let root = URL(fileURLWithPath: "/test/app/Library/Caches", isDirectory: true)
        let outside = URL(fileURLWithPath: "/test/app/Documents/photo.jpg")
        XCTAssertFalse(CachePolicy.isEligible(outside, root: root, source: .ownCaches))
    }

    func testRejectsTraversal() {
        let root = URL(fileURLWithPath: "/test/app/Library/Caches", isDirectory: true)
        let traversal = root.appendingPathComponent("../Documents/photo.jpg")
        XCTAssertFalse(CachePolicy.isEligible(traversal, root: root, source: .ownCaches))
    }

    func testExternalOnlyMarkedCacheFolders() {
        let root = URL(fileURLWithPath: "/test/selected", isDirectory: true)
        XCTAssertTrue(CachePolicy.isEligible(
            root.appendingPathComponent("Caches/thumb.jpg"), root: root, source: .chosenFolder
        ))
        XCTAssertFalse(CachePolicy.isEligible(
            root.appendingPathComponent("photos/photo.jpg"), root: root, source: .chosenFolder
        ))
    }

    func testProtectsDatabasesAndDocuments() {
        let root = URL(fileURLWithPath: "/test/selected", isDirectory: true)
        XCTAssertFalse(CachePolicy.isEligible(
            root.appendingPathComponent("Caches/messages.sqlite"), root: root, source: .chosenFolder
        ))
        XCTAssertFalse(CachePolicy.isEligible(
            root.appendingPathComponent("Documents/Caches/irreplaceable.jpg"), root: root, source: .chosenFolder
        ))
        XCTAssertFalse(CachePolicy.isEligible(
            root.appendingPathComponent("Caches/history.db-wal"), root: root, source: .chosenFolder
        ))
    }
}
