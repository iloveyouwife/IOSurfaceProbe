import XCTest
@testable import CacheGuard

final class CacheTraversalProbeTests: XCTestCase {
    func testOnlyAppDataContainerRootIsEligible() {
        XCTAssertTrue(CacheTraversalProbe.validateAppRoot(
            "/var/mobile/Containers/Data/Application/00000000-0000-4000-8000-000000000001"
        ))
        XCTAssertFalse(CacheTraversalProbe.validateAppRoot("/var/mobile/Library"))
        XCTAssertFalse(CacheTraversalProbe.validateAppRoot("/var/mobile/Containers/Data/Application/not-a-uuid"))
        XCTAssertFalse(CacheTraversalProbe.validateAppRoot(
            "/var/mobile/Containers/Data/Application/00000000-0000-4000-8000-000000000001/Library/Caches"
        ))
    }

    func testAllowlistContainsOnlyDisposableRoots() {
        XCTAssertEqual(CacheTraversalProbe.eligibleDirectories, ["Library/Caches", "tmp"])
    }
}
