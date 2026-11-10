import SwiftUI

struct ContentView: View {
    @Bindable var store: ChatStore
    @State private var renameTarget: Conversation?
    @State private var deleteTarget: Conversation?
    @State private var renameText = ""
    @State private var scrollPinned = true
    @State private var isUserScrolling = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
        }
        .sheet(item: $renameTarget) { conversation in
            VStack(alignment: .leading, spacing: 20) {
                Text("重命名会话").font(.headline)
                TextField("会话名称", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { finishRename(conversation) }
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { renameTarget = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("保存") { finishRename(conversation) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
        .alert("删除这个会话？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let conversation = deleteTarget { Task { await store.delete(conversation) } }
                deleteTarget = nil
            }
        } message: {
            Text("会话及其消息将从 Hermes 中永久删除。")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { store.selectedID }, set: { id in
                if let id { Task { await store.select(id) } }
            })) {
                Section("会话") {
                    ForEach(store.filteredConversations) { conversation in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                                .frame(width: 20).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                HStack(spacing: 5) {
                                    Text(conversation.startedAt, format: .dateTime.month().day())
                                    Text("·")
                                    Text("\(conversation.messageCount) 条消息")
                                    Spacer(minLength: 0)
                                    if conversation.isRunning {
                                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                                            .accessibilityLabel("正在运行")
                                    }
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(conversation.id)
                        .contextMenu {
                            Button("重命名", systemImage: "pencil") {
                                renameText = conversation.title
                                renameTarget = conversation
                            }
                            Button("删除会话", systemImage: "trash", role: .destructive) { deleteTarget = conversation }
                                .disabled(conversation.isRunning)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $store.search, placement: .sidebar, prompt: "搜索会话")
            .overlay {
                if store.filteredConversations.isEmpty, store.connection != .connecting {
                    ContentUnavailableView {
                        Label(store.search.isEmpty ? "还没有会话" : "没有找到会话", systemImage: "bubble.left")
                    } description: {
                        Text(store.search.isEmpty ? "开始一次新的对话" : "试试其他关键词")
                    }
                }
            }
            HStack(spacing: 8) {
                if store.connection == .connecting {
                    HermacMark(isAnimating: true)
                        .frame(width: 18, height: 18)
                        .accessibilityLabel("正在连接 Hermes")
                }
                else { Circle().fill(store.connection == .connected ? .green : .secondary).frame(width: 6, height: 6) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes").font(.system(size: 12, weight: .medium))
                    Text(connectionLabel).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if store.connection == .disconnected {
                    Button("重新连接", systemImage: "arrow.clockwise") { Task { await store.connect() } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("重新连接 Hermes")
                }
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.borderless).help("设置")
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .navigationTitle("Hermac")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建对话", systemImage: "square.and.pencil") { store.newConversation() }
                    .labelStyle(.iconOnly).help("新建对话（⌘N）")
                    .accessibilityIdentifier("newConversation")
            }
        }
    }

    private var connectionLabel: String {
        switch store.connection {
        case .connected: "已连接本机"
        case .connecting: "正在连接本机…"
        case .disconnected: "未连接"
        }
    }

    private var detail: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor).ignoresSafeArea()
            if store.isLoading {
                VStack(spacing: 12) {
                    HermacMark(isAnimating: true)
                        .frame(width: 34, height: 34)
                        .accessibilityLabel("正在载入会话")
                    Text("正在载入会话…").foregroundStyle(.secondary)
                }
            } else if store.messages.isEmpty {
                welcome
            } else {
                transcript
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if let error = store.errorMessage { errorBanner(error) }
                ForEach(store.prompts) { prompt in
                    PromptCard(prompt: prompt) { answer in await store.answer(prompt, answer: answer) }
                }
                ComposerView(store: store)
            }
            .frame(maxWidth: 790)
            .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 18)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(store.title)
        .navigationSubtitle(store.model)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("刷新会话", systemImage: "arrow.clockwise") {
                        Task {
                            do { try await store.refreshConversations() }
                            catch { store.errorMessage = error.localizedDescription }
                            if let id = store.selectedID { await store.select(id) }
                        }
                    }
                    if let conversation = store.selectedConversation {
                        Button("重命名", systemImage: "pencil") { renameText = conversation.title; renameTarget = conversation }
                        Divider()
                        Button("删除会话", systemImage: "trash", role: .destructive) { deleteTarget = conversation }
                            .disabled(store.isRunning)
                    }
                } label: { Label("会话操作", systemImage: "ellipsis") }
                .disabled(store.connection != .connected)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            HermacMark()
                .frame(width: 70, height: 70)
                .padding(12)
                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            Text("从一个想法开始").font(.system(size: 27, weight: .semibold))
            Text("你的 Hermes，在 Mac 上触手可及。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                suggestion("梳理思路", icon: "lightbulb", draft: "帮我一起梳理一个想法：")
                suggestion("写点什么", icon: "text.alignleft", draft: "帮我起草一份")
                suggestion("解决问题", icon: "chevron.left.forwardslash.chevron.right", draft: "帮我分析这个问题：")
            }
            .padding(.top, 10)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestion(_ title: String, icon: String, draft: String) -> some View {
        Button { store.draft = draft; store.composerFocus += 1 } label: {
            Label(title, systemImage: icon).font(.system(size: 12)).padding(.horizontal, 5).padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(store.messages) { message in
                        MessageView(message: message,
                                    canBranch: message.canBranch && store.connection == .connected
                                        && !store.isRunning && !store.isSubmitting && !store.isBranching) {
                            Task { await store.branch(after: message) }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 730)
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 100
            } action: { _, pinned in
                if isUserScrolling { scrollPinned = pinned }
            }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
            }
            .onChange(of: store.messages.last?.text) {
                if store.messages.last?.role == "user" { scrollPinned = true }
                if scrollPinned { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.selectedID) { scrollPinned = true }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(error).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("关闭", systemImage: "xmark") { store.errorMessage = nil }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func finishRename(_ conversation: Conversation) {
        let title = renameText
        renameTarget = nil
        Task { await store.rename(conversation, to: title) }
    }
}

