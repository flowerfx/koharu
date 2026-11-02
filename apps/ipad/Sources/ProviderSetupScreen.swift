import SwiftUI

struct ProviderSetupScreen: View {
    var complete: (TranslationProvider, String?) -> Void
    @State private var provider = AppConfiguration.current.defaults.provider
    @State private var choosingModel = false
    @State private var download = AppConfiguration.current.enabledGGUF.first?.url ?? ""
    @Environment(MangaLibrary.self) private var library

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L("OCR model"), value: AppConfiguration.current.ocr.first { $0.id == (library.preferences.ocrModel ?? "apple") }?.displayName ?? "")
                } footer: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("OCR recognizes the original text on manga pages. Apple Vision is built in; other OCR models need a download. You can change the OCR model in Settings."))
                        Text(String(format: L("Available models: %@"), AppConfiguration.current.enabledOCR.map(\.displayName).joined(separator: ", ")))
                    }
                }
                Section {
                    LabeledContent(L("AI inpainting"), value: L(library.preferences.inpaint ? "On" : "Off"))
                } footer: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("AI inpainting uses a downloaded model to remove original text and restore the background. When off, translations appear on white cards. You can change this and select an inpainting model in Settings."))
                        if !AppConfiguration.current.enabledInpainting.isEmpty {
                            Text(String(format: L("Available models: %@"), AppConfiguration.current.enabledInpainting.map(\.displayName).joined(separator: ", ")))
                        }
                    }
                }
                Section(L("Provider")) {
                    ForEach(AppConfiguration.current.providers) { option in
                        Button { provider = option } label: {
                            HStack {
                                Text(option.name).foregroundStyle(.primary)
                                Spacer()
                                if provider == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("setup-provider-\(option.rawValue)")
                        .accessibilityAddTraits(provider == option ? .isSelected : [])
                    }
                }
            }
            .navigationTitle(L("Choose a translation provider"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !choosingModel {
                    ToolbarItem(placement: .principal) {
                        Label(L("Choose a translation provider"), systemImage: "text.bubble")
                            .labelStyle(.titleAndIcon).font(.headline)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Continue")) {
                            if provider == .local { choosingModel = true }
                            else { complete(provider, nil) }
                        }.disabled(!AppConfiguration.current.providers.contains(provider)).accessibilityIdentifier("setup-continue")
                    }
                }
            }
            .navigationDestination(isPresented: $choosingModel) {
                GGUFDownloadScreen(selection: $download, context: library.preferences.contextSize,
                                   download: { complete(.local, $0) }, configureLater: { complete(.local, nil) })
            }
        }
    }
}
