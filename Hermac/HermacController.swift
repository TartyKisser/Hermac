import AppKit
import CoreGraphics

/// The main window and quick panel keep independent selections and drafts while
/// Hermes remains the single owner of both conversations.
@MainActor
final class HermacController {
    let store = ChatStore()
    let quickStore = ChatStore()
    let shortcuts = GlobalShortcutController()
    let translationShortcuts = GlobalShortcutController(purpose: .translation)
    let translation = TranslationStore()
    private var hasStarted = false
    private var isQuitting = false
    private var selectionRevision = 0

    lazy var quickPanel = QuickChatPanelController(
        store: quickStore,
        submit: { [weak self] screenshot, panel in
            guard let self else { return false }
            return await sendQuickChat(includingScreenshot: screenshot, panel: panel)
        },
        didClose: { [weak self] in self?.refreshMainConversations() }
    )
    lazy var translationPanel = TranslationPanelController(
        store: translation,
        didClose: { [weak self] in self?.closeTranslation() },
        requestAccessibility: { SelectedTextService.requestPermission() }
    )

    init() {
        quickStore.onConversationsChanged = { [weak self] in self?.refreshMainConversations() }
        translation.onCleanupFailure = { [weak self] in self?.store.errorMessage = $0 }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        shortcuts.start { [weak self] in self?.toggleQuickChat() }
        translationShortcuts.start { [weak self] in self?.translateSelection() }
        await store.connect()
    }

    func translateSelection() {
        guard !isQuitting else { return }
        selectionRevision += 1
        let revision = selectionRevision
        // Preserve the source before Electron accessibility setup can suspend.
        guard let application = NSWorkspace.shared.frontmostApplication else { return }
        Task {
            do {
                let selection = try await SelectedTextService.capture(from: application)
                guard !isQuitting, revision == selectionRevision else { return }
                translation.translate(selection.text, launcherPath: store.launcherPath)
            } catch {
                guard !isQuitting, revision == selectionRevision else { return }
                translation.showError(error, needsPermission: error as? SelectedTextService.SelectionError == .permissionRequired)
            }
            translationPanel.show()
        }
    }

    private func closeTranslation() {
        selectionRevision += 1
        translation.close()
    }

    func prepareToQuit() async {
        isQuitting = true
        selectionRevision += 1
        shortcuts.stop()
        translationShortcuts.stop()
        await translation.shutdown()
    }

    func toggleQuickChat() {
        guard !isQuitting else { return }
        quickPanel.toggle()
        guard quickPanel.panel.isVisible else { return }
        Task {
            if quickStore.connection == .disconnected {
                quickStore.launcherPath = store.launcherPath
                await quickStore.connect()
            }
        }
    }

    private func sendQuickChat(includingScreenshot: Bool, panel: NSPanel) async -> Bool {
        guard quickStore.canSend else { return false }
        var image: URL?
        defer {
            if let image { try? FileManager.default.removeItem(at: image) }
        }
        do {
            if includingScreenshot {
                guard let screen = panel.screen,
                      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    throw HermesServiceError(message: "无法确定快捷窗口所在的屏幕，请重新呼出后再试。")
                }
                image = try await ScreenCaptureService.capture(
                    displayID: number.uint32Value, excludingWindowID: CGWindowID(panel.windowNumber)
                )
            }
            return await quickStore.send(images: image.map { [$0] } ?? [])
        } catch {
            quickStore.errorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshMainConversations() {
        guard store.connection == .connected else { return }
        Task {
            do { try await store.refreshConversations() }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    func stop() {
        shortcuts.stop()
        translationShortcuts.stop()
        quickStore.disconnect()
        store.disconnect()
    }
}
