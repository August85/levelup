import SwiftUI
import SafariServices

/// Top and latest posts from AI blogs and Hacker News, with offline Save.
struct FeedsView: View {
    @EnvironmentObject var store: Store
    @State private var mode = Mode.hot
    @State private var source: String?

    enum Mode: String, CaseIterable { case hot = "Top & Hot", latest = "Latest", saved = "Saved" }

    private var items: [FeedItem] {
        var list: [FeedItem]
        switch mode {
        case .hot: list = (store.feeds?.items ?? []).sorted { ($0.hot ?? 0) > ($1.hot ?? 0) }
        case .latest: list = (store.feeds?.items ?? []).sorted { ($0.ts ?? 0) > ($1.ts ?? 0) }
        case .saved: list = store.saved
        }
        if let source { list = list.filter { $0.source == source } }
        return Array(list.prefix(150))
    }

    private var sources: [String] {
        var seen = Set<String>()
        return (mode == .saved ? store.saved : store.feeds?.items ?? []).map(\.source).filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { m in Text(m == .saved && !store.saved.isEmpty ? "Saved (\(store.saved.count))" : m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                ForEach(items) { item in
                    NavigationLink { ArticleView(item: item) } label: { FeedRow(item: item) }
                        .swipeActions(edge: .trailing) {
                            Button { store.toggleSave(item) } label: {
                                Label(store.isSaved(item) ? "Unsave" : "Save", systemImage: store.isSaved(item) ? "bookmark.slash" : "bookmark")
                            }
                            .tint(.levelUp)
                        }
                }

                if let f = store.feeds?.fetchedAt, mode != .saved {
                    Text("Updated \(Self.parse(f)?.relative ?? f) · \(store.feeds?.sources?.count ?? 0) sources")
                        .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(mode == .saved ? "Nothing saved yet" : "No articles", systemImage: mode == .saved ? "bookmark" : "dot.radiowaves.up.forward",
                                           description: Text(mode == .saved ? "Swipe left on an article, or tap the bookmark while reading, to keep it on this phone." : "Pull down to refresh."))
                }
            }
            .navigationTitle("AI Feeds")
            .toolbar {
                Menu {
                    Button("All sources") { source = nil }
                    ForEach(sources, id: \.self) { s in
                        Button { source = s } label: { if source == s { Label(s, systemImage: "checkmark") } else { Text(s) } }
                    }
                } label: { Image(systemName: source == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                .accessibilityLabel("Filter by source")
            }
            .refreshable { await store.refresh() }
            .onChange(of: mode) { _, _ in source = nil }
        }
    }

    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

struct FeedRow: View {
    var item: FeedItem
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.source).font(.caption.weight(.semibold)).foregroundStyle(Color.levelUp)
                if let d = item.when ?? item.savedAt { Text(d.relative).font(.caption).foregroundStyle(.secondary) }
                if let p = item.points { Text("· \(p) points").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if store.isSaved(item) { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(Color.levelUp) }
            }
            Text(item.title).font(.system(.headline, design: .serif))
            if let x = item.excerpt, !x.isEmpty { Text(x).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
        }
        .padding(.vertical, 4)
    }
}

/// Reads a feed article: full text when the feed carried it, otherwise the web page.
struct ArticleView: View {
    var item: FeedItem
    @EnvironmentObject var store: Store
    @State private var showWeb = false

    var body: some View {
        Group {
            if item.hasText {
                ReaderView(html: """
                    <div class="eyebrow">\(item.source.htmlEscaped)</div>
                    <h1 class="title">\(item.title.htmlEscaped)</h1>
                    \(item.content ?? "")
                    """)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.source.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(item.title).font(.system(.title2, design: .serif, weight: .bold))
                        if let x = item.excerpt, !x.isEmpty { Text(x).font(.system(.body, design: .serif)).foregroundStyle(.secondary) }
                        Button { showWeb = true } label: { Label("Read on the web", systemImage: "safari") }
                            .buttonStyle(.borderedProminent).tint(.levelUp)
                        if let d = item.discuss, let u = URL(string: d) { Link("Hacker News discussion", destination: u) }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fullScreenCover(isPresented: $showWeb) {
            if let url = URL(string: item.url) { SafariView(url: url).ignoresSafeArea() }
        }
        .navigationTitle(item.source)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { store.toggleSave(item) } label: { Image(systemName: store.isSaved(item) ? "bookmark.fill" : "bookmark") }
                .accessibilityLabel(store.isSaved(item) ? "Remove from Saved" : "Save")
            if let url = URL(string: item.url) { ShareLink(item: url) }
            if item.hasText {
                Button { showWeb = true } label: { Image(systemName: "safari") }.accessibilityLabel("Open original")
            }
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let c = SFSafariViewController.Configuration()
        c.entersReaderIfAvailable = true
        return SFSafariViewController(url: url, configuration: c)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
