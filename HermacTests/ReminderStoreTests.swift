import XCTest
@testable import Hermac

@MainActor
final class ReminderStoreTests: XCTestCase {
    private let reply = #"{"title":"评审方案","notes":"带上文档","location":"会议室A","date":"2026-11-11","time":"15:00","priority":5}"#

    func testExtractionIsHiddenAndDeletesBeforeReviewWithoutCreatingReminder() async {
        let client = ModelClient()
        client.reply = reply
        let reminders = ReminderClient()
        let store = ReminderStore(tool: HermesToolSession(client: client), reminders: reminders)
        store.begin(selectedText: "明天下午三点去会议室A评审方案", context: "带上文档", appName: "测试 App", launcherPath: "/test/hermes")
        await store.waitForPendingOperation()
        XCTAssertEqual(store.phase, .review)
        XCTAssertEqual(store.draft.title, "评审方案")
        XCTAssertTrue(reminders.created.isEmpty)
        XCTAssertEqual(client.deleted, ["reminder-1"])
        let create = client.calls.first { $0.0 == "session.create" }!.1
        XCTAssertEqual(create["hidden"], .bool(true))
        XCTAssertEqual(create["toolsets"], .array([]))
        XCTAssertEqual(create["accept_hooks"], .bool(false))
        XCTAssertEqual(create["max_turns"], .number(1))
        let prompt = client.calls.first { $0.0 == "prompt.submit" }!.1["text"]!.stringValue!
        XCTAssertTrue(prompt.contains("当前本地时间"))
        XCTAssertTrue(prompt.contains("时区"))
        XCTAssertTrue(prompt.contains("不能猜测"))
    }

    func testOnlyConfirmationSavesEditedFieldsAndDuplicateClicksDoNotCreateTwice() async {
        let client = ModelClient()
        client.reply = reply
        let reminders = ReminderClient()
        let store = ReminderStore(tool: HermesToolSession(client: client), reminders: reminders)
        store.begin(selectedText: "test", context: "", appName: "Test", launcherPath: "/test/hermes")
        await store.waitForPendingOperation()
        store.draft.title = "已修改的标题"
        store.draft.calendarID = "chosen-list"
        store.draft.location = "会议室B"
        store.confirm()
        store.confirm()
        await store.waitForPendingOperation()
        XCTAssertEqual(store.phase, .success)
        XCTAssertEqual(reminders.created.count, 1)
        XCTAssertEqual(reminders.created[0].title, "已修改的标题")
        XCTAssertEqual(reminders.created[0].calendarID, "chosen-list")
        XCTAssertEqual(reminders.created[0].location, "会议室B")
        XCTAssertEqual(store.createdIdentifier, "created-reminder")
    }

    func testClosingDuringSessionCreateDeletesWithoutSubmittingOrSaving() async {
        let client = ModelClient()
        client.pauseCreate = true
        let reminders = ReminderClient()
        let store = ReminderStore(tool: HermesToolSession(client: client), reminders: reminders)
        store.begin(selectedText: "test", context: "", appName: "Test", launcherPath: "/test/hermes")
        while client.creation == nil { await Task.yield() }
        store.close()
        client.creation?.resume(returning: .object(["session_id": .string("reminder-1")]))
        client.creation = nil
        await store.waitForPendingOperation()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(client.deleted, ["reminder-1"])
        XCTAssertFalse(client.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertTrue(reminders.created.isEmpty)
    }

    func testClosingDuringPermissionRequestPreventsCreation() async {
        let client = ModelClient()
        client.reply = reply
        let reminders = ReminderClient()
        let store = ReminderStore(tool: HermesToolSession(client: client), reminders: reminders)
        store.begin(selectedText: "test", context: "", appName: "Test", launcherPath: "/test/hermes")
        await store.waitForPendingOperation()
        reminders.pausePermission = true
        store.confirm()
        while reminders.permission == nil { await Task.yield() }
        store.close()
        reminders.permission?.resume()
        reminders.permission = nil
        await store.waitForPendingOperation()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(reminders.created.isEmpty)
    }

    func testSaveFailureKeepsEditsAndAllowsExplicitRetry() async {
        let client = ModelClient()
        client.reply = reply
        let reminders = ReminderClient()
        let store = ReminderStore(tool: HermesToolSession(client: client), reminders: reminders)
        store.begin(selectedText: "test", context: "", appName: "Test", launcherPath: "/test/hermes")
        await store.waitForPendingOperation()
        store.draft.notes = "用户补充内容"
        reminders.failSave = true
        store.confirm()
        await store.waitForPendingOperation()
        XCTAssertEqual(store.phase, .review)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.draft.notes, "用户补充内容")
        reminders.failSave = false
        store.confirm()
        await store.waitForPendingOperation()
        XCTAssertEqual(store.phase, .success)
        XCTAssertEqual(reminders.created.count, 1)
    }

    func testReplacementIgnoresOldEventsAndCleansBothSessions() async {
        let client = ModelClient()
        client.reply = nil
        let store = ReminderStore(tool: HermesToolSession(client: client), reminders: ReminderClient())
        store.begin(selectedText: "first", context: "", appName: "Test", launcherPath: "/test/hermes")
        while !client.calls.contains(where: { $0.0 == "prompt.submit" }) { await Task.yield() }
        store.begin(selectedText: "second", context: "", appName: "Test", launcherPath: "/test/hermes")
        while client.count < 2 || !client.calls.contains(where: { $0.0 == "prompt.submit" && $0.1["session_id"] == .string("reminder-2") }) { await Task.yield() }
        client.event(id: "reminder-1", text: #"{"title":"stale"}"#)
        client.event(id: "reminder-2", text: reply)
        await store.waitForPendingOperation()
        XCTAssertEqual(store.phase, .review)
        XCTAssertEqual(store.draft.title, "评审方案")
        XCTAssertEqual(client.deleted, ["reminder-1", "reminder-2"])
        await store.shutdown()
        XCTAssertFalse(client.isConnected)
    }

    func testContextImageIsReadBeforeCallerDeletesTemporaryFile() async throws {
        let client = ModelClient()
        client.reply = reply
        let store = ReminderStore(tool: HermesToolSession(client: client), reminders: ReminderClient())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermac-reminder-test-\(UUID().uuidString).png")
        let image = Data([137, 80, 78, 71])
        try image.write(to: url)
        store.begin(selectedText: "test", context: "", appName: "Test", launcherPath: "/test/hermes", imageURL: url)
        try FileManager.default.removeItem(at: url)
        await store.waitForPendingOperation()
        XCTAssertEqual(client.calls.first { $0.0 == "image.attach_bytes" }?.1["content_base64"], .string(image.base64EncodedString()))
        XCTAssertEqual(client.calls.first { $0.0 == "prompt.submit" }?.1["attachments"], .array([
            .object(["path": .string("/staged/context.png"), "mime": .string("image/png")])
        ]))
        XCTAssertEqual(store.phase, .review)
    }

    private final class ReminderClient: RemindersClient {
        var hasAccess = true
        var created: [ReminderDraft] = []
        var failSave = false
        var pausePermission = false
        var permission: CheckedContinuation<Void, Never>?
        func requestAccess() async throws {
            if pausePermission { await withCheckedContinuation { permission = $0 } }
            hasAccess = true
        }
        func availableLists() -> [ReminderList] { [ReminderList(id: "chosen-list", title: "测试清单")] }
        func create(_ draft: ReminderDraft) throws -> String {
            if failSave { throw HermesServiceError(message: "test save failure") }
            created.append(draft)
            return "created-reminder"
        }
    }

    private final class ModelClient: HermesToolClient {
        var onEvent: ((HermesEvent) -> Void)?
        var onDisconnect: ((String?) -> Void)?
        var isConnected = false
        var calls: [(String, [String: JSONValue])] = []
        var deleted: [String] = []
        var count = 0
        var reply: String?
        var pauseCreate = false
        var creation: CheckedContinuation<JSONValue, Error>?
        func connect(launcherPath: String) async throws { isConnected = true }
        func disconnect() { isConnected = false }
        func request(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
            calls.append((method, params))
            switch method {
            case "session.create":
                count += 1
                if pauseCreate { return try await withCheckedThrowingContinuation { creation = $0 } }
                return .object(["session_id": .string("reminder-\(count)")])
            case "prompt.submit":
                if let reply { event(id: params["session_id"]!.stringValue!, text: reply) }
            case "session.resume":
                return .object(["revision": .number(1), "execution_generation": .number(1), "running": .bool(false)])
            case "session.mutate": deleted.append(params["session_id"]!.stringValue!)
            case "image.attach_bytes": return .object(["path": .string("/staged/context.png"), "mime": .string("image/png")])
            default: break
            }
            return .object([:])
        }
        func event(id: String, text: String) {
            onEvent?(HermesEvent(type: "message.complete", sessionID: id,
                                 payload: .object(["text": .string(text)]), executionGeneration: 1, sequence: nil))
        }
    }
}
