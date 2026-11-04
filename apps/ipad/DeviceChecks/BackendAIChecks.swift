import XCTest
@testable import KoharuPad

private actor BackendAITrace {
    private var outputs: [[String: String]] = []
    func record(_ text: String) {
        guard let job = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              job["status"] as? String == "succeeded", let result = job["result"] as? [String: Any],
              let provider = result["provider"] as? String, let model = result["model"] as? String else { return }
        outputs.append(["provider": provider, "model": model])
    }
    func results() -> [[String: String]] { outputs }
}
final class BackendAIChecks: XCTestCase {
    @MainActor func testNativeBackendTranslationAndAnimePrompt() async throws {
        let (connection, certificate) = try NakamaConnection.configured(AppConfiguration.current.server.endpoint)
        let client = NakamaClient(connection: connection, certificate: certificate)
        let session = try await client.device("native-ai-check-" + UUID().uuidString)
        func profile(_ name: String, _ payload: [String: Any] = [:]) async throws -> CreditResponse {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            return try CreditResponse.decoder().decode(CreditResponse.self, from: Data(try await client.rpc(name, payload: text, auth: session).utf8))
        }
        let trace = BackendAITrace()
        let backend = BackendAI { name, payload in
            let value = try await client.rpc(name, payload: payload, auth: session)
            await trace.record(value)
            return value
        }
        let catalog = try await backend.catalog()
        guard !catalog.isEmpty else { throw AppError.message("Enable a provider in the AI dashboard before running this live check") }
        let configuration = try ConfigurationStore.shared.get()
        // App launch may already be refreshing this same store. Wait for that
        // owner before requesting a refresh; refresh() coalesces concurrent calls.
        let refreshDeadline = ContinuousClock.now + .seconds(25)
        while configuration.isRefreshing && ContinuousClock.now < refreshDeadline { try await Task.sleep(for: .milliseconds(50)) }
        await configuration.refresh()
        XCTAssertTrue(configuration.configuration.providers.contains(.backend), "Configuration status: \(configuration.status); target: \(configuration.target.key)")
        try configuration.configuration.requireProvider(.backend)
        let engine = TranslationEngine(backend: backend)
        let initial = try await profile("profile_daily", ["operation_id": UUID().uuidString.lowercased()])
        var config = Preferences(); config.provider = .backend; config.target = "en-US"; config.instructions = ""
        // Translation and prompt assistance use the server-managed provider order.
        let translationReservation = try await profile("profile_reserve", ["operation_id": UUID().uuidString.lowercased(), "action": "translate", "provider": "backend", "rerun": false])
        let translationTicket = try XCTUnwrap(translationReservation.reservation_id)
        let translations = try await engine.translate(["こんにちは", "ありがとう"], config: config, model: nil, batchSize: 1,
            backendContext: .init(reservationID: translationTicket))
        XCTAssertEqual(translations.count, 2); XCTAssertTrue(translations.allSatisfy { !$0.isEmpty })
        let afterTranslation = try await profile("ai_finish", ["reservation_id": translationTicket])
        XCTAssertEqual(afterTranslation.profile.credit, initial.profile.credit - initial.policy.cost(.translate, tier: initial.profile.account_type, provider: .backend))
        let promptReservation = try await profile("profile_reserve", ["operation_id": UUID().uuidString.lowercased(), "action": "enhance", "provider": "backend", "rerun": false])
        let promptTicket = try XCTUnwrap(promptReservation.reservation_id)
        let input = try AnimePromptContract.request(.enhance, prompt: "An original anime girl with pink hair and a white dress in a garden.")
        let data = try await engine.generateStructured(input, config: config, model: nil,
            backendContext: .init(reservationID: promptTicket), backendTask: .enhance)
        let prompt = try AnimePromptContract.decode(data)
        let finished = try await profile("ai_finish", ["reservation_id": promptTicket])
        XCTAssertEqual(finished.profile.credit, afterTranslation.profile.credit - initial.policy.cost(.enhance, tier: initial.profile.account_type, provider: .backend))
        XCTAssertTrue(prompt.prompt.lowercased().contains("pink"))
        let outputs = await trace.results(); XCTAssertEqual(outputs.count, 3)
        let report: [String: Any] = ["endpoint": connection.endpoint.absoluteString,
            "environment": try ConfigurationTarget(bundle: .main).environment.rawValue,
            "translationBatches": 2, "translations": translations, "enhancedPrompt": prompt.prompt,
            "actualResults": outputs, "chapterChargedOnce": true, "promptChargedOnce": true,
            "initialCredit": initial.profile.credit, "finalCredit": finished.profile.credit,
            "preferredProvider": "server-managed"]
        let evidence = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.json"); attachment.name = "Native client Nakama AI RPC"; attachment.lifetime = .keepAlways; add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try evidence.write(to: documents.appendingPathComponent("backend-ai-check.json"))
    }
}
