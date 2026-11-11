import AppKit
import Carbon
import XCTest
@testable import Hermac

@MainActor
final class GlobalShortcutTests: XCTestCase {
    func testModifierNormalizationIgnoresCapsLockFunctionAndNumericPad() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .capsLock, .function, .numericPad]
        XCTAssertEqual(GlobalShortcut.carbonModifiers(from: flags), UInt32(controlKey | optionKey | shiftKey))
        XCTAssertEqual(GlobalShortcut.default.modifiers, UInt32(controlKey | shiftKey))
        XCTAssertEqual(GlobalShortcut.translationDefault.keyCode, UInt32(kVK_ANSI_T))
        XCTAssertEqual(GlobalShortcut.reminderDefault.keyCode, UInt32(kVK_ANSI_R))
        XCTAssertEqual(Set([GlobalShortcut.default.keyCode, GlobalShortcut.translationDefault.keyCode,
                            GlobalShortcut.reminderDefault.keyCode]).count, 3)
    }

    func testOnlyMatchingEnabledSystemShortcutsConflict() {
        let chord = GlobalShortcut.default
        let systemKey: [String: Any] = [
            kHISymbolicHotKeyCode as String: NSNumber(value: chord.keyCode),
            kHISymbolicHotKeyModifiers as String: NSNumber(value: chord.modifiers),
            kHISymbolicHotKeyEnabled as String: true
        ]
        XCTAssertTrue(chord.conflicts(with: [systemKey]))
        var disabled = systemKey
        disabled[kHISymbolicHotKeyEnabled as String] = false
        XCTAssertFalse(chord.conflicts(with: [disabled]))
        var otherModifiers = systemKey
        otherModifiers[kHISymbolicHotKeyModifiers as String] = NSNumber(value: UInt32(controlKey | optionKey))
        XCTAssertFalse(chord.conflicts(with: [otherModifiers]))
    }

    func testReservedSystemCombinationsAreRejected() {
        XCTAssertTrue(GlobalShortcut(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey), keyName: "⇥").isReservedSystemCommand)
        XCTAssertTrue(GlobalShortcut(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | optionKey), keyName: "Esc").isReservedSystemCommand)
        XCTAssertTrue(GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | shiftKey), keyName: "Q").isReservedSystemCommand)
        XCTAssertTrue(GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | optionKey | shiftKey), keyName: "Q").isReservedSystemCommand)
        XCTAssertFalse(GlobalShortcut.default.isReservedSystemCommand)
        XCTAssertFalse(GlobalShortcut(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), keyName: "⇥").isReservedSystemCommand)
    }

    func testEscapeCancelsRecordingWithoutChangingSavedShortcut() throws {
        let (controller, defaults, suite) = makeController()
        defer { controller.stop(); defaults.removePersistentDomain(forName: suite) }
        let original = controller.shortcut
        controller.beginRecording()
        let capture = ShortcutCaptureView()
        capture.isRecording = true
        capture.onCancel = { controller.cancelRecording() }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                   modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil,
                                                   characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                                   isARepeat: false, keyCode: UInt16(kVK_Escape)))
        capture.keyDown(with: escape)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.shortcut, original)
        XCTAssertNil(defaults.data(forKey: "quickChatShortcut"))
    }

    func testRecordingConsumesCommandKeyEquivalentBeforeMenus() throws {
        let capture = ShortcutCaptureView()
        capture.isRecording = true
        var recorded: GlobalShortcut?
        capture.onShortcut = { recorded = $0 }
        let commandN = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                     modifierFlags: [.command], timestamp: 0,
                                                     windowNumber: 0, context: nil,
                                                     characters: "n", charactersIgnoringModifiers: "n",
                                                     isARepeat: false, keyCode: UInt16(kVK_ANSI_N)))
        XCTAssertTrue(capture.performKeyEquivalent(with: commandN))
        XCTAssertEqual(recorded?.keyCode, UInt32(kVK_ANSI_N))
        XCTAssertEqual(recorded?.modifiers, UInt32(cmdKey))
    }

    func testFailedRegistrationKeepsPreviousShortcutRegistered() throws {
        let (first, firstDefaults, firstSuite) = makeController()
        let (second, secondDefaults, secondSuite) = makeController()
        defer {
            first.stop(); second.stop()
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let occupied = GlobalShortcut(keyCode: UInt32(kVK_F18), modifiers: modifiers, keyName: "F18")
        let original = GlobalShortcut(keyCode: UInt32(kVK_F19), modifiers: modifiers, keyName: "F19")
        first.choose(occupied)
        second.choose(original)
        XCTAssertNil(first.errorMessage)
        XCTAssertNil(second.errorMessage)
        second.beginRecording()
        second.choose(occupied)
        XCTAssertEqual(second.shortcut, original)
        XCTAssertNotNil(second.errorMessage)
        XCTAssertFalse(second.isRecording)

        var probe: EventHotKeyRef?
        let status = RegisterEventHotKey(original.keyCode, original.modifiers,
                                        EventHotKeyID(signature: 0x54455354, id: 99),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &probe)
        if let probe { UnregisterEventHotKey(probe) }
        XCTAssertEqual(status, OSStatus(eventHotKeyExistsErr), "The original shortcut must remain registered")
    }

    func testAllThreePurposesReadIndependentSavedShortcuts() throws {
        let suite = "HermacShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let chat = GlobalShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | shiftKey), keyName: "J")
        let translation = GlobalShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey | shiftKey), keyName: "Y")
        let reminder = GlobalShortcut(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(controlKey | shiftKey), keyName: "U")
        defaults.set(try JSONEncoder().encode(chat), forKey: "quickChatShortcut")
        defaults.set(try JSONEncoder().encode(translation), forKey: "quickTranslationShortcut")
        defaults.set(try JSONEncoder().encode(reminder), forKey: "quickReminderShortcut")

        XCTAssertEqual(GlobalShortcutController(defaults: defaults).shortcut, chat)
        XCTAssertEqual(GlobalShortcutController(purpose: .translation, defaults: defaults).shortcut, translation)
        XCTAssertEqual(GlobalShortcutController(purpose: .reminder, defaults: defaults).shortcut, reminder)
    }

    func testTranslationRejectsChatShortcutAndKeepsItsOwnRegistration() {
        let (chat, chatDefaults, chatSuite) = makeController()
        let (translation, translationDefaults, translationSuite) = makeController(purpose: .translation)
        defer {
            chat.stop(); translation.stop()
            chatDefaults.removePersistentDomain(forName: chatSuite)
            translationDefaults.removePersistentDomain(forName: translationSuite)
        }
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let chatKey = GlobalShortcut(keyCode: UInt32(kVK_F16), modifiers: modifiers, keyName: "F16")
        let translationKey = GlobalShortcut(keyCode: UInt32(kVK_F17), modifiers: modifiers, keyName: "F17")
        chat.choose(chatKey)
        translation.choose(translationKey)
        XCTAssertNil(chat.errorMessage)
        XCTAssertNil(translation.errorMessage)
        translation.beginRecording()
        translation.choose(chatKey)
        XCTAssertEqual(translation.shortcut, translationKey)
        XCTAssertNotNil(translation.errorMessage)

        var probe: EventHotKeyRef?
        let status = RegisterEventHotKey(translationKey.keyCode, translationKey.modifiers,
                                        EventHotKeyID(signature: 0x54455354, id: 100),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &probe)
        if let probe { UnregisterEventHotKey(probe) }
        XCTAssertEqual(status, OSStatus(eventHotKeyExistsErr))
    }

    func testCarbonEventsOnlyInvokeTheMatchingShortcutPurpose() throws {
        let (chat, chatDefaults, chatSuite) = makeController()
        let (translation, translationDefaults, translationSuite) = makeController(purpose: .translation)
        let (reminder, reminderDefaults, reminderSuite) = makeController(purpose: .reminder)
        defer {
            chat.stop(); translation.stop(); reminder.stop()
            chatDefaults.removePersistentDomain(forName: chatSuite)
            translationDefaults.removePersistentDomain(forName: translationSuite)
            reminderDefaults.removePersistentDomain(forName: reminderSuite)
        }
        var chatCalls = 0
        var translationCalls = 0
        var reminderCalls = 0
        chat.start { chatCalls += 1 }
        translation.start { translationCalls += 1 }
        reminder.start { reminderCalls += 1 }

        func dispatch(id: UInt32) throws {
            var rawEvent: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                       GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &rawEvent), noErr)
            let event = try XCTUnwrap(rawEvent)
            defer { ReleaseEvent(event) }
            var key = EventHotKeyID(signature: 0x484D4143, id: id)
            XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &key), noErr)
            _ = SendEventToEventTarget(event, GetApplicationEventTarget())
        }

        try dispatch(id: 1)
        XCTAssertEqual(chatCalls, 1)
        XCTAssertEqual(translationCalls, 0)
        try dispatch(id: 2)
        XCTAssertEqual(chatCalls, 1)
        XCTAssertEqual(translationCalls, 1)
        XCTAssertEqual(reminderCalls, 0)
        try dispatch(id: 3)
        XCTAssertEqual(chatCalls, 1)
        XCTAssertEqual(translationCalls, 1)
        XCTAssertEqual(reminderCalls, 1)
        try dispatch(id: 99)
        XCTAssertEqual(chatCalls, 1)
        XCTAssertEqual(translationCalls, 1)
        XCTAssertEqual(reminderCalls, 1)
    }

    private func makeController(purpose: GlobalShortcutController.Purpose = .chat) -> (GlobalShortcutController, UserDefaults, String) {
        let suite = "HermacShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (GlobalShortcutController(purpose: purpose, defaults: defaults), defaults, suite)
    }
}
