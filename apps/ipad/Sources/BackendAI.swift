import Foundation

struct BackendAIProvider: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let model: String
}
struct BackendAIContext: Sendable {
    let reservationID: String
}
enum BackendAITask: String, Sendable { case translate, enhance, generatePrompt }

// Uses the account's existing authenticated Nakama transport. Provider keys and
// model choice belong to the server; no hosted credential enters this request.
actor BackendAI {
    typealias RPC = @Sendable (String, String) async throws -> String
    private let rpc: RPC
    private let pause: @Sendable () async throws -> Void
    static let providerIDs: Set<String> = ["openai", "anthropic", "deepseek", "gemini", "grok", "minimax"]
    init(rpc: @escaping RPC, pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.rpc = rpc; self.pause = pause
    }
    private func call(_ name: String, _ payload: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await rpc(name, String(decoding: body, as: UTF8.self))
        guard response.utf8.count <= 262_144 else { throw invalidResponse }
        return Data(response.utf8)
    }
    func catalog() async throws -> [BackendAIProvider] {
        struct Catalog: Decodable { let providers: [BackendAIProvider] }
        let values = try JSONDecoder().decode(Catalog.self, from: await call("ai_catalog", [:])).providers
        guard values.count <= Self.providerIDs.count, Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ Self.providerIDs.contains($0.id) && !$0.model.isEmpty }) else { throw invalidResponse }
        return values
    }
    private var invalidResponse: AppError { .message(L("The AI service returned an invalid response. Please try again.")) }
    private func cancel(_ requestID: String) async { _ = try? await call("ai_cancel", ["request_id": requestID]) }
    func generate(_ input: StructuredTextRequest, task: BackendAITask, context: BackendAIContext, count: Int? = nil) async throws -> Data {
        guard let reservation = UUID(uuidString: context.reservationID), input.system.utf16.count <= 8192, input.user.utf16.count <= 32768,
              task == .translate ? count.map({ (1...100).contains($0) }) == true : count == nil else {
            throw AppError.message(L("The AI request is too large or invalid. Reduce segments per request or shorten the instructions."))
        }
        let requestID = UUID().uuidString.lowercased(), reservationID = reservation.uuidString.lowercased()
        var payload: [String: Any] = ["request_id": requestID, "reservation_id": reservationID, "task": task.rawValue, "system": input.system, "user": input.user]
        if let count { payload["count"] = count }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                var response = try await call("ai_generate", payload)
                let deadline = ContinuousClock.now + .seconds(660)
                while true {
                    try Task.checkCancellation()
                    guard let job = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                          job["request_id"] as? String == requestID, job["reservation_id"] as? String == reservationID,
                          let status = job["status"] as? String else { throw invalidResponse }
                    switch status {
                    case "succeeded":
                        guard let result = job["result"] as? [String: Any], let provider = result["provider"] as? String,
                              Self.providerIDs.contains(provider), let model = result["model"] as? String, !model.isEmpty,
                              let output = result["output"] as? [String: Any] else { throw invalidResponse }
                        let data = try JSONSerialization.data(withJSONObject: output)
                        // The same strict contract validates local, hosted and server output.
                        if task == .translate { _ = try TranslationContract.decode(data, count: count!) }
                        else { _ = try AnimePromptContract.decode(data) }
                        return data
                    case "failed":
                        throw AppError.message(Self.message(job["error"] as? String))
                    case "cancelled": throw CancellationError()
                    case "queued", "running": break
                    default: throw invalidResponse
                    }
                    guard ContinuousClock.now < deadline else { throw AppError.message(L("The AI request is taking too long. A running request may still finish on the server.")) }
                    try await pause()
                    response = try await call("ai_result", ["request_id": requestID])
                }
            } catch {
                // Also clean up queued work after a lost/malformed submission response.
                // Running vendor calls remain server-owned and settle independently.
                await Task { await self.cancel(requestID) }.value
                throw error
            }
        } onCancel: { Task { await self.cancel(requestID) } }
    }
    private static func message(_ code: String?) -> String {
        switch code {
        case "no_active_provider": return L("The AI service has no available provider. Please try again later.")
        case "content_refused": return L("The AI provider could not process this content. Please revise your request.")
        case "worker_interrupted": return L("The AI request was interrupted. Please try again.")
        default: return L("The AI service could not complete the request. Please try again later.")
        }
    }
}
