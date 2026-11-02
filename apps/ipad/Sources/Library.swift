import Foundation
import Observation
import UIKit

@MainActor @Observable final class MangaLibrary {
    let disk: LibraryDisk
    let credits: CreditStore
    let subscriptions: SubscriptionStore
    let backendAuthentication: NakamaAuthentication
    var showCreditRewards = false
    var creditRequest: CreditRequest?
    var approvedCreditRequest: CreditRequest?
    var showCreditProviderSettings = false
    var chapters: [Chapter] = []
    var preferences = Preferences()
    var readingMode = ReadingMode(rawValue: UserDefaults.standard.string(forKey: "readingMode") ?? "horizontal") ?? .horizontal {
        didSet { UserDefaults.standard.set(readingMode.rawValue, forKey: "readingMode") }
    }
    // Request sizing is an execution preference, separate from page content/cache.
    var translationBatchSize = min(100, max(1, UserDefaults.standard.object(forKey: "translationBatchSize") as? Int ?? 100)) {
        didSet {
            UserDefaults.standard.set(translationBatchSize, forKey: "translationBatchSize")
        }
    }
    var models: [LocalModel] = []
    var animeImages: [GeneratedAnimeImage] = []
    var animePromptSuggestion: AnimePromptSuggestion?
    var availableModels: [LocalModel] {
        models.filter { model in
            do { _ = try AppConfiguration.current.catalog(for: model); return true }
            catch { return false }
        }
    }
    var busy = false {
        didSet { if !busy { activeJobUsesGPU = false; endBackgroundWork() } }
    }
    // Metal, Core ML and Vision work cannot run while the app is in the
    // background; such jobs are stopped cooperatively when the scene leaves.
    @ObservationIgnored var activeJobUsesGPU = false
    @ObservationIgnored var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored var readPositionSaves: [UUID: Task<Void, Never>] = [:]
    var status = ""
    var progress: Double = 0
    var error: String?
    var activeTask: Task<Void, Never>?
    var modelTask: Task<Void, Never>?
    var downloadingModel = false
    let translator: TranslationEngine
    let backendAI: BackendAI
    let rewardedAds = RewardedAds()
    let pipeline = PagePipeline()
    let images = SourceImages()

    init(disk: LibraryDisk) {
        self.disk = disk
        let authentication = NakamaAuthentication()
        backendAuthentication = authentication
        let backend = BackendAI { name, payload in try await authentication.rpcCommand(name, payload: payload) }
        backendAI = backend
        translator = TranslationEngine(backend: backend)
        // KoharuPadApp validates both bundled resources before creating the
        // library and shows a startup error instead; these are build invariants.
        let policy = AppConfiguration.current.credit
        let credits = CreditStore(authentication: authentication, policy: policy)
        self.credits = credits
        subscriptions = SubscriptionStore(credits: credits, environment: (try? ConfigurationTarget(bundle: .main).environment) ?? .production)
        do {
            chapters = try disk.chapters()
            let config = disk.root.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: config.path) { preferences = try disk.load(Preferences.self, config) }
            else { try disk.save(preferences, to: config) }
            let inventory = disk.root.appendingPathComponent("models.json")
            if FileManager.default.fileExists(atPath: inventory.path) { models = try disk.load([LocalModel].self, inventory) }
            let animeInventory = animeDirectory.appendingPathComponent("images.json")
            if FileManager.default.fileExists(atPath: animeInventory.path) { animeImages = try disk.load([GeneratedAnimeImage].self, animeInventory) }
        } catch { self.error = error.localizedDescription }
    }
    func savePreferences() { do { try disk.save(preferences, to: disk.root.appendingPathComponent("preferences.json")) } catch { self.error = error.localizedDescription } }
    func update(_ chapter: Chapter, recordUndo: Bool = true) throws {
        try disk.save(chapter, recordUndo: recordUndo)
        if let index = chapters.firstIndex(where: { $0.id == chapter.id }) { chapters[index] = chapter }
        else { chapters.insert(chapter, at: 0) }
    }
    func importChapter(_ source: SourceChapter, revalidate: Bool, newCopy: Bool = false, onReady: @escaping @MainActor (UUID) -> Void) {
        guard !busy else { return }
        do { try requireCreditProvider() } catch { self.error = error.localizedDescription; return }
        requestCredits(.translate, cost: creditCost(.translate), explanation: translationCreditExplanation) {
            self.startImportChapter(source, revalidate: revalidate, newCopy: newCopy, onReady: onReady)
        }
    }
    private func startImportChapter(_ source: SourceChapter, revalidate: Bool, newCopy: Bool, onReady: @escaping @MainActor (UUID) -> Void) {
        guard !busy else { return }
        let config = preferences
        busy = true; activeJobUsesGPU = true
        activeTask = Task {
            var translated = false
            var renderedPages = 0
            var ticket: String?
            do {
                ticket = try await credits.reserve(action: .translate, provider: config.provider, rerun: false)
                try Task.checkCancellation()
                let source = try source.validated()
                var chapter = (newCopy ? nil : chapters.first { $0.sourceURL == source.url && $0.target == config.target }) ?? Chapter(title: source.title, sourceURL: source.url, target: config.target, pages: [])
                var pages: [MangaPage] = []
                for (index, url) in source.images.enumerated() {
                    try Task.checkCancellation()
                    status = "\(L("Downloading")) \(index + 1)/\(source.images.count)"
                    progress = Double(index) / Double(source.images.count)
                    let old = chapter.pages.first { $0.source == url }
                    let page = try await images.fetch(url: url, referer: source.url, chapter: chapter.id, previous: old, revalidate: revalidate, disk: disk)
                    pages.append(page)
                }
                chapter.pages = pages
                try update(chapter)
                onReady(chapter.id)
                try await translate(chapter.id, config: config, ticket: ticket, force: false) { renderedPages += 1 }
                translated = true
            } catch is CancellationError { status = L("Stopped") }
            catch { processingFailed(error) }
            // A run that delivered any newly rendered page is charged; only a run
            // that produced nothing (failed or stopped before the first page) is refunded.
            await finishCredits(ticket, success: translated || renderedPages > 0, provider: config.provider)
            await pipeline.releaseCachedModels()
            busy = false; activeTask = nil
        }
    }
    func run(_ id: UUID, force: Bool, page: UUID? = nil) {
        guard !busy else { return }
        guard chapters.contains(where: { $0.id == id && !$0.pages.isEmpty }) else { error = L("Chapter not found"); return }
        do { try requireCreditProvider() } catch { self.error = error.localizedDescription; return }
        requestCredits(.translate, cost: rerunCreditCost, explanation: translationCreditExplanation, rerun: true) {
            self.startRun(id, force: force, page: page)
        }
    }
    private func startRun(_ id: UUID, force: Bool, page: UUID?) {
        guard !busy else { return }
        let config = preferences
        busy = true; activeJobUsesGPU = true
        activeTask = Task {
            var translated = false
            var renderedPages = 0
            var ticket: String?
            do {
                ticket = try await credits.reserve(action: .translate, provider: config.provider, rerun: true)
                try Task.checkCancellation()
                var target = id
                if let source = chapters.first(where: { $0.id == id }), source.target != config.target {
                    var copy = source; copy.id = UUID(); copy.target = config.target; copy.created = Date()
                    try FileManager.default.createDirectory(at: disk.chapterURL(copy.id), withIntermediateDirectories: true)
                    for i in copy.pages.indices {
                        let input = disk.pageURL(source.id, copy.pages[i].original), output = disk.pageURL(copy.id, copy.pages[i].original)
                        if !FileManager.default.fileExists(atPath: output.path) { try FileManager.default.copyItem(at: input, to: output) }
                        copy.pages[i].rendered = nil; copy.pages[i].fingerprint = nil
                        for s in copy.pages[i].segments.indices { copy.pages[i].segments[s].text = nil; copy.pages[i].segments[s].edited = false }
                    }
                    try update(copy); target = copy.id
                }
                try await translate(target, config: config, ticket: ticket, force: force, only: page) { renderedPages += 1 }
                translated = true
            }
            catch is CancellationError { status = L("Stopped") }
            catch { processingFailed(error) }
            await finishCredits(ticket, success: translated || renderedPages > 0, provider: config.provider)
            await pipeline.releaseCachedModels()
            busy = false; activeTask = nil
        }
    }
    private func processingFailed(_ error: Error) {
        // A job stopped for backgrounding may surface a GPU error after the
        // cancellation; the background notice already explains it.
        if Task.isCancelled { status = L("Stopped"); return }
        self.error = status + "\n" + error.localizedDescription
        status = L("Failed")
    }
    private func translate(_ id: UUID, config: Preferences, ticket: String?, force: Bool, only: UUID? = nil, onPageSaved: () -> Void = {}) async throws {
        guard var chapter = chapters.first(where: { $0.id == id }) else { throw AppError.message(L("Chapter not found")) }
        // Superseded renders are unreferenced once the run ends (also on failure).
        defer { disk.pruneRendered(id) }
        try AppConfiguration.current.requireProvider(config.provider)
        _ = try AppConfiguration.current.requireVision(config.ocrModel ?? "apple")
        if config.inpaint { _ = try AppConfiguration.current.requireVision(config.cleanupModel ?? AppConfiguration.current.defaults.inpainting, inpainting: true) }
        let batchSize = translationBatchSize
        let model = models.first { $0.id == config.localModel }
        let catalog = config.provider == .local ? try model.flatMap { try AppConfiguration.current.catalog(for: $0) } : nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let prompt = try TranslationContract.prompts([], preferences: config).0
        // Only settings that change the rendered page take part. Pages saved with
        // the previous whole-preferences fingerprint remain valid.
        let fingerprint = digest(Data(("ipad-pipeline-4\n" + prompt).utf8) + (try encoder.encode(RenderFingerprint(config))))
        let legacyFingerprint = digest(Data(("ipad-pipeline-3\n" + prompt).utf8) + (try encoder.encode(config)))
        func fresh(_ value: String?) -> Bool { value == fingerprint || value == legacyFingerprint }
        let ocrSignature = "vision-3:" + (config.ocrModel ?? "apple") + ":" + (config.ocrModel.flatMap { id in (AppConfiguration.current.ocr + AppConfiguration.current.inpainting).first { $0.id == id } }?.files.map(\.sha256).joined() ?? "document-2")
        for index in chapter.pages.indices {
            if let only, chapter.pages[index].id != only { continue }
            try Task.checkCancellation()
            if !force && fresh(chapter.pages[index].fingerprint),
               chapter.pages[index].textLayoutVersion == PageTypography.version,
               let file = chapter.pages[index].rendered, FileManager.default.fileExists(atPath: disk.pageURL(id, file).path) { continue }
            status = "\(L("Translating")) \(index + 1)/\(chapter.pages.count)"
            progress = Double(index) / Double(chapter.pages.count)
            let source = disk.pageURL(id, chapter.pages[index].original)
            var page = chapter.pages[index]
            let rescanned = page.ocrSignature != ocrSignature
            if rescanned {
                guard !page.segments.contains(where: \.edited) else {
                    throw AppError.message(L("This page has edits from a different OCR configuration. Make a new copy to rescan without losing them."))
                }
                status = "\(L("Recognizing text")) \(index + 1)/\(chapter.pages.count)"
                await translator.unload()
                page.segments = try await pipeline.recognize(source, modelID: config.ocrModel, modelRoot: disk.modelsURL)
                page.ocrSignature = ocrSignature
            }
            let targets = page.segments.filter { !$0.edited }
            if !targets.isEmpty && (force || rescanned || !fresh(page.fingerprint) || targets.contains(where: { $0.text == nil })) {
                status = "\(L("Translating")) \(index + 1)/\(chapter.pages.count)"
                // A local GGUF needs the memory held by cached OCR/cleanup sessions.
                if config.provider == .local { await pipeline.releaseCachedModels() }
                let context = ticket.map { BackendAIContext(reservationID: $0, provider: config.backendProvider) }
                let texts = try await translator.translate(targets.map(\.source), config: config, model: model.map { disk.modelsURL.appendingPathComponent($0.filename) }, catalog: catalog, batchSize: batchSize, backendContext: context)
                for (segment, text) in zip(targets, texts) {
                    if let i = page.segments.firstIndex(where: { $0.id == segment.id }) { page.segments[i].text = text }
                }
            }
            // Release the large GGUF allocation before inpainting takes the device lane.
            if config.inpaint { await translator.unload() }
            status = "\(L("Rendering page")) \(index + 1)/\(chapter.pages.count)"
            let cleanupModel = config.cleanupModel ?? AppConfiguration.current.defaults.inpainting
            let cleanupName = AppConfiguration.current.inpainting.first { $0.id == cleanupModel }?.name ?? cleanupModel
            let output: Data
            // Native inference reports into a bounded per-page stream. Cancel
            // its UI consumer before saving so an obsolete tile cannot replace
            // the next page's status or revive a stopped job.
            let (events, continuation) = AsyncStream<CleanupProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let reporting = Task { @MainActor in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .loading:
                        status = "\(L("Loading cleanup model")) \(index + 1)/\(chapter.pages.count) · \(cleanupName)"
                    case .tiles(let completed, let total):
                        status = "\(L("Cleaning background")) \(index + 1)/\(chapter.pages.count) · \(cleanupName) · \(completed)/\(total)"
                        progress = (Double(index) + 0.4 + 0.5 * Double(completed) / Double(max(1, total))) / Double(chapter.pages.count)
                    }
                }
            }
            do {
                defer { continuation.finish(); reporting.cancel() }
                output = try await pipeline.render(source, segments: page.segments, inpaint: config.inpaint, modelID: cleanupModel, modelRoot: disk.modelsURL) { continuation.yield($0) }
            }
            try Task.checkCancellation()
            status = "\(L("Saving page")) \(index + 1)/\(chapter.pages.count)"
            let file = UUID().uuidString + ".png"
            try output.write(to: disk.pageURL(id, file), options: .atomic)
            page.rendered = file; page.fingerprint = fingerprint; page.textLayoutVersion = PageTypography.version
            chapter.pages[index] = page
            chapter.readPage = chapters.first { $0.id == id }?.readPage ?? chapter.readPage
            try update(chapter)
            onPageSaved()
        }
        status = L("Completed"); progress = 1
    }
    func edit(_ chapterID: UUID, page: UUID, texts: [Int: String]) async -> Bool {
        guard !busy, var chapter = chapters.first(where: { $0.id == chapterID }), let index = chapter.pages.firstIndex(where: { $0.id == page }) else { return false }
        busy = true
        defer { busy = false }
        do {
            for s in chapter.pages[index].segments.indices {
                if let text = texts[chapter.pages[index].segments[s].id] {
                    chapter.pages[index].segments[s].text = text
                    chapter.pages[index].segments[s].edited = true
                }
            }
            if preferences.inpaint { await translator.unload() }
            let output = try await pipeline.render(disk.pageURL(chapterID, chapter.pages[index].original), segments: chapter.pages[index].segments, inpaint: preferences.inpaint, modelID: preferences.cleanupModel ?? AppConfiguration.current.defaults.inpainting, modelRoot: disk.modelsURL)
            await pipeline.releaseCachedModels()
            try Task.checkCancellation()
            let file = UUID().uuidString + ".png"; try output.write(to: disk.pageURL(chapterID, file), options: .atomic)
            chapter.pages[index].rendered = file
            chapter.pages[index].textLayoutVersion = PageTypography.version
            chapter.readPage = chapters.first { $0.id == chapterID }?.readPage ?? chapter.readPage
            try update(chapter)
            disk.pruneRendered(chapterID)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func clearCache(_ id: UUID) {
        guard !busy else { return }
        do { try disk.clearDerived(id); chapters = try disk.chapters() } catch { self.error = error.localizedDescription }
    }
    func restore(_ id: UUID, redo: Bool) {
        guard !busy else { return }
        do {
            let chapter = try disk.restore(id, redo: redo)
            if let index = chapters.firstIndex(where: { $0.id == id }) { chapters[index] = chapter }
            disk.pruneRendered(id)
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ ids: [UUID]) {
        guard !busy else { return }
        let requested = Set(ids)
        do {
            for id in chapters.map(\.id) where requested.contains(id) {
                try FileManager.default.removeItem(at: disk.chapterURL(id))
                chapters.removeAll { $0.id == id }
            }
        } catch { self.error = error.localizedDescription }
    }
}
