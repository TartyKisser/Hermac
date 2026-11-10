import AppKit
@preconcurrency import ApplicationServices
import OSLog

enum SelectedTextService {
    private static let diagnostics = Logger(subsystem: "dev.hermac.app", category: "SelectedText")
    struct Selection: Equatable {
        let text: String
        let appName: String
    }

    enum SelectionError: LocalizedError, Equatable {
        case permissionRequired
        case noSelection
        case unsupportedApplication(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                "请在系统设置的“隐私与安全性 → 辅助功能”中允许 Hermac 读取所选文本，授权后重新选中文本并触发翻译快捷键。"
            case .noSelection:
                "请先选中要翻译的英文文本，再按翻译快捷键。"
            case .unsupportedApplication(let name):
                "\(name) 没有向 macOS 提供当前所选文本，请尝试在支持文本选择的应用中翻译。"
            case .readFailed(let name):
                "暂时无法读取\(name)中的所选文本，请重新选择后再试。"
            }
        }
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// macOS presents its own permission prompt; approval is asynchronous.
    @MainActor
    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Call directly from the hot-key handler, before showing or activating a
    /// Hermac window, so the source application's selection remains focused.
    @MainActor
    static func capture() async throws -> Selection {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw SelectionError.noSelection
        }
        return try await capture(from: application)
    }

    /// The caller captures this application synchronously in the hot-key event.
    @MainActor
    static func capture(from application: NSRunningApplication) async throws -> Selection {
        let name = application.localizedName ?? "当前应用"
        diagnostics.notice("Capture source=\(application.bundleIdentifier ?? "unknown", privacy: .public)")
        guard hasPermission else { throw SelectionError.permissionRequired }
        let pid = application.processIdentifier
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw SelectionError.readFailed(name)
        }
        do {
            return Selection(text: try readSelection(appElement, pid: pid, appName: name), appName: name)
        } catch let initialError as SelectionError {
            diagnostics.notice("AX selection failed: \(String(describing: initialError), privacy: .public)")
            let isCode = application.bundleIdentifier?.hasPrefix("com.microsoft.VSCode") == true
            if !isCode {
                switch initialError {
                case .readFailed, .unsupportedApplication:
                    return Selection(text: try await copySelection(count: nil, pid: pid, appName: name), appName: name)
                case .noSelection, .permissionRequired:
                    throw initialError
                }
            }
            // With accessibility support disabled, Monaco omits selections of
            // 500+ characters from its text client. Its status item still tells
            // us whether a real selection exists, so Copy cannot grab a line.
            if initialError != .permissionRequired,
               isCode,
               let count = codeSelectionCount(appElement, pid: pid) {
                return Selection(text: try await copySelection(count: count, pid: pid, appName: name), appName: name)
            }
            guard shouldEnableManualAccessibility(bundleID: application.bundleIdentifier, after: initialError) else {
                throw initialError
            }
            // Electron documents this attribute for third-party assistive clients.
            // It enables the runtime AX tree; it does not edit VS Code settings.
            let attribute = "AXManualAccessibility" as CFString
            var enabled: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(appElement, attribute, &enabled)
            if (enabled as? Bool) != true {
                guard AXUIElementSetAttributeValue(appElement, attribute, kCFBooleanTrue) == .success else {
                    throw initialError
                }
            }
            // Electron debounces AX tree activation for two seconds. Do not
            // turn its shared accessibility mode off after reading the selection.
            let deadline = Date().addingTimeInterval(3)
            var lastError = initialError
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    throw SelectionError.readFailed(name)
                }
                do {
                    return Selection(text: try readSelection(appElement, pid: pid, appName: name), appName: name)
                } catch let error as SelectionError {
                    if error == .permissionRequired { throw error }
                    lastError = error
                }
            } while Date() < deadline
            if let count = codeSelectionCount(appElement, pid: pid) {
                return Selection(text: try await copySelection(count: count, pid: pid, appName: name), appName: name)
            }
            throw lastError
        }
    }

    /// Find only the editor's selection status, without reading document values.
    @MainActor
    private static func codeSelectionCount(_ application: AXUIElement, pid: pid_t) -> Int? {
        var windowValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard status == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            diagnostics.notice("Code window unavailable: \(status.rawValue)")
            return nil
        }
        var queue: [(AXUIElement, Int)] = [(windowValue as! AXUIElement, 0)]
        var cursor = 0
        var roleErrors: [Int32: Int] = [:]
        var identifierErrors: [Int32: Int] = [:]
        var childrenErrors: [Int32: Int] = [:]
        let deadline = Date().addingTimeInterval(1)
        while cursor < queue.count, cursor < 400, Date() < deadline {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            let (element, depth) = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            var roleValue: CFTypeRef?
            let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            if roleStatus != .success { roleErrors[roleStatus.rawValue, default: 0] += 1 }
            let role = roleValue as? String
            var isSelectionItem = false
            // Optional Chromium identifiers are not supported by every node.
            // A failed identifier query must not cut off the node's children.
            for attribute in [kAXIdentifierAttribute, "AXDOMIdentifier"] {
                var identifier: CFTypeRef?
                let identifierStatus = AXUIElementCopyAttributeValue(element, attribute as CFString, &identifier)
                if identifierStatus != .success { identifierErrors[identifierStatus.rawValue, default: 0] += 1 }
                if identifierStatus == .success,
                   identifier as? String == "status.editor.selection" {
                    isSelectionItem = true
                    break
                }
            }
            // Electron exposes status items as buttons below generic groups;
            // they need not be inside an AXToolbar. Match the complete official
            // status label rather than arbitrary editor text containing numbers.
            if isSelectionItem || role == kAXButtonRole {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                       let label = value as? String, let count = codeSelectionCount(from: label) {
                        diagnostics.notice("Code selection count=\(count), visited=\(cursor)")
                        return count
                    }
                }
            }
            guard depth < 12, queue.count < 400,
                  role != kAXTextAreaRole, role != kAXTextFieldRole,
                  role != kAXStaticTextRole, role != kAXImageRole else { continue }
            for attribute in [kAXChildrenAttribute, kAXContentsAttribute] {
                var children: CFTypeRef?
                let childrenStatus = AXUIElementCopyAttributeValue(element, attribute as CFString, &children)
                if childrenStatus != .success { childrenErrors[childrenStatus.rawValue, default: 0] += 1 }
                if childrenStatus == .success,
                   let children = children as? [AXUIElement], !children.isEmpty {
                    queue.append(contentsOf: children.prefix(400 - queue.count).map { ($0, depth + 1) })
                    break
                }
            }
        }
        diagnostics.notice("Code selection status missing, visited=\(cursor), queued=\(queue.count)")
        diagnostics.notice("Code AX scan errors role=\(String(describing: roleErrors), privacy: .public), identifier=\(String(describing: identifierErrors), privacy: .public), children=\(String(describing: childrenErrors), privacy: .public)")
        return nil
    }

    static func codeSelectionCount(from label: String) -> Int? {
        // VS Code's single- and multi-selection labels, in English and Chinese.
        let patterns = [
            #"^Ln [0-9,]+, Col [0-9,]+ \(([0-9,]+) selected\)$"#,
            #"^[0-9,]+ selections \(([0-9,]+) characters selected\)$"#,
            #"^行 [0-9,]+，列 [0-9,]+ \(已选择\s*([0-9,]+)\)$"#,
            #"^[0-9,]+ 选择\(已选择\s*([0-9,]+) 个字符\)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let range = Range(match.range(at: 1), in: label),
                  let count = Int(label[range].replacingOccurrences(of: ",", with: "")), count > 0 else { continue }
            return count
        }
        return nil
    }

    @MainActor
    private static func copySelection(count: Int?, pid: pid_t, appName: String) async throws -> String {
        let pasteboard = NSPasteboard.general
        guard let snapshot = PasteboardSnapshot(pasteboard),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw SelectionError.readFailed(appName)
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        let deadline = Date().addingTimeInterval(0.6)
        while pasteboard.changeCount == snapshot.changeCount, Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { break }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { break }
        }
        let copiedCount = pasteboard.changeCount
        diagnostics.notice("Selection copy changed=\(copiedCount != snapshot.changeCount), foreground=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        guard copiedCount != snapshot.changeCount,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw SelectionError.readFailed(appName)
        }
        defer {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                snapshot.restore(to: pasteboard, ifUnchanged: copiedCount)
            }
        }
        try Task.checkCancellation()
        let metadata = pasteboard.data(forType: NSPasteboard.PasteboardType("vscode-editor-data"))
        let text = pasteboard.string(forType: .string)
        diagnostics.notice("Copied count=\(text?.utf16.count ?? -1), expected=\(count ?? -1)")
        guard pasteboard.changeCount == copiedCount else { throw SelectionError.readFailed(appName) }
        if let count {
            return try copiedCodeText(text, selectedCount: count, metadata: metadata, appName: appName)
        }
        return try selectionText(from: text as CFString?, status: .success, appName: appName)
    }

    static func copiedCodeText(_ text: String?, selectedCount: Int, metadata: Data?, appName: String) throws -> String {
        if let metadata,
           let object = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Any],
           object["isFromEmptySelection"] as? Bool == true {
            throw SelectionError.noSelection
        }
        guard let text, selectedCount > 0,
              text.utf16.count == selectedCount ||
              text.replacingOccurrences(of: "\r\n", with: "\n").utf16.count == selectedCount else {
            throw SelectionError.readFailed(appName)
        }
        return try selectionText(from: text as CFString, status: .success, appName: appName)
    }

    struct PasteboardSnapshot {
        let changeCount: Int
        private let items: [[NSPasteboard.PasteboardType: Data]]

        @MainActor
        init?(_ pasteboard: NSPasteboard) {
            changeCount = pasteboard.changeCount
            var saved: [[NSPasteboard.PasteboardType: Data]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var representations: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else { return nil }
                    representations[type] = data
                }
                saved.append(representations)
            }
            guard pasteboard.changeCount == changeCount else { return nil }
            items = saved
        }

        @MainActor
        @discardableResult
        func restore(to pasteboard: NSPasteboard, ifUnchanged expectedCount: Int) -> Bool {
            guard pasteboard.changeCount == expectedCount else { return false }
            let restored = items.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
            return true
        }
    }

    static func shouldEnableManualAccessibility(bundleID: String?, after error: SelectionError) -> Bool {
        guard bundleID?.hasPrefix("com.microsoft.VSCode") == true else { return false }
        switch error {
        case .permissionRequired: return false
        case .noSelection, .readFailed, .unsupportedApplication: return true
        }
    }

    @MainActor
    private static func focusedElement(_ element: AXUIElement, pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let focused = value as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(focused, &owner) == .success, owner == pid else { return nil }
        AXUIElementSetMessagingTimeout(focused, 1)
        return focused
    }

    @MainActor
    private static func readSelection(_ application: AXUIElement, pid: pid_t, appName: String) throws -> String {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        guard let focused = focusedElement(application, pid: pid) ?? focusedElement(system, pid: pid) else {
            throw SelectionError.readFailed(appName)
        }
        do {
            return try selectedText(focused, appName: appName)
        } catch let error as SelectionError {
            // Some webviews expose a focused text client below their focused
            // area. Prefer the area's own selection when it already exposes one.
            switch error {
            case .readFailed, .unsupportedApplication:
                if let child = focusedElement(focused, pid: pid), !CFEqual(child, focused) {
                    return try selectedText(child, appName: appName)
                }
            case .noSelection, .permissionRequired: break
            }
            throw error
        }
    }

    @MainActor
    private static func selectedText(_ element: AXUIElement, appName: String) throws -> String {
        var selectedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                                  &selectedValue)
        if status == .success, let text = selectedValue as? String, !text.isEmpty {
            return try selectionText(from: selectedValue, status: status, appName: appName)
        }
        if status == .apiDisabled { throw SelectionError.permissionRequired }

        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                guard range.length > 0 else { throw SelectionError.noSelection }
                var rangeText: CFTypeRef?
                let rangeStatus = AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &rangeText
                )
                if rangeStatus == .success {
                    return try selectionText(from: rangeText, status: rangeStatus, appName: appName)
                }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                   let text = value as? String {
                    return try selectionText(in: text, range: range, appName: appName)
                }
            }
        }
        return try selectionText(from: selectedValue, status: status, appName: appName)
    }

    static func selectionText(in text: String, range: CFRange, appName: String) throws -> String {
        let value = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= value.length,
              range.length <= value.length - range.location else { throw SelectionError.readFailed(appName) }
        let selected = value.substring(with: NSRange(location: range.location, length: range.length))
        return try selectionText(from: selected as CFString, status: .success, appName: appName)
    }

    static func selectionText(from value: CFTypeRef?, status: AXError, appName: String) throws -> String {
        if status == .apiDisabled { throw SelectionError.permissionRequired }
        if status == .attributeUnsupported { throw SelectionError.unsupportedApplication(appName) }
        if status == .noValue { throw SelectionError.noSelection }
        guard status == .success else { throw SelectionError.readFailed(appName) }
        guard let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionError.noSelection
        }
        return text
    }
}
