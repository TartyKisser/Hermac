import SwiftUI
import AppKit

struct CopyButton: View {
    let text: String
    var title = "复制"
    @State private var copied = false
    @State private var copyRevision = 0

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(text, forType: .string) {
                copied = true
                copyRevision += 1
            }
        } label: {
            Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "document.on.document")
                .frame(minWidth: 60, alignment: .leading)
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.accentColor : .secondary)
        .help(copied ? "已复制到剪贴板" : title)
        .task(id: copyRevision) {
            guard copyRevision > 0 else { return }
            do { try await Task.sleep(for: .seconds(1.6)) }
            catch { return }
            copied = false
        }
    }
}
