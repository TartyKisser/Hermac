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
    let reminderShortcuts = GlobalShortcutController(purpose: .reminder)
    let translation = TranslationStore()
    let reminder = ReminderStore()
    private var hasStarted = false
    private var isQuitting = false
    private var selectionRevision = 0
    private var reminderRevision = 0
    private var reminderCaptureTask: Task<Void, Never>?
    private var reminderSource: NSRunningApplication?
    private var reminderContext: SelectionContext?
    private var reminderContextText = ""
    private var reminderContextSummary = ""
    private var reminderImage: URL?

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
    lazy var reminderPanel = ReminderPanelController(
        store: reminder,
        didClose: { [weak self] in self?.closeReminder() },
        retry: { [weak self] in self?.retryReminder() },
        requestAccessibility: { SelectedTextService.requestPermission() }
    )

    init() {
        quickStore.onConversationsChanged = { [weak self] in self?.refreshMainConversations() }
        translation.onCleanupFailure = { [weak self] in self?.store.errorMessage = $0 }
        reminder.onCleanupFailure = { [weak self] in self?.store.errorMessage = $0 }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        shortcuts.start { [weak self] in self?.toggleQuickChat() }
        translationShortcuts.start { [weak self] in self?.translateSelection() }
        reminderShortcuts.start { [weak self] in self?.createReminderFromSelection() }
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

    func createReminderFromSelection() {
        guard !isQuitting, reminder.phase != .saving,
              let source = NSWorkspace.shared.frontmostApplication else { return }
        prepareReminder(from: source)
    }

    private func prepareReminder(from source: NSRunningApplication) {
        let previous = reminderCaptureTask
        previous?.cancel()
        reminderRevision += 1
        let revision = reminderRevision
        reminder.close()
        clearReminderInput()
        reminderSource = source
        reminder.phase = .extracting
        reminderPanel.showProcessing(anchorRect: SelectionContextService.anchorRect(from: source))
        reminderCaptureTask = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                let context = try await SelectionContextService.capture(from: source)
                guard revision == reminderRevision, !isQuitting else { return }
                reminderPanel.showProcessing(anchorRect: context.anchorRect)
                var contextText = [context.windowTitle, context.visibleText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                var summary = context.contextScope + (context.notice.isEmpty ? "" : " · " + context.notice)
                var image: URL?
                if !context.hasExtendedContext {
                    do {
                        let recent = try await RecentContextCaptureService.capture(
                            application: source, windowTitle: context.windowTitle, windowFrame: context.windowFrame,
                            scrollRect: context.scrollRect, anchorRect: context.anchorRect,
                            selectedText: context.selectedText
                        )
                        contextText += (contextText.isEmpty ? "" : "\n\n") + recent.text
                        image = recent.imageURL
                        summary = recent.notice
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processIdentifier else { throw error }
                        summary = "仅使用选区及已读取文字；暂未取得更多上下文。"
                    }
                }
                guard revision == reminderRevision, !isQuitting, !Task.isCancelled else {
                    if let image { try? FileManager.default.removeItem(at: image) }
                    return
                }
                reminderContext = context
                reminderContextText = contextText
                reminderContextSummary = summary
                reminderImage = image
                beginReminderExtraction()
            } catch is CancellationError { }
            catch {
                guard revision == reminderRevision, !isQuitting else { return }
                let problem = reminderSelectionError(error)
                reminder.showError(problem, needsPermission: error as? SelectedTextService.SelectionError == .permissionRequired)
            }
        }
    }

    private func beginReminderExtraction() {
        guard let context = reminderContext else { return }
        reminder.contextSummary = reminderContextSummary
        reminder.begin(selectedText: context.selectedText, context: reminderContextText,
                       appName: context.appName, launcherPath: store.launcherPath, imageURL: reminderImage)
    }

    private func retryReminder() {
        if reminderContext != nil { beginReminderExtraction() }
        else if let source = reminderSource,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processIdentifier {
            prepareReminder(from: source)
        } else {
            reminder.showError(HermesServiceError(message: "请回到原来的聊天、邮件或文档，重新选中文字并触发快捷键。"))
        }
    }

    private func closeReminder() {
        reminderRevision += 1
        reminderCaptureTask?.cancel()
        reminder.close()
        clearReminderInput()
        reminderSource = nil
    }

    private func clearReminderInput() {
        if let reminderImage { try? FileManager.default.removeItem(at: reminderImage) }
        reminderImage = nil
        reminderContext = nil
        reminderContextText = ""
        reminderContextSummary = ""
    }

    private func reminderSelectionError(_ error: Error) -> Error {
        guard let selection = error as? SelectedTextService.SelectionError else { return error }
        switch selection {
        case .permissionRequired:
            return HermesServiceError(message: "请在系统设置的“隐私与安全性 → 辅助功能”中允许 Hermac，返回原界面后重新触发快捷键。")
        case .noSelection:
            return HermesServiceError(message: "请先选中包含日程要求的文字，再使用快捷键创建提醒事项。")
        case .readFailed(let name), .unsupportedApplication(let name):
            return HermesServiceError(message: "无法读取\(name)中的所选文字，请重新选择后再试。")
        }
    }

    func prepareToQuit() async {
        isQuitting = true
        selectionRevision += 1
        shortcuts.stop()
        translationShortcuts.stop()
        reminderShortcuts.stop()
        closeReminder()
        await reminderCaptureTask?.value
        await reminder.shutdown()
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
        reminderShortcuts.stop()
        quickStore.disconnect()
        store.disconnect()
    }
}
