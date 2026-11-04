import XCTest
@testable import KoharuPad

private actor BackendRPCFixture {
    let reservation = UUID().uuidString.lowercased()
    var calls: [(String, [String: Any])] = []
    var jobs: [String: [String: Any]] = [:]
    var malformed = false
    var keepRunning = false
    func call(_ name: String, _ text: String) throws -> String {
        let p = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        calls.append((name, p))
        let value: [String: Any]
        switch name {
        case "ai_catalog": value = ["providers": [["id": "anthropic", "name": "Anthropic", "model": "claude-test"]]]
        case "ai_generate":
            let id = p["request_id"] as! String
            XCTAssertEqual(p["reservation_id"] as? String, reservation)
            XCTAssertNil(p["model"]); XCTAssertNil(p["key"]); XCTAssertNil(p["url"])
            jobs[id] = p
            value = ["request_id": id, "reservation_id": reservation, "status": "queued"]
        case "ai_result":
            let id = p["request_id"] as! String, request = jobs[id]!
            let output: [String: Any] = request["task"] as? String == "translate"
                ? ["translations": [["id": 0, "text": "Translated"], ["id": 1, "text": "Wrong extra segment"]].prefix(malformed ? 2 : 1).map { $0 }]
                : ["prompt": "An anime girl with pink hair and a white dress, standing under warm sunlight in a quiet garden.", "character": "Original character"]
            value = ["request_id": id, "reservation_id": reservation, "status": keepRunning ? "running" : "succeeded",
                     "result": ["provider": "anthropic", "model": "claude-test", "output": output]]
        default: value = ["accepted": true]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    func configure(malformed: Bool = false, keepRunning: Bool = false) { self.malformed = malformed; self.keepRunning = keepRunning }
    func recorded() -> [(String, [String: Any])] { calls }
}
final class BackendAITests: XCTestCase {
    func testEngineUsesSharedPromptsAndOneReservationForEveryBackendBatch() async throws {
        let f = BackendRPCFixture(), backend = BackendAI(rpc: { try await f.call($0, $1) }, pause: {})
        let configuration = try AppConfiguration.decode(AppConfiguration.bundledData())
        let engine = TranslationEngine(backend: backend, configuration: { configuration })
        var config = Preferences(); config.provider = .backend
        let context = BackendAIContext(reservationID: f.reservation)
        let result = try await engine.translate(["Bonjour", "Salut"], config: config, model: nil, batchSize: 1, backendContext: context)
        XCTAssertEqual(result, ["Translated", "Translated"])
        let calls = await f.recorded(), submissions = calls.filter { $0.0 == "ai_generate" }.map(\.1)
        XCTAssertEqual(submissions.count, 2)
        XCTAssertNotEqual(submissions[0]["request_id"] as? String, submissions[1]["request_id"] as? String)
        for p in submissions {
            XCTAssertEqual(p["reservation_id"] as? String, f.reservation)
            XCTAssertNil(p["provider"])
            XCTAssertEqual(p["task"] as? String, "translate")
            XCTAssertEqual(p["count"] as? Int, 1)
            XCTAssertEqual(p["system"] as? String, try TranslationContract.prompts(["Bonjour"], preferences: config).0)
        }
    }
    func testAnimePromptUsesBackendTaskAndOriginalInputWithoutAClientModelOrKey() async throws {
        let f = BackendRPCFixture(), backend = BackendAI(rpc: { try await f.call($0, $1) }, pause: {})
        let configuration = try AppConfiguration.decode(AppConfiguration.bundledData())
        let engine = TranslationEngine(backend: backend, configuration: { configuration })
        var config = Preferences(); config.provider = .backend
        let input = try AnimePromptContract.request(.enhance, prompt: "Pink hair and a white dress")
        let data = try await engine.generateStructured(input, config: config, model: nil,
            backendContext: .init(reservationID: f.reservation), backendTask: .enhance)
        XCTAssertTrue(try AnimePromptContract.decode(data).prompt.contains("pink hair"))
        let calls = await f.recorded(), submitted = try XCTUnwrap(calls.first { $0.0 == "ai_generate" }?.1)
        XCTAssertEqual(submitted["task"] as? String, "enhance"); XCTAssertEqual(submitted["user"] as? String, input.user)
        XCTAssertNil(submitted["count"]); XCTAssertNil(submitted["provider"])
    }
    func testInvalidBackendOutputIsRejectedAndQueuedWorkIsCleanedUp() async throws {
        let f = BackendRPCFixture(); await f.configure(malformed: true)
        let backend = BackendAI(rpc: { try await f.call($0, $1) }, pause: {})
        let input = try TranslationContract.request(system: "Translate", user: "Hello", count: 1)
        do { _ = try await backend.generate(input, task: .translate, context: .init(reservationID: f.reservation), count: 1); XCTFail("Invalid IDs must fail") }
        catch { }
        let calls = await f.recorded(); XCTAssertEqual(calls.last?.0, "ai_cancel")
    }
    func testCancellationRequestsServerCancellationAndNeverReturnsQueuedOutput() async throws {
        let f = BackendRPCFixture(); await f.configure(keepRunning: true)
        let submitted = expectation(description: "submitted")
        let backend = BackendAI(rpc: { name, payload in
            let result = try await f.call(name, payload)
            if name == "ai_generate" { submitted.fulfill() }
            return result
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let input = try TranslationContract.request(system: "Translate", user: "Hello", count: 1)
        let task = Task { try await backend.generate(input, task: .translate, context: .init(reservationID: f.reservation), count: 1) }
        await fulfillment(of: [submitted], timeout: 2); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not publish") } catch is CancellationError { }
        let calls = await f.recorded(); XCTAssertTrue(calls.contains { $0.0 == "ai_cancel" })
    }
}
