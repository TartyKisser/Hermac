import AppKit
import SwiftUI

@MainActor
final class TranslationPanelController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let didClose: @MainActor () -> Void
    private var keyMonitor: Any?
    private var hideAfterFullScreen = false

    init(store: TranslationStore,
         didClose: @escaping @MainActor () -> Void,
         requestAccessibility: @escaping @MainActor () -> Void = {}) {
        self.didClose = didClose
        panel = TranslationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        panel.title = "快捷翻译"
        panel.identifier = NSUserInterfaceItemIdentifier("translation")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.contentMinSize = NSSize(width: 400, height: 220)
        panel.contentMaxSize = NSSize(width: 1200, height: 1200)
        panel.contentView = FloatingPanelContentView(rootView: TranslationView(
            store: store, requestAccessibility: requestAccessibility
        ), materialVisible: true)
    }

    func show() {
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        } else if !panel.isVisible, !panel.styleMask.contains(.fullScreen),
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            var frame = panel.frame
            frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                   y: screen.visibleFrame.midY - frame.height / 2)
            panel.setFrame(panel.constrainFrameRect(frame, to: screen), display: true)
        }
        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.isMiniaturized else { return }
        if panel.styleMask.contains(.fullScreen) {
            guard !hideAfterFullScreen else { return }
            hideAfterFullScreen = true
            panel.toggleFullScreen(nil)
            return
        }
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        didClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if hideAfterFullScreen {
            hideAfterFullScreen = false
            hide()
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { [weak self] in
                guard let self, panel.isKeyWindow, event.keyCode == 53 else { return false }
                hide()
                return true
            }
            return consumed ? nil : event
        }
    }
}

private final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
