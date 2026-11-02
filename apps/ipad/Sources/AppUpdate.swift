import Foundation
import SwiftUI

struct AppUpdate: Identifiable, Equatable {
    let version: String
    let storeURL: URL
    var id: String { version + storeURL.absoluteString }

    static func required(current: String, minimum: String, enabled: Bool, store: String, allowTestFlight: Bool) -> Self? {
        func components(_ value: String) -> [Int]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(part) else { return nil }
                numbers.append(number)
            }
            return numbers + Array(repeating: 0, count: 3 - numbers.count)
        }
        guard enabled, let installed = components(current), let target = components(minimum),
              installed.lexicographicallyPrecedes(target), let url = URL(string: store),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return nil }
        let appID = url.lastPathComponent.dropFirst(2)
        let appStore = url.host == "apps.apple.com" && url.lastPathComponent.hasPrefix("id") &&
            !appID.isEmpty && appID.utf8.allSatisfy { (48...57).contains($0) }
        let testFlight = allowTestFlight && url.host == "testflight.apple.com" &&
            url.pathComponents.count == 3 && url.pathComponents[1] == "join" && !url.lastPathComponent.isEmpty
        guard appStore || testFlight else { return nil }
        return Self(version: minimum, storeURL: url)
    }
}

struct AppUpdateScreen: View {
    let update: AppUpdate
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.app.fill").font(.system(size: 60)).foregroundStyle(.tint)
            Text(L("Update required")).font(.title.bold())
            Text(String(format: L("Update to version %@ to continue."), update.version)).multilineTextAlignment(.center)
            Button(L("Update app")) { openURL(update.storeURL) }.buttonStyle(.borderedProminent)
            Button(L("Check again")) { Task { await CloudServices.shared.refreshUpdates(force: true) } }
                .disabled(CloudServices.shared.refreshing)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
