import XCTest
import CoreGraphics
@testable import Hermac

@MainActor
final class RecentContextCaptureTests: XCTestCase {
    func testWindowMatchingRequiresTheOriginalFrameAndAvoidsAmbiguousWindows() {
        let frame = NSRect(x: -800, y: 100, width: 800, height: 600)
        let windows = [
            RecentContextCaptureService.WindowCandidate(id: 10, title: "聊天", frame: frame),
            .init(id: 20, title: "聊天", frame: frame.offsetBy(dx: 900, dy: 0))
        ]
        XCTAssertEqual(RecentContextCaptureService.matchingWindowID(windows, title: "聊天", frame: frame, anchor: nil), 10)
        XCTAssertNil(RecentContextCaptureService.matchingWindowID(windows, title: "聊天", frame: nil, anchor: nil))
        XCTAssertNil(RecentContextCaptureService.matchingWindowID(windows, title: "聊天", frame: frame.offsetBy(dx: 0, dy: 80), anchor: nil))
    }

    func testCropCoordinatesConvertAppKitToImagePixels() {
        let window = NSRect(x: -1000, y: 200, width: 800, height: 600)
        let region = NSRect(x: -800, y: 400, width: 400, height: 200)
        XCTAssertEqual(RecentContextCaptureService.pixelRect(region, in: window, imageWidth: 1600, imageHeight: 1200),
                       CGRect(x: 400, y: 400, width: 800, height: 400))
        let tracking = RecentContextCaptureService.trackingRect(window: window,
                                                                anchor: NSPoint(x: -250, y: 500), hasViewport: false)
        XCTAssertTrue(window.contains(tracking))
        XCTAssertGreaterThan(tracking.minY, window.minY)
        XCTAssertLessThan(tracking.maxY, window.maxY)
        XCTAssertLessThan(tracking.width, window.width)
    }

    func testRecentTextKeepsReadingOrderDeduplicatesAndPrioritizesCurrentScreen() {
        typealias Line = RecentContextCaptureService.OCRLine
        let pages = [[Line(text: "重叠文字", box: .zero), Line(text: "最新内容", box: .zero)],
                     [Line(text: "较早内容", box: .zero), Line(text: "重叠文字", box: .zero)]]
        let result = RecentContextCaptureService.combinedText(pages)
        XCTAssertEqual(result.components(separatedBy: "重叠文字").count, 2)
        XCTAssertLessThan(result.range(of: "较早内容")!.lowerBound, result.range(of: "最新内容")!.lowerBound)
        let bounded = RecentContextCaptureService.combinedText(pages, limit: 20)
        XCTAssertLessThanOrEqual(bounded.count, 20)
        XCTAssertTrue(bounded.contains("当前选区"))
    }

    func testMatchingOCRLinesMeasureMotionWithoutStaticChrome() {
        typealias Line = RecentContextCaptureService.OCRLine
        let old = [Line(text: "第一条独特消息", box: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.03)),
                   Line(text: "第二条独特消息", box: CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.03)),
                   Line(text: "固定菜单标签", box: CGRect(x: 0.1, y: 0.95, width: 0.2, height: 0.02))]
        let new = old.map { line in
            Line(text: line.text, box: line.text == "固定菜单标签" ? line.box : line.box.offsetBy(dx: 0, dy: -0.18))
        }
        let motion = RecentContextCaptureService.textTranslation(from: old, to: new,
                                                                 region: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.8))
        XCTAssertEqual(motion ?? 0, -0.18, accuracy: 0.001)
        XCTAssertEqual(RecentContextCaptureService.scrollDistance(translationPixels: -90, imageHeight: 500, viewportHeight: 1000), 180)
    }

    func testStaticOCRLabelsDoNotHideImageMotion() {
        XCTAssertEqual(RecentContextCaptureService.resolvedMovement(ocrMotion: 0, imageMotion: 240), 240)
        XCTAssertNil(RecentContextCaptureService.resolvedMovement(ocrMotion: 0, imageMotion: nil))
        XCTAssertEqual(RecentContextCaptureService.resolvedMovement(ocrMotion: 0, imageMotion: 0), 0)
        XCTAssertEqual(RecentContextCaptureService.resolvedMovement(ocrMotion: 180, imageMotion: nil), 180)
    }

    func testPixelScrollEventHasSourceLocationAndNoInheritedModifiers() throws {
        // Construct only: this test never posts an event to the user's desktop.
        let event = try XCTUnwrap(RecentContextCaptureService.makeScrollEvent(180,
                                                                            at: CGPoint(x: -350, y: 400), top: 900))
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.location, CGPoint(x: -350, y: 500))
        XCTAssertTrue(event.flags.isEmpty)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 180)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertNotEqual(event.getIntegerValueField(.eventSourceUserData), 0)
    }

    func testRestorationReplaysRequestedStepsWithoutMergingOrImageScaling() {
        XCTAssertEqual(RecentContextCaptureService.restorationSteps(from: [316, 316]), [-316, -316])
        XCTAssertEqual(RecentContextCaptureService.restorationSteps(from: [120, 240]), [-240, -120])
        XCTAssertTrue(RecentContextCaptureService.restorationSteps(from: []).isEmpty)
    }

    func testRestorationAnchorPrefersSelectionOverStaticLabels() throws {
        typealias Line = RecentContextCaptureService.OCRLine
        let message = CGRect(x: 0.55, y: 0.4, width: 0.35, height: 0.04)
        let lines = [Line(text: "文件传输助手", box: CGRect(x: 0.05, y: 0.85, width: 0.2, height: 0.04)),
                     Line(text: "明天 下午三点开会", box: message),
                     Line(text: "重复文字", box: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.04)),
                     Line(text: "重复文字", box: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.04))]
        let anchor = try XCTUnwrap(RecentContextCaptureService.restorationAnchor(in: lines,
                                                                               selectedText: "明天下午三点开会", point: CGPoint(x: 0.1, y: 0.9)))
        XCTAssertEqual(anchor.box, message)
        XCTAssertEqual(anchor.text, "明天下午三点开会")
    }

    func testRestorationRequiresTheOriginalAnchorPosition() {
        let anchor = RecentContextCaptureService.TextAnchor(text: "选中的日程要求",
                                                            box: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.04))
        let lines = [RecentContextCaptureService.OCRLine(text: "选中的日程要求", box: anchor.box.offsetBy(dx: 0, dy: -0.1))]
        let drift = RecentContextCaptureService.anchorDisplacement(anchor, in: lines)
        XCTAssertEqual(drift?.y ?? 0, -0.1, accuracy: 0.001)
        let viewport = CGSize(width: 800, height: 600)
        XCTAssertFalse(RecentContextCaptureService.restorationVerified(anchor: anchor, drift: drift,
                                                                       viewport: viewport, imageDifference: 0))
        XCTAssertFalse(RecentContextCaptureService.restorationVerified(anchor: anchor, drift: nil,
                                                                       viewport: viewport, imageDifference: 0))
        XCTAssertTrue(RecentContextCaptureService.restorationVerified(anchor: anchor, drift: CGPoint(x: 0, y: 0.004),
                                                                      viewport: viewport, imageDifference: 0.2))
        XCTAssertTrue(RecentContextCaptureService.restorationVerified(anchor: nil, drift: nil,
                                                                      viewport: viewport, imageDifference: 0.0002))
        let nearbyLabel = RecentContextCaptureService.TextAnchor(text: "固定侧栏文字", box: anchor.box, isSelection: false)
        XCTAssertFalse(RecentContextCaptureService.restorationVerified(anchor: nearbyLabel, drift: .zero,
                                                                       viewport: viewport, imageDifference: 0.2))
    }

    func testSmallCorrectionFollowsBottomLeftOCRCoordinates() {
        XCTAssertEqual(RecentContextCaptureService.correctionDistance(normalizedDrift: -0.1, viewportHeight: 600), -60)
        XCTAssertEqual(RecentContextCaptureService.correctionDistance(normalizedDrift: 0.08, viewportHeight: 600), 48)
        XCTAssertEqual(RecentContextCaptureService.correctionDistance(normalizedDrift: 0.8, viewportHeight: 600), 140)
        XCTAssertNil(RecentContextCaptureService.correctionDistance(normalizedDrift: 0.001, viewportHeight: 600))
    }

    func testSyntheticImageRegistrationReportsPixelDisplacement() async throws {
        let reference = try patternImage()
        let shifted = try XCTUnwrap(CGContext(data: nil, width: 320, height: 480, bitsPerComponent: 8,
                                             bytesPerRow: 320, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        shifted.setFillColor(gray: 1, alpha: 1)
        shifted.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        shifted.draw(reference, in: CGRect(x: 0, y: 56, width: 320, height: 480))
        let image = try XCTUnwrap(shifted.makeImage())
        let measured = try await RecentContextCaptureService.translation(from: reference, to: image,
                                                                        region: CGRect(x: 0, y: 0, width: 320, height: 480))
        let pixels = try XCTUnwrap(measured)
        // The returned alignment reverses the generated +56-pixel shift.
        XCTAssertEqual(pixels, -56, accuracy: 3)
        XCTAssertEqual(RecentContextCaptureService.scrollDistance(translationPixels: pixels, imageHeight: 480, viewportHeight: 240),
                       28, accuracy: 1.5)
    }

    private func patternImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 480, bitsPerComponent: 8,
                                             bytesPerRow: 320, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        for index in 0..<80 {
            let x = CGFloat((index * 79 + 17) % 270)
            let y = CGFloat((index * 113 + 29) % 420)
            context.setFillColor(gray: CGFloat(index % 5) / 8, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: CGFloat(12 + index % 31), height: CGFloat(3 + index % 11)))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
