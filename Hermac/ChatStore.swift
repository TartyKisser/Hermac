import Foundation
import Observation

@MainActor @Observable
final class ChatStore {
    enum ConnectionState: Equatable {
        case disconnected, connecting, connected
    }

    var conversations: [Conversation] = []
    var selectedID: String?
    var messages: [ChatMessage] = []
    var prompts: [AgentPrompt] = []
    var drafts: [String: String] = [:]
    var connection: ConnectionState = .disconnected
    var isLoading = false
    var isSubmitting = false
    var isBranching = false
    var errorMessage: String?
    var activity = ""
    var model = ""
    var search = ""
    var composerFocus = 0
    var launcherPath = UserDefaults.standard.string(forKey: "hermesLauncher")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hermes").path

    @ObservationIgnored private let service: HermesService
    @ObservationIgnored var onConversationsChanged: (() -> Void)?
    @ObservationIgnored private var snapshots: [String: JSONValue] = [:]
    @ObservationIgnored private var runningIDs: Set<String> = []
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var loadingEvents: [HermesEvent] = []
    @ObservationIgnored private var streamID: String?
    @ObservationIgnored private var selectionVersion = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(service: HermesService = HermesService()) {
        self.service = service
        service.onEvent = { [weak self] event in self?.receive(event) }
        service.onDisconnect = { [weak self] message in
            guard let self else { return }
            connection = .disconnected
            activity = ""
            if let message { errorMessage = message }
        }
    }

    var filteredConversations: [Conversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var selectedConversation: Conversation? { conversations.first { $0.id == selectedID } }
    var title: String { selectedConversation?.title ?? "新对话" }
    var isRunning: Bool { selectedID.map { runningIDs.contains($0) } ?? false }
    var draftKey: String { selectedID ?? "new" }
    var draft: String {
        get { drafts[draftKey] ?? "" }
        set { drafts[draftKey] = newValue }
    }
    var canSend: Bool {
        connection == .connected && !isLoading && !isSubmitting && !isBranching && !isRunning
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func connect() async {
        guard connection != .connecting else { return }
        connection = .connecting
        errorMessage = nil
        do {
            try await service.connect(launcherPath: launcherPath)
            UserDefaults.standard.set(launcherPath, forKey: "hermesLauncher")
            connection = .connected
            try await refreshConversations()
            if let selectedID { await select(selectedID) }
        } catch {
            connection = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func refreshConversations() async throws {
        async let stored = service.request("session.list", params: ["scope": .string("stored"), "limit": .number(200)])
        async let live = service.request("session.list", params: ["scope": .string("live"), "limit": .number(200)])
        let results = try await (stored, live)
        var rows: [String: Conversation] = [:]
        for value in (results.0["sessions"].arrayValue ?? []) + (results.1["sessions"].arrayValue ?? []) {
            let conversation = Conversation(value)
            if !conversation.id.isEmpty, conversation.isLocalConversation { rows[conversation.id] = conversation }
        }
        conversations = rows.values.sorted { $0.startedAt > $1.startedAt }
        runningIDs = Set(conversations.filter(\.isRunning).map(\.id))
        onConversationsChanged?()
    }

    func newConversation() {
        selectionVersion += 1
        selectedID = nil
        messages = []
        prompts = []
        streamID = nil
        activity = ""
        model = ""
        isLoading = false
        loadingEvents = []
        composerFocus += 1
    }

    func select(_ id: String) async {
        selectionVersion += 1
        let version = selectionVersion
        selectedID = id
        messages = []
        prompts = []
        streamID = nil
        activity = ""
        isLoading = true
        loadingEvents = []
        defer { if selectionVersion == version { isLoading = false } }
        do {
            let snapshot = try await service.request("session.resume", params: ["session_id": .string(id), "display_projection": .bool(true)])
            snapshots[id] = snapshot
            guard selectionVersion == version else { return }
            apply(snapshot)
            isLoading = false
            let events = loadingEvents
            loadingEvents = []
            for event in events where event.sequence == nil || event.sequence! > (snapshot["last_sequence"].intValue ?? 0) {
                receive(event)
            }
        } catch {
            if selectionVersion == version { errorMessage = error.localizedDescription }
        }
    }

    private func apply(_ snapshot: JSONValue) {
        messages = ChatMessage.transcript(snapshot)
        model = snapshot["info"]["model"].stringValue ?? ""
        let id = snapshot["session_id"].stringValue ?? selectedID ?? ""
        if snapshot["running"].boolValue == true { runningIDs.insert(id) } else { runningIDs.remove(id) }
        let generation = snapshot["execution_generation"].intValue ?? 0
        generations[id] = generation
        prompts = (snapshot["prompts"].arrayValue ?? []).map {
            AgentPrompt($0, sessionID: id, kind: $0["kind"].stringValue ?? "approval", generation: generation)
        }
        if isRunning { activity = prompts.isEmpty ? "Hermes 正在处理…" : "等待你的回复" }
    }

    @discardableResult
    func send(images: [URL] = []) async -> Bool {
        guard canSend else { return false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDraft = draft
        let oldKey = draftKey
        let version = selectionVersion
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        var submitted = false
        do {
            var id = selectedID
            if id == nil {
                let snapshot = try await service.request("session.create", params: [
                    "source": .string("gui"), "request_id": .string(UUID().uuidString),
                    "cwd": .string(FileManager.default.homeDirectoryForCurrentUser.path)
                ])
                guard let created = snapshot["session_id"].stringValue else { throw CocoaError(.coderReadCorrupt) }
                id = created
                snapshots[created] = snapshot
                if selectionVersion == version {
                    selectedID = created
                    apply(snapshot)
                }
            }
            guard let id else { return false }
            var attachments: [JSONValue] = []
            for image in images {
                attachments.append(try await service.stageImage(at: image, sessionID: id))
            }
            let optimisticID = UUID().uuidString
            if selectedID == id, selectionVersion == version {
                messages.append(ChatMessage(id: optimisticID, role: "user", text: text,
                                            imagePaths: attachments.compactMap { $0["path"].stringValue }))
                streamID = nil
                activity = "Hermes 正在思考…"
            }
            if drafts[oldKey] == originalDraft { drafts[oldKey] = "" }
            runningIDs.insert(id)
            do {
                var params: [String: JSONValue] = [
                    "session_id": .string(id), "text": .string(text),
                    "input_id": .string(UUID().uuidString)
                ]
                if !attachments.isEmpty { params["attachments"] = .array(attachments) }
                let receipt = try await service.request("prompt.submit", params: params)
                submitted = true
                if let generation = receipt["execution_generation"].intValue {
                    setGeneration(generation, for: id)
                }
                if receipt["status"].stringValue == "unknown" {
                    errorMessage = "Hermes 尚未确认这条消息的状态。请刷新会话查看结果，避免重复发送。"
                }
            } catch {
                // A dropped reply may still mean the owner accepted the message. Re-read history,
                // and leave the user's text available without automatically submitting it again.
                runningIDs.remove(id)
                drafts[id] = text
                errorMessage = error.localizedDescription
                if selectedID == id, selectionVersion == version { await select(id) }
            }
            try await refreshConversations()
        } catch {
            if !submitted, selectionVersion == version { draft = originalDraft }
            errorMessage = error.localizedDescription
        }
        return submitted
    }

    func interrupt() async {
        guard let id = selectedID else { return }
        do {
            _ = try await service.request("session.interrupt", params: [
                "session_id": .string(id), "execution_generation": .number(Double(snapshots[id]?["execution_generation"].intValue ?? 0))
            ])
            activity = "正在停止…"
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ conversation: Conversation, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        await mutate(conversation, operation: "rename", payload: ["title": .string(title)])
    }

    func branch(after message: ChatMessage) async {
        guard connection == .connected, !isRunning, !isSubmitting, !isBranching,
              let id = selectedID, let rowID = message.persistedRowID, message.canBranch else { return }
        let version = selectionVersion
        isBranching = true
        errorMessage = nil
        defer { isBranching = false }
        do {
            let snapshot = try await service.request("session.resume", params: [
                "session_id": .string(id), "display_projection": .bool(true)
            ])
            snapshots[id] = snapshot
            // A compression or another client's rewind may have retired the old row.
            guard ChatMessage.transcript(snapshot).contains(where: { $0.persistedRowID == rowID && $0.canBranch }) else {
                throw HermesServiceError(message: "这条回复的上下文已发生变化，请刷新会话后重新选择分支位置。")
            }
            let canonicalID = snapshot["session_id"].stringValue ?? id
            let result = try await service.request("session.mutate", params: [
                "session_id": .string(canonicalID), "request_id": .string(UUID().uuidString),
                "expected_revision": snapshot["revision"], "expected_generation": snapshot["execution_generation"],
                "operation": .string("branch"), "payload": .object(["through_message_id": .number(Double(rowID))])
            ])
            guard let child = result["branched_session_id"].stringValue else { throw CocoaError(.coderReadCorrupt) }
            try await refreshConversations()
            if selectedID == id, selectionVersion == version {
                search = ""
                await select(child)
                composerFocus += 1
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ conversation: Conversation) async {
        await mutate(conversation, operation: "delete", payload: [:])
    }

    private func mutate(_ conversation: Conversation, operation: String, payload: [String: JSONValue]) async {
        do {
            let snapshot = try await service.request("session.resume", params: ["session_id": .string(conversation.id), "omit_messages": .bool(true)])
            _ = try await service.request("session.mutate", params: [
                "session_id": .string(conversation.id), "request_id": .string(UUID().uuidString),
                "expected_revision": snapshot["revision"], "expected_generation": snapshot["execution_generation"],
                "operation": .string(operation), "payload": .object(payload)
            ])
            if operation == "delete", selectedID == conversation.id { newConversation() }
            try await refreshConversations()
        } catch { errorMessage = error.localizedDescription }
    }

    func answer(_ prompt: AgentPrompt, answer: String) async {
        do {
            var params: [String: JSONValue] = [
                "session_id": .string(prompt.sessionID), "prompt_id": .string(prompt.id),
                "execution_generation": .number(Double(prompt.generation))
            ]
            params[prompt.kind == "approval" ? "choice" : "answer"] = .string(answer)
            _ = try await service.request("\(prompt.kind).respond", params: params)
            prompts.removeAll { $0.id == prompt.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private func setGeneration(_ generation: Int, for id: String) {
        generations[id] = generation
        if case .object(var object) = snapshots[id] {
            object["execution_generation"] = .number(Double(generation))
            snapshots[id] = .object(object)
        }
    }

    func receive(_ event: HermesEvent) {
        guard let id = event.sessionID else { return }
        if isLoading, selectedID == id { loadingEvents.append(event); return }
        if let generation = event.executionGeneration, generation < (generations[id] ?? 0) { return }
        if let generation = event.executionGeneration { setGeneration(generation, for: id) }
        switch event.type {
        case "message.start":
            runningIDs.insert(id)
            if selectedID == id { streamID = nil; activity = "Hermes 正在思考…" }
        case "message.delta":
            guard selectedID == id else { return }
            guard let text = event.payload["text"].stringValue else { streamID = nil; return }
            appendDelta(text)
            activity = "正在回复…"
        case "message.interim":
            guard selectedID == id else { return }
            if event.payload["already_streamed"].boolValue != true,
               let text = event.payload["text"].stringValue, !text.isEmpty {
                messages.append(ChatMessage(role: "assistant", text: text))
            }
            streamID = nil
        case "tool.start":
            if selectedID == id { activity = "正在使用 \(event.payload["name"].stringValue ?? "工具")…"; streamID = nil }
        case "tool.complete":
            if selectedID == id { activity = "Hermes 正在处理…" }
        case "approval.request", "clarify.request":
            let kind = String(event.type.split(separator: ".")[0])
            let prompt = AgentPrompt(event.payload, sessionID: id, kind: kind, generation: event.executionGeneration ?? 0)
            if selectedID == id, !prompts.contains(where: { $0.id == prompt.id }) { prompts.append(prompt); activity = "等待你的回复" }
        case "approval.settled", "clarify.settled":
            prompts.removeAll { $0.sessionID == id && $0.id == event.payload["prompt_id"].stringValue }
        case "message.complete":
            runningIDs.remove(id)
            if selectedID == id {
                if let text = event.payload["text"].stringValue, !text.isEmpty,
                   !((event.payload["response_reused"].boolValue == true || event.payload["response_previewed"].boolValue == true)
                     && messages.contains(where: { $0.role == "assistant" && $0.text == text })) {
                    if let streamID, let index = messages.firstIndex(where: { $0.id == streamID }) { messages[index].text = text }
                    else { messages.append(ChatMessage(role: "assistant", text: text)) }
                }
                streamID = nil
                activity = ""
                if event.payload["status"].stringValue == "error" {
                    errorMessage = event.payload["error"].stringValue ?? "Hermes 处理失败，请检查模型配置后重试。"
                }
            }
            scheduleRefresh(id)
        case "session.updated", "session.title", "session.renamed": scheduleRefresh(id)
        case "session.replay_gap":
            if selectedID == id { Task { await select(id) } }
        default: break
        }
    }

    private func appendDelta(_ text: String) {
        guard !text.isEmpty else { return }
        if let streamID, let index = messages.firstIndex(where: { $0.id == streamID }) { messages[index].text += text }
        else {
            let message = ChatMessage(role: "assistant", text: text)
            streamID = message.id
            messages.append(message)
        }
    }

    private func scheduleRefresh(_ id: String) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            do {
                try await refreshConversations()
                if selectedID == id, !isRunning {
                    let version = selectionVersion
                    let snapshot = try await service.request("session.resume", params: ["session_id": .string(id), "display_projection": .bool(true)])
                    snapshots[id] = snapshot
                    if selectionVersion == version, !isRunning { apply(snapshot) }
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func disconnect() { service.disconnect() }
}
