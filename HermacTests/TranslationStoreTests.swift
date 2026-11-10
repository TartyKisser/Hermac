import XCTest
@testable import Hermac

@MainActor
final class TranslationStoreTests: XCTestCase {
    func testHiddenToolFreeSessionStreamsResultAndDeletesOnClose() async {
        let client = Client()
        let store = TranslationStore(client: client)
        store.translate("Hello, world.", launcherPath: "/test/hermes")
        await store.waitForPendingOperation()
        let create = client.calls.first { $0.0 == "session.create" }!.1
        XCTAssertEqual(create["hidden"], .bool(true))
        XCTAssertEqual(create["source"], .string("tool"))
        XCTAssertEqual(create["toolsets"], .array([]))
        XCTAssertEqual(client.calls.first { $0.0 == "prompt.submit" }?.1["text"], .string(TranslationStore.prompt(for: "Hello, world.")))
        client.event("message.delta", text: "你好")
        XCTAssertEqual(store.result, "你好")
        client.event("message.complete", text: "你好，世界。")
        XCTAssertEqual(store.result, "你好，世界。")
        XCTAssertFalse(store.isRunning)

        store.close()
        await store.waitForPendingOperation()
        XCTAssertEqual(client.deleted, ["translation-1"])
        XCTAssertTrue(store.result.isEmpty)
        client.event("message.complete", text: "late result")
        XCTAssertTrue(store.result.isEmpty)
    }

    func testClosingDuringCreateDeletesReceivedSessionWithoutSubmitting() async {
        let client = Client()
        client.pauseCreate = true
        let store = TranslationStore(client: client)
        store.translate("Test.", launcherPath: "/test/hermes")
        while client.creation == nil { await Task.yield() }
        store.close()
        client.creation?.resume(returning: .object(["session_id": .string("translation-1")]))
        client.creation = nil
        await store.waitForPendingOperation()
        XCTAssertFalse(client.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertEqual(client.deleted, ["translation-1"])
    }

    func testReplacementStopsAndDeletesOldTranslationAndIgnoresOldEvents() async {
        let client = Client()
        let store = TranslationStore(client: client)
        store.translate("First.", launcherPath: "/test/hermes")
        await store.waitForPendingOperation()
        client.running = true
        store.translate("Second.", launcherPath: "/test/hermes")
        client.event("message.complete", text: "old response")
        XCTAssertTrue(store.result.isEmpty)
        await store.waitForPendingOperation()
        XCTAssertTrue(client.calls.contains { $0.0 == "session.interrupt" })
        XCTAssertEqual(client.deleted, ["translation-1"])
        client.event("message.complete", id: "translation-2", text: "第二。")
        XCTAssertEqual(store.result, "第二。")
        await store.shutdown()
        XCTAssertEqual(client.deleted, ["translation-1", "translation-2"])
        XCTAssertFalse(client.isConnected)
    }

    private final class Client: TranslationClient {
        var onEvent: ((HermesEvent) -> Void)?
        var isConnected = false
        var calls: [(String, [String: JSONValue])] = []
        var deleted: [String] = []
        var running = false
        var pauseCreate = false
        var creation: CheckedContinuation<JSONValue, Error>?
        var count = 0
        func connect(launcherPath: String) async throws { isConnected = true }
        func disconnect() { isConnected = false }
        func request(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
            calls.append((method, params))
            switch method {
            case "session.create":
                count += 1
                if pauseCreate { return try await withCheckedThrowingContinuation { creation = $0 } }
                return .object(["session_id": .string("translation-\(count)")])
            case "session.resume":
                return .object(["revision": .number(1), "execution_generation": .number(1), "running": .bool(running)])
            case "session.interrupt": running = false
            case "session.mutate": deleted.append(params["session_id"]!.stringValue!)
            default: break
            }
            return .object(["execution_generation": .number(1)])
        }
        func event(_ type: String, id: String = "translation-1", text: String) {
            onEvent?(HermesEvent(type: type, sessionID: id, payload: .object(["text": .string(text)]),
                                executionGeneration: 1, sequence: nil))
        }
    }
}
