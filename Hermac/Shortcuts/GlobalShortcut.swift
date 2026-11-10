import AppKit
import Carbon
import Observation

struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyName: String

    static let `default` = GlobalShortcut(
        keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey), keyName: "空格"
    )
    static let translationDefault = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | shiftKey), keyName: "T"
    )
    static let modifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    var displayName: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyName
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
        self.keyName = keyName
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let names: [UInt16: String] = [
            UInt16(kVK_Space): "空格", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓"
        ]
        keyName = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func conflicts(with hotKeys: [[String: Any]]) -> Bool {
        hotKeys.contains { hotKey in
            (hotKey[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true
                && (hotKey[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == keyCode
                && ((hotKey[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value ?? 0)
                    & Self.modifierMask == modifiers
        }
    }

    var hasRequiredModifier: Bool {
        modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    // Some system commands are fixed and are not in CopySymbolicHotKeys.
    var isReservedSystemCommand: Bool {
        let command = UInt32(cmdKey)
        let option = UInt32(optionKey)
        let shift = UInt32(shiftKey)
        return (keyCode == UInt32(kVK_Tab) && [command, command | shift].contains(modifiers))
            || (keyCode == UInt32(kVK_Escape) && modifiers == command | option)
            || (keyCode == UInt32(kVK_ANSI_Q) && modifiers == command | UInt32(controlKey))
            || (keyCode == UInt32(kVK_ANSI_Q) && [command | shift, command | option | shift].contains(modifiers))
    }
}

@MainActor @Observable
final class GlobalShortcutController {
    enum Purpose: UInt32 {
        case chat = 1
        case translation = 2

        var storageKey: String {
            self == .chat ? "quickChatShortcut" : "quickTranslationShortcut"
        }
        var defaultShortcut: GlobalShortcut {
            self == .chat ? .default : .translationDefault
        }
    }

    private(set) var shortcut: GlobalShortcut
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?

    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let purpose: Purpose
    private static let signature: OSType = 0x484D4143

    init(purpose: Purpose = .chat, defaults: UserDefaults = .standard) {
        self.purpose = purpose
        self.defaults = defaults
        if let data = defaults.data(forKey: purpose.storageKey),
           let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = purpose.defaultShortcut
            var systemKeys: Unmanaged<CFArray>?
            if CopySymbolicHotKeys(&systemKeys) == noErr,
               let keys = systemKeys?.takeRetainedValue() as? [[String: Any]],
               shortcut.conflicts(with: keys) {
                let fallback = GlobalShortcut(keyCode: shortcut.keyCode,
                                              modifiers: UInt32(controlKey | optionKey | shiftKey), keyName: shortcut.keyName)
                if !fallback.conflicts(with: keys) {
                    shortcut = fallback
                    noticeMessage = "默认组合已被系统使用，现使用 \(fallback.displayName)。"
                }
            }
        }
    }

    func start(action: @escaping () -> Void) {
        self.action = action
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                return MainActor.assumeIsolated {
                    let controller = Unmanaged<GlobalShortcutController>.fromOpaque(context).takeUnretainedValue()
                    guard result == noErr, hotKeyID.signature == GlobalShortcutController.signature,
                          hotKeyID.id == controller.purpose.rawValue else {
                        return OSStatus(eventNotHandledErr)
                    }
                    controller.action?()
                    return noErr
                }
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        }
        if hotKeyRef == nil && !isRecording { register(shortcut) }
    }

    func stop() {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        action = nil
    }

    func beginRecording() {
        unregister()
        errorMessage = nil
        isRecording = true
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        register(shortcut)
    }

    func choose(_ candidate: GlobalShortcut) {
        if let problem = validationMessage(for: candidate) {
            finishWithError(problem)
            return
        }
        if candidate == shortcut, hotKeyRef != nil {
            errorMessage = nil
            isRecording = false
            return
        }
        var candidateRef: EventHotKeyRef?
        let status = RegisterEventHotKey(candidate.keyCode, candidate.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: purpose.rawValue),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidateRef)
        guard status == noErr else {
            finishWithError(registrationMessage(status))
            return
        }
        unregister()
        hotKeyRef = candidateRef
        shortcut = candidate
        if let data = try? JSONEncoder().encode(candidate) { defaults.set(data, forKey: purpose.storageKey) }
        isRecording = false
        errorMessage = nil
        noticeMessage = nil
    }

    func restoreDefault() {
        beginRecording()
        choose(purpose.defaultShortcut)
        if isRecording { cancelRecording() }
    }

    func validationMessage(for candidate: GlobalShortcut) -> String? {
        guard candidate.hasRequiredModifier else { return "请同时按住 ⌃、⌥ 或 ⌘ 中的至少一个修饰键。" }
        if candidate.keyName.isEmpty { return "请选择一个普通按键。" }
        if candidate.isReservedSystemCommand { return "这个组合是 macOS 保留的快捷键，请换一个。" }
        var systemHotKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&systemHotKeys) == noErr,
              let hotKeys = systemHotKeys?.takeRetainedValue() as? [[String: Any]] else {
            return "暂时无法检查 macOS 快捷键，请稍后再试。"
        }
        return candidate.conflicts(with: hotKeys)
            ? "这个组合已被 macOS 的系统快捷键使用，请换一个或先在系统设置中修改。" : nil
    }

    @discardableResult
    private func register(_ candidate: GlobalShortcut) -> Bool {
        if let problem = validationMessage(for: candidate) {
            errorMessage = problem
            return false
        }
        let status = RegisterEventHotKey(candidate.keyCode, candidate.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: purpose.rawValue),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKeyRef)
        if status != noErr {
            errorMessage = registrationMessage(status)
            return false
        }
        errorMessage = nil
        return true
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func finishWithError(_ message: String) {
        isRecording = false
        if hotKeyRef == nil { register(shortcut) }
        errorMessage = message
    }

    private func registrationMessage(_ status: OSStatus) -> String {
        status == eventHotKeyExistsErr
            ? "这个组合已被其他全局快捷键使用，请换一个。"
            : "无法注册这个快捷键，请换一个。"
    }
}
