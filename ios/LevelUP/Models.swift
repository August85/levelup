import Foundation

// Mirrors app/data/library.json, feeds.json and inbox.json produced by scripts/*.mjs.

struct Library: Codable {
    var title: String
    var subtitle: String
    var howTo: String
    var parts: [Part]
    var volumes: [Volume]
    var principles: [VolumePrinciple]
    var principleCatalog: [Category]?
    var algorithms: [Category]?
    var probes: [Probe]?
    var keyIdeas: [KeyIdea]?
    var builtAt: String?

    func volume(_ n: Int) -> Volume? { volumes.first { $0.n == n } }
}

struct Part: Codable, Identifiable {
    var id: String
    var title: String
    var volumes: [Int]
}

struct DocSection: Codable, Hashable, Identifiable {
    var level: Int
    var id: String
    var title: String
    var text: String
}

struct Companion: Codable {
    var html: String
    var sections: [DocSection]
    var words: Int
    var summary: String?
}

struct Volume: Codable, Identifiable {
    var n: Int
    var title: String
    var scope: String
    var part: String
    var partTitle: String
    var ready: Bool
    var summary: String?
    var meta: String?
    var html: String?
    var sections: [DocSection]?
    var words: Int?
    var principleCount: Int?
    var checklistCount: Int?
    var companion: Companion?
    var id: Int { n }
    var readMinutes: Int { max(1, (words ?? 0) / 230) }
}

struct VolumePrinciple: Codable, Identifiable {
    var vol: Int
    var volTitle: String
    var name: String
    var html: String
    var id: String { "\(vol)-\(name)" }
}

struct Category: Codable, Identifiable {
    var title: String
    var items: [CollectionItem]
    var id: String { title }
}

struct CollectionItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var summary: String
    var html: String
    var text: String
}

struct Probe: Codable, Identifiable {
    var vol: Int
    var id: String
    var section: String
    var html: String
    var volTitle: String?
}

struct KeyIdea: Codable {
    var vol: Int
    var volTitle: String
    var html: String
}

struct Feeds: Codable {
    var fetchedAt: String?
    var sources: [String]?
    var items: [FeedItem]
}

struct FeedItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var url: String
    var date: String?
    var source: String
    var kind: String?
    var ts: Double?
    var hot: Double?
    var content: String?
    var excerpt: String?
    var points: Int?
    var comments: Int?
    var discuss: String?
    var savedAt: Date?

    var hasText: Bool { (content ?? "").count > 200 }
    var when: Date? { ts.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil } }
}

struct Inbox: Codable {
    var fetchedAt: String?
    var items: [InboxItem]
}

struct InboxItem: Codable {
    var id: String
    var url: String
    var addedAt: String?
    var source: String?
    var title: String?
    var excerpt: String?
    var byline: String?
    var content: String?
}

/// A page saved to Read Later, from the share sheet, the + button, or the GitHub inbox.
struct LaterItem: Codable, Identifiable, Hashable {
    var id: String
    var url: String
    var title: String
    var addedAt: Date
    var done: Bool = false
    var read: Bool = false
    var hasArchive: Bool = false
    var content: String?

    var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "" }
}

extension String {
    /// Plain text from a fragment of HTML, for snippets and search.
    var strippingTags: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: self, relativeTo: Date())
    }
}
