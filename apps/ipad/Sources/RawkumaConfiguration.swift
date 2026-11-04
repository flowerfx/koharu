import Foundation

struct RawkumaConfiguration: Decodable, Equatable, Sendable {
    let url: URL?
    private enum CodingKeys: String, CodingKey { case url }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let value = try values.decodeIfPresent(String.self, forKey: .url)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty { url = nil; return }
        guard let address = URL(string: value), address.scheme == "https", let host = address.host, !host.isEmpty,
              address.port == nil, address.user == nil, address.password == nil,
              address.query == nil, address.fragment == nil, address.path.isEmpty || address.path == "/",
              var components = URLComponents(url: address, resolvingAgainstBaseURL: false) else {
            throw AppError.message(L("Invalid app configuration (app-config.json)"))
        }
        components.path = "/"
        url = components.url
    }
    func contains(_ value: String) -> Bool {
        guard let base = url, let address = URL(string: value) else { return false }
        return address.scheme == base.scheme && address.host == base.host && address.port == nil && address.user == nil && address.password == nil
    }
    func address(forPath value: String) -> URL? {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = url, !path.hasPrefix("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let relative = URLComponents(string: path), relative.scheme == nil, relative.host == nil else { return nil }
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let address = URL(string: base.absoluteString + suffix), contains(address.absoluteString) else { return nil }
        return address
    }
    func path(from value: String) -> String? {
        guard contains(value), let components = URLComponents(string: value) else { return nil }
        return String(components.percentEncodedPath.dropFirst()) +
            (components.percentEncodedQuery.map { "?" + $0 } ?? "") +
            (components.percentEncodedFragment.map { "#" + $0 } ?? "")
    }
}
