import XCTest
@testable import Brewery

@MainActor
final class DependencyViewportTests: XCTestCase {
    func testScaleIsClampedToSupportedRange() {
        XCTAssertEqual(DependencyViewport.clampedScale(0.2), 0.6)
        XCTAssertEqual(DependencyViewport.clampedScale(1.2), 1.2)
        XCTAssertEqual(DependencyViewport.clampedScale(2.4), 1.8)
    }

    func testVisibleRectKeepsCurrentOffset() {
        let offset = DependencyViewport.offsetToReveal(
            contentRect: CGRect(x: 40, y: 40, width: 80, height: 40),
            viewportSize: CGSize(width: 300, height: 200),
            scale: 1,
            currentOffset: CGSize(width: 0, height: 0),
            margin: 16
        )

        XCTAssertEqual(offset, .zero)
    }

    func testOffscreenBottomRectMovesCanvasUpOnlyAsNeeded() {
        let offset = DependencyViewport.offsetToReveal(
            contentRect: CGRect(x: 40, y: 220, width: 80, height: 40),
            viewportSize: CGSize(width: 300, height: 200),
            scale: 1,
            currentOffset: .zero,
            margin: 16
        )

        XCTAssertEqual(offset.height, -76, accuracy: 0.001)
    }
}
