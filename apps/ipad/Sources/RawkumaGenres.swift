import Foundation
import WebKit

enum RawkumaGenreFailure: Error, LocalizedError {
    case blocked([String]), unavailable
    var errorDescription: String? {
        switch self {
        case .blocked(let genres): return L("Translation is blocked for these genres:") + " " + genres.joined(separator: ", ")
        case .unavailable: return L("Could not verify this manga's genres. Translation is blocked. Please try again.")
        }
    }
}

@MainActor enum RawkumaGenreChecker {
    static func seriesURL(_ value: String) -> URL? {
        guard SourceChapter.isSource(value), let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "manga", !parts[1].isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/manga/" + parts[1] + "/"; components.query = nil; components.fragment = nil
        return components.url
    }
    static func requireAllowed(_ value: String, configuration: ContentSafetyConfiguration) async throws {
        // none-safe does not fetch or filter genres. Imported local images have
        // no Rawkuma series; full-safe has no built-in Rawkuma entry point.
        guard configuration.mode == .half, !configuration.blockedGenres.isEmpty, SourceChapter.isSource(value) else { return }
        guard let url = seriesURL(value) else { throw RawkumaGenreFailure.unavailable }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: RedirectBoundary { SourceChapter.isSource($0.absoluteString) }, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("KoharuPad/1.0", forHTTPHeaderField: "User-Agent")
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url.flatMap({ seriesURL($0.absoluteString) })?.path == url.path,
                  (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4 * 1024 * 1024,
                  let html = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw RawkumaGenreFailure.unavailable }
            let genres = try await RawkumaGenreDocument().parse(html, base: url)
            guard !genres.isEmpty else { throw RawkumaGenreFailure.unavailable }
            let blocked = configuration.blockedMatches(genres)
            if !blocked.isEmpty { throw RawkumaGenreFailure.blocked(blocked) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as RawkumaGenreFailure { throw error }
        catch { throw RawkumaGenreFailure.unavailable }
    }
}

// Read schema.org genre tags from the series synopsis only, excluding genre
// links belonging to recommendations/navigation. Remote page code stays inert.
@MainActor final class RawkumaGenreDocument: NSObject, WKNavigationDelegate {
    private let web = WKWebView(frame: .zero, configuration: {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false; return config
    }())
    private var continuation: CheckedContinuation<Void, Error>?
    private var started = false
    func parse(_ html: String, base: URL) async throws -> [String] {
        let rule = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "rawkuma-genre-document", encodedContentRuleList:
            #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}}]"#)
        guard let rule else { throw RawkumaGenreFailure.unavailable }
        web.configuration.userContentController.add(rule); web.navigationDelegate = self
        let timeout = Task { try await Task.sleep(for: .seconds(10)); finish(RawkumaGenreFailure.unavailable) }
        defer { timeout.cancel(); web.stopLoading(); web.navigationDelegate = nil }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                web.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'none'; frame-src 'none'\">" + html, baseURL: base)
            }
        } onCancel: { Task { @MainActor in self.finish(CancellationError()); self.web.stopLoading() } }
        try Task.checkCancellation()
        let result = try await web.evaluateJavaScript(#"""
        (() => {
          const panel=document.getElementById('tabpanel-description');
          if(!panel)return [];
          return [...panel.querySelectorAll('a[itemprop="genre"]')].filter(a=>{
            try{const u=new URL(a.href);return u.protocol==='https:'&&['rawkuma.net','www.rawkuma.net'].includes(u.hostname)&&/^\/genre\/[^/]+\/$/.test(u.pathname);}catch{return false;}
          }).map(a=>a.textContent.trim()).filter(s=>s.length>0&&s.length<=80);
        })()
        """#)
        guard let genres = result as? [String], genres.count <= 100 else { throw RawkumaGenreFailure.unavailable }
        return genres
    }
    private func finish(_ error: Error? = nil) {
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !started, action.targetFrame?.isMainFrame == true { started = true; decisionHandler(.allow) } else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
}
