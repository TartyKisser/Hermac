import Foundation

struct ReminderDraft: Equatable {
    var title = ""
    var notes = ""
    var location = ""
    var dueDate: Date?
    var includesTime = false
    var priority = 0
    var calendarID: String?

    static func parse(_ response: String, timeZone: TimeZone = .current) throws -> ReminderDraft {
        struct Fields: Decodable {
            let title: String
            let notes: String?
            let location: String?
            let date: String?
            let time: String?
            let priority: Int?
        }
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```"), let newline = json.firstIndex(of: "\n") {
            json = String(json[json.index(after: newline)..<json.index(json.endIndex, offsetBy: -3)])
        }
        let fields = try JSONDecoder().decode(Fields.self, from: Data(json.utf8))
        var draft = ReminderDraft()
        draft.title = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.title.isEmpty else { throw HermesServiceError(message: "没有识别到事项内容，请重新选择包含日程要求的文本。") }
        draft.notes = fields.notes ?? ""
        draft.location = fields.location ?? ""
        if let priority = fields.priority, [0, 1, 5, 9].contains(priority) { draft.priority = priority }
        if let day = fields.date {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.isLenient = false
            let value = day + (fields.time.map { " " + $0 } ?? "")
            formatter.dateFormat = fields.time == nil ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
                throw HermesServiceError(message: "模型返回的日期或时间无效，请重新整理日程。")
            }
            draft.dueDate = date
            draft.includesTime = fields.time != nil
        } else if let time = fields.time {
            draft.notes += (draft.notes.isEmpty ? "" : "\n\n") + "时间：\(time)（日期待定）"
        }
        return draft
    }

    func dueComponents(timeZone: TimeZone = .current) -> DateComponents? {
        guard let dueDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fields: Set<Calendar.Component> = includesTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        var components = calendar.dateComponents(fields, from: dueDate)
        components.calendar = calendar
        components.timeZone = timeZone
        return components
    }

    var reminderNotes: String? {
        let content = [notes.trimmingCharacters(in: .whitespacesAndNewlines),
                       location.isEmpty ? "" : "地点：\(location)"]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        return content.isEmpty ? nil : content
    }
}

struct ReminderList: Identifiable, Equatable {
    let id: String
    let title: String
}
