import SwiftUI

struct QuickChatView: View {
    @Bindable var store: ChatStore
    @Bindable var presentation: QuickChatPresentation
    let send: () -> Void
    let beginConversation: () -> Void
    let updateLayout: () -> Void

    var body: some View {
        Group {
            if presentation.isExpanded {
                content
            } else {
                content
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(8)
            }
        }
        .onChange(of: store.messages.count) {
            if !store.messages.isEmpty { beginConversation() }
        }
        .onChange(of: store.title) { updateLayout() }
        .onChange(of: store.errorMessage) { updateLayout() }
        .onChange(of: presentation.composerHeight) { updateLayout() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if presentation.isExpanded {
                transcript
            }
            if let error = store.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("关闭错误提示")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 10)
            }
            if presentation.isExpanded {
                ForEach(store.prompts) { prompt in
                    PromptCard(prompt: prompt) { answer in await store.answer(prompt, answer: answer) }
                        .padding(.horizontal, 12).padding(.top, 8)
                }
            }
            composer.padding(12)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(store.messages) { message in
                        MessageView(message: message,
                                    canBranch: message.canBranch && store.connection == .connected
                                        && !store.isRunning && !store.isSubmitting && !store.isBranching) {
                            Task { await store.branch(after: message) }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if presentation.isExpanded {
            composerContent
                .padding(12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            composerContent
        }
    }

    private var composerContent: some View {
        VStack(spacing: 7) {
            if store.isRunning {
                HStack(spacing: 6) {
                    HermacMark(isAnimating: true).frame(width: 20, height: 20)
                    Text(store.activity.isEmpty ? "Hermes 正在处理…" : store.activity)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 5)
            }
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if store.draft.isEmpty {
                        Text(store.connection == .connecting ? "正在连接 Hermes…" : "问问 Hermes…")
                            .foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                    ComposerEditor(text: Binding(get: { store.draft }, set: { store.draft = $0 }),
                                   height: $presentation.composerHeight,
                                   enabled: !presentation.isSending,
                                   focusToken: store.composerFocus, submit: send)
                        .frame(height: min(180, presentation.composerHeight))
                        .accessibilityIdentifier("quickChatComposer")
                }
                .font(.system(size: 14))
                Toggle("截图", isOn: $presentation.includesScreenshot)
                    .toggleStyle(.checkbox).font(.caption)
                    .padding(.bottom, 11)
                    .disabled(presentation.isSending)
                    .help("发送时附带此窗口所在屏幕的截图")
                    .accessibilityLabel("附带此屏幕截图")
                    .accessibilityIdentifier("quickChatScreenshot")
                if store.isRunning {
                    Button("停止生成", systemImage: "stop.fill") { Task { await store.interrupt() } }
                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.large)
                        .buttonBorderShape(.circle).help("停止生成")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)) }
                        .buttonStyle(.glassProminent).controlSize(.large).buttonBorderShape(.circle)
                        .disabled(!store.canSend || presentation.isSending)
                        .help("发送消息（Return）").accessibilityLabel("发送消息")
                        .accessibilityIdentifier("sendQuickChat")
                }
            }
        }
    }
}
