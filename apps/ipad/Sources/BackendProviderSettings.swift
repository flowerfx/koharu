import SwiftUI

struct BackendProviderSettings: View {
    var body: some View {
        Section(L("Backend API")) {
            LabeledContent(L("Preferred AI provider"), value: L("Kuruby Server"))
                .accessibilityIdentifier("backend-ai-provider")
            Button {} label: { Label(L("Refresh available providers"), systemImage: "arrow.clockwise") }
                .disabled(true)
            Text(L("Kuruby Server manages the AI provider and model automatically."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
