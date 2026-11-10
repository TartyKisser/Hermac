import XCTest
@testable import Hermac

final class ScreenCaptureTests: XCTestCase {
    func testRetinaCaptureIsBoundedWithoutChangingAspectRatio() {
        let size = ScreenCaptureService.outputSize(width: 5120, height: 2880)
        XCTAssertEqual(size.width, 2048)
        XCTAssertEqual(size.height, 1152)
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.001)
    }

    func testPortraitDisplayKeepsItsOrientationAndSmallDisplayIsNotUpscaled() {
        let portrait = ScreenCaptureService.outputSize(width: 2160, height: 3840)
        XCTAssertEqual(portrait, CGSize(width: 1152, height: 2048))
        XCTAssertEqual(ScreenCaptureService.outputSize(width: 1280, height: 800),
                       CGSize(width: 1280, height: 800))
    }
}
