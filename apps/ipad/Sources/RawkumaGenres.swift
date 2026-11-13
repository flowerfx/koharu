import Foundation
import WebKit

enum RawkumaGenreFailure: Error, LocalizedError {
    case blocked([String]), unavailable
    var errorDescription: String? {
        switch self {
        case .blocked: return L("This content is inappropriate and cannot be translated.")
        case .unavailable: return L("Could not verify this manga's genres. Translation is blocked. Please try again.")
        }
    }
}

@MainActor enum RawkumaGenreChecker {
    static func seriesURL(_ value: String, rawkuma: RawkumaConfiguration? = AppConfiguration.current.rawkuma) -> URL? {
        guard rawkuma?.contains(value) == true, let url = URL(string: value) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "manga", !parts[1].isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/manga/" + parts[1] + "/"; components.query = nil; components.fragment = nil
        return components.url
    }
    /// Fetches the series page once. Half-safe mode blocks on its genres; every
    /// mode returns the series description as translation reference data.
    @discardableResult
    static func requireAllowed(_ value: String, configuration: ContentSafetyConfiguration, rawkuma: RawkumaConfiguration? = AppConfiguration.current.rawkuma) async throws -> SeriesContext? {
        // Imported local images have no Rawkuma series; full-safe has no built-in Rawkuma entry point.
        let checking = configuration.mode == .half && !configuration.blockedGenres.isEmpty
        guard !value.hasPrefix("imported://") else { return nil }
        do {
            let series = try await load(value, rawkuma: rawkuma)
            if checking {
                guard !series.genres.isEmpty else { throw RawkumaGenreFailure.unavailable }
                let blocked = configuration.blockedMatches(series.genres)
                if !blocked.isEmpty { throw RawkumaGenreFailure.blocked(blocked) }
            }
            return series
        } catch is CancellationError { throw CancellationError() }
        catch let error as RawkumaGenreFailure where checking { throw error }
        catch { if checking { throw RawkumaGenreFailure.unavailable }; return nil }
    }
    private static func load(_ value: String, rawkuma: RawkumaConfiguration?) async throws -> SeriesContext {
        guard let url = seriesURL(value, rawkuma: rawkuma) else { throw RawkumaGenreFailure.unavailable }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: RedirectBoundary { rawkuma?.contains($0.absoluteString) == true }, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("KoharuPad/1.0", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url.flatMap({ seriesURL($0.absoluteString, rawkuma: rawkuma) })?.path == url.path,
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4 * 1024 * 1024,
              let html = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw RawkumaGenreFailure.unavailable }
        return try await RawkumaGenreDocument().parse(html, base: url)
    }
}

// Read the series title, Japanese alternative titles, synopsis and schema.org genre
// tags from the series description only, excluding recommendations/navigation.
// Remote page code stays inert; the text is untrusted reference data.
@MainActor final class RawkumaGenreDocument: NSObject, WKNavigationDelegate {
    private let web = WKWebView(frame: .zero, configuration: {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false; return config
    }())
    private var continuation: CheckedContinuation<Void, Error>?
    private var started = false
    func parse(_ html: String, base: URL) async throws -> SeriesContext {
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
          if(!panel)return null;
          const clean=s=>s.replace(/\s+/g,' ').trim(), japanese=s=>/[\u3040-\u30ff\u3400-\u9fff]/.test(s);
          const genres=[...panel.querySelectorAll('a[itemprop="genre"]')].filter(a=>{
            try{const u=new URL(a.href);return u.protocol==='https:'&&u.origin===new URL(document.baseURI).origin&&/^\/genre\/[^/]+\/$/.test(u.pathname);}catch{return false;}
          }).map(a=>a.textContent.trim()).filter(s=>s.length>0&&s.length<=80);
          const name=document.querySelector('h1[itemprop="name"]'), title=name?clean(name.textContent):'';
          const alternatives=name&&name.nextElementSibling?name.nextElementSibling.textContent.split(/[,、]/).map(clean).filter(s=>s&&s!==title&&japanese(s)):[];
          // The longest description is the expanded one; <hr> separates its language versions.
          const full=[...panel.querySelectorAll('[itemprop="description"]')].sort((a,b)=>b.textContent.length-a.textContent.length)[0];
          let parts=[];
          if(full){const copy=full.cloneNode(true);copy.querySelectorAll('hr,br').forEach(e=>e.replaceWith('\n'));parts=copy.textContent.split('\n').map(clean).filter(Boolean);}
          const native=parts.filter(japanese);
          return {genres,title,alternatives,synopsis:(native.length?native:parts).join('\n')};
        })()
        """#)
        guard let value = result as? [String: Any], let genres = value["genres"] as? [String], genres.count <= 100,
              let title = value["title"] as? String, let alternatives = value["alternatives"] as? [String],
              let synopsis = value["synopsis"] as? String else { throw RawkumaGenreFailure.unavailable }
        return SeriesContext(title: String(title.prefix(200)), alternative_titles: alternatives.prefix(5).map { String($0.prefix(200)) },
                             genres: genres.prefix(30).map { $0 }, synopsis: String(synopsis.prefix(3000)))
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
