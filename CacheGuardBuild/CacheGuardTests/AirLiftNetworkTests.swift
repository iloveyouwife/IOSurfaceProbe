import XCTest
@testable import CacheGuard

final class AirLiftNetworkTests: XCTestCase {
    func testPermitsLocalVpnAndWifiAddresses() {
        XCTAssertTrue(AirLiftNetwork.isLocalIPv4("10.7.0.1"))
        XCTAssertTrue(AirLiftNetwork.isLocalIPv4("192.168.1.8"))
        XCTAssertTrue(AirLiftNetwork.isLocalIPv4("172.20.0.1"))
        XCTAssertTrue(AirLiftNetwork.isLocalIPv4("127.0.0.1"))
    }

    func testRejectsPublicOrMalformedAddresses() {
        XCTAssertFalse(AirLiftNetwork.isLocalIPv4("8.8.8.8"))
        XCTAssertFalse(AirLiftNetwork.isLocalIPv4("example.com"))
        XCTAssertFalse(AirLiftNetwork.isLocalIPv4("10.7.0.999"))
        XCTAssertFalse(AirLiftNetwork.isLocalIPv4("10.7.0.1:8080"))
    }
}
