import SwiftUI

struct SettingsView: View {
    @Bindable var store: ChatStore
    @Bindable var shortcuts: GlobalShortcutController
    @Bindable var translationShortcuts: GlobalShortcutController

    var body: some View {
        Form {
            Section {
                LabeledContent("Hermes 启动程序") {
                    TextField("路径", text: $store.launcherPath)
                        .textFieldStyle(.roundedBorder).frame(width: 300)
                }
                HStack {
                    Text("沿用本机 Hermes 的配置、模型和工具。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.connection == .connecting ? "正在连接…" : "连接") {
                        Task { await store.connect() }
                    }.disabled(store.connection == .connecting)
                }
            } header: { Text("本地连接") }
            Section {
                ShortcutSettingRow(title: "呼出快捷会话", identifier: "quickChat", shortcuts: shortcuts)
                ShortcutSettingRow(title: "翻译选中的英文", identifier: "quickTranslation", shortcuts: translationShortcuts)
            } header: { Text("全局快捷键") }
            Section {
                LabeledContent("应用", value: "Hermac \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                LabeledContent("存储", value: "Hermes 原生会话")
            }
        }
        .formStyle(.grouped)
        .padding(12).frame(width: 600, height: 570)
        .onDisappear {
            shortcuts.cancelRecording()
            translationShortcuts.cancelRecording()
        }
    }
}

private struct ShortcutSettingRow: View {
    let title: String
    let identifier: String
    @Bindable var shortcuts: GlobalShortcutController
    @State private var isManualShortcutPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(title) {
                Button(shortcuts.isRecording ? "按下快捷键…" : shortcuts.shortcut.displayName) {
                    if shortcuts.isRecording { shortcuts.cancelRecording() }
                    else { shortcuts.beginRecording() }
                }
                .frame(minWidth: 140)
                .accessibilityIdentifier(identifier + "Shortcut")
                .background(ShortcutRecorder(shortcuts: shortcuts).frame(width: 0, height: 0))
                Button("恢复默认") { shortcuts.restoreDefault() }
                    .disabled(shortcuts.isRecording)
            }
            HStack {
                Text("若系统先响应，使用手动设置检查组合。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("手动设置…") { isManualShortcutPresented = true }
                    .disabled(shortcuts.isRecording)
                    .popover(isPresented: $isManualShortcutPresented) {
                        ManualShortcutEditor(shortcuts: shortcuts) { isManualShortcutPresented = false }
                    }
            }
            if let error = shortcuts.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier(identifier + "ShortcutConflict")
            } else {
                Text(shortcuts.isRecording ? "按 Esc 取消。" : shortcuts.noticeMessage ?? "Hermac 运行时，可在其他 App 中使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
