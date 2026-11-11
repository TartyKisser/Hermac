import AppKit
import XCTest
@testable import Hermac

final class SelectionContextTests: XCTestCase {
    func testAXBoundsFlipIntoAppKitCoordinatesAcrossDisplayLayouts() {
        XCTAssertEqual(SelectionContextService.appKitRect(fromAX: CGRect(x: 120, y: 100, width: 200, height: 40),
                                                         primaryScreenTop: 900),
                       NSRect(x: 120, y: 760, width: 200, height: 40))
        XCTAssertEqual(SelectionContextService.appKitRect(fromAX: CGRect(x: -800, y: -300, width: 100, height: 60),
                                                         primaryScreenTop: 900),
                       NSRect(x: -800, y: 1140, width: 100, height: 60))
        XCTAssertEqual(SelectionContextService.appKitRect(fromAX: CGRect(x: 0, y: 1000, width: 100, height: 50),
                                                         primaryScreenTop: 900),
                       NSRect(x: 0, y: -150, width: 100, height: 50))
    }

    func testContextDoesNotReadWholeOffscreenOrScrollableDocumentValues() {
        let viewport = NSRect(x: 0, y: 0, width: 800, height: 600)
        let label = NSRect(x: 20, y: 20, width: 200, height: 30)
        XCTAssertTrue(SelectionContextService.mayReadWholeText(role: "AXStaticText", frame: label, clip: viewport))
        XCTAssertFalse(SelectionContextService.mayReadWholeText(role: "AXStaticText",
                                                               frame: NSRect(x: 20, y: -50, width: 200, height: 100),
                                                               clip: viewport))
        XCTAssertFalse(SelectionContextService.mayReadWholeText(role: "AXStaticText",
                                                               frame: NSRect(x: 20, y: 650, width: 200, height: 30),
                                                               clip: viewport))
        for role in ["AXTextArea", "AXTextField", "AXWindow", "AXWebArea"] {
            XCTAssertFalse(SelectionContextService.mayReadWholeText(role: role, frame: label, clip: viewport))
        }
    }

    func testVisibleSnippetsDeduplicateAndRespectUnicodeLengthBudget() {
        var text = VisibleContextText(limit: 14)
        text.append("  周三下午 3 点  ")
        text.append("周三下午 3 点")
        text.append("\n会议室 👨‍👩‍👧‍👦 A\n")
        text.append("不可再加入")
        XCTAssertEqual(text.text, "周三下午 3 点\n会议室 👨‍👩‍👧‍👦")
        XCTAssertEqual(text.text.count, 14)
        XCTAssertTrue(text.isFull)
    }

    func testDocumentContextUsesOnlySmallRangesAroundTheSelection() {
        let ranges = SelectionContextService.surroundingRanges(selection: CFRange(location: 9_000, length: 400),
                                                              totalLength: 100_000)
        XCTAssertEqual(ranges.map(\.location), [7_000, 9_400])
        XCTAssertEqual(ranges.map(\.length), [2_000, 2_000])
        let edge = SelectionContextService.surroundingRanges(selection: CFRange(location: 0, length: 50), totalLength: 70)
        XCTAssertEqual(edge.map(\.location), [50])
        XCTAssertEqual(edge.map(\.length), [20])
        XCTAssertTrue(SelectionContextService.surroundingRanges(selection: CFRange(location: 80, length: 50),
                                                               totalLength: 100).isEmpty)
    }
}
