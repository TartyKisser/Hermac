import SwiftUI
import AppKit

struct ComposerView: View {
    @Bindable var store: ChatStore
    @State private var editorHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 8) {
            if store.isRunning {
                HStack(spacing: 7) {
                    HermacMark(isAnimating: true)
                        .frame(width: 24, height: 24)
                        .accessibilityIdentifier("thinkingIndicator")
                    Text(store.activity.isEmpty ? "Hermes 正在处理…" : store.activity).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if store.draft.isEmpty {
                        Text("发消息给 Hermes…").foregroundStyle(.tertiary)
                            .padding(.leading, 5).padding(.top, 4).allowsHitTesting(false)
                    }
                    ComposerEditor(text: Binding(get: { store.draft }, set: { store.draft = $0 }), height: $editorHeight,
                                   enabled: store.connection == .connected && !store.isLoading,
                                   focusToken: store.composerFocus, submit: { Task { await store.send() } })
                        .frame(height: editorHeight)
                        .accessibilityIdentifier("messageComposer")
                }
                .font(.system(size: 14))
                if store.isRunning {
                    Button("停止生成", systemImage: "stop.fill") { Task { await store.interrupt() } }
                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.large)
                        .buttonBorderShape(.circle).help("停止生成（⌘.）")
                } else {
                    Button("发送消息", systemImage: "arrow.up") { Task { await store.send() } }
                        .font(.system(size: 16, weight: .semibold))
                        .labelStyle(.iconOnly).buttonStyle(.glassProminent).controlSize(.large)
                        .buttonBorderShape(.circle).disabled(!store.canSend)
                        .help("发送消息（Return）").accessibilityIdentifier("sendMessage")
                }
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            HStack {
                Text("本地 Hermes · 现有模型与工具")
                Spacer()
                Text("Return 发送 · ⇧Return 换行")
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 10)
        }
    }
}

// AppKit keeps native selection, dictation and Chinese input composition intact.
struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let enabled: Bool
    var focusToken: Int = 0
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = SubmitTextView()
        editor.delegate = context.coordinator
        editor.submit = submit
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("消息输入框")
        editor.setAccessibilityIdentifier("messageComposer")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? SubmitTextView else { return }
        editor.submit = submit
        editor.isEditable = enabled
        editor.synchronizeText(text)
        context.coordinator.measure(editor)
        if enabled, context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        var focusToken: Int?
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, editor.hasMarkedText() else { return }
            // Preedit moves the selection without sending textDidChange until
            // conversion commits. Keep the placeholder and draft in sync too.
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let measured = min(180, max(26, layout.usedRect(for: container).height + 8))
            guard abs(parent.height - measured) > 1 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.height = measured }
        }
    }
}

final class SubmitTextView: NSTextView {
    var submit: (() -> Void)?

    func synchronizeText(_ text: String) {
        // Setting string during preedit cancels the input method's conversion.
        guard !hasMarkedText(), string != text else { return }
        string = text
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() {
            submit?()
        } else { super.keyDown(with: event) }
    }
}
