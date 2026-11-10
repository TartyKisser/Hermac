import SwiftUI
import AppKit
import Carbon

struct ShortcutRecorder: View {
    @Bindable var shortcuts: GlobalShortcutController

    var body: some View {
        ShortcutKeyCapture(isRecording: shortcuts.isRecording,
                           onShortcut: { shortcuts.choose($0) },
                           onCancel: { shortcuts.cancelRecording() })
    }
}

private struct ShortcutKeyCapture: NSViewRepresentable {
    var isRecording: Bool
    var onShortcut: (GlobalShortcut) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView { ShortcutCaptureView() }

    func updateNSView(_ view: ShortcutCaptureView, context: Context) {
        view.isRecording = isRecording
        view.onShortcut = onShortcut
        view.onCancel = onCancel
        if isRecording && view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}

struct ManualShortcutEditor: View {
    @Bindable var shortcuts: GlobalShortcutController
    var dismiss: () -> Void
    @State private var key: GlobalShortcut
    @State private var modifiers: UInt32
    @State private var isCapturingKey = false
    @State private var errorMessage: String?

    init(shortcuts: GlobalShortcutController, dismiss: @escaping () -> Void) {
        self.shortcuts = shortcuts
        self.dismiss = dismiss
        _key = State(initialValue: shortcuts.shortcut)
        _modifiers = State(initialValue: shortcuts.shortcut.modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("手动设置快捷键").font(.headline)
            Text("先勾选修饰键，再单独按主键，无需同时按下整个组合。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Toggle("⌃", isOn: modifier(controlKey)).help("Control")
                Toggle("⌥", isOn: modifier(optionKey)).help("Option")
                Toggle("⇧", isOn: modifier(shiftKey)).help("Shift")
                Toggle("⌘", isOn: modifier(cmdKey)).help("Command")
            }.toggleStyle(.button)
            LabeledContent("主键") {
                Button(isCapturingKey ? "按下单个主键…" : key.keyName) { isCapturingKey = true }
                    .frame(minWidth: 140)
                    .accessibilityIdentifier("manualShortcutKey")
                    .background(ShortcutKeyCapture(isRecording: isCapturingKey, onShortcut: {
                        key = $0
                        isCapturingKey = false
                    }, onCancel: { isCapturingKey = false }).frame(width: 0, height: 0))
            }
            Text("组合：\(candidate.displayName)").font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("manualShortcutConflict")
            }
            HStack {
                Spacer()
                Button("取消", action: dismiss)
                Button("保存") {
                    shortcuts.choose(candidate)
                    if let problem = shortcuts.errorMessage { errorMessage = problem }
                    else { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCapturingKey)
            }
        }.padding(20).frame(width: 340)
    }

    private var candidate: GlobalShortcut {
        GlobalShortcut(keyCode: key.keyCode, modifiers: modifiers, keyName: key.keyName)
    }

    private func modifier(_ flag: Int) -> Binding<Bool> {
        Binding(get: { modifiers & UInt32(flag) != 0 }, set: { enabled in
            if enabled { modifiers |= UInt32(flag) }
            else { modifiers &= ~UInt32(flag) }
        })
    }
}

final class ShortcutCaptureView: NSView {
    var isRecording = false
    var onShortcut: ((GlobalShortcut) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?() }
        else { onShortcut?(GlobalShortcut(event: event)) }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { onCancel?() }
        return true
    }
}
