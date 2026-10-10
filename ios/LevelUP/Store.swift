import Foundation
import SwiftUI

/// Loads the library and feeds (cache → bundle → network) and keeps saved articles and Read Later on disk.
@MainActor
final class Store: ObservableObject {
    static let site = URL(string: "https://august85.github.io/levelup/")!

    @Published var library: Library?
    @Published var feeds: Feeds?
    @Published var saved: [FeedItem] = []
    @Published var later: [LaterItem] = []
    @Published var refreshing = false
    @Published var lastRefresh: Date?

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LevelUP", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    var archiveDir: URL {
        let d = dir.appendingPathComponent("archives", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() {
        library = cachedOrBundled(Library.self, "library.json")
        feeds = cachedOrBundled(Feeds.self, "feeds.json")
        saved = readLocal([FeedItem].self, "saved.json") ?? []
        later = readLocal([LaterItem].self, "later.json") ?? []
    }

    // MARK: Loading

    private func cachedOrBundled<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let cached = dir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: cached), let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        if let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "json"),
           let data = try? Data(contentsOf: url) { return try? JSONDecoder().decode(T.self, from: data) }
        return nil
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ name: String) async -> T? {
        var req = URLRequest(url: Self.site.appendingPathComponent("data/\(name)"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return value
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let lib = fetch(Library.self, "library.json")
        async let fd = fetch(Feeds.self, "feeds.json")
        async let ib = fetch(Inbox.self, "inbox.json")
        if let v = await lib { library = v }
        if let v = await fd { feeds = v }
        if let v = await ib { mergeInbox(v) }
        lastRefresh = Date()
    }

    // MARK: Saved feed articles

    func isSaved(_ item: FeedItem) -> Bool { saved.contains { $0.id == item.id } }

    func toggleSave(_ item: FeedItem) {
        if let i = saved.firstIndex(where: { $0.id == item.id }) {
            saved.remove(at: i)
        } else {
            var copy = item
            copy.savedAt = Date()
            saved.insert(copy, at: 0)
        }
        writeLocal(saved, "saved.json")
    }

    // MARK: Read Later

    /// Picks up links shared from Safari while the app was closed.
    func ingestShared() {
        for p in SharedQueue.drain() { addLater(url: p.url, title: p.title, at: p.addedAt) }
    }

    func addLater(url: String, title: String = "", at date: Date = Date()) {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true else { return }
        if let i = later.firstIndex(where: { $0.url == u.absoluteString }) {
            later[i].done = false
            persistLater()
            return
        }
        let item = LaterItem(id: "l-\(UUID().uuidString.prefix(8))", url: u.absoluteString, title: title, addedAt: date)
        later.insert(item, at: 0)
        persistLater()
        OfflineSaver.shared.enqueue(item, store: self)
    }

    private func mergeInbox(_ inbox: Inbox) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var changed = false
        for i in inbox.items {
            if let k = later.firstIndex(where: { $0.url == i.url }) {
                if later[k].content == nil, let c = i.content, !c.isEmpty { later[k].content = c; changed = true }
                continue
            }
            let date = i.addedAt.flatMap { iso.date(from: $0) ?? plain.date(from: $0) } ?? Date()
            later.append(LaterItem(id: i.id, url: i.url, title: i.title ?? i.url, addedAt: date, content: i.content))
            changed = true
        }
        if changed {
            later.sort { $0.addedAt > $1.addedAt }
            persistLater()
        }
    }

    func update(_ item: LaterItem) {
        guard let i = later.firstIndex(where: { $0.id == item.id }) else { return }
        later[i] = item
        persistLater()
    }

    func delete(_ item: LaterItem) {
        later.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: archiveURL(for: item))
        persistLater()
    }

    func archiveURL(for item: LaterItem) -> URL { archiveDir.appendingPathComponent("\(item.id).webarchive") }

    func persistLater() { writeLocal(later, "later.json") }

    // MARK: Files

    private func readLocal<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: data)
    }

    private func writeLocal<T: Encodable>(_ value: T, _ name: String) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(value) { try? data.write(to: dir.appendingPathComponent(name), options: .atomic) }
    }
}
