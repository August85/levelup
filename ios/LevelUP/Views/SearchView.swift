import SwiftUI

/// Full-text search across volumes, companion notes, principles, algorithms, Interview Prep,
/// practice cards, saved articles and Read Later. Shown by the Library tab while its search field is active.
struct SearchResults: View {
    @EnvironmentObject var store: Store
    @Binding var query: String
    @State private var index: [Doc] = []
    @AppStorage("recentSearches") private var recentData: Data = Data()

    struct Doc: Identifiable {
        enum Target { case volume(Int, String), item(CollectionItem, String, String), principle(Int), saved(FeedItem), later(LaterItem), chapter(PrepChapter, String), card(Card, String) }
        let id = UUID()
        var title: String
        var place: String
        var text: String
        var target: Target
        var lt: String
        var lx: String
    }

    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: recentData)) ?? [] }

    var body: some View {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if recent.isEmpty {
                        ContentUnavailableView("Search everything", systemImage: "magnifyingglass", description: Text("Volumes, companion notes, principles, algorithms, Interview Prep, practice cards, saved articles and Read Later."))
                            .listRowBackground(Color.clear)
                    } else {
                        Section("Recent") {
                            ForEach(recent, id: \.self) { r in Button(r) { query = r }.foregroundStyle(.primary) }
                        }
                    }
                } else {
                    let res = results
                    Section(res.isEmpty ? "No matches" : "\(res.count) results") {
                        ForEach(res) { d in
                            NavigationLink { destination(d) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(d.place).font(.caption).foregroundStyle(.secondary)
                                    Text(d.title).font(.headline)
                                    Text(snippet(d.text)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            .simultaneousGesture(TapGesture().onEnded { remember() })
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onSubmit(of: .search) { remember() }
            .task(id: store.library?.builtAt) { index = buildIndex() }
            .onChange(of: store.saved.count) { _, _ in index = buildIndex() }
            .onChange(of: store.later.count) { _, _ in index = buildIndex() }
            .onChange(of: store.customCards.count) { _, _ in index = buildIndex() }
    }

    private var terms: [String] { query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty } }

    private var results: [Doc] {
        let t = terms, q = query.lowercased()
        guard !t.isEmpty else { return [] }
        var scored: [(Doc, Double)] = []
        for d in index {
            var score = 0.0, ok = true
            for term in t {
                let inTitle = d.lt.contains(term)
                let n = d.lx.components(separatedBy: term).count - 1
                if !inTitle && n == 0 { ok = false; break }
                score += (inTitle ? 12 : 0) + log2(1 + Double(min(n, 30))) * 2
            }
            guard ok else { continue }
            if d.lt.contains(q) { score += 10 }
            if d.lx.contains(q) { score += 4 }
            scored.append((d, score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(80).map(\.0)
    }

    private func snippet(_ text: String) -> String {
        let lx = text.lowercased()
        guard let term = terms.first(where: { lx.contains($0) }), let r = lx.range(of: term) else { return String(text.prefix(200)) }
        let start = text.index(r.lowerBound, offsetBy: -min(70, text.distance(from: text.startIndex, to: r.lowerBound)))
        let end = text.index(start, offsetBy: min(220, text.distance(from: start, to: text.endIndex)))
        let mid = String(text[start..<end])
        return (start > text.startIndex ? "…" : "") + mid + (end < text.endIndex ? "…" : "")
    }

    private func remember() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let list = [q] + recent.filter { $0 != q }
        recentData = (try? JSONEncoder().encode(Array(list.prefix(10)))) ?? Data()
    }

    @ViewBuilder
    private func destination(_ d: Doc) -> some View {
        switch d.target {
        case .volume(let n, let anchor):
            if let v = store.library?.volume(n) { VolumeView(volume: v, anchor: anchor, highlight: query) }
        case .item(let item, let kind, let cat):
            ItemView(item: item, kind: kind, category: cat, highlight: query)
        case .principle:
            PrinciplesView()
        case .saved(let f):
            ArticleView(item: f)
        case .later(let l):
            LaterReader(item: l)
        case .chapter(let c, let anchor):
            ChapterView(chapter: c, anchor: anchor, highlight: query)
        case .card(let c, let deck):
            CardDetailView(card: c, deck: deck)
        }
    }

    private func buildIndex() -> [Doc] {
        guard let lib = store.library else { return [] }
        var docs: [Doc] = []
        func add(_ title: String, _ place: String, _ text: String, _ target: Doc.Target) {
            docs.append(Doc(title: title, place: place, text: text, target: target, lt: title.lowercased(), lx: text.lowercased()))
        }
        for v in lib.volumes {
            guard v.ready else { add(v.title, "Vol \(v.n) · Queued", v.scope, .volume(v.n, "")); continue }
            for s in v.sections ?? [] { add(s.title, "Vol \(v.n) · \(v.title)", s.text, .volume(v.n, s.id)) }
            for s in v.companion?.sections ?? [] { add(s.title, "Vol \(v.n) · Companion notes", s.text, .volume(v.n, s.id)) }
        }
        for p in lib.principles { add(p.name, "Principle · Vol \(p.vol)", p.html.strippingTags, .principle(p.vol)) }
        for c in lib.principleCatalog ?? [] { for i in c.items { add(i.name, "Design Principle · \(c.title)", i.summary + " " + i.text, .item(i, "Principle", c.title)) } }
        for c in lib.algorithms ?? [] { for i in c.items { add(i.name, "Algorithm · \(c.title)", i.summary + " " + i.text, .item(i, "Algorithm", c.title)) } }
        for c in store.prep?.chapters ?? [] {
            for s in c.sections { add(s.title, "Interview Prep · \(c.n). \(c.title)", s.text, .chapter(c, s.id)) }
        }
        for d in store.practiceDecks where !d.id.hasSuffix("-catalog") {
            for c in d.cards { add(c.q, "Practice · \(d.title)", c.md, .card(c, d.title)) }
        }
        for s in store.saved { add(s.title, "Saved · \(s.source)", (s.content ?? s.excerpt ?? "").strippingTags, .saved(s)) }
        for l in store.later { add(l.title.isEmpty ? l.url : l.title, "Read Later · \(l.host)", (l.content ?? "").strippingTags, .later(l)) }
        return docs
    }
}

/// One practice card, opened from search.
struct CardDetailView: View {
    var card: Card
    var deck: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(deck.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Text(card.q).font(.system(.title2, design: .serif, weight: .bold))
                Text((try? AttributedString(markdown: card.md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(card.md))
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Practice card")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shows search results while the search field is active, otherwise the normal content.
struct SearchSwitch<Normal: View>: View {
    @Binding var query: String
    @ViewBuilder var normal: () -> Normal
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if isSearching || !query.isEmpty { SearchResults(query: $query) } else { normal() }
    }
}
