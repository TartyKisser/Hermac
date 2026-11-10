import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var intValue: Int? { if case .number(let value) = self { Int(exactly: value) } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    subscript(key: String) -> JSONValue { objectValue?[key] ?? .null }
}

struct HermesEvent: Sendable {
    let type: String
    let sessionID: String?
    let payload: JSONValue
    let executionGeneration: Int?
    let sequence: Int?
}

struct HermesServerRequest: Sendable {
    let id: JSONValue
    let method: String
    let params: JSONValue
}

struct HermesServiceError: LocalizedError, Sendable {
    let message: String
    let code: Int?
    let data: JSONValue

    init(message: String, code: Int? = nil, data: JSONValue = .null) {
        self.message = message
        self.code = code
        self.data = data
    }

    var errorDescription: String? {
        let details = [data["field"].stringValue, data["detail"].stringValue,
                       data["fields"].arrayValue?.compactMap(\.stringValue).joined(separator: ", ")]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return details.isEmpty ? message : message + "：" + details.joined(separator: " · ")
    }
}

/// Hermes remains the authority for sessions and execution; this client only transports RPC.
@MainActor
final class HermesService {
    var onEvent: ((HermesEvent) -> Void)?
    var onServerRequest: ((HermesServerRequest) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    private(set) var isConnected = false

    static var defaultLauncherPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [".local/bin/hermes", ".hermes/hermes-agent/.hermes/bin/hermes"]
        return candidates.map { home.appendingPathComponent($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? home.appendingPathComponent(candidates[0]).path
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private var startupDeadline: Task<Void, Never>?

    func connect(launcherPath: String = HermesService.defaultLauncherPath) async throws {
        disconnect()
        let launcher = NSString(string: launcherPath).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            throw HermesServiceError(message: "找不到 Hermes。请在设置中选择 Hermes 可执行文件。")
        }
        guard let helper = Bundle.main.url(forResource: "hermac_bridge", withExtension: "py") else {
            throw HermesServiceError(message: "App 中缺少 Hermes 连接组件，请重新编译。")
        }
        // Ask the published launcher for its runtime, rather than pinning a versioned Python path.
        let commandData = try await Self.runLauncher(launcher, arguments: [
            "--print-runtime-command", "--module", "types", "--", helper.path
        ])
        var command: [String]
        do { command = try JSONDecoder().decode([String].self, from: commandData) }
        catch { throw HermesServiceError(message: "Hermes 未提供运行时命令，请更新 Hermes 后重试。") }
        guard let executable = command.first else {
            throw HermesServiceError(message: "Hermes 返回了空的运行时命令。")
        }
        guard let codeIndex = command.firstIndex(of: "-c"), command.indices.contains(codeIndex + 1) else {
            throw HermesServiceError(message: "Hermes 运行时命令格式不受支持，请更新 Hermes 后重试。")
        }
        // Keep Hermes's generated dependency bootstrap, then run our bundled file in that runtime.
        // `types` is an inert standard-library module; runpy's CLI accepts modules rather than files.
        command[codeIndex + 1] += ";runpy.run_path(sys.argv[1], run_name='__main__')"

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = Array(command.dropFirst())
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        // A GUI launch has a minimal PATH. Preserve common local tool locations for Hermes tools.
        environment["PATH"] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        ].joined(separator: ":")
        child.environment = environment
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        diagnostics = stderrPipe.fileHandleForReading
        process = child

        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data, from: child) }
        }
        diagnostics?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.process === child else { return }
                self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(4000))
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.process === child else { return }
                let message = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                self.finish(message: message.isEmpty ? "Hermes 连接已断开。请重新连接。" : message)
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            startupDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self else { return }
                self.finish(message: "连接 Hermes 超时，请检查 Hermes 是否可以在终端正常运行。")
            }
            do { try child.run() }
            catch { finish(message: "无法启动 Hermes：\(error.localizedDescription)") }
        }
    }

    func request(_ method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard isConnected else { throw HermesServiceError(message: "Hermes 尚未连接。") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(125))
                guard !Task.isCancelled, let self else { return }
                self.deadlines.removeValue(forKey: id)
                self.pending.removeValue(forKey: id)?.resume(throwing: HermesServiceError(
                    message: "Hermes 请求超时。请重新打开会话检查结果后再决定是否重试。"))
            }
            do {
                try write(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                   "method": .string(method), "params": .object(params)]))
            } catch {
                deadlines.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    /// The canonical gateway accepts image paths only from its own staging cache.
    /// Upload first, then pass this reference in prompt.submit's attachments array.
    func stageImage(at url: URL, sessionID: String) async throws -> JSONValue {
        let data = try Data(contentsOf: url)
        let result = try await request("image.attach_bytes", params: [
            "session_id": .string(sessionID), "content_base64": .string(data.base64EncodedString()),
            "filename": .string(url.lastPathComponent), "ext": .string(url.pathExtension)
        ])
        guard let path = result["path"].stringValue, let mime = result["mime"].stringValue else {
            throw HermesServiceError(message: "Hermes 未能接收屏幕截图。")
        }
        return .object(["path": .string(path), "mime": .string(mime)])
    }

    func respond(to request: HermesServerRequest, result: JSONValue) async throws {
        try write(.object(["jsonrpc": .string("2.0"), "id": request.id, "result": result]))
    }

    func disconnect() {
        cleanup()
        let error = HermesServiceError(message: "Hermes 连接已关闭。")
        startup?.resume(throwing: error)
        startup = nil
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
    }

    private func receive(_ data: Data, from child: Process) {
        guard process === child, !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty, let frame = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
            if let method = frame["method"].stringValue {
                if method == "event" {
                    let params = frame["params"]
                    guard let type = params["type"].stringValue else { continue }
                    if type == "bridge.ready" {
                        isConnected = true
                        startupDeadline?.cancel()
                        startupDeadline = nil
                        startup?.resume()
                        startup = nil
                    } else if type == "bridge.error" {
                        finish(message: params["payload"]["message"].stringValue ?? "Hermes 连接失败。")
                    } else {
                        onEvent?(HermesEvent(type: type, sessionID: params["session_id"].stringValue,
                            payload: params["payload"],
                            executionGeneration: params["execution_generation"].intValue
                                ?? params["payload"]["execution_generation"].intValue,
                            sequence: params["seq"].intValue))
                    }
                } else {
                    let request = HermesServerRequest(id: frame["id"], method: method, params: frame["params"])
                    if let onServerRequest { onServerRequest(request) }
                    else {
                        try? write(.object(["jsonrpc": .string("2.0"), "id": request.id,
                            "error": .object(["code": .number(-32601),
                                "message": .string("Hermac does not support this request yet")])]))
                    }
                }
            } else if let id = frame["id"].intValue, let continuation = pending.removeValue(forKey: id) {
                deadlines.removeValue(forKey: id)?.cancel()
                if frame["error"] != .null {
                    continuation.resume(throwing: HermesServiceError(
                        message: frame["error"]["message"].stringValue
                            ?? frame["error"]["data"]["reason"].stringValue ?? "Hermes 请求失败。",
                        code: frame["error"]["code"].intValue, data: frame["error"]["data"]))
                } else { continuation.resume(returning: frame["result"]) }
            }
        }
    }

    private func write(_ frame: JSONValue) throws {
        guard let input else { throw HermesServiceError(message: "Hermes 连接已关闭。") }
        var data = try JSONEncoder().encode(frame)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func finish(message: String) {
        let error = HermesServiceError(message: message)
        cleanup()
        startup?.resume(throwing: error)
        startup = nil
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        onDisconnect?(message)
    }

    private func cleanup() {
        isConnected = false
        startupDeadline?.cancel()
        startupDeadline = nil
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        output?.readabilityHandler = nil
        diagnostics?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? diagnostics?.close()
        input = nil
        output = nil
        diagnostics = nil
        let child = process
        process = nil
        child?.terminationHandler = nil
        if child?.isRunning == true { child?.terminate() }
        buffer.removeAll()
        stderrTail = ""
    }

    private static func runLauncher(_ path: String, arguments: [String]) async throws -> Data {
        try await Task.detached {
            let task = Process()
            let output = Pipe(), errorOutput = Pipe()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = arguments
            task.standardOutput = output
            task.standardError = errorOutput
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errors = errorOutput.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                let detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw HermesServiceError(message: detail.isEmpty ? "无法读取 Hermes 运行时命令。" : detail)
            }
            return data
        }.value
    }
}
