import SwiftUI

struct TranslationView: View {
    @Bindable var store: TranslationStore
    var requestAccessibility: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !store.result.isEmpty {
                        MessageBody(text: store.result)
                            .foregroundStyle(Color(nsColor: .systemBlue))
                            .accessibilityIdentifier("translationResult")
                    }
                    if let error = store.errorMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if store.needsAccessibilityPermission {
                                Button("打开辅助功能设置", action: requestAccessibility)
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("translationAccessibilitySettings")
                            }
                        }
                    } else if store.result.isEmpty {
                        Text(store.isRunning ? "正在将所选英文译为中文…" : "选中英文后，使用快捷键开始翻译。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack(spacing: 8) {
                if store.isRunning {
                    HermacMark(isAnimating: true).frame(width: 18, height: 18)
                    Text("正在翻译…")
                        .accessibilityIdentifier("translationStatus")
                } else {
                    Text("英译中")
                }
                Spacer()
                CopyButton(text: store.result, title: "复制译文")
                    .disabled(store.result.isEmpty)
                    .accessibilityIdentifier("copyTranslation")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }
}
