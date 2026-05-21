import XCTest
@testable import Graph

final class GraphTests: XCTestCase {
    func test_module_placeholder_present() {
        XCTAssertFalse(GraphModule.placeholder.isEmpty)
    }
}
