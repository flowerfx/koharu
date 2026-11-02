import SwiftUI

struct GGUFMemoryInfo: View {
    let bytes: Int64
    let catalog: GGUFDownload?
    let context: Int
    @State private var available = GGUFMemory.available
    private var required: UInt64 {
        catalog?.estimatedMemory(context: context) ?? GGUFMemory.estimate(bytes: bytes, context: context)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(L("Estimated RAM required")): \(GGUFMemory.formatted(required)) · \(L("Context tokens")): \(context)")
            Text("\(L("Device RAM")): \(GGUFMemory.formatted(ProcessInfo.processInfo.physicalMemory)) · \(L("Available to this app")): \(GGUFMemory.formatted(available))")
            Label(L(required <= min(available, ProcessInfo.processInfo.physicalMemory) ? "Estimated to fit available RAM" : "Exceeds this device's available RAM"),
                  systemImage: required <= min(available, ProcessInfo.processInfo.physicalMemory) ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(required <= min(available, ProcessInfo.processInfo.physicalMemory) ? Color.green : .orange)
            Text(L("RAM is an estimate, not a guarantee. Context length, page size and other apps affect actual usage."))
                .foregroundStyle(.secondary)
            Text(L("We recommend not using models that exceed available RAM. They may fail to load or cause the app to close."))
                .foregroundStyle(.secondary)
            Button(L("Refresh RAM estimate")) { available = GGUFMemory.available }
        }
        .font(.caption)
        .onAppear { available = GGUFMemory.available }
        .onChange(of: context) { _, _ in available = GGUFMemory.available }
    }
}

struct GGUFDownloadScreen: View {
    @Environment(MangaLibrary.self) private var library
    @Binding var selection: String
    let context: Int
    var download: (String) -> Void
    var configureLater: (() -> Void)?
    @State private var available = GGUFMemory.available
    private var selected: GGUFDownload? { AppConfiguration.current.enabledGGUF.first { $0.url == selection } }

    var body: some View {
        Form {
            Section {
                Text(L("Download a GGUF model to translate on this device, or import one in Settings."))
                LabeledContent(L("Device RAM"), value: GGUFMemory.formatted(ProcessInfo.processInfo.physicalMemory))
                LabeledContent(L("Available to this app"), value: GGUFMemory.formatted(available))
                Text(L("RAM is an estimate, not a guarantee. Context length, page size and other apps affect actual usage."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("We recommend not using models that exceed available RAM. They may fail to load or cause the app to close."))
                    .font(.caption).foregroundStyle(.orange)
                Button(L("Refresh RAM estimate")) { available = GGUFMemory.available }
            }
            Section(L("Model")) {
                ForEach(AppConfiguration.current.enabledGGUF) { model in
                    Button { selection = model.url } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                Text(model.name).font(.headline).foregroundStyle(.primary)
                                Spacer()
                                if selection == model.url { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            Text("\(L("Download size")): \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))")
                                .foregroundStyle(.secondary)
                            Text("\(L("Estimated RAM required")): \(GGUFMemory.formatted(model.estimatedMemory(context: min(context, model.maxTokens)))) · \(L("Context tokens")): \(min(context, model.maxTokens))")
                                .foregroundStyle(.secondary)
                            Text("\(L("Maximum context tokens")): \(model.maxTokens)").foregroundStyle(.secondary)
                            let fits = model.estimatedMemory(context: min(context, model.maxTokens)) <= min(available, ProcessInfo.processInfo.physicalMemory)
                            Label(L(fits ? "Estimated to fit available RAM" : "Exceeds this device's available RAM"),
                                  systemImage: fits ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(fits ? Color.green : .orange)
                        }.font(.caption).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("gguf-\(model.url.components(separatedBy: "/").last ?? model.name)")
                    .accessibilityAddTraits(selection == model.url ? .isSelected : [])
                }
            }
        }
        .navigationTitle(L("Choose a GGUF download"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Label(L("Choose a GGUF download"), systemImage: "arrow.down.circle").labelStyle(.titleAndIcon).font(.headline)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let selected {
                    Text(selected.name).font(.caption).multilineTextAlignment(.center)
                    Text("\(L("Estimated RAM required")): \(GGUFMemory.formatted(selected.estimatedMemory(context: min(context, selected.maxTokens))))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(L("Download GGUF"), systemImage: "arrow.down.circle") { download(selection) }
                    .buttonStyle(.borderedProminent).disabled(selected == nil || library.downloadingModel || library.busy)
                    .accessibilityIdentifier("setup-download")
                if let configureLater {
                    Button(L("Configure in Settings"), action: configureLater)
                        .accessibilityIdentifier("setup-local-settings")
                }
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .onAppear { available = GGUFMemory.available }
    }
}
