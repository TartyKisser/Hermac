import AppKit
import ApplicationServices
import XCTest
@testable import Hermac

final class SelectedTextTests: XCTestCase {
    func testSelectionPreservesParagraphsAndOriginalWhitespace() throws {
        let text = "  First paragraph.\n\nSecond paragraph — with Unicode.  "
        let selected = try SelectedTextService.selectionText(from: text as CFString, status: .success, appName: "Test")
        XCTAssertEqual(selected, text)
    }

    func testEmptySelectionDoesNotStartTranslation() {
        for value in [nil, "" as CFString, " \n\t" as CFString] {
            XCTAssertThrowsError(try SelectedTextService.selectionText(from: value, status: .success, appName: "Test")) {
                XCTAssertEqual($0 as? SelectedTextService.SelectionError, .noSelection)
            }
        }
    }

    func testUnavailableSelectionDistinguishesPermissionsAndUnsupportedApps() {
        let cases: [(AXError, SelectedTextService.SelectionError)] = [
            (.apiDisabled, .permissionRequired),
            (.attributeUnsupported, .unsupportedApplication("Test")),
            (.noValue, .noSelection),
            (.cannotComplete, .readFailed("Test"))
        ]
        for (status, expected) in cases {
            XCTAssertThrowsError(try SelectedTextService.selectionText(from: nil, status: status, appName: "Test")) {
                XCTAssertEqual($0 as? SelectedTextService.SelectionError, expected)
            }
        }
    }

    func testRangeFallbackUsesUTF16OffsetsAndPreservesSelectedFormatting() throws {
        let text = "👋 Prefix\n  English selection.\nSecond line.  尾声"
        let expected = "  English selection.\nSecond line.  "
        let range = (text as NSString).range(of: expected)
        let selected = try SelectedTextService.selectionText(
            in: text, range: CFRange(location: range.location, length: range.length), appName: "Code"
        )
        XCTAssertEqual(selected, expected)
    }

    func testRangeFallbackRejectsStaleOrEmptySelection() {
        for range in [CFRange(location: -1, length: 2), CFRange(location: 0, length: 30),
                      CFRange(location: 10, length: 1)] {
            XCTAssertThrowsError(try SelectedTextService.selectionText(in: "English", range: range, appName: "Code")) {
                XCTAssertEqual($0 as? SelectedTextService.SelectionError, .readFailed("Code"))
            }
        }
        XCTAssertThrowsError(try SelectedTextService.selectionText(in: "English", range: CFRange(location: 0, length: 0), appName: "Code")) {
            XCTAssertEqual($0 as? SelectedTextService.SelectionError, .noSelection)
        }
    }

    func testOnlyVSCodeReadFailuresEnableElectronAccessibility() {
        XCTAssertTrue(SelectedTextService.shouldEnableManualAccessibility(bundleID: "com.microsoft.VSCode", after: .readFailed("Code")))
        XCTAssertTrue(SelectedTextService.shouldEnableManualAccessibility(bundleID: "com.microsoft.VSCodeInsiders", after: .unsupportedApplication("Code")))
        XCTAssertFalse(SelectedTextService.shouldEnableManualAccessibility(bundleID: "com.apple.TextEdit", after: .readFailed("TextEdit")))
        XCTAssertTrue(SelectedTextService.shouldEnableManualAccessibility(bundleID: "com.microsoft.VSCode", after: .noSelection))
        XCTAssertFalse(SelectedTextService.shouldEnableManualAccessibility(bundleID: "com.microsoft.VSCode", after: .permissionRequired))
    }

    func testCodeStatusRequiresARealNonemptySelection() {
        XCTAssertEqual(SelectedTextService.codeSelectionCount(from: "Ln 3, Col 1 (806 selected)"), 806)
        XCTAssertEqual(SelectedTextService.codeSelectionCount(from: "2 selections (1,240 characters selected)"), 1240)
        XCTAssertEqual(SelectedTextService.codeSelectionCount(from: "行 3，列 1 (已选择806)"), 806)
        XCTAssertEqual(SelectedTextService.codeSelectionCount(from: "2 选择(已选择 806 个字符)"), 806)
        for label in ["Ln 3, Col 1", "2 selections", "Ln 3, Col 1 (0 selected)",
                      "Copied 806 selected characters", "Ln 3, Col 1 (806 selected) inside document"] {
            XCTAssertNil(SelectedTextService.codeSelectionCount(from: label))
        }
    }

    func testCopiedCodeTextChecksUTF16CountAndRetainsLineEndings() throws {
        let text = "👋 English.\r\n  Second line.  "
        let normalizedCount = text.replacingOccurrences(of: "\r\n", with: "\n").utf16.count
        XCTAssertEqual(try SelectedTextService.copiedCodeText(text, selectedCount: text.utf16.count,
                                                            metadata: nil, appName: "Code"), text)
        XCTAssertEqual(try SelectedTextService.copiedCodeText(text, selectedCount: normalizedCount,
                                                            metadata: nil, appName: "Code"), text)
        XCTAssertThrowsError(try SelectedTextService.copiedCodeText(text, selectedCount: 4,
                                                                  metadata: nil, appName: "Code"))
        let emptySelectionMetadata = Data(#"{"version":1,"isFromEmptySelection":true}"#.utf8)
        XCTAssertThrowsError(try SelectedTextService.copiedCodeText("Current line", selectedCount: 12,
                                                                  metadata: emptySelectionMetadata, appName: "Code")) {
            XCTAssertEqual($0 as? SelectedTextService.SelectionError, .noSelection)
        }
    }

    @MainActor
    func testCopyFallbackRestoresAllClipboardRepresentationsAndItems() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("com.hermac.test.selection")
        let first = NSPasteboardItem()
        first.setString("Original clipboard", forType: .string)
        first.setData(Data([1, 2, 255]), forType: customType)
        let second = NSPasteboardItem()
        second.setData(Data([5, 6]), forType: customType)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let snapshot = try XCTUnwrap(SelectedTextService.PasteboardSnapshot(pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("Copied selection", forType: .string)
        XCTAssertTrue(snapshot.restore(to: pasteboard, ifUnchanged: pasteboard.changeCount))
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "Original clipboard")
        XCTAssertEqual(items[0].data(forType: customType), Data([1, 2, 255]))
        XCTAssertEqual(items[1].data(forType: customType), Data([5, 6]))
    }

    @MainActor
    func testCopyFallbackDoesNotOverwriteANewerClipboardChange() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original clipboard", forType: .string)
        let snapshot = try XCTUnwrap(SelectedTextService.PasteboardSnapshot(pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("Copied selection", forType: .string)
        let copiedCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("New user copy", forType: .string)
        XCTAssertFalse(snapshot.restore(to: pasteboard, ifUnchanged: copiedCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "New user copy")
    }
}
