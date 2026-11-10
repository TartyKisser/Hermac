import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class QuickChatPresentation {
    var isExpanded = false
    var includesScreenshot = false
    var isSending = false
    var composerHeight: CGFloat = 26
}

@MainActor
final class QuickChatPanelController: NSObject, NSWindowDelegate {
    let store: ChatStore
    let presentation = QuickChatPresentation()
    let panel: NSPanel
    private let submit: @MainActor (Bool, NSPanel) async -> Bool
    private let didClose: @MainActor () -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hideAfterFullScreen = false
    private var contentSurface: FloatingPanelContentView?

    init(store: ChatStore,
         submit: @escaping @MainActor (Bool, NSPanel) async -> Bool,
         didClose: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.submit = submit
        self.didClose = didClose
        let panel = QuickChatPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 68),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        self.panel = panel
        super.init()
        panel.title = "Hermac 快捷会话"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        let content = FloatingPanelContentView(rootView: QuickChatView(
            store: store, presentation: presentation,
            send: { [weak self] in self?.send() },
            beginConversation: { [weak self] in self?.expand() },
            updateLayout: { [weak self] in self?.updateSize() }
        ), materialVisible: false)
        contentSurface = content
        panel.contentView = content
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() }
        else { show() }
    }

    func show() {
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
            panel.makeKeyAndOrderFront(nil)
            store.composerFocus += 1
            return
        }
        guard !panel.isVisible else {
            panel.makeKeyAndOrderFront(nil)
            store.composerFocus += 1
            return
        }
        let isFullScreen = panel.styleMask.contains(.fullScreen)
        if !isFullScreen, !store.isRunning, !presentation.isSending, store.selectedID != nil { store.newConversation() }
        presentation.isExpanded = isFullScreen || store.isRunning || !store.messages.isEmpty
        presentation.includesScreenshot = false
        store.errorMessage = nil
        updateSize(centerOnScreen: true)
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        store.composerFocus += 1
    }

    func hide() {
        guard panel.isVisible else { return }
        if panel.styleMask.contains(.fullScreen) {
            guard !hideAfterFullScreen else { return }
            hideAfterFullScreen = true
            panel.toggleFullScreen(nil)
            return
        }
        panel.orderOut(nil)
        removeMonitors()
        didClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        if !presentation.isExpanded, !presentation.isSending { hide() }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if hideAfterFullScreen {
            hideAfterFullScreen = false
            hide()
        }
    }

    private func send() {
        guard store.canSend, !presentation.isSending else { return }
        presentation.isSending = true
        Task { [weak self] in
            guard let self else { return }
            let sent = await submit(presentation.includesScreenshot, panel)
            presentation.isSending = false
            if sent || !store.messages.isEmpty { expand() }
            updateSize()
            store.composerFocus += 1
        }
    }

    private func expand() {
        guard !presentation.isExpanded else { return }
        presentation.isExpanded = true
        updateSize()
    }

    private func updateSize(centerOnScreen: Bool = false) {
        updateChrome()
        guard !panel.styleMask.contains(.fullScreen) else { return }
        let screen = centerOnScreen
            ? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            : panel.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let contentHeight: CGFloat = presentation.isExpanded ? 500
            : max(44, min(180, presentation.composerHeight)) + 40 + (store.errorMessage == nil ? 0 : 48)
        let height = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 640, height: contentHeight)).height
        let width = centerOnScreen ? min(640, visible.width - 40) : panel.frame.width
        let keepExpandedFrame = !centerOnScreen && presentation.isExpanded && panel.frame.height >= 360
        panel.contentMinSize = NSSize(width: 480, height: presentation.isExpanded ? 320 : contentHeight)
        panel.contentMaxSize = NSSize(width: 1200, height: presentation.isExpanded ? 1200 : contentHeight)
        if keepExpandedFrame { return }
        let center = centerOnScreen
            ? NSPoint(x: visible.midX, y: visible.minY + visible.height * 0.58)
            : NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let frame = NSRect(x: min(max(center.x - width / 2, visible.minX), visible.maxX - width),
                           y: min(max(center.y - height / 2, visible.minY), visible.maxY - height),
                           width: width, height: min(height, visible.height))
        panel.setFrame(frame, display: true,
                       animate: panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func updateChrome() {
        var style: NSWindow.StyleMask = [.nonactivatingPanel]
        if presentation.isExpanded {
            style.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            // AppKit owns this bit while the green window control is in use.
            style.formUnion(panel.styleMask.intersection(.fullScreen))
        }
        if panel.styleMask != style { panel.styleMask = style }
        panel.title = presentation.isExpanded ? store.title : "Hermac 快捷会话"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = presentation.isExpanded
        panel.titlebarSeparatorStyle = .none
        contentSurface?.setMaterialVisible(presentation.isExpanded)
        panel.hasShadow = presentation.isExpanded
        panel.isMovableByWindowBackground = !presentation.isExpanded
        panel.collectionBehavior = presentation.isExpanded
            ? [.fullScreenPrimary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private func dismissIfCompact() {
        guard !presentation.isExpanded, !presentation.isSending else { return }
        if panel.isKeyWindow, let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return }
        hide()
    }

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfCompact() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            let consumed = MainActor.assumeIsolated { [weak self] in
                guard let self, self.panel.isVisible else { return false }
                if event.type == .keyDown, self.panel.isKeyWindow, event.keyCode == 47,
                   event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
                    if self.store.isRunning { Task { await self.store.interrupt() } }
                    return true
                }
                if event.type == .keyDown, event.keyCode == 53, self.panel.isKeyWindow {
                    // Let the input method dismiss its composition before the panel.
                    if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                    self.hide()
                    return true
                }
                if event.type != .keyDown, event.window !== self.panel { self.dismissIfCompact() }
                return false
            }
            return consumed ? nil : event
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}

private final class QuickChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { styleMask.contains(.titled) }
}
