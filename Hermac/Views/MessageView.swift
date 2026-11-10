import SwiftUI
import AppKit

struct MessageView: View {
    let message: ChatMessage
    var canBranch = false
    var branch: () -> Void = {}

    var body: some View {
        if message.role == "user" {
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Spacer(minLength: 60)
                    VStack(alignment: .leading, spacing: 10) {
                        if !message.text.isEmpty {
                            Text(message.text)
                                .textSelection(.enabled).font(.system(size: 14)).lineSpacing(5)
                        }
                        ForEach(message.imagePaths, id: \.self) { path in
                            if let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image)
                                    .resizable().scaledToFit()
                                    .frame(maxWidth: 280, maxHeight: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .accessibilityLabel("附带的屏幕截图")
                            } else {
                                Label("已附带图片", systemImage: "photo")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                        .padding(.horizontal, 18).padding(.vertical, 13)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                CopyButton(text: message.text)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Hermes")
                } icon: {
                    HermacMark()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                MessageBody(text: message.text)
                HStack(spacing: 14) {
                    CopyButton(text: message.text)
                    Button("分支", systemImage: "arrow.triangle.branch") { branch() }
                        .font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary)
                        .disabled(!canBranch)
                        .help(message.isArchived ? "这条回复已被 Hermes 压缩归档，无法从此处创建分支"
                              : canBranch ? "从这条回复创建独立会话" : "会话空闲且回复保存后可创建分支")
                        .accessibilityIdentifier("branch-\(message.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
