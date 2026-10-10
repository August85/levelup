import Foundation

/// Links shared from Safari wait here (in the App Group) until the app next opens.
enum SharedQueue {
    static let groupID = "group.com.august85.levelup"
    private static let key = "pendingLinks"

    struct Pending: Codable {
        var url: String
        var title: String
        var addedAt: Date
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }

    static func push(url: String, title: String) {
        guard let defaults else { return }
        var list = pending()
        list.append(Pending(url: url, title: title, addedAt: Date()))
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }

    static func pending() -> [Pending] {
        guard let data = defaults?.data(forKey: key),
              let list = try? JSONDecoder().decode([Pending].self, from: data) else { return [] }
        return list
    }

    static func drain() -> [Pending] {
        let list = pending()
        defaults?.removeObject(forKey: key)
        return list
    }
}

extension String {
    /// The first http(s) link in a piece of text.
    var firstURL: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(startIndex..., in: self)
        return detector.matches(in: self, range: range).compactMap(\.url).first { $0.scheme?.hasPrefix("http") == true }
    }
}
