import XCTest
@testable import Presets

final class PresetsTests: XCTestCase {
    func test_module_placeholder_present() {
        XCTAssertFalse(PresetsModule.placeholder.isEmpty)
    }
}
