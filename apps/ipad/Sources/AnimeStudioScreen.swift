import SwiftUI

struct AnimeStudioScreen: View {
    var openProviderSettings: () -> Void
    @Environment(MangaLibrary.self) private var library
    @AppStorage("animePrompt") private var prompt = ""
    @AppStorage("animeGenerationSteps") private var steps = 6
    @AppStorage("animeGenerationSize") private var imageSize: AnimeImageSize = .square512
    @AppStorage("animeUpscaler") private var upscaler: AnimeUpscaler = .none
    @State private var configuration: AnimeConfiguration?
    @State private var configurationError: String?
    @State private var removing = false
    @State private var removingUpscaler = false
    @State private var removingAllImages = false
    @State private var generateAfterReview: String?
    private var upscalerReady: Bool { upscaler.model?.ready(library.disk.modelsURL) ?? true }

    var body: some View {
        Form {
            if let configuration {
                studio(configuration)
            } else if let configurationError {
                ContentUnavailableView(L("Invalid Anima model configuration"), systemImage: "exclamationmark.triangle", description: Text(configurationError))
            } else { ProgressView() }
        }
        .navigationTitle(L("Anime Studio"))
        .task {
            do { configuration = try AnimeConfiguration.bundled() }
            catch { configurationError = error.localizedDescription }
        }
        .sheet(item: Binding(get: { library.animePromptSuggestion }, set: { library.animePromptSuggestion = $0 }), onDismiss: {
            if let text = generateAfterReview { generateAfterReview = nil; generateImage(text) }
        }) { suggestion in
            AnimePromptReview(suggestion: suggestion, canGenerate: configuration.map { config in
                AnimeConfiguration.deviceMemory.map { config.supportsDevice(memory: $0) } == true && config.model.ready(library.disk.modelsURL) && upscalerReady
            } == true) { updated, generate in
                guard prompt == suggestion.original else {
                    library.animePromptSuggestion = nil
                    library.error = L("Your prompt changed while the suggestion was open. Request a new suggestion to keep your latest edits.")
                    return
                }
                prompt = updated
                library.animePromptSuggestion = nil
                if generate { generateAfterReview = updated }
            }
        }
    }

    @ViewBuilder private func studio(_ configuration: AnimeConfiguration) -> some View {
        let model = configuration.model
        let supported = AnimeConfiguration.deviceMemory.map { configuration.supportsDevice(memory: $0) } ?? false
        let ready = model.ready(library.disk.modelsURL)
        let canGenerate = supported && ready && upscalerReady && !library.busy && !library.downloadingModel
        Section {
            Label(configuration.name, systemImage: "paintpalette.fill").font(.headline)
            Text(L("Create anime images locally with Metal GPU.")).foregroundStyle(.secondary)
            if let memory = AnimeConfiguration.deviceMemory {
                LabeledContent(L("Device RAM"), value: GGUFMemory.formatted(memory))
                Label(L(supported ? "Device meets the 8 GB RAM target" : "Anime Studio requires a device with at least 8 GB RAM."),
                      systemImage: supported ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(supported ? Color.green : .orange)
            } else {
                Label(L("Device RAM can only be checked on a physical iPad or iPhone."), systemImage: "iphone")
                    .foregroundStyle(.secondary)
            }
            Text(L("8 GB is the device eligibility target. Available memory and generation speed depend on the device."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent(L("Current provider"), value: library.preferences.provider.name)
            LabeledContent(L("Image credit cost"), value: String(library.creditCost(.image)))
            LabeledContent(L("Enhance credit cost"), value: String(library.creditCost(.enhance)))
            LabeledContent(L("Random prompt credit cost"), value: String(library.creditCost(.generatePrompt)))
            Text(L("Prompt assistance is charged when a valid suggestion is returned, even if you cancel its review. Image generation is charged separately."))
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent(L("Model"), value: library.animePromptModel)
            TextEditor(text: $prompt).frame(minHeight: 110)
                .accessibilityLabel(L("Image description"))
                .disabled(library.busy)
            Stepper(value: $steps, in: 5...20) {
                LabeledContent(L("Steps"), value: "\(steps)")
            }.disabled(library.busy)
            Picker(L("Resolution"), selection: $imageSize) {
                ForEach(AnimeImageSize.allCases) { size in Text(size.title).tag(size) }
            }.disabled(library.busy)
            Picker(L("Upscale"), selection: $upscaler) {
                ForEach(AnimeUpscaler.allCases) { choice in Text(choice.title).tag(choice) }
            }.disabled(library.busy || library.downloadingModel)
            LabeledContent(L("Final image size"), value: "\(imageSize.dimensions.width * upscaler.scale) × \(imageSize.dimensions.height * upscaler.scale)")
            if upscaler != .none {
                Label(L("Upscale takes longer and uses more RAM. 4× makes each side four times larger: 16× as many pixels."), systemImage: "clock")
                    .font(.caption).foregroundStyle(.orange)
                if !upscalerReady {
                    Label(L("Download the selected upscaler first"), systemImage: "arrow.down.circle").foregroundStyle(.orange)
                }
            }
            Text(L("More steps may improve detail, but generation takes longer. Anima Turbo can reach its best quality with fewer steps; more is not always sharper."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("Larger images have more pixels and need more time and RAM. Start with 512 × 512; a larger size may not fit your device's available memory."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Enhance prompt"), systemImage: "wand.and.stars") { library.assistAnimePrompt(.enhance, prompt: prompt) }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Menu {
                    Button(L("Existing anime character")) { library.assistAnimePrompt(.randomAnime, prompt: prompt) }
                    Button(L("Original anime character")) { library.assistAnimePrompt(.randomOriginal, prompt: prompt) }
                } label: { Label(L("Random character"), systemImage: "dice") }
            }
            .disabled(library.busy || library.downloadingModel || library.animePromptUnavailable != nil)
            Button("\(L("Generate image")) · \(library.creditCost(.image)) \(L("credits"))", systemImage: "sparkles") { generateImage(prompt) }
                .disabled(!supported || !ready || !upscalerReady || library.busy || library.downloadingModel || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: { Text(L("Image description")) } footer: {
            Text(L("Image generation stays on this device. Prompt assistance uses your selected provider."))
        }
        if library.downloadingModel {
            Section {
                HStack { ProgressView(); Text(library.status) }
                Button(L("Cancel download"), role: .cancel) { library.modelTask?.cancel() }
            }
        }
        Section(L("Prompt assistant")) {
            if let reason = library.animePromptUnavailable {
                Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            Button(L("Configure current provider"), systemImage: "gear") { openProviderSettings() }.disabled(library.busy)
            Text(L(library.preferences.provider == .local ? "Prompt assistance runs on this device using the selected language GGUF model, which is separate from Anima."
                 : library.preferences.provider == .lmStudio ? "Prompt assistance sends text to your LM Studio server. Generated images are not sent to it."
                 : "Prompt assistance sends text to the selected API provider and may use paid credits. Generated images are not uploaded."))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L("How to use prompt assistance")) {
                Text(L("1. Select a provider and language model in Settings. For local GGUF, download and select a language model separately from the Anima image model."))
                Text(L("2. Describe the image in your language. Enhance prompt keeps your subject, names, appearance, outfit and pose while adding compatible lighting, composition and background details."))
                Text(L("3. Random character proposes either an existing anime character with their series, or a new original character. This creates a prompt, not an image."))
                Text(L("4. Review and edit the English suggestion. Use prompt replaces the editor only when you choose it; Use and generate also starts Anima. Cancel keeps your original text."))
                Text(L("5. Check character details before generating. Keep the app in the foreground while Anima works; loading and image generation can take several minutes. Stop is cooperative and may finish the current phase first."))
            }
        }
        Section(L("Upscale models")) {
            Text(L("No upscale keeps the original size. Choose and download a model before generating. Anima is unloaded before local Metal upscaling."))
                .font(.caption).foregroundStyle(.secondary)
            if let upscaleModel = upscaler.model {
                Text(upscaler.title).font(.headline)
                Text(upscaler.detail).font(.caption).foregroundStyle(.secondary)
                LabeledContent(L("Total download"), value: ByteCountFormatter.string(fromByteCount: upscaleModel.bytes, countStyle: .file))
                if upscalerReady {
                    Label(L("Model ready"), systemImage: "checkmark.circle").foregroundStyle(.green)
                    Button(L("Delete upscaler"), systemImage: "trash", role: .destructive) { removingUpscaler = true }
                        .disabled(library.busy || library.downloadingModel)
                } else {
                    Button(L("Download upscaler"), systemImage: "arrow.down.circle") { library.downloadAnimeUpscaler(upscaler) }
                        .disabled(!supported || library.busy || library.downloadingModel)
                }
                Link(L("Model source"), destination: upscaleModel.source)
                Link(L("Model license"), destination: URL(string: "https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE")!)
            }
            Text(L("Keep the app open. Stop waits for the upscale pass to finish, then discards the result."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(L("Delete upscaler?"), isPresented: $removingUpscaler, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let model = upscaler.model { library.removeVisionModel(model) } }
            Button(L("Cancel"), role: .cancel) {}
        }
        if let latest = library.animeImages.first {
            Section(L("Latest image")) {
                AnimeImageContent(image: latest, canGenerate: canGenerate, settingsDescription: settingsDescription, regenerate: generateImage)
            }
            Section(L("Generated images")) {
                ForEach(library.animeImages.dropFirst()) { image in
                    NavigationLink {
                        AnimeImageDetail(image: image, canGenerate: canGenerate, settingsDescription: settingsDescription, regenerate: generateImage)
                    } label: { Text(image.prompt).lineLimit(2) }
                }
                Button(L("Delete all images"), systemImage: "trash", role: .destructive) { removingAllImages = true }
                    .disabled(library.busy || library.downloadingModel)
            }
            .confirmationDialog(L("Delete all images?"), isPresented: $removingAllImages, titleVisibility: .visible) {
                Button(L("Delete all images"), role: .destructive) { library.deleteAnimeImages(Set(library.animeImages.map(\.id))) }
                Button(L("Cancel"), role: .cancel) {}
            } message: { Text(L("All generated images and their saved prompts will be deleted from this device. This cannot be undone.")) }
        }
        Section {
            Label("GPU · Metal", systemImage: "cpu")
            Text(L("GGUF generation uses the Apple GPU through Metal, not Apple Neural Engine."))
                .foregroundStyle(.secondary)
            Text("Euler · SGM Uniform · CFG 1").font(.caption).foregroundStyle(.secondary)
        } header: { Text(L("Image generation")) }
        Section {
            ForEach(configuration.components) { component in
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent(component.title, value: ByteCountFormatter.string(fromByteCount: component.file.bytes, countStyle: .file))
                    Text(component.file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.vertical, 3)
            }
            LabeledContent(L("Total download"), value: ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
            if ready {
                Label(L("Model ready"), systemImage: "checkmark.circle").foregroundStyle(.green)
                Button(L("Delete downloaded models"), systemImage: "trash", role: .destructive) { removing = true }
                    .disabled(library.busy || library.downloadingModel)
            } else {
                Button(L("Download Anima models"), systemImage: "arrow.down.circle") { library.downloadAnimeModels() }
                    .disabled(!supported || library.busy || library.downloadingModel)
            }
        } header: { Text(L("Model files")) } footer: {
            Text(L("Downloads are checked with SHA-256 and stored on this device."))
        }
        Section {
            Link(L("Model source"), destination: configuration.source)
            Link(L("Model license"), destination: configuration.license)
        }
        .confirmationDialog(L("Delete downloaded models?"), isPresented: $removing, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { library.removeVisionModel(model) }
            Button(L("Cancel"), role: .cancel) {}
        }
    }
    private func generateImage(_ text: String) {
        do { library.generateAnime(prompt: text, settings: try AnimeGenerationSettings(steps: steps, size: imageSize, upscaler: upscaler)) }
        catch { library.error = error.localizedDescription }
    }
    private var settingsDescription: String {
        "\(L("Steps")): \(steps) · \(imageSize.title) · \(upscaler.title) · \(L("Final image size")): \(imageSize.dimensions.width * upscaler.scale) × \(imageSize.dimensions.height * upscaler.scale)"
    }
}

private struct AnimeImageContent: View {
    @Environment(MangaLibrary.self) private var library
    let image: GeneratedAnimeImage
    let canGenerate: Bool
    let settingsDescription: String
    let regenerate: (String) -> Void
    @State private var removing = false
    @State private var regenerating = false
    var body: some View {
        let url = library.animeDirectory.appendingPathComponent(image.filename)
        let preview = UIImage(contentsOfFile: url.path)
        if let preview {
            Image(uiImage: preview).resizable().scaledToFit().accessibilityLabel(image.prompt)
            Text(image.prompt).textSelection(.enabled)
            LabeledContent(L("Image settings"), value: "\(image.width) × \(image.height) · \(L("Steps")): \(image.steps)")
            Text("\(L("Seed")): \(image.seed)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        HStack(alignment: .top, spacing: 12) {
            if preview != nil {
                ShareLink(item: url) { Label(L("Share image"), systemImage: "square.and.arrow.up") }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // These actions also allow recovery/removal of a missing PNG.
            Button(L("Delete image"), systemImage: "trash", role: .destructive) { removing = true }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(library.busy || library.downloadingModel)
                .confirmationDialog(L("Delete image?"), isPresented: $removing, titleVisibility: .visible) {
                    Button(L("Delete image"), role: .destructive) { library.deleteAnimeImages([image.id]) }
                    Button(L("Cancel"), role: .cancel) {}
                } message: { Text(L("This image and its saved prompt will be deleted from this device. This cannot be undone.")) }
            Button("\(L("Regenerate image")) · \(library.creditCost(.image)) \(L("credits"))", systemImage: "arrow.clockwise") { regenerating = true }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!canGenerate || library.busy || library.downloadingModel)
                .confirmationDialog(L("Regenerate image?"), isPresented: $regenerating, titleVisibility: .visible) {
                    Button("\(L("Regenerate image")) · \(library.creditCost(.image)) \(L("credits"))") { regenerate(image.prompt) }
                    Button(L("Cancel"), role: .cancel) {}
                } message: {
                    Text(L("Use this image's saved prompt with your current generation settings and a new random seed. The existing image is kept.") + "\n\n" + settingsDescription)
                }
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
    }
}

private struct AnimeImageDetail: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let image: GeneratedAnimeImage
    let canGenerate: Bool
    let settingsDescription: String
    let regenerate: (String) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnimeImageContent(image: image, canGenerate: canGenerate, settingsDescription: settingsDescription, regenerate: regenerate)
            }.padding()
        }
        .navigationTitle(L("Generated image"))
        .onChange(of: library.animeImages.contains { $0.id == image.id }) { _, exists in
            if !exists { dismiss() }
        }
    }
}
