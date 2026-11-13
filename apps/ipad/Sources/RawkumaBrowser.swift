import SwiftUI
import WebKit
import Observation

@MainActor @Observable final class RawkumaBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let appConfiguration: () -> AppConfiguration
    var safetyMode: ContentSafetyMode { appConfiguration().contentSafety.mode }
    private var source: RawkumaConfiguration? { appConfiguration().rawkuma }
    var baseAddress: String { source?.url?.absoluteString ?? "" }
    let webView: WKWebView
    var addressPath = ""
    var address: String { baseAddress + addressPath }
    var isCurrentAddress: Bool { source?.address(forPath: addressPath) == webView.url }
    var loading = false
    var hasLoaded = false
    var chapter: SourceChapter?
    var error: String?
    var showsWarning = false
    var showsBlockedContent = false
    var genreMessage: String?
    private var genresVerified = false
    var canTranslate: Bool { safetyMode == .none || (safetyMode == .half && genresVerified) }
    private var acceptedWarning = false
    private var pendingAddress: String?
    private var inspection: Task<Void, Never>?
    init(appConfiguration: @escaping () -> AppConfiguration = { AppConfiguration.current }) {
        self.appConfiguration = appConfiguration
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if let file = Bundle.main.url(forResource: "rawkuma-navigation", withExtension: "js"), let script = try? String(contentsOf: file, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }
    func goPath() {
        guard let url = source?.address(forPath: addressPath) else { error = L("Enter a path on the configured Rawkuma website."); return }
        go(url.absoluteString)
    }
    func go(_ address: String) {
        guard appConfiguration().allowsRawkuma else { suspend(); return }
        guard let path = source?.path(from: address), let url = URL(string: address) else { error = L("Enter a path on the configured Rawkuma website."); return }
        if safetyMode.warnsAboutRawkuma && !acceptedWarning {
            pendingAddress = address; showsWarning = true; return
        }
        addressPath = path; chapter = nil; error = nil; hasLoaded = true; webView.isHidden = safetyMode == .half
        inspection?.cancel()
        webView.load(URLRequest(url: url))
    }
    func acceptWarning() {
        acceptedWarning = true; showsWarning = false
        if let pendingAddress { go(pendingAddress) }
        pendingAddress = nil
    }
    func suspend() {
        inspection?.cancel(); webView.stopLoading(); chapter = nil; loading = false; hasLoaded = false; webView.isHidden = true
        acceptedWarning = false; pendingAddress = nil; showsWarning = false
        genresVerified = false; genreMessage = nil; showsBlockedContent = false
        webView.loadHTMLString("", baseURL: nil)
    }
    func returnHomeFromBlockedContent() {
        guard showsBlockedContent else { return }
        showsBlockedContent = false
        go(baseAddress)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard appConfiguration().allowsRawkuma,
              !safetyMode.warnsAboutRawkuma || acceptedWarning else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == true || action.targetFrame == nil {
            decisionHandler(action.request.url.map { source?.contains($0.absoluteString) == true } == true && action.targetFrame != nil ? .allow : .cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(!response.isForMainFrame || (appConfiguration().allowsRawkuma && response.response.url.map { source?.contains($0.absoluteString) == true } == true) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; chapter = nil; error = nil; inspection?.cancel()
        genresVerified = false; genreMessage = nil
        if safetyMode == .half { webView.isHidden = true }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        guard let url = webView.url, let path = source?.path(from: url.absoluteString) else { suspend(); return }
        addressPath = path
        inspection?.cancel()
        inspection = Task {
            if safetyMode == .half, let value = webView.url?.absoluteString, RawkumaGenreChecker.seriesURL(value, rawkuma: source) != nil {
                genreMessage = L("Checking manga genres…")
                do {
                    try await RawkumaGenreChecker.requireAllowed(value, configuration: appConfiguration().contentSafety, rawkuma: source)
                    try Task.checkCancellation()
                    guard webView.url?.absoluteString == value else { return }
                    genresVerified = true; genreMessage = nil
                } catch {
                    guard !Task.isCancelled, webView.url?.absoluteString == value else { return }
                    genreMessage = error.localizedDescription; chapter = nil
                    if case RawkumaGenreFailure.blocked = error {
                        showsBlockedContent = true
                    } else { webView.isHidden = false }
                    return
                }
            }
            webView.isHidden = false
            for _ in 0..<15 {
                if Task.isCancelled { return }
                await inspect()
                if chapter != nil { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        // Replacing an in-flight navigation is normal when choosing another chapter.
        guard (error as NSError).code != NSURLErrorCancelled || (error as NSError).domain != NSURLErrorDomain else { return }
        loading = false; self.error = error.localizedDescription
    }
    func inspect() async {
        guard let url = webView.url, source?.contains(url.absoluteString) == true, !webView.isLoading else { return }
        do {
            let value = try await webView.evaluateJavaScript(#"""
            (() => {
              const reader = [...document.querySelectorAll('section[data-image-data] img')];
              const nodes = reader.length ? reader : [...document.querySelectorAll('img[alt*=" - Page "]')];
              const images = [];
              for (const image of nodes) {
                for (const source of [image.getAttribute('data-src'), image.getAttribute('data-original'), image.getAttribute('src'), image.currentSrc]) {
                  if (!source) continue;
                  try {
                    const url = new URL(source, location.href);
                    if (url.protocol === 'https:' && url.hostname === 'cdn.rawkuma.com' && !url.username && !url.password && !url.port) {
                      if (!images.includes(url.href)) images.push(url.href);
                      break;
                    }
                  } catch {}
                }
              }
              return JSON.stringify({url: location.href, title: document.title, images});
            })()
            """#)
            guard webView.url == url, let string = value as? String else { return }
            let candidate = try JSONDecoder().decode(SourceChapter.self, from: Data(string.utf8)).validated(rawkuma: source)
            guard candidate.url == url.absoluteString else { return }
            chapter = candidate; error = nil
        } catch { chapter = nil }
    }
}

struct BrowserSurface: UIViewRepresentable {
    let browser: RawkumaBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserScreen: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var browser: RawkumaBrowser
    @State private var revalidate = true
    @State private var newCopy = false
    var showLibrary: (UUID) -> Void
    private var translateTitle: String {
        "\(L("Translate this chapter")) · \(library.creditCost(.translate)) \(L("credits"))"
    }
    private var enhancedTitle: String {
        "\(L("Enhanced translation")) · \(library.creditCost(.translateEnhanced)) \(L("credits"))"
    }
    private var cannotTranslate: Bool { library.busy || browser.chapter == nil || browser.loading || !browser.canTranslate }
    var body: some View {
        VStack(spacing: 0) {
            if browser.safetyMode.warnsAboutRawkuma {
                Label(L("Rawkuma is an external website and may contain inappropriate content."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(8)
            }
            if let message = browser.genreMessage {
                Text(message).font(.caption).foregroundStyle(.orange).padding(8)
            }
            if horizontalSizeClass == .compact {
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Group {
                            if browser.loading { ProgressView().controlSize(.small) }
                            else { Image(systemName: "globe").foregroundStyle(.secondary) }
                        }.frame(width: 18)
                        addressField
                        Button {
                            if browser.isCurrentAddress { browser.webView.reload() }
                            else { browser.goPath() }
                        } label: {
                            Image(systemName: browser.isCurrentAddress ? "arrow.clockwise" : "arrow.right")
                                .frame(width: 32, height: 40).contentShape(Rectangle())
                        }.accessibilityLabel(L(browser.isCurrentAddress ? "Reload" : "Go"))
                    }
                    .padding(.leading, 12).padding(.trailing, 4)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    HStack(spacing: 4) {
                        Button { browser.webView.goBack() } label: {
                            Image(systemName: "chevron.backward").frame(width: 44, height: 44).contentShape(Rectangle())
                        }.accessibilityLabel(L("Back")).disabled(!browser.webView.canGoBack)
                        Button { browser.webView.goForward() } label: {
                            Image(systemName: "chevron.forward").frame(width: 44, height: 44).contentShape(Rectangle())
                        }.accessibilityLabel(L("Forward")).disabled(!browser.webView.canGoForward)
                        Button { translateChapter(enhanced: false) } label: {
                            HStack(spacing: 6) {
                                Label(translateTitle, systemImage: "translate")
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                if let chapter = browser.chapter {
                                    Text(chapter.images.count, format: .number).font(.caption.monospacedDigit())
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(.white.opacity(0.18), in: Capsule())
                                }
                            }.font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(cannotTranslate)
                        Button { translateChapter(enhanced: true) } label: {
                            Label(enhancedTitle, systemImage: "sparkles")
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(cannotTranslate)
                        Menu {
                            if let chapter = browser.chapter { Text("\(chapter.images.count) \(L("pages"))") }
                            Toggle(L("Check source updates"), isOn: $revalidate)
                            Toggle(L("New copy"), isOn: $newCopy)
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                        }.accessibilityLabel(L("Translation"))
                    }.font(.subheadline)
                }.padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2).background(.bar)
                Divider()
            } else {
                HStack {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.backward") }.accessibilityLabel(L("Back"))
                    Button { browser.webView.goForward() } label: { Image(systemName: "chevron.forward") }.accessibilityLabel(L("Forward"))
                    Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(L("Reload"))
                    addressField
                    Button(L("Go")) { browser.goPath() }
                }.padding(10)
                HStack {
                    Button { translateChapter(enhanced: false) } label: { Label(translateTitle, systemImage: "translate") }
                    .buttonStyle(.borderedProminent).disabled(cannotTranslate)
                    Button { translateChapter(enhanced: true) } label: { Label(enhancedTitle, systemImage: "sparkles") }
                    .buttonStyle(.bordered).disabled(cannotTranslate)
                    Toggle(L("Check source updates"), isOn: $revalidate).toggleStyle(.button)
                    Toggle(L("New copy"), isOn: $newCopy).toggleStyle(.button)
                    Spacer()
                    if let chapter = browser.chapter { Text("\(chapter.images.count) \(L("pages"))").font(.caption).foregroundStyle(.secondary) }
                    if browser.loading { ProgressView() }
                }.padding(.horizontal, 10).padding(.bottom, 8)
            }
            if let error = browser.error { Text(error).font(.caption).foregroundStyle(.red).padding(6) }
            BrowserSurface(browser: browser)
        }
        .navigationTitle(L("Rawkuma"))
        .alert(browser.showsBlockedContent ? L("Inappropriate content") : L("External content warning"), isPresented: Binding(get: { browser.showsWarning || browser.showsBlockedContent }, set: { visible in
            if !visible {
                if browser.showsBlockedContent { browser.returnHomeFromBlockedContent() }
                else { browser.showsWarning = false }
            }
        })) {
            if browser.showsBlockedContent {
                Button(L("Back"), role: .cancel) { browser.returnHomeFromBlockedContent() }
            } else {
                Button(L("Continue")) { browser.acceptWarning() }
                Button(L("Cancel"), role: .cancel) { browser.showsWarning = false }
            }
        } message: {
            Text(browser.showsBlockedContent ? L("This content is inappropriate and cannot be translated.") : L("Rawkuma is an external website and may contain inappropriate content."))
        }
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .inline : .large)
        .task { if !browser.hasLoaded { browser.go(browser.address) } }
    }
    private var addressField: some View {
        HStack(spacing: 6) {
            Text(browser.baseAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 7).padding(.vertical, 8)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityIdentifier("rawkuma-fixed-origin")
            TextField(L("Manga path"), text: $browser.addressPath)
                .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).submitLabel(.go).onSubmit { browser.goPath() }
                .accessibilityIdentifier("rawkuma-address-path")
        }.environment(\.layoutDirection, .leftToRight).frame(maxWidth: .infinity)
    }
    private func translateChapter(enhanced: Bool) {
        guard browser.canTranslate, let chapter = browser.chapter else { return }
        library.importChapter(chapter, revalidate: revalidate, newCopy: newCopy, enhanced: enhanced, onReady: showLibrary)
    }
}
