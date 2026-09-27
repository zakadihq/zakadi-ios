import XCTest

@testable import ZakadiProbe

/// The scaffold's one case: the test bundle builds against the app target.
final class ZakadiProbeTests: XCTestCase {
    func testTheScreenIsMade() {
        XCTAssertNoThrow(ContentView())
    }
}
