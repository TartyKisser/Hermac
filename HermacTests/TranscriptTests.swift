import XCTest
@testable import Hermac

final class TranscriptTests: XCTestCase {
    func testDisplayProjectionHidesInternalAndToolRows() {
        let snapshot: JSONValue = .object([
            "display_messages": .array([
                .object(["role": .string("system"), "text": .string("internal system prompt")]),
                .object(["role": .string("user"), "text": .string("你好"), "row_id": .string("u-1")]),
                .object(["role": .string("user"), "text": .string("compaction handoff"), "display_kind": .string("hidden")]),
                .object(["role": .string("tool"), "text": .string("tool result")]),
                .object(["role": .string("assistant"), "text": .string("你好！"), "row_id": .string("a-1")]),
                .object(["role": .string("assistant"), "text": .string("")]),
                .object(["role": .string("assistant"), "text": .string(" \n\t")])
            ]),
            "messages": .array([.object(["role": .string("user"), "content": .string("raw rows must not leak")])])
        ])

        let messages = ChatMessage.transcript(snapshot)

        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.map(\.text), ["你好", "你好！"])
        XCTAssertEqual(messages.map(\.id), ["u-1", "a-1"])
    }

    func testEmptyDisplayProjectionDoesNotFallBackToRawHistory() {
        let snapshot: JSONValue = .object([
            "display_messages": .array([]),
            "messages": .array([.object(["role": .string("user"), "content": .string("hidden model context")])])
        ])

        XCTAssertTrue(ChatMessage.transcript(snapshot).isEmpty)
    }

    func testRawHistoryFallbackAcceptsContentStrings() {
        let snapshot: JSONValue = .object([
            "messages": .array([
                .object(["role": .string("user"), "content": .string("问题")]),
                .object(["role": .string("assistant"), "content": .string("回答")]),
                .object(["role": .string("tool"), "content": .string("不显示")])
            ])
        ])

        XCTAssertEqual(ChatMessage.transcript(snapshot).map(\.text), ["问题", "回答"])
    }

    func testJSONValueRoundTripsUnicodeNullAndNumericTypes() throws {
        let source: JSONValue = .object([
            "text": .string("Hermes 的回复 👋"),
            "enabled": .bool(true),
            "generation": .number(4),
            "delta": .null,
            "rows": .array([.string("first"), .number(1.5)])
        ])
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded["generation"].intValue, 4)
        XCTAssertNil(decoded["rows"].arrayValue?[1].intValue)
        XCTAssertNil(decoded["enabled"].intValue)
    }

    func testScreenshotReferencesSurviveResumeWithoutLeakingPathsIntoMessageText() {
        let snapshot: JSONValue = .object([
            "display_messages": .array([
                .object(["role": .string("user"), "row_id": .number(12),
                         "text": .string("看看这个界面 👀\n@image:`/cache/屏幕 截图.jpg`")]),
                .object(["role": .string("assistant"), "text": .string("这是一个窗口。")])
            ])
        ])
        let messages = ChatMessage.transcript(snapshot)
        XCTAssertEqual(messages[0].text, "看看这个界面 👀")
        XCTAssertEqual(messages[0].imagePaths, ["/cache/屏幕 截图.jpg"])
        XCTAssertEqual(messages[0].persistedRowID, 12)
        XCTAssertTrue(messages[1].imagePaths.isEmpty)
    }

    func testImageReferencesAcceptHermesQuotingAndRawMultimodalContent() {
        let snapshot: JSONValue = .object([
            "messages": .array([
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("text"),
                             "text": .string("问题\n@image:'/cache/first image.jpg'\n@image:\"/cache/second image.jpg\"\n@image:/cache/third.jpg")]),
                    .object(["type": .string("image_url"),
                             "image_url": .object(["url": .string("data:image/jpeg;base64,AAAA")])])
                ])])
            ])
        ])
        let messages = ChatMessage.transcript(snapshot)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "问题")
        XCTAssertEqual(messages[0].imagePaths, ["/cache/first image.jpg", "/cache/second image.jpg", "/cache/third.jpg"])
        XCTAssertFalse(messages[0].text.contains("base64"))
    }
}
