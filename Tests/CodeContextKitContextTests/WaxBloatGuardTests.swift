import XCTest
@testable import CodeContextKitRetrieval

final class WaxBloatGuardTests: XCTestCase {
    func testBreachesPastFactor() {
        // 20 GB file against a 1 GB live estimate at 10x.
        XCTAssertTrue(WaxBloatGuard.isBreached(
            fileBytes: 20_000_000_000,
            expectedLiveBytes: 1_000_000_000,
            factor: 10
        ))
    }

    func testDoesNotBreachWithinFactor() {
        XCTAssertFalse(WaxBloatGuard.isBreached(
            fileBytes: 5_000_000_000,
            expectedLiveBytes: 1_000_000_000,
            factor: 10
        ))
    }

    func testZeroLiveBytesNeverBreaches() {
        // Unusable live estimate (fresh store) must not trip the breaker.
        XCTAssertFalse(WaxBloatGuard.isBreached(
            fileBytes: 500_000_000,
            expectedLiveBytes: 0,
            factor: 10
        ))
    }

    func testNonPositiveFactorDisablesBreaker() {
        XCTAssertFalse(WaxBloatGuard.isBreached(
            fileBytes: 999_999_999_999,
            expectedLiveBytes: 1,
            factor: 0
        ))
    }

    func testDefaultFactorMatchesAsk() {
        XCTAssertEqual(WaxBloatGuard.defaultFactor, 10.0)
    }
}
