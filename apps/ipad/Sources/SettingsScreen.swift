import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @Binding var providerFocus: TranslationProvider?
    @Environment(MangaLibrary.self) private var library
    @State private var remoteModels: [String] = []
    @State private var servers: [LMStudio.Server] = []
    @State private var probing = false
    @State private var token = ""
    @State private var downloadURL = ""
    @State private var importing = false
    @State private var choosingDownload = false
    @State private var deleting: LocalModel?
    private var selectedCatalog: GGUFDownload? {
        guard let model = library.models.first(where: { $0.id == library.preferences.localModel }) else { return nil }
        return try? AppConfiguration.current.catalog(for: model)
    }
    private var contextOptions: [Int] {
        let limit = selectedCatalog?.maxTokens ?? 262144
        return Array(Set(([2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, limit, library.preferences.contextSize]).filter { $0 > 0 && $0 <= limit })).sorted()
    }
    var body: some View {
        @Bindable var library = library
        @Bindable var localization = AppLocalization.shared
        let configuration = try? ConfigurationStore.shared.get()
        ScrollViewReader { proxy in
        Form {
            NakamaAccountSection()
            CreditAccountSection()
            Section(L("Interface")) {
                Picker(L("App language"), selection: $localization.language) {
                    ForEach(InterfaceLanguage.allCases) { Text($0.name).tag($0) }
                }
                Text(L("Interface language changes menus and controls. The translation target is selected separately.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Reading")) {
                Picker(L("Reading mode"), selection: $library.readingMode) {
                    ForEach(ReadingMode.allCases) { Text($0.name).tag($0) }
                }
            }
            Section(L("Notifications")) {
                LabeledContent(L("Push notifications"), value: CloudServices.shared.notificationStatusText)
                Button(L(CloudServices.shared.notificationStatus == .notDetermined ? "Enable notifications" : "Open notification settings")) {
                    Task {
                        await CloudServices.shared.requestNotifications()
                        if library.credits.loaded { await CloudServices.shared.scheduleCreditReminders(nextReset: library.credits.nextDaily) }
                    }
                }.disabled(!CloudServices.shared.available)
                if let next = CloudServices.shared.nextCreditReminder {
                    LabeledContent(L("Next credit reminder"), value: next.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.shared.locale)))
                        .accessibilityIdentifier("credit-reminder-next")
                    Text(L("Reminder times use your device's local time zone."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = CloudServices.shared.reminderMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Text(L("Receive app notifications. You can change permission in iPadOS Settings."))
                    .font(.caption).foregroundStyle(.secondary)
            }.task { await CloudServices.shared.refreshNotificationStatus() }
            Section(L("Translation")) {
                Picker(L("Provider"), selection: Binding(get: { library.preferences.provider }, set: { library.selectCreditProvider($0) })) {
                    if !AppConfiguration.current.providers.contains(library.preferences.provider) {
                        Text(library.preferences.provider.name + " · " + L("Disabled in app configuration")).tag(library.preferences.provider).disabled(true)
                    }
                    ForEach(AppConfiguration.current.providers) { provider in
                        Text(provider.name + (library.credits.tier.allows(provider) ? "" : " · " + L("Premium")))
                            .tag(provider).disabled(!library.credits.tier.allows(provider))
                    }
                }
                Text(L("Translating from Rawkuma costs credits. Reruns cost credits only with Backend API. Reading downloaded chapters is free."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("Target language"), selection: $library.preferences.target) {
                    ForEach(TargetLanguage.all) { Text($0.displayName).tag($0.tag) }
                }
                TextField(L("Additional instructions"), text: $library.preferences.instructions, axis: .vertical).lineLimit(3...6)
                LabeledContent(L("Text regions per batch")) {
                    TextField(L("Text regions per batch"), value: Binding(get: { library.translationBatchSize }, set: { library.translationBatchSize = min(100, max(1, $0)) }), format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                }
                Text(L("Default: 100. OCR scans the chapter before translation. Set 1–100 regions per batch; reduce this if the model context or output limit is too small.")).font(.caption).foregroundStyle(.secondary)
            }
            if library.preferences.provider == .backend { BackendProviderSettings() }
            if library.preferences.provider == .lmStudio && AppConfiguration.current.providers.contains(.lmStudio) {
                Section("LM Studio") {
                    TextField(L("Server URL"), text: $library.preferences.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight)
                    Text(L("Use the server root URL, without /v1. Enable LAN serving in LM Studio.")).font(.caption).foregroundStyle(.secondary)
                    SecureField(L("API token (optional)"), text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight)
                    if !token.isEmpty, (try? LMStudio.baseURL(library.preferences.server))?.scheme == "http" {
                        Label(L("This server uses HTTP. The API token is sent unencrypted on your local network."), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button(L("Save credential")) {
                        do { try Credentials.save(token, library.preferences.server) } catch { library.error = error.localizedDescription }
                    }
                    Button {
                        Task { await refreshModels() }
                    } label: { Label(L("Refresh models"), systemImage: "arrow.clockwise") }.disabled(probing || library.busy)
                    Picker(L("Model"), selection: $library.preferences.remoteModel) {
                        if !remoteModels.contains(library.preferences.remoteModel) { Text(library.preferences.remoteModel.isEmpty ? L("Select a model") : library.preferences.remoteModel).tag(library.preferences.remoteModel) }
                        ForEach(remoteModels, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        probing = true
                        Task {
                            defer { probing = false }
                            do {
                                let base = try LMStudio.baseURL(library.preferences.server)
                                servers = try await LMStudio.discover(port: base.port ?? (base.scheme == "https" ? 443 : 80))
                                if servers.isEmpty { library.error = L("No LM Studio server found. Check Wi-Fi, LAN serving and firewall.") }
                            } catch { library.error = error.localizedDescription }
                        }
                    } label: { Label(L("Find server on /24 LAN"), systemImage: "network") }.disabled(probing || library.busy)
                    if probing { ProgressView() }
                    ForEach(servers) { server in
                        Button {
                            library.preferences.server = server.url
                            remoteModels = server.models
                            library.preferences.remoteModel = server.models.first ?? ""
                            token = Credentials.read(server.url)
                        } label: { VStack(alignment: .leading) { Text(server.url); Text("\(server.models.count) \(L("models"))").font(.caption).foregroundStyle(.secondary) } }
                    }
                }.id(TranslationProvider.lmStudio)
            } else if library.preferences.provider == .local && AppConfiguration.current.providers.contains(.local) {
                Section(L("Local AI")) {
                    Picker(L("Model"), selection: $library.preferences.localModel) {
                        Text(L("Select a model")).tag(UUID?.none)
                        if let selected = library.preferences.localModel, !library.availableModels.contains(where: { $0.id == selected }) {
                            Text(L("Disabled in app configuration")).tag(Optional(selected)).disabled(true)
                        }
                        ForEach(library.availableModels) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker(L("Context tokens"), selection: $library.preferences.contextSize) {
                        if !contextOptions.contains(library.preferences.contextSize) {
                            Text(String(library.preferences.contextSize)).tag(library.preferences.contextSize).disabled(true)
                        }
                        ForEach(contextOptions, id: \.self) { Text(String($0)).tag($0) }
                    }
                    if let selectedCatalog {
                        Text("\(L("Maximum context tokens")): \(selectedCatalog.maxTokens)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let model = library.models.first(where: { $0.id == library.preferences.localModel }) {
                        GGUFMemoryInfo(bytes: model.bytes, catalog: selectedCatalog, context: library.preferences.contextSize)
                    }
                    #if targetEnvironment(simulator)
                    Text(L("Local GGUF inference requires a physical iPad/iPhone. Use LM Studio in Simulator.")).font(.caption).foregroundStyle(.orange)
                    #endif
                    TextField(L("HTTPS GGUF download URL"), text: $downloadURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight)
                    Button(L("Choose a GGUF download")) { choosingDownload = true }.disabled(library.downloadingModel || library.busy)
                    Button(L("Download GGUF"), systemImage: "arrow.down.circle") { library.downloadModel(downloadURL) }.disabled(downloadURL.isEmpty || library.downloadingModel || library.busy)
                    Button(L("Import GGUF from Files"), systemImage: "folder") { importing = true }.disabled(library.downloadingModel || library.busy)
                    Button(L("Unload local model")) { Task { await library.translator.unload() } }.disabled(library.busy)
                    ForEach(library.models) { model in
                        HStack {
                            VStack(alignment: .leading) { Text(model.name); Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button(role: .destructive) { deleting = model } label: { Image(systemName: "trash") }.disabled(library.busy || library.downloadingModel)
                        }
                    }
                }.id(TranslationProvider.local)
            }
            if library.preferences.provider.hosted && AppConfiguration.current.providers.contains(library.preferences.provider) {
                HostedProviderSettings(provider: library.preferences.provider).id(library.preferences.provider)
            }
            Section(L("OCR model")) {
                Picker(L("Model"), selection: $library.preferences.ocrModel) {
                    if !AppConfiguration.current.enabledOCR.contains(where: { $0.id == (library.preferences.ocrModel ?? "apple") }) {
                        Text(L("Disabled in app configuration")).tag(library.preferences.ocrModel).disabled(true)
                    }
                    ForEach(AppConfiguration.current.enabledOCR) { Text($0.displayName).tag($0.builtIn ? String?.none : Optional($0.id)) }
                }
                Text(L("Apple Vision detects text regions. The selected OCR model reads each crop locally; models are downloaded separately.")).font(.caption).foregroundStyle(.secondary)
                if let id = library.preferences.ocrModel { VisionModelDownload(modelID: id) }
            }
            Section(L("Image cleanup")) {
                Toggle(L("AI inpainting"), isOn: $library.preferences.inpaint)
                    .disabled(AppConfiguration.current.enabledInpainting.isEmpty && !library.preferences.inpaint)
                if library.preferences.inpaint {
                    Picker(L("Model"), selection: Binding(get: { library.preferences.cleanupModel ?? AppConfiguration.current.defaults.inpainting }, set: { library.preferences.cleanupModel = $0 })) {
                        let selected = library.preferences.cleanupModel ?? AppConfiguration.current.defaults.inpainting
                        if !AppConfiguration.current.enabledInpainting.contains(where: { $0.id == selected }) {
                            Text(L("Disabled in app configuration")).tag(selected).disabled(true)
                        }
                        ForEach(AppConfiguration.current.enabledInpainting) { Text($0.displayName).tag($0.id) }
                    }
                    VisionModelDownload(modelID: library.preferences.cleanupModel ?? AppConfiguration.current.defaults.inpainting)
                }
                Text(L("Inpainting runs on this device on native-resolution crops. FLUX and RORem need more RAM and time. Without cleanup, translated text uses white speech cards.")).font(.caption).foregroundStyle(.secondary)
            }
            if library.downloadingModel {
                Section {
                    HStack { ProgressView(); Text(library.status) }
                    Button(L("Cancel download"), role: .cancel) { library.modelTask?.cancel() }
                }
            }
            if let configuration {
            Section(L("Configuration")) {
                LabeledContent(L("Environment"), value: configuration.target.environment.rawValue + " · " + configuration.target.version)
                Text(configuration.statusText).font(.caption).foregroundStyle(configuration.status == .failed ? Color.orange : .secondary)
                if let etag = configuration.etag { LabeledContent(L("ETag"), value: etag).font(.caption) }
                if let modified = configuration.modified { LabeledContent(L("Last modified")) { Text(modified, format: .dateTime).font(.caption) } }
                Button(L("Check configuration updates")) { Task { await configuration.refresh { library.canApplyConfiguration } } }
                    .disabled(!library.canApplyConfiguration || configuration.isRefreshing)
            }
            }
            AppAboutSection()
        }
        .navigationTitle(L("Settings"))
        .task(id: providerFocus) {
            guard let providerFocus else { return }
            // Let Form lay out the newly selected provider before scrolling.
            await Task.yield()
            proxy.scrollTo(providerFocus, anchor: .top)
            self.providerFocus = nil
        }
        .disabled(library.busy)
        .task { token = Credentials.read(library.preferences.server) }
        .onChange(of: library.preferences.server) { _, value in token = Credentials.read(value) }
        .onChange(of: library.preferences.localModel) { _, _ in
            if let selectedCatalog { library.preferences.contextSize = min(library.preferences.contextSize, selectedCatalog.maxTokens) }
        }
        .onChange(of: library.preferences.inpaint) { _, enabled in
            if enabled && !AppConfiguration.current.enabledInpainting.contains(where: { $0.id == library.preferences.cleanupModel }) {
                library.preferences.cleanupModel = AppConfiguration.current.enabledInpainting.first?.id
            }
        }
        .sheet(isPresented: $choosingDownload) {
            NavigationStack {
                GGUFDownloadScreen(selection: $downloadURL, context: library.preferences.contextSize) { address in
                    library.downloadModel(address)
                    choosingDownload = false
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { choosingDownload = false } } }
            }
            .presentationSizing(.page)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            switch result { case .success(let url): library.importModel(url); case .failure(let error): library.error = error.localizedDescription }
        }
        .confirmationDialog(L("Delete this downloaded model?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let deleting { Task { await library.removeModel(deleting) } }; deleting = nil }
        }
        }
    }
    private func refreshModels() async {
        probing = true; defer { probing = false }
        do {
            remoteModels = try await LMStudio.models(library.preferences.server, token: Credentials.read(library.preferences.server))
            if !remoteModels.contains(library.preferences.remoteModel) { library.preferences.remoteModel = remoteModels.first ?? "" }
        } catch { library.error = error.localizedDescription }
    }
}

struct VisionModelDownload: View {
    @Environment(MangaLibrary.self) private var library
    let modelID: String
    @State private var removing = false
    var body: some View {
        if let model = try? VisionModel.named(modelID), !model.builtIn, let ram = model.ramRequirementMB {
            Text("\(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)) · \(L("Estimated free RAM required")): \(ram) MB").font(.caption).foregroundStyle(.secondary)
            if VisionModel.availableMemory < ram * 1024 * 1024 {
                Label(L("Not enough available RAM"), systemImage: "memorychip").font(.caption).foregroundStyle(.orange)
            }
            if model.ready(library.disk.modelsURL) {
                HStack {
                    Label(L("Model ready"), systemImage: "checkmark.circle").foregroundStyle(.green)
                    Spacer()
                    Button(role: .destructive) { removing = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel(L("Delete this downloaded model?"))
                        .disabled(library.busy || library.downloadingModel)
                }
                .confirmationDialog(L("Delete this downloaded model?"), isPresented: $removing, titleVisibility: .visible) {
                    Button(L("Delete"), role: .destructive) {
                        library.removeVisionModel(model)
                    }
                }
            } else {
                Button(L("Download selected model"), systemImage: "arrow.down.circle") { library.downloadVisionModel(model) }.disabled(library.downloadingModel || library.busy)
            }
            Link(L("Model source"), destination: model.source)
        }
    }
}
