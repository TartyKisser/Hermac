import SwiftUI

@main
struct HermacApp: App {
    @NSApplicationDelegateAdaptor(HermacLifecycleDelegate.self) private var lifecycle
    @State private var controller = HermacController()

    private var store: ChatStore { controller.store }

    var body: some Scene {
        Window("Hermac", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 780, minHeight: 540)
                .task {
                    if NSClassFromString("XCTestCase") == nil {
                        lifecycle.prepareToQuit = { await controller.prepareToQuit() }
                        await controller.start()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    controller.stop()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建对话", systemImage: "square.and.pencil") { store.newConversation() }
                    .keyboardShortcut("n")
                Button("呼出快捷会话", systemImage: "rectangle.and.pencil.and.ellipsis") {
                    controller.toggleQuickChat()
                }
                Button("翻译所选文本", systemImage: "translate") { controller.translateSelection() }
            }
            CommandMenu("会话") {
                Button("刷新会话", systemImage: "arrow.clockwise") {
                    Task {
                        do { try await store.refreshConversations() }
                        catch { store.errorMessage = error.localizedDescription }
                        if let id = store.selectedID { await store.select(id) }
                    }
                }
                .keyboardShortcut("r")
                .disabled(store.connection != .connected)
                Button("停止生成", systemImage: "stop.fill") { Task { await store.interrupt() } }
                    .keyboardShortcut(".")
                    .disabled(!store.isRunning)
            }
        }

        Settings {
            SettingsView(store: store, shortcuts: controller.shortcuts, translationShortcuts: controller.translationShortcuts)
        }
    }
}

@MainActor
final class HermacLifecycleDelegate: NSObject, NSApplicationDelegate {
    var prepareToQuit: (() async -> Void)?
    private var isQuitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareToQuit else { return .terminateNow }
        if !isQuitting {
            isQuitting = true
            Task {
                await prepareToQuit()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
