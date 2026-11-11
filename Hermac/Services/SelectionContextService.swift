import AppKit
@preconcurrency import ApplicationServices

struct SelectionContext {
    let selectedText: String
    let appName: String
    let windowTitle: String
    let visibleText: String
    let anchorRect: NSRect?
    let windowFrame: NSRect?
    let scrollRect: NSRect?
    let contextScope: String
    let notice: String
    let hasExtendedContext: Bool

    init(selectedText: String, appName: String, windowTitle: String = "", visibleText: String = "",
         anchorRect: NSRect? = nil, windowFrame: NSRect? = nil,
         scrollRect: NSRect? = nil, contextScope: String = "可见文字", notice: String = "",
         hasExtendedContext: Bool = false) {
        self.selectedText = selectedText
        self.appName = appName
        self.windowTitle = windowTitle
        self.visibleText = visibleText
        self.anchorRect = anchorRect
        self.windowFrame = windowFrame
        self.scrollRect = scrollRect
        self.contextScope = contextScope
        self.notice = notice
        self.hasExtendedContext = hasExtendedContext
    }
}

enum SelectionContextService {
    enum ContextError: LocalizedError {
        case protectedContent

        var errorDescription: String? { "安全输入框中的内容不能用于创建提醒事项。" }
    }

    /// Must run before a Hermac panel takes focus. Context is limited to the
    /// source window's visible text; it never reads other windows or menus.
    @MainActor
    static func capture(from application: NSRunningApplication) async throws -> SelectionContext {
        try Task.checkCancellation()
        let mouse = NSEvent.mouseLocation
        let pid = application.processIdentifier
        let name = application.localizedName ?? "当前应用"
        let source = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(source, 0.2)
        let focused = focusedElement(source, pid: pid)
        if let focused, isProtected(focused) {
            throw ContextError.protectedContent
        }
        let initialAnchor = selectionBounds(in: focused)
        let selection = try await SelectedTextService.capture(from: application)
        try Task.checkCancellation()
        guard isFrontmost(pid) else { throw SelectedTextService.SelectionError.readFailed(name) }

        let window = element(source, attribute: kAXFocusedWindowAttribute)
        let title = window.flatMap { string($0, attribute: kAXTitleAttribute) } ?? ""
        let frame = window.flatMap(frame)
        let anchor = initialAnchor ?? selectionBounds(in: focusedElement(source, pid: pid))
        var visible = ""
        var scope = "仅选中文字"
        var notice = "未读取到其他上下文，将以选中文字为准。"
        var scrollRect: NSRect?
        var hasExtendedContext = false
        if let window, let frame {
            let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouse
            if let nearby = nearbyRegion(in: source, window: window, at: point, pid: pid) {
                if let viewport = nearby.scrollRect?.intersection(frame), !viewport.isEmpty { scrollRect = viewport }
                visible = try await nearbyText(in: nearby.element, pid: pid)
                if !visible.isEmpty {
                    let bundle = application.bundleIdentifier?.lowercased() ?? ""
                    scope = ["wechat", "lark", "slack", "telegram"].contains(where: bundle.contains)
                        ? "近期会话文字" : "文档上下文"
                    notice = "读取选区所在会话或文档中已加载的最近 30 项，不读取其他会话。"
                    hasExtendedContext = true
                }
            }
            if visible.isEmpty {
                visible = try await visibleText(in: window, windowFrame: frame, pid: pid)
                if !visible.isEmpty {
                    scope = "可见文字"
                    notice = "仅使用当前窗口中可见的文字。"
                }
            }
        }
        try Task.checkCancellation()
        guard isFrontmost(pid) else { throw SelectedTextService.SelectionError.readFailed(name) }
        if let window {
            guard let current = element(source, attribute: kAXFocusedWindowAttribute), CFEqual(window, current) else {
                throw SelectedTextService.SelectionError.readFailed(name)
            }
        }
        return SelectionContext(selectedText: selection.text, appName: selection.appName,
                                windowTitle: title, visibleText: visible,
                                anchorRect: anchor ?? NSRect(origin: mouse, size: .zero), windowFrame: frame,
                                scrollRect: scrollRect, contextScope: scope, notice: notice,
                                hasExtendedContext: hasExtendedContext)
    }

    /// Fast placement hint for the processing pill, without extracting text.
    @MainActor
    static func anchorRect(from application: NSRunningApplication) -> NSRect? {
        guard SelectedTextService.hasPermission, isFrontmost(application.processIdentifier) else { return nil }
        let source = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(source, 0.15)
        return selectionBounds(in: focusedElement(source, pid: application.processIdentifier))
    }

    /// Locate the selected text's own scrolling container, not the source
    /// window's other conversation lists or document panes.
    @MainActor
    private static func nearbyRegion(in source: AXUIElement, window: AXUIElement,
                                     at point: NSPoint, pid: pid_t) -> (element: AXUIElement, scrollRect: NSRect?)? {
        var starts: [AXUIElement] = []
        if let focused = focusedElement(source, pid: pid) { starts.append(focused) }
        var hit: AXUIElement?
        let axY = (NSScreen.screens.first?.frame.maxY ?? 0) - point.y
        if AXUIElementCopyElementAtPosition(source, Float(point.x), Float(axY), &hit) == .success,
           let hit { starts.append(hit) }
        for start in starts {
            var current: AXUIElement? = start
            var candidate: AXUIElement?
            var foundList = false
            var scrollRect: NSRect?
            for _ in 0..<16 {
                guard let node = current, !Task.isCancelled else { break }
                if CFEqual(node, window) {
                    if let candidate { return (candidate, scrollRect) }
                    break
                }
                var owner: pid_t = 0
                guard AXUIElementGetPid(node, &owner) == .success, owner == pid, !isProtected(node) else { break }
                let role = string(node, attribute: kAXRoleAttribute)
                if let bounds = frame(node), !bounds.isEmpty {
                    if scrollRect == nil, role == kAXScrollAreaRole { scrollRect = bounds }
                    if !foundList, [kAXTableRole, kAXListRole].contains(role ?? "") {
                        candidate = node
                        foundList = true
                        scrollRect = nil
                    } else if candidate == nil, role == kAXScrollAreaRole {
                        candidate = node
                    }
                }
                current = element(node, attribute: kAXParentAttribute)
            }
        }
        return nil
    }

    @MainActor
    private static func nearbyText(in container: AXUIElement, pid: pid_t) async throws -> String {
        // AXRows/AXChildren expose loaded objects; this does not scroll or ask
        // the source app to load earlier history.
        let roots = recentChildren(container, limit: 30)
        var stack = roots.reversed().map { ($0, 0) }
        var visited = 0
        var collector = VisibleContextText(limit: 12_000)
        let deadline = Date().addingTimeInterval(1)
        while let (current, depth) = stack.popLast(), visited < 350, Date() < deadline, !collector.isFull {
            try Task.checkCancellation()
            guard isFrontmost(pid) else { break }
            visited += 1
            AXUIElementSetMessagingTimeout(current, 0.1)
            var owner: pid_t = 0
            guard AXUIElementGetPid(current, &owner) == .success, owner == pid, !isProtected(current) else { continue }
            let role = string(current, attribute: kAXRoleAttribute) ?? ""
            if role == kAXTextAreaRole || role == kAXTextFieldRole {
                if let text = textAroundSelection(current) ?? visibleTextRange(current) { collector.append(text) }
            } else if [kAXStaticTextRole, kAXButtonRole, kAXPopUpButtonRole, "AXHeading"].contains(role) {
                collector.append(string(current, attribute: kAXValueAttribute)
                                 ?? string(current, attribute: kAXTitleAttribute)
                                 ?? string(current, attribute: kAXDescriptionAttribute) ?? "")
            }
            if depth < 12 {
                let descendants = allChildren(current)
                stack.append(contentsOf: descendants.prefix(350 - visited).reversed().map { ($0, depth + 1) })
            }
            if visited.isMultiple(of: 12) { await Task.yield() }
        }
        return collector.text
    }

    @MainActor
    private static func textAroundSelection(_ element: AXUIElement) -> String? {
        guard let selected = value(element, attribute: kAXSelectedTextRangeAttribute),
              CFGetTypeID(selected) == AXValueGetTypeID(),
              let length = value(element, attribute: kAXNumberOfCharactersAttribute) as? NSNumber else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(selected as! AXValue, .cfRange, &selection), selection.length > 0 else { return nil }
        let ranges = surroundingRanges(selection: selection, totalLength: length.intValue)
        let snippets = ranges.compactMap { range -> String? in
            var range = range
            guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
            var text: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                             axRange, &text) == .success else { return nil }
            return text as? String
        }
        return snippets.isEmpty ? nil : snippets.joined(separator: "\n")
    }

    @MainActor
    private static func recentChildren(_ element: AXUIElement, limit: Int) -> [AXUIElement] {
        var container = element
        for _ in 0..<6 {
            var result: [AXUIElement] = []
            for attribute in [kAXRowsAttribute, kAXChildrenAttribute, kAXContentsAttribute] {
                var count: CFIndex = 0
                guard AXUIElementGetAttributeValueCount(container, attribute as CFString, &count) == .success,
                      count > 0 else { continue }
                var children: CFArray?
                if AXUIElementCopyAttributeValues(container, attribute as CFString, max(0, count - limit), min(count, limit),
                                                  &children) == .success, let children = children as? [AXUIElement] {
                    result = children
                    break
                }
            }
            if result.isEmpty { result = Array(allChildren(container).suffix(limit)) }
            result.removeAll { string($0, attribute: kAXRoleAttribute) == kAXScrollBarRole }
            if result.count == 1, let only = result.first,
               [kAXGroupRole, kAXTableRole, kAXListRole].contains(string(only, attribute: kAXRoleAttribute) ?? "") {
                container = only
            } else { return result }
        }
        return Array(allChildren(container).suffix(limit))
    }

    @MainActor
    private static func visibleText(in window: AXUIElement, windowFrame: NSRect, pid: pid_t) async throws -> String {
        let displays = NSScreen.screens.map(\.frame)
        var collector = VisibleContextText(limit: 12_000)
        var queue: [(AXUIElement, NSRect, Int)] = [(window, windowFrame, 0)]
        var cursor = 0
        let deadline = Date().addingTimeInterval(1)
        while cursor < queue.count, cursor < 350, Date() < deadline, !collector.isFull {
            try Task.checkCancellation()
            guard isFrontmost(pid) else { break }
            let (current, inheritedClip, depth) = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(current, 0.1)
            var owner: pid_t = 0
            guard AXUIElementGetPid(current, &owner) == .success, owner == pid,
                  !isProtected(current), !bool(current, attribute: "AXHidden") else { continue }
            let role = string(current, attribute: kAXRoleAttribute) ?? ""
            let bounds = frame(current)
            if let bounds,
               (!bounds.intersects(inheritedClip) || !displays.contains(where: { $0.intersects(bounds) })) {
                continue
            }
            let clip = role == kAXScrollAreaRole ? bounds?.intersection(inheritedClip) ?? inheritedClip : inheritedClip

            if let bounds {
                if role == kAXTextAreaRole || role == kAXTextFieldRole {
                    if let text = visibleTextRange(current) { collector.append(text) }
                } else if mayReadWholeText(role: role, frame: bounds, clip: clip),
                          displays.contains(where: { $0.contains(bounds) }) {
                    collector.append(string(current, attribute: kAXValueAttribute)
                                     ?? string(current, attribute: kAXTitleAttribute)
                                     ?? string(current, attribute: kAXDescriptionAttribute) ?? "")
                }
            }
            guard depth < 16, queue.count < 350 else { continue }
            let children = children(current)
            queue.append(contentsOf: children.prefix(350 - queue.count).map { ($0, clip, depth + 1) })
            if cursor.isMultiple(of: 12) { await Task.yield() }
        }
        return collector.text
    }

    // Text clients expose a visible character range independently of their full
    // AXValue. Reading only this range avoids collecting an entire document.
    @MainActor
    private static func visibleTextRange(_ element: AXUIElement) -> String? {
        guard let range = value(element, attribute: kAXVisibleCharacterRangeAttribute),
              CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        var characters = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &characters), characters.length > 0 else { return nil }
        characters.length = min(characters.length, 12_000)
        guard let bounded = AXValueCreate(.cfRange, &characters) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         bounded, &text) == .success else { return nil }
        return text as? String
    }

    @MainActor
    private static func selectionBounds(in focused: AXUIElement?) -> NSRect? {
        guard let focused, !isProtected(focused) else { return nil }
        if let range = value(focused, attribute: kAXSelectedTextRangeAttribute),
           CFGetTypeID(range) == AXValueGetTypeID() {
            var selected = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &selected), selected.length > 0,
               let bounds = parameterizedRect(focused, attribute: kAXBoundsForRangeParameterizedAttribute, parameter: range) {
                return bounds
            }
        }
        // Chromium/WebKit expose opaque markers through AX parameter attributes;
        // pass the marker back unchanged rather than parsing its representation.
        if let marker = value(focused, attribute: "AXSelectedTextMarkerRange") {
            return parameterizedRect(focused, attribute: "AXBoundsForTextMarkerRange", parameter: marker)
        }
        return nil
    }

    @MainActor
    private static func parameterizedRect(_ element: AXUIElement, attribute: String, parameter: CFTypeRef) -> NSRect? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect), !rect.isEmpty else { return nil }
        return appKitRect(fromAX: rect, primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    @MainActor
    private static func frame(_ element: AXUIElement) -> NSRect? {
        guard let pointValue = value(element, attribute: kAXPositionAttribute),
              let sizeValue = value(element, attribute: kAXSizeAttribute),
              CFGetTypeID(pointValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pointValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return appKitRect(fromAX: CGRect(origin: point, size: size), primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    @MainActor
    private static func focusedElement(_ source: AXUIElement, pid: pid_t) -> AXUIElement? {
        guard let focused = element(source, attribute: kAXFocusedUIElementAttribute) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(focused, &owner) == .success, owner == pid else { return nil }
        if let child = element(focused, attribute: kAXFocusedUIElementAttribute),
           AXUIElementGetPid(child, &owner) == .success, owner == pid { return child }
        return focused
    }

    @MainActor
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        for attribute in [kAXVisibleChildrenAttribute, kAXChildrenAttribute, kAXContentsAttribute] {
            if let children = value(element, attribute: attribute) as? [AXUIElement] { return children }
        }
        return []
    }

    @MainActor
    private static func allChildren(_ element: AXUIElement) -> [AXUIElement] {
        for attribute in [kAXChildrenAttribute, kAXContentsAttribute] {
            if let children = value(element, attribute: attribute) as? [AXUIElement] { return children }
        }
        return []
    }

    @MainActor
    private static func isProtected(_ element: AXUIElement) -> Bool {
        string(element, attribute: kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            || bool(element, attribute: NSAccessibility.Attribute.containsProtectedContent.rawValue)
    }

    @MainActor
    private static func value(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    @MainActor
    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        value(element, attribute: attribute) as? String
    }

    @MainActor
    private static func bool(_ element: AXUIElement, attribute: String) -> Bool {
        value(element, attribute: attribute) as? Bool ?? false
    }

    @MainActor
    private static func element(_ source: AXUIElement, attribute: String) -> AXUIElement? {
        guard let result = value(source, attribute: attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    @MainActor
    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    static func appKitRect(fromAX rect: CGRect, primaryScreenTop: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func mayReadWholeText(role: String, frame: NSRect, clip: NSRect) -> Bool {
        [kAXStaticTextRole, kAXButtonRole, kAXPopUpButtonRole, "AXHeading"].contains(role)
            && !frame.isEmpty && clip.contains(frame)
    }

    static func surroundingRanges(selection: CFRange, totalLength: Int, radius: Int = 2_000) -> [CFRange] {
        guard selection.location >= 0, selection.length > 0, selection.location <= totalLength,
              selection.length <= totalLength - selection.location else { return [] }
        let start = max(0, selection.location - radius)
        let end = selection.location + selection.length
        return [CFRange(location: start, length: selection.location - start),
                CFRange(location: end, length: min(radius, totalLength - end))].filter { $0.length > 0 }
    }
}

/// Preserves visible snippets in their reading order without repeated labels.
struct VisibleContextText {
    let limit: Int
    private var snippets: [String] = []
    private var seen = Set<String>()
    private var count = 0

    var isFull: Bool { count >= limit }
    var text: String { snippets.joined(separator: "\n") }

    mutating func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed), !isFull else { return }
        seen.insert(trimmed)
        let separator = snippets.isEmpty ? 0 : 1
        let remaining = max(0, limit - count - separator)
        guard remaining > 0 else { return }
        let snippet = String(trimmed.prefix(remaining))
        snippets.append(snippet)
        count += snippet.count + separator
    }
}
