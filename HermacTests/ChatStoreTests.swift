import XCTest
@testable import Hermac

@MainActor
final class ChatStoreTests: XCTestCase {
    private func event(
        _ type: String,
        session: String? = "alpha",
        generation: Int = 1,
        payload: [String: JSONValue] = [:]
    ) -> HermesEvent {
        HermesEvent(type: type, sessionID: session, payload: .object(payload), executionGeneration: generation, sequence: nil)
    }

    func testStreamingSegmentsKeepInterimAndReplaceFinalTail() {
        let store = ChatStore()
        store.selectedID = "alpha"
        store.receive(event("message.start"))
        store.receive(event("message.delta", payload: ["text": .string("正在")]))
        store.receive(event("message.delta", payload: ["text": .string("检查文件。")]))
        store.receive(event("message.interim", payload: ["text": .string("正在检查文件。"), "already_streamed": .bool(true)]))
        store.receive(event("tool.start", payload: ["name": .string("read_file"), "tool_id": .string("call-1")]))
        store.receive(event("tool.complete", payload: ["name": .string("read_file"), "tool_id": .string("call-1")]))
        store.receive(event("message.delta", payload: ["text": .string("检查")]))
        store.receive(event("message.complete", payload: ["text": .string("检查完成。"), "status": .string("ok")]))

        XCTAssertEqual(store.messages.map(\.text), ["正在检查文件。", "检查完成。"])
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.activity, "")
    }

    func testUnstreamedInterimAndNullBoundaryCreateSeparateSegments() {
        let store = ChatStore()
        store.selectedID = "alpha"
        store.receive(event("message.start"))
        store.receive(event("message.interim", payload: ["text": .string("先检查配置。"), "already_streamed": .bool(false)]))
        store.receive(event("message.delta", payload: ["text": .string("第一部分。")]))
        store.receive(event("message.delta", payload: ["text": .null]))
        store.receive(event("message.delta", payload: ["text": .string("第二部分。")]))
        store.receive(event("message.complete", payload: ["status": .string("ok")]))

        XCTAssertEqual(store.messages.map(\.text), ["先检查配置。", "第一部分。", "第二部分。"])
        XCTAssertFalse(store.isRunning)
    }

    func testReusedFinalResponseDoesNotDuplicateSealedInterim() {
        let store = ChatStore()
        store.selectedID = "alpha"
        store.receive(event("message.start"))
        store.receive(event("message.interim", payload: [
            "text": .string("已经完成。"), "already_streamed": .bool(false)
        ]))
        store.receive(event("message.complete", payload: [
            "text": .string("已经完成。"), "status": .string("complete"), "response_reused": .bool(true)
        ]))

        XCTAssertEqual(store.messages.map(\.text), ["已经完成。"])
        XCTAssertFalse(store.isRunning)
    }

    func testEventsForOtherSessionDoNotChangeVisibleTranscriptOrActivity() {
        let store = ChatStore()
        store.selectedID = "alpha"
        store.messages = [ChatMessage(role: "user", text: "当前会话")]
        store.activity = "当前状态"

        store.receive(event("message.start", session: "beta"))
        store.receive(event("message.delta", session: "beta", payload: ["text": .string("其他会话回复")]))
        store.receive(event("tool.start", session: "beta", payload: ["name": .string("terminal")]))
        store.receive(event("message.complete", session: "beta", payload: ["text": .string("其他会话完成"), "status": .string("ok")]))

        XCTAssertEqual(store.messages.map(\.text), ["当前会话"])
        XCTAssertEqual(store.activity, "当前状态")
        XCTAssertFalse(store.isRunning)
    }

    func testLateCompletionDoesNotFinishNewerExecution() {
        let store = ChatStore()
        store.selectedID = "alpha"
        store.receive(event("message.start", generation: 4))
        store.receive(event("message.delta", generation: 4, payload: ["text": .string("新回复")]))
        store.receive(event("message.complete", generation: 3, payload: ["text": .string("旧回复"), "status": .string("ok")]))

        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.messages.map(\.text), ["新回复"])
        XCTAssertNil(store.errorMessage)
    }

    func testPromptEventsAreSessionScopedAndDeduplicated() {
        let store = ChatStore()
        store.selectedID = "alpha"
        let payload: [String: JSONValue] = [
            "prompt_id": .string("approval-1"),
            "execution_generation": .number(2),
            "description": .string("运行命令"),
            "command": .string("echo hello"),
            "choices": .array([.string("once"), .string("deny")])
        ]
        store.receive(event("approval.request", generation: 2, payload: payload))
        store.receive(event("approval.request", generation: 2, payload: payload))
        store.receive(event("approval.settled", session: "beta", generation: 2, payload: ["prompt_id": .string("approval-1")]))

        XCTAssertEqual(store.prompts.count, 1)
        XCTAssertEqual(store.prompts.first?.sessionID, "alpha")
        XCTAssertEqual(store.prompts.first?.generation, 2)
        XCTAssertEqual(store.prompts.first?.choices, ["once", "deny"])

        store.receive(event("approval.settled", generation: 2, payload: ["prompt_id": .string("approval-1")]))
        XCTAssertTrue(store.prompts.isEmpty)
    }

    func testNewConversationPreservesPerSessionDraftsAndClearsVisibleState() {
        let store = ChatStore()
        store.selectedID = "alpha"
        store.draft = "稍后继续"
        store.messages = [ChatMessage(role: "assistant", text: "之前的回复")]
        store.model = "local-model"
        store.activity = "正在回复…"

        store.newConversation()
        store.draft = "新问题"

        XCTAssertNil(store.selectedID)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.model, "")
        XCTAssertEqual(store.activity, "")
        XCTAssertEqual(store.drafts["alpha"], "稍后继续")
        XCTAssertEqual(store.drafts["new"], "新问题")
    }

    func testCompleteErrorShowsFailureAndStopsRunning() {
        let store = ChatStore()
        store.selectedID = "alpha"
        store.receive(event("message.start"))
        store.receive(event("message.complete", payload: ["status": .string("error"), "error": .string("模型未配置")]))

        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.errorMessage, "模型未配置")
    }
}
