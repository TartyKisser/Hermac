import AppKit
import SwiftUI
import XCTest
@testable import Hermac

@MainActor
final class ComposerInputMethodTests: XCTestCase {
    func testChinesePreeditUpdatesDraftBindingBeforeConversionCommits() {
        var draft = ""
        var height: CGFloat = 26
        let bridge = ComposerEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            height: Binding(get: { height }, set: { height = $0 }),
            enabled: true, submit: {}
        )
        let coordinator = bridge.makeCoordinator()
        let editor = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.delegate = coordinator

        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(draft, "nihao", "Preedit must hide the placeholder before conversion commits")
        XCTAssertTrue(editor.hasMarkedText())
        editor.synchronizeText(draft)
        XCTAssertTrue(editor.hasMarkedText())

        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(draft, "你好")
        XCTAssertFalse(editor.hasMarkedText())
    }

    func testExternalRefreshPreservesChinesePreeditAndMarkedRange() {
        let editor = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.string = "帮我"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedRange = editor.markedRange()

        editor.synchronizeText("帮我")

        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertEqual(editor.string, "帮我nihao")
    }

    func testExternalClearResumesAfterChineseConversionCommits() {
        let editor = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "你好")

        editor.synchronizeText("")

        XCTAssertTrue(editor.string.isEmpty)
    }
}
