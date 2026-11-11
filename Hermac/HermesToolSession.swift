import Foundation

@MainActor
protocol HermesToolClient: TranslationClient {
    var onDisconnect: ((String?) -> Void)? { get set }
}

extension HermesService: HermesToolClient {}

/// A single tool-free model operation. Its hidden session is removed before
/// returning, so tools can show their result without keeping a conversation.
@MainActor
final class HermesToolSession {
    struct ImageAttachment {
        let data: Data
        let filename: String
        let ext: String

        init(url: URL) throws {
            data = try Data(contentsOf: url)
            filename = url.lastPathComponent
            ext = url.pathExtension
        }
    }

    var onCleanupFailure: ((String) -> Void)?
    private let client: any HermesToolClient
    private var sessionID: String?
    private var launcherPath = HermesService.defaultLauncherPath
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var partialText = ""
    private var cancelled = false

    init(client: any HermesToolClient = HermesService()) {
        self.client = client
        client.onEvent = { [weak self] in self?.receive($0) }
        client.onDisconnect = { [weak self] message in
            self?.complete(.failure(HermesServiceError(message: message ?? "Hermes 连接已断开。")))
        }
    }

    func run(prompt: String, launcherPath: String, image: ImageAttachment? = nil) async throws -> String {
        self.launcherPath = launcherPath
        result = nil
        partialText = ""
        cancelled = false
        do {
            try await deleteSession()
            if !client.isConnected { try await client.connect(launcherPath: launcherPath) }
            try checkCancellation()
            let created = try await client.request("session.create", params: [
                "source": .string("tool"), "hidden": .bool(true), "toolsets": .array([]),
                "max_turns": .number(1), "accept_hooks": .bool(false),
                "title": .string("Hermac Reminder \(UUID().uuidString)"), "request_id": .string(UUID().uuidString)
            ])
            guard let id = created["session_id"].stringValue else { throw CocoaError(.coderReadCorrupt) }
            sessionID = id
            try checkCancellation()
            var params: [String: JSONValue] = ["session_id": .string(id), "text": .string(prompt),
                                               "input_id": .string(UUID().uuidString)]
            if let image {
                let staged = try await client.request("image.attach_bytes", params: [
                    "session_id": .string(id), "content_base64": .string(image.data.base64EncodedString()),
                    "filename": .string(image.filename), "ext": .string(image.ext)
                ])
                guard let path = staged["path"].stringValue, let mime = staged["mime"].stringValue else {
                    throw HermesServiceError(message: "Hermes 未能接收上下文截图。")
                }
                params["attachments"] = .array([.object(["path": .string(path), "mime": .string(mime)])])
            }
            try checkCancellation()
            _ = try await client.request("prompt.submit", params: params)
            let value = try await waitForResult()
            try await deleteSession()
            return value
        } catch {
            timeout?.cancel()
            do { try await deleteSession() }
            catch { onCleanupFailure?(error.localizedDescription) }
            throw error
        }
    }

    func cancel() {
        cancelled = true
        complete(.failure(CancellationError()))
    }

    func disconnect() { client.disconnect() }

    private func checkCancellation() throws {
        if cancelled { throw CancellationError() }
    }

    private func waitForResult() async throws -> String {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) }
                catch { return }
                self?.complete(.failure(HermesServiceError(message: "整理日程超时，请重新选择文本后再试。")))
            }
        }
    }

    private func receive(_ event: HermesEvent) {
        guard event.sessionID == sessionID, sessionID != nil else { return }
        if event.type == "message.delta", let text = event.payload["text"].stringValue { partialText += text }
        if event.type == "message.complete" {
            if event.payload["status"].stringValue == "error" {
                complete(.failure(HermesServiceError(message: event.payload["error"].stringValue ?? "整理日程失败，请重试。")))
            } else {
                let text = event.payload["text"].stringValue ?? ""
                complete(.success(text.isEmpty ? partialText : text))
            }
        }
    }

    private func complete(_ value: Result<String, Error>) {
        guard result == nil else { return }
        result = value
        timeout?.cancel()
        continuation?.resume(with: value)
        continuation = nil
    }

    private func deleteSession() async throws {
        guard let id = sessionID else { return }
        if !client.isConnected { try await client.connect(launcherPath: launcherPath) }
        let params: [String: JSONValue] = ["session_id": .string(id), "omit_messages": .bool(true)]
        var snapshot = try await client.request("session.resume", params: params)
        if snapshot["running"].boolValue == true {
            _ = try await client.request("session.interrupt", params: ["session_id": .string(id),
                                                                     "execution_generation": snapshot["execution_generation"]])
            let deadline = Date().addingTimeInterval(30)
            repeat {
                try await Task.sleep(for: .milliseconds(200))
                snapshot = try await client.request("session.resume", params: params)
            } while snapshot["running"].boolValue == true && Date() < deadline
            guard snapshot["running"].boolValue != true else { throw HermesServiceError(message: "Hermes 尚未停止，请稍后重试清理。") }
        }
        _ = try await client.request("session.mutate", params: [
            "session_id": .string(id), "request_id": .string(UUID().uuidString),
            "expected_revision": snapshot["revision"], "expected_generation": snapshot["execution_generation"],
            "operation": .string("delete"), "payload": .object([:])
        ])
        sessionID = nil
    }
}
