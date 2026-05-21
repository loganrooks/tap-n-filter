import XCTest
@testable import Capture

final class CaptureTests: XCTestCase {
    func test_module_placeholder_present() {
        XCTAssertFalse(CaptureModule.placeholder.isEmpty)
    }
}
