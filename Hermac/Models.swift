import Foundation

struct Conversation: Identifiable, Equatable {
    let id: String
    var title: String
    var source: String
    var startedAt: Date
    var messageCount: Int
    var isRunning: Bool

    // Interactive sessions created on this Mac. Messaging lanes and scheduled/tool
    // runs have their own source labels and do not belong in this client's sidebar.
    var isLocalConversation: Bool { ["cli", "tui", "gui", "desktop", "local"].contains(source) }

    init(_ value: JSONValue) {
        id = value["session_id"].stringValue ?? value["id"].stringValue ?? ""
        title = value["title"].stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名会话"
        source = value["source"].stringValue ?? ""
        startedAt = Date(timeIntervalSince1970: value["started_at"].doubleValue ?? 0)
        messageCount = value["message_count"].intValue ?? 0
        isRunning = value["running"].boolValue ?? false
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    var text: String
    let imagePaths: [String]
    let persistedRowID: Int?
    let isArchived: Bool

    var canBranch: Bool { role == "assistant" && persistedRowID != nil }

    init(id: String = UUID().uuidString, role: String, text: String, imagePaths: [String] = [],
         persistedRowID: Int? = nil, isArchived: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.imagePaths = imagePaths
        self.persistedRowID = persistedRowID
        self.isArchived = isArchived
    }

    static func transcript(_ snapshot: JSONValue) -> [ChatMessage] {
        let rows = snapshot["display_messages"].arrayValue ?? snapshot["messages"].arrayValue ?? []
        let archivedIDs = Set((snapshot["messages"].arrayValue ?? []).compactMap { row -> Int? in
            row["archived"].boolValue == true ? row["row_id"].intValue : nil
        })
        return rows.enumerated().compactMap { index, row in
            let role = row["role"].stringValue ?? ""
            guard ["user", "assistant"].contains(role), row["display_kind"].stringValue != "hidden" else { return nil }
            let content = row["content"].arrayValue?.compactMap { $0["text"].stringValue }.joined(separator: "\n") ?? ""
            let rawText = row["text"].stringValue ?? row["content"].stringValue ?? content
            let (text, images) = role == "user" ? extractImages(from: rawText) : (rawText, [])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
            let rowID = row["row_id"].intValue.flatMap { $0 > 0 ? $0 : nil }
            let archived = row["archived"].boolValue == true || rowID.map { archivedIDs.contains($0) } == true
            let liveRowID = archived ? nil : rowID
            return ChatMessage(id: rowID.map { "row-\($0)" } ?? row["row_id"].stringValue ?? "history-\(index)",
                               role: role, text: text, imagePaths: images, persistedRowID: liveRowID, isArchived: archived)
        }
    }

    // Hermes preserves local image attachments as @image references in its
    // display projection, including quoted paths when the filename has spaces.
    private static func extractImages(from text: String) -> (String, [String]) {
        let pattern = #"@image:(?:`([^`]+)`|"([^"]+)"|'([^']+)'|([^\s]+))"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var paths: [String] = []
        var cleaned = text
        for match in matches {
            if let range = (1..<match.numberOfRanges).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) {
                paths.append(source.substring(with: range))
            }
        }
        for match in matches.reversed() {
            if let range = Range(match.range, in: cleaned) { cleaned.removeSubrange(range) }
        }
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }
}

struct AgentPrompt: Identifiable {
    let id: String
    let sessionID: String
    let kind: String
    let generation: Int
    let question: String
    let detail: String
    let choices: [String]

    init(_ value: JSONValue, sessionID: String, kind: String, generation: Int) {
        id = value["prompt_id"].stringValue ?? UUID().uuidString
        self.sessionID = sessionID
        self.kind = kind
        self.generation = value["execution_generation"].intValue ?? generation
        question = value["question"].stringValue ?? value["description"].stringValue ?? "Hermes 请求执行操作"
        detail = value["command"].stringValue ?? ""
        choices = value["choices"].arrayValue?.compactMap(\.stringValue) ?? []
    }
}

extension JSONValue {
    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
