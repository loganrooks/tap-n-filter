import XCTest
@testable import Effects

final class EffectsTests: XCTestCase {
    func test_module_placeholder_present() {
        XCTAssertFalse(EffectsModule.placeholder.isEmpty)
    }
}
