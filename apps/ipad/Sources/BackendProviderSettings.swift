import SwiftUI

struct BackendProviderSettings: View {
    @Environment(MangaLibrary.self) private var library
    @State private var providers: [BackendAIProvider] = []
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        Section(L("Backend API")) {
            Picker(L("Preferred AI provider"), selection: Binding(get: { library.preferences.backendProvider ?? "" }, set: {
                library.preferences.backendProvider = $0.isEmpty ? nil : $0
                library.savePreferences()
            })) {
                Text(L("Automatic (random available provider)")).tag("")
                if let selected = library.preferences.backendProvider, !providers.contains(where: { $0.id == selected }) {
                    Text(selected + " · " + L("Currently unavailable; automatic fallback")).tag(selected)
                }
                ForEach(providers) { provider in Text(provider.name + " · " + provider.model).tag(provider.id) }
            }.disabled(loading || library.busy).accessibilityIdentifier("backend-ai-provider")
            Button {
                Task { await refresh() }
            } label: { Label(L("Refresh available providers"), systemImage: "arrow.clockwise") }
                .disabled(loading || library.busy)
            if loading { ProgressView() }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            else if !loading && providers.isEmpty {
                Text(L("The AI service has no available provider. Please try again later.")).font(.caption).foregroundStyle(.orange)
            }
            Text(L("Prompts are sent securely to the server. It selects the configured model and returns the AI result. An unavailable preferred provider falls back automatically."))
                .font(.caption).foregroundStyle(.secondary)
        }.task(id: library.backendAuthentication.user?.id) { await refresh() }
    }
    private func refresh() async {
        loading = true; failure = nil
        defer { loading = false }
        do { providers = try await library.backendAI.catalog() }
        catch { failure = error.localizedDescription }
    }
}
