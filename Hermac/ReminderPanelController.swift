import AppKit
import SwiftUI

@MainActor
final class ReminderPanelController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let store: ReminderStore
    private let didClose: @MainActor () -> Void
    private var anchor = NSRect.zero
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var completionTask: Task<Void, Never>?

    init(store: ReminderStore,
         didClose: @escaping @MainActor () -> Void,
         retry: @escaping @MainActor () -> Void,
         requestAccessibility: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.didClose = didClose
        panel = ReminderPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 60),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        super.init()
        panel.title = "快捷日程"
        panel.identifier = NSUserInterfaceItemIdentifier("quickReminder")
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
        panel.contentView = NSHostingView(rootView: ReminderView(
            store: store, cancel: { [weak self] in self?.hide() },
            retry: retry, requestAccessibility: requestAccessibility,
            updatePresentation: { [weak self] in self?.updatePresentation() }
        ))
    }

    /// The anchor is already in AppKit's global coordinate system. Showing
    /// processing uses orderFront only, keeping the source application's focus.
    func showProcessing(anchorRect: NSRect?) {
        completionTask?.cancel()
        let mouse = NSEvent.mouseLocation
        anchor = anchorRect ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        setSize(NSSize(width: 236, height: 60), animated: false)
        installKeyMonitor()
        panel.orderFrontRegardless()
    }

    func hide() {
        guard store.phase != .saving else { return }
        completionTask?.cancel()
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        keyMonitor = nil
        globalKeyMonitor = nil
        didClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func updatePresentation() {
        guard panel.isVisible else { return }
        completionTask?.cancel()
        let expanded = store.phase == .review || store.phase == .error
        let height: CGFloat = store.phase == .error ? 260 : 540
        setSize(expanded ? NSSize(width: 440, height: height) : NSSize(width: 236, height: 60), animated: true)
        if expanded { panel.makeKeyAndOrderFront(nil) }
        if store.phase == .success {
            completionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled, let self, store.phase == .success else { return }
                hide()
            }
        }
    }

    private func setSize(_ proposed: NSSize, animated: Bool) {
        let point = NSPoint(x: anchor.maxX, y: anchor.maxY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let size = NSSize(width: min(proposed.width, visible.width), height: min(proposed.height, visible.height))
        // Prefer above and to the right of the selection; grow down when the
        // screen's top edge leaves too little room for the expanded editor.
        let preferredY = point.y + 6
        let y = preferredY + size.height <= visible.maxY ? preferredY : point.y - size.height - 6
        let frame = NSRect(x: min(max(point.x + 6, visible.minX), visible.maxX - size.width),
                           y: min(max(y, visible.minY), visible.maxY - size.height),
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true,
                       animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.panel.isKeyWindow, event.keyCode == 53,
                      self.store.phase == .extracting || self.store.phase == .idle else { return }
                self.hide()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { [weak self] in
                guard let self, panel.isVisible, panel.isKeyWindow, event.keyCode == 53 else { return false }
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                if store.phase != .saving { hide() }
                return true
            }
            return consumed ? nil : event
        }
    }
}

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
