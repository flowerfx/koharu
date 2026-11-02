import SwiftUI
import UIKit

@main struct KoharuPadApp: App {
    @UIApplicationDelegateAdaptor(CloudAppDelegate.self) private var cloudDelegate
    @State private var library: MangaLibrary?
    @State private var store: ConfigurationStore?
    @State private var startupError: String?
    @State private var starting = false
    @Environment(\.scenePhase) private var phase
    init() {
        do { _store = State(initialValue: try ConfigurationStore.shared.get()) }
        catch { _startupError = State(initialValue: error.localizedDescription) }
    }
    var body: some Scene {
        WindowGroup {
            let cloud = CloudServices.shared
            Group {
                if let store, !store.configuration.server.active {
                    ServerMaintenanceScreen(refreshing: starting || store.isRefreshing) { Task { await refreshConfiguration() } }
                } else if let update = cloud.update, library?.busy != true, library?.downloadingModel != true {
                    AppUpdateScreen(update: update).tint(.pink)
                } else if let library, let store {
                    AuthenticatedAppScreen(refreshConfiguration: { Task { await refreshConfiguration() } })
                        .environment(library).id(library.backendAuthentication.endpoint).tint(.pink)
                } else if let startupError {
                    ContentUnavailableView(L("Could not open library"), systemImage: "exclamationmark.triangle", description: Text(startupError))
                } else { ProgressView(L("Checking configuration…")) }
            }
            .environment(\.locale, AppLocalization.shared.locale)
            .environment(\.layoutDirection, AppLocalization.shared.isRightToLeft ? .rightToLeft : .leftToRight)
            .task { await start() }
            .task { await cloud.refreshUpdates() }
            .onChange(of: store?.configuration.server) { _, _ in
                Task { await applyServerConfiguration() }
            }
            .onChange(of: phase) { _, phase in
                if phase == .background { library?.enterBackground() }
                if phase == .active {
                    if let library, store?.configuration.server.active == true {
                        Task {
                            await library.subscriptions.refreshEntitlements()
                            await library.loginCredits()
                            if library.credits.loaded { await cloud.scheduleCreditReminders(nextReset: library.credits.nextDaily) }
                        }
                    }
                    Task { await refreshConfiguration() }
                    Task { await cloud.refreshNotificationStatus(); await cloud.refreshUpdates() }
                }
            }
        }
    }
    @MainActor private func start(refresh: Bool = true) async {
        guard !starting, library == nil, let store else { return }
        starting = true
        defer { starting = false }
        do {
            // Surface a broken bundle as a startup error rather than a crash.
            let disk = try LibraryDisk()
            let firstRun = !FileManager.default.fileExists(atPath: disk.root.appendingPathComponent("preferences.json").path)
            // The maintenance switch and endpoint are checked before account
            // restoration on every launch, including a surviving Keychain login.
            if refresh { await store.refresh() }
            guard !Task.isCancelled else { return }
            if firstRun { UserDefaults.standard.set(true, forKey: "translationProviderSetupPending") }
            guard store.configuration.server.active else {
                await CloudServices.shared.scheduleCreditReminders(nextReset: nil)
                return
            }
            let opened = MangaLibrary(disk: disk)
            library = opened
            Task { await opened.rewardedAds.refreshConsent() }
        } catch { startupError = error.localizedDescription }
    }
    @MainActor private func refreshConfiguration() async {
        guard let store, !starting else { return }
        await store.refresh { library?.canApplyConfiguration ?? true }
        await applyServerConfiguration()
    }
    @MainActor private func applyServerConfiguration() async {
        guard let store, !starting else { return }
        guard store.configuration.server.active else {
            await CloudServices.shared.scheduleCreditReminders(nextReset: nil)
            return
        }
        guard let library else { await start(refresh: false); return }
        let endpoint = store.configuration.server.endpoint
        guard library.backendAuthentication.endpoint != endpoint.absoluteString else { return }
        guard library.canApplyConfiguration else { store.refreshDeferred = true; return }
        library.credits.clear()
        do {
            try await library.backendAuthentication.reconfigure(endpoint: endpoint)
            if library.backendAuthentication.user != nil { try await library.credits.load() }
        } catch { library.error = error.localizedDescription }
    }

}

struct AuthenticatedAppScreen: View {
    var refreshConfiguration: () -> Void
    @Environment(MangaLibrary.self) private var library
    @State private var restoring = true
    @AppStorage("backendSignInCompleted") private var signInCompleted = false
    var body: some View {
        let account = library.backendAuthentication
        Group {
            if restoring {
                ProgressView(L("Checking sign-in…"))
            } else if let user = account.user {
                // Offline, the saved library opens without a credit profile; credit
                // actions stay blocked until the profile reloads from the backend.
                if (library.credits.loaded && library.credits.profile.id.uuidString.lowercased() == user.id.lowercased()) || library.credits.offline {
                    RootScreen(refreshConfiguration: refreshConfiguration).id(user.id)
                } else if library.credits.working || account.working {
                    ProgressView(L("Checking sign-in…"))
                } else {
                    ContentUnavailableView {
                        Label(L("Could not open credit profile"), systemImage: "exclamationmark.triangle")
                    } description: { Text(library.credits.failure ?? "") } actions: {
                        Button(L("Try again")) { Task { try? await library.credits.load() } }
                        Button(L("Sign out of backend")) { Task { await account.signOut() } }
                    }
                }
            } else {
                NavigationStack {
                    Form {
                        Section {
                            Text(L("Sign in to access your library, translation and image generation."))
                        }
                        NakamaAccountSection()
                    }
                    .navigationTitle(L("Sign in to continue"))
                }
            }
        }
        .task { await library.subscriptions.observeChanges() }
        .task {
            // Keychain survives reinstall; a new installation must still let
            // the user choose Guest or Apple before restoring access/paywalls.
            if signInCompleted { await account.restore() }
            restoring = false
        }
        .task(id: account.user?.id) {
            if account.user != nil { try? await library.credits.load() }
        }
        .onChange(of: account.user?.id) { _, id in
            signInCompleted = id != nil
            library.subscriptions.resetAccount()
            library.credits.clear()
            Task {
                if account.user?.id == id { await CloudServices.shared.scheduleCreditReminders(nextReset: nil) }
            }
            if id == nil {
                library.showCreditRewards = false
                library.creditRequest = nil
                library.approvedCreditRequest = nil
                library.showCreditProviderSettings = false
            }
        }
    }
}

enum MainTab: String {
    case library, browser, anime, settings
    var title: String {
        switch self {
        case .library: return L("Library")
        case .browser: return L("Rawkuma")
        case .anime: return L("Anime Studio")
        case .settings: return L("Settings")
        }
    }
    var symbol: String {
        switch self {
        case .library: return "books.vertical"
        case .browser: return "globe"
        case .anime: return "paintpalette"
        case .settings: return "gear"
        }
    }
}
private struct CreditReminderSchedule: Equatable {
    let nextReset: Date?
    let language: InterfaceLanguage
}

struct RootScreen: View {
    var refreshConfiguration: () -> Void
    @Environment(MangaLibrary.self) private var library
    @State private var browser = RawkumaBrowser()
    @State private var selection = MainTab.library
    @State private var readerPath: [UUID] = []
    @AppStorage("translationProviderSetupPending") private var providerSetupPending = false
    @State private var settingsProvider: TranslationProvider?
    var body: some View {
        @Bindable var library = library
        @Bindable var subscriptions = library.subscriptions
        TabView(selection: $selection) {
            Tab(MainTab.library.title, systemImage: MainTab.library.symbol, value: .library) {
                NavigationStack(path: $readerPath) {
                    LibraryScreen { url in browser.go(url); selection = .browser } browse: { selection = .browser }
                        .navigationDestination(for: UUID.self) { id in
                            ReaderScreen(chapterID: id, openSource: { url in browser.go(url); selection = .browser }).id(id)
                        }
                }
            }
            Tab(MainTab.browser.title, systemImage: MainTab.browser.symbol, value: .browser) {
                NavigationStack {
                    BrowserScreen(browser: browser) { id in
                        readerPath = [id]
                        selection = .library
                    }
                }
            }
            Tab(MainTab.anime.title, systemImage: MainTab.anime.symbol, value: .anime) {
                NavigationStack {
                    AnimeStudioScreen {
                        settingsProvider = library.preferences.provider
                        selection = .settings
                    }
                }
            }
            Tab(MainTab.settings.title, systemImage: MainTab.settings.symbol, value: .settings) {
                NavigationStack { SettingsScreen(providerFocus: $settingsProvider) }
            }
        }
        // UIKit's collection/tab controllers retain mirrored transforms when a
        // live language switch crosses RTL/LTR. Recreate presentation only;
        // selected tab, browser and durable reading state remain above it.
        .id(AppLocalization.shared.isRightToLeft)
        .tabViewStyle(.sidebarAdaptable)
        .task(id: CreditReminderSchedule(nextReset: library.credits.loaded ? library.credits.nextDaily : nil, language: AppLocalization.shared.language)) {
            guard library.credits.loaded else { return }
            let accountID = library.credits.profile.id
            let cloud = CloudServices.shared
            // Keep system permission UI ahead of the subscription sheet. A
            // previous refusal never opens Settings during automatic onboarding.
            await cloud.requestNotifications(openSettings: false)
            guard !Task.isCancelled, library.credits.loaded, library.credits.profile.id == accountID else { return }
            await cloud.scheduleCreditReminders(nextReset: library.credits.nextDaily)
            guard !Task.isCancelled, library.credits.loaded, library.credits.profile.id == accountID else { return }
            cloud.trackScreen(selection.rawValue)
            await subscriptions.prepareLaunchOffer()
            if !library.credits.loaded { return }
            await library.loginCredits()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            if library.credits.loaded {
                Task { await CloudServices.shared.scheduleCreditReminders(nextReset: library.credits.nextDaily) }
            }
        }
        .sheet(isPresented: $subscriptions.showOffer, onDismiss: { subscriptions.continueWithoutSubscription() }) {
            SubscriptionOfferScreen(subscriptions: subscriptions, policy: library.credits.policy)
                .presentationSizing(.page)
        }
        .sheet(isPresented: Binding(get: {
            subscriptions.launchOfferFinished && !subscriptions.showOffer && !providerSetupPending && (library.showCreditRewards || library.creditRequest != nil)
        }, set: { if !$0 { library.showCreditRewards = false; library.creditRequest = nil } }), onDismiss: {
            let approved = library.approvedCreditRequest
            library.approvedCreditRequest = nil
            library.showCreditRewards = false
            library.creditRequest = nil
            if subscriptions.offerAfterCredits {
                subscriptions.offerAfterCredits = false
                subscriptions.showOffer = true
            } else { approved?.proceed() }
        }) { CreditPanel() }
        .onChange(of: library.showCreditProviderSettings) { _, show in
            if show {
                settingsProvider = library.preferences.provider
                selection = .settings
                library.showCreditProviderSettings = false
            }
        }
        .onChange(of: selection) { _, tab in CloudServices.shared.trackScreen(tab.rawValue) }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
            if library.busy {
                HStack {
                    ProgressView(value: library.progress).frame(maxWidth: 180)
                    Text(library.status).font(.caption)
                    Button(L("Stop"), role: .destructive) { library.activeTask?.cancel() }.buttonStyle(.bordered)
                }.padding(10).frame(maxWidth: .infinity).background(.regularMaterial)
            }
            CreditSummary()
            }
        }
        .alert(L("Koharu"), isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button(L("OK")) { library.error = nil }
        } message: { Text(library.error ?? "") }
        .sheet(isPresented: Binding(get: {
            subscriptions.launchOfferFinished && !subscriptions.showOffer && providerSetupPending
        }, set: { providerSetupPending = $0 })) {
            ProviderSetupScreen { provider, download in
                library.preferences.provider = provider
                library.savePreferences()
                settingsProvider = provider
                selection = .settings
                providerSetupPending = false
                if let download { library.downloadModel(download) }
            }
            .interactiveDismissDisabled()
            .presentationSizing(.page)
        }
        .onChange(of: library.preferences) { _, _ in library.savePreferences() }
        .onChange(of: library.busy) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy
        }
        .onChange(of: library.canApplyConfiguration) { _, canApply in
            if canApply && (try? ConfigurationStore.shared.get().refreshDeferred) == true { refreshConfiguration() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            if !library.busy { Task { await library.translator.unload(); await library.pipeline.releaseCachedModels() } }
        }
    }
}

struct LibraryScreen: View {
    @Environment(MangaLibrary.self) private var library
    var openSource: (String) -> Void
    var browse: () -> Void
    @State private var deleting: Chapter?
    @State private var deletingAll = false
    @State private var searchText = ""
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleChapters: [Chapter] {
        query.isEmpty ? library.chapters : library.chapters.filter { $0.title.localizedStandardContains(query) }
    }
    var body: some View {
        List {
            Section {
                if library.chapters.isEmpty {
                    ContentUnavailableView {
                        Label(L("Your manga library"), systemImage: "books.vertical")
                    } description: { Text(L("Browse Rawkuma and translate a chapter. Saved chapters stay on this device.")) } actions: { Button(L("Browse Rawkuma"), action: browse).buttonStyle(.borderedProminent) }
                }
                if !library.chapters.isEmpty && visibleChapters.isEmpty {
                    ContentUnavailableView(L("No matching chapters"), systemImage: "magnifyingglass", description: Text(L("Try another chapter title.")))
                }
                ForEach(visibleChapters) { chapter in
                    NavigationLink(value: chapter.id) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(chapter.title).font(.headline).lineLimit(2)
                            Text("\(chapter.pages.count) \(L("pages")) · \(AppLocalization.shared.locale.localizedString(forIdentifier: chapter.target) ?? chapter.target)").font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: Double(chapter.pages.filter { $0.rendered != nil }.count), total: Double(max(1, chapter.pages.count))).tint(.pink)
                        }.padding(.vertical, 8)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(L("Delete"), systemImage: "trash", role: .destructive) { deleting = chapter }.disabled(library.busy)
                    }
                    .contextMenu {
                        Button(L("Original chapter"), systemImage: "globe") { openSource(chapter.sourceURL) }
                        Button(library.preferences.provider == .backend ? "\(L("Retranslate")) · \(library.rerunCreditCost) \(L("credits"))" : L("Retranslate"), systemImage: "arrow.clockwise") { library.run(chapter.id, force: true) }.disabled(library.busy)
                        Divider()
                        Button(L("Delete"), systemImage: "trash", role: .destructive) { deleting = chapter }.disabled(library.busy)
                    }
                }
            } header: {
                Text("\(L("Chapters")): \(query.isEmpty ? "\(library.chapters.count)" : "\(visibleChapters.count) / \(library.chapters.count)")")
                    .monospacedDigit().textCase(nil)
            }
        }
        .navigationTitle(L("Library"))
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Search chapters"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(L("Delete all chapters"), systemImage: "trash") { deletingAll = true }
                    .disabled(library.busy || library.chapters.isEmpty)
                Button(L("Browse Rawkuma"), systemImage: "globe", action: browse)
            }
        }
        .confirmationDialog(L("Delete this saved chapter?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let deleting { library.delete([deleting.id]) }; deleting = nil }
            Button(L("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L("Original images, translations and chapter history will be permanently deleted. Downloaded models and settings are kept."))
        }
        .confirmationDialog(L("Delete all saved chapters?"), isPresented: $deletingAll, titleVisibility: .visible) {
            Button(L("Delete all chapters"), role: .destructive) { library.delete(library.chapters.map(\.id)) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Original images, translations and chapter history will be permanently deleted. Downloaded models and settings are kept."))
        }
    }
}

struct ReaderScreen: View {
    @Environment(MangaLibrary.self) private var library
    let chapterID: UUID
    var openSource: (String) -> Void
    @State private var index = 0
    @State private var original = false
    @State private var entireProject = true
    @State private var editing = false
    @State private var clear = false
    @State private var share: URL?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var rerunCreditSuffix: String {
        library.preferences.provider == .backend ? " · \(library.rerunCreditCost) \(L("credits"))" : ""
    }
    var chapter: Chapter? { library.chapters.first { $0.id == chapterID } }
    var body: some View {
        Group {
            if let chapter, !chapter.pages.isEmpty {
                let page = chapter.pages[min(index, chapter.pages.count - 1)]
                VStack(spacing: 0) {
                    // iPhone widths put the page slider on its own row and show
                    // the edit action as an icon, so no control is squeezed out.
                    let compact = horizontalSizeClass == .compact
                    VStack(spacing: 6) {
                        HStack {
                            Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.backward") }.disabled(index == 0).accessibilityLabel(L("Previous page"))
                            Text("\(index + 1) / \(chapter.pages.count)").monospacedDigit()
                            Button { index = min(chapter.pages.count - 1, index + 1) } label: { Image(systemName: "chevron.forward") }.disabled(index == chapter.pages.count - 1).accessibilityLabel(L("Next page"))
                            if compact { Spacer() } else { pageSlider(chapter.pages.count) }
                            Toggle(L("Original"), isOn: $original).toggleStyle(.button)
                            if compact {
                                Button(L("Edit text"), systemImage: "text.cursor") { editing = true }.labelStyle(.iconOnly).disabled(library.busy || page.segments.isEmpty)
                            } else {
                                Button(L("Edit text"), systemImage: "text.cursor") { editing = true }.disabled(library.busy || page.segments.isEmpty)
                            }
                        }
                        if compact { pageSlider(chapter.pages.count) }
                    }.padding(10).background(.bar)
                    if library.readingMode == .vertical {
                        ContinuousReader(urls: chapter.pages.map { pageURL($0) }, index: index) { index = $0 }
                    } else {
                        ZoomPage(url: pageURL(page)) { offset in
                            index = min(chapter.pages.count - 1, max(0, index + offset))
                        }.id(page.id.uuidString + (original ? "original" : page.rendered ?? "source"))
                    }
                }
                .sheet(isPresented: $editing) { TextEditorScreen(chapterID: chapterID, page: page) }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(L("Original chapter"), systemImage: "globe") { openSource(chapter.sourceURL) }
                        Menu {
                            Toggle(L("Entire project"), isOn: $entireProject)
                            Button(L("Run") + rerunCreditSuffix, systemImage: "play") { library.run(chapterID, force: false, page: entireProject ? nil : page.id) }.disabled(library.busy)
                            Button(L("Retranslate") + rerunCreditSuffix, systemImage: "arrow.clockwise") { library.run(chapterID, force: true, page: entireProject ? nil : page.id) }.disabled(library.busy)
                            Button(L("Undo"), systemImage: "arrow.uturn.backward") { library.restore(chapterID, redo: false) }.disabled(library.busy || !FileManager.default.fileExists(atPath: library.disk.chapterURL(chapterID).appendingPathComponent("undo.json").path))
                            Button(L("Redo"), systemImage: "arrow.uturn.forward") { library.restore(chapterID, redo: true) }.disabled(library.busy || !FileManager.default.fileExists(atPath: library.disk.chapterURL(chapterID).appendingPathComponent("redo.json").path))
                            Button(L("Share page"), systemImage: "square.and.arrow.up") { share = pageURL(page) }
                            Button(L("Export PDF"), systemImage: "doc") { exportPDF(chapter) }.disabled(library.busy)
                            Button(L("Clear cache"), systemImage: "trash") { clear = true }.disabled(library.busy)
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            } else { ContentUnavailableView(L("Chapter not found"), systemImage: "book.closed") }
        }
        .background(ReaderNavigationGuard().allowsHitTesting(false))
        .navigationTitle(chapter?.title ?? L("Reader"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let chapter, !chapter.pages.isEmpty {
                index = min(chapter.readPage, max(0, chapter.pages.count - 1))
            }
        }
        .onChange(of: index) { _, value in library.setReadPage(chapterID, value) }
        .onDisappear { library.flushReadPositions() }
        .sheet(item: Binding(get: { share.map { ShareDocument(url: $0) } }, set: { share = $0?.url })) { ActivityShare(items: [$0.url]) }
        .confirmationDialog(L("Clear rendered cache? Originals, OCR and edited text are kept."), isPresented: $clear, titleVisibility: .visible) {
            Button(L("Clear cache"), role: .destructive) { library.clearCache(chapterID) }
        }
    }
    private func pageSlider(_ count: Int) -> some View {
        Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }), in: 0...Double(max(1, count - 1)), step: 1).disabled(count == 1)
    }
    private func pageURL(_ page: MangaPage) -> URL {
        if !original, let rendered = page.rendered {
            let url = library.disk.pageURL(chapterID, rendered)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return library.disk.pageURL(chapterID, page.original)
    }
    private func exportPDF(_ chapter: Chapter) {
        let disk = library.disk
        Task {
            do {
                share = try await Task.detached {
                    // One export folder, emptied before each export, so shared PDFs
                    // do not accumulate in tmp for the life of the install.
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
                    try? FileManager.default.removeItem(at: folder)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(UUID().uuidString + ".pdf")
                    guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else { throw AppError.message(L("Could not create PDF")) }
                    defer { context.closePDF() }
                    for page in chapter.pages {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            let rendered = page.rendered.map { disk.pageURL(chapter.id, $0) }
                            let path = rendered.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? disk.pageURL(chapter.id, page.original)
                            guard let image = UIImage(contentsOfFile: path.path)?.cgImage else { throw AppError.message(L("Could not decode source image")) }
                            var rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                            let box = Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
                            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
                            context.draw(image, in: rect); context.endPDFPage()
                        }
                    }
                    return url
                }.value
            } catch { library.error = error.localizedDescription }
        }
    }
}

struct ReaderNavigationGuard: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ReaderNavigationController { ReaderNavigationController() }
    func updateUIViewController(_ controller: ReaderNavigationController, context: Context) {}
    static func dismantleUIViewController(_ controller: ReaderNavigationController, coordinator: ()) { controller.restoreNavigationGestures() }
}

final class ReaderNavigationController: UIViewController {
    private var savedGestures: [(UIGestureRecognizer, Bool)] = []
    override func loadView() { view = UIView(); view.backgroundColor = .clear }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reserveReaderGestures()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reserveReaderGestures()
    }
    override func viewWillDisappear(_ animated: Bool) {
        restoreNavigationGestures()
        super.viewWillDisappear(animated)
    }
    private func reserveReaderGestures() {
        guard let navigationController else { return }
        if savedGestures.isEmpty {
            // iPadOS 26+ also recognizes back swipes across the content area.
            // The reader owns horizontal gestures until it leaves the screen.
            savedGestures = [navigationController.interactivePopGestureRecognizer,
                             navigationController.interactiveContentPopGestureRecognizer]
                .compactMap { $0 }.map { ($0, $0.isEnabled) }
        }
        for (gesture, _) in savedGestures { gesture.isEnabled = false }
    }
    func restoreNavigationGestures() {
        for (gesture, enabled) in savedGestures { gesture.isEnabled = enabled }
        savedGestures.removeAll()
    }
}

struct ShareDocument: Identifiable { let url: URL; var id: String { url.absoluteString } }
struct ActivityShare: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct ZoomPage: UIViewRepresentable {
    let url: URL
    var turnPage: (Int) -> Void
    func makeUIView(context: Context) -> PageScrollView { let view = PageScrollView(); view.turnPage = turnPage; view.show(url); return view }
    func updateUIView(_ view: PageScrollView, context: Context) { view.turnPage = turnPage; view.show(url) }
}
final class PageScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var turnPage: ((Int) -> Void)?
    private let picture = UIImageView()
    private var url: URL?
    private var loading: Task<Void, Never>?
    private var previousSize: CGSize = .zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; maximumZoomScale = 6; backgroundColor = .black; addSubview(picture)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(turnPageWithSwipe(_:)))
            swipe.direction = direction; swipe.delegate = self
            addGestureRecognizer(swipe)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func show(_ url: URL) {
        guard self.url != url else { return }
        self.url = url
        loading?.cancel()
        // Full resolution is kept for zooming, but decoded off the main thread.
        loading = Task { @MainActor [weak self] in
            let image = await PageImageLoader.load(url)
            guard let self, !Task.isCancelled, self.url == url else { return }
            self.picture.image = image
            self.picture.frame = CGRect(origin: .zero, size: image?.size ?? CGSize(width: 1, height: 1))
            self.previousSize = .zero; self.setNeedsLayout()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = picture.image, bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != previousSize {
            minimumZoomScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            zoomScale = minimumZoomScale; previousSize = bounds.size
        }
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - picture.frame.height) / 2), left: max(0, (bounds.width - picture.frame.width) / 2), bottom: 0, right: 0)
        contentSize = picture.frame.size
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UISwipeGestureRecognizer else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        // A zoomed page owns horizontal drags for panning, including when a
        // second finger is just beginning a pinch.
        return zoomScale <= minimumZoomScale * 1.01 && !isZooming && (pinchGestureRecognizer?.numberOfTouches ?? 0) < 2
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer === panGestureRecognizer
    }
    @objc private func turnPageWithSwipe(_ swipe: UISwipeGestureRecognizer) {
        guard swipe.state == .ended, gestureRecognizerShouldBegin(swipe) else { return }
        turnPage?(swipe.direction == .left ? 1 : -1)
    }
}

struct TextEditorScreen: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let chapterID: UUID
    let page: MangaPage
    @State private var texts: [Int: String] = [:]
    @State private var saving = false
    var body: some View {
        NavigationStack {
            List(page.segments) { segment in
                VStack(alignment: .leading) {
                    Text(segment.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    TextField(L("Translation"), text: Binding(get: { texts[segment.id] ?? segment.text ?? "" }, set: { texts[segment.id] = $0 }), axis: .vertical)
                }.padding(.vertical, 5)
            }
            .navigationTitle(L("Edit text"))
            .toolbar {
                Button(L("Cancel")) { dismiss() }.disabled(saving)
                Button(L("Save")) {
                    saving = true
                    Task {
                        if await library.edit(chapterID, page: page.id, texts: texts) { dismiss() }
                        saving = false
                    }
                }.disabled(saving || library.busy)
            }
        }
    }
}
