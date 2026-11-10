import XCTest
@testable import Hermac

final class BranchAndSourceTests: XCTestCase {
    func testOnlyInteractiveLocalSourcesAreListed() {
        for source in ["cli", "tui", "gui", "desktop", "local"] {
            XCTAssertTrue(Conversation(.object(["source": .string(source)])).isLocalConversation, source)
        }
        for source in ["qq", "telegram", "discord", "wechat", "slack", "cron", "tool", "oneshot", "acp", "api_server", "unknown", ""] {
            XCTAssertFalse(Conversation(.object(["source": .string(source)])).isLocalConversation, source)
        }
    }

    func testBranchBoundaryUsesPhysicalRowIDInsteadOfVisibleIndex() {
        let snapshot: JSONValue = .object([
            "display_messages": .array([
                .object(["role": .string("user"), "text": .string("问题"), "row_id": .number(101)]),
                .object(["role": .string("assistant"), "text": .string("工具前说明"), "row_id": .number(106)]),
                .object(["role": .string("tool"), "text": .string("工具结果"), "row_id": .number(107)]),
                .object(["role": .string("assistant"), "text": .string("最终回复"), "row_id": .number(109)])
            ])
        ])
        let messages = ChatMessage.transcript(snapshot)
        XCTAssertEqual(messages.map(\.id), ["row-101", "row-106", "row-109"])
        XCTAssertEqual(messages.map(\.persistedRowID), [101, 106, 109])
        XCTAssertEqual(messages.map(\.canBranch), [false, true, true])
    }

    func testUncommittedStreamHasNoBranchBoundary() {
        XCTAssertFalse(ChatMessage(role: "assistant", text: "正在回复").canBranch)
        XCTAssertFalse(ChatMessage(role: "user", text: "提问", persistedRowID: 42).canBranch)
    }

    func testArchivedCompressionRowsRemainVisibleButCannotBranch() {
        let archived: JSONValue = .object([
            "role": .string("assistant"), "text": .string("压缩前的回复"), "row_id": .number(5), "archived": .bool(true)
        ])
        let shown: JSONValue = .object([
            "role": .string("assistant"), "text": .string("压缩前的回复"), "row_id": .number(5)
        ])
        let snapshot: JSONValue = .object(["messages": .array([archived]), "display_messages": .array([shown])])
        let messages = ChatMessage.transcript(snapshot)
        XCTAssertEqual(messages.map(\.text), ["压缩前的回复"])
        XCTAssertTrue(messages[0].isArchived)
        XCTAssertFalse(messages[0].canBranch)
    }
}
