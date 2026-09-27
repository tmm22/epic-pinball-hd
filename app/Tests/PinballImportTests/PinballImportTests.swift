import XCTest
@testable import PinballImport

final class PinballImportContractTests: XCTestCase {
    func testDefaultRootIsInApplicationSupport() {
        XCTAssertTrue(LibraryLocation.defaultRoot.path.contains("Application Support/EpicPinballHD"))
    }
}
