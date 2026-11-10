import AppKit
import XCTest
@testable import Hermac

@MainActor
final class ComposerEditorTests: XCTestCase {
    private func returnEvent(modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        )!
    }

    func testReturnSubmitsWithoutInsertingNewline() {
        let editor = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.string = "问题"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        var submitted = 0
        editor.submit = { submitted += 1 }

        editor.keyDown(with: returnEvent())

        XCTAssertEqual(submitted, 1)
        XCTAssertEqual(editor.string, "问题")
    }

    func testShiftReturnInsertsNewlineWithoutSubmitting() {
        let editor = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.string = "第一行"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        var submitted = 0
        editor.submit = { submitted += 1 }

        editor.keyDown(with: returnEvent(modifiers: .shift))

        XCTAssertEqual(submitted, 0)
        XCTAssertTrue(editor.string.contains("\n"))
    }

    func testReturnDuringIMECompositionDoesNotSubmit() {
        let editor = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        var submitted = 0
        editor.submit = { submitted += 1 }
        XCTAssertTrue(editor.hasMarkedText())

        editor.keyDown(with: returnEvent())

        XCTAssertEqual(submitted, 0)
    }
}
