import SwiftUI
import PDFKit

/// Interview Prep: the System Design Interview course as reflowed chapters, plus your books.
/// The content is private and only present in builds made on your Mac.
struct PrepView: View {
    @EnvironmentObject var store: Store
    @AppStorage("prep.last") private var lastSlug = ""

    var body: some View {
        NavigationStack {
            Group {
                if let prep = store.prep { list(prep) } else { missing }
            }
            .navigationTitle("Interview Prep")
        }
    }

    private func list(_ prep: PrepContent) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prep.source.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                    Text(prep.title).font(.system(.title2, design: .serif, weight: .bold))
                    Text("\(prep.chapters.count) chapters · \(prep.chapters.reduce(0) { $0 + $1.figures }) diagrams")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if let last = prep.chapters.first(where: { $0.slug == lastSlug }) {
                Section("Continue reading") {
                    NavigationLink { ChapterView(chapter: last) } label: { ChapterRow(chapter: last) }
                }
            }
            ForEach(prep.groups) { g in
                Section(g.title) {
                    ForEach(g.chapters) { c in
                        NavigationLink { ChapterView(chapter: c) } label: { ChapterRow(chapter: c) }
                    }
                }
            }
            if let books = prep.books, !books.isEmpty {
                Section("Books") {
                    ForEach(books) { b in
                        NavigationLink { BookView(book: b) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed").font(.title3).foregroundStyle(Color.levelUp).frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.title).font(.headline)
                                    Text([b.author, b.pages.map { "\($0) pages" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private var missing: some View {
        ContentUnavailableView {
            Label("Interview Prep isn't in this build", systemImage: "lock.doc")
        } description: {
            Text("The course chapters and books are private, so they're added only when you build the app on your Mac. See ios/README.md.")
        }
    }
}

struct ChapterRow: View {
    var chapter: PrepChapter
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(chapter.n)")
                .font(.subheadline.weight(.bold)).monospacedDigit()
                .frame(width: 34, height: 34)
                .background(Color.levelUp.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(Color.levelUp)
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title).font(.headline)
                Text("\(chapter.readMinutes) min · \(chapter.figures) diagrams").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ChapterView: View {
    var chapter: PrepChapter
    var anchor: String? = nil
    var highlight: String? = nil
    @AppStorage("prep.last") private var lastSlug = ""
    @State private var jump: String?
    @State private var showSettings = false

    var body: some View {
        ReaderView(html: header + chapter.html, anchor: jump, highlight: highlight, baseURL: URL(string: "lvl://private/interview/"))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Chapter \(chapter.n)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    ForEach(chapter.sections.filter { $0.level == 2 || chapter.sections.count < 25 }) { s in
                        Button(s.level == 2 ? s.title : "    " + s.title) { go(s.id) }
                    }
                } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel("Contents")
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("Reading settings")
            }
            .sheet(isPresented: $showSettings) { SettingsView().presentationDetents([.medium]) }
            .onAppear {
                lastSlug = chapter.slug
                if let anchor { jump = anchor }
            }
    }

    private var header: String {
        """
        <div class="eyebrow">System Design Interview · Chapter \(chapter.n)</div>
        <h1 class="title">\(chapter.title.htmlEscaped)</h1>
        <p class="muted" style="font-size:14px">\(chapter.readMinutes) min read · \(chapter.figures) diagrams</p>
        """
    }

    private func go(_ id: String) {
        jump = nil
        DispatchQueue.main.async { jump = id }
    }
}

/// A PDF book, reopened at the page you left.
struct BookView: View {
    var book: PrepBook

    var body: some View {
        Group {
            if let url = PrivateContent.bookURL(book) {
                PDFReader(url: url, key: "book.page." + book.file)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Book not found", systemImage: "book.closed")
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PDFReader: UIViewRepresentable {
    var url: URL
    var key: String

    func makeCoordinator() -> Coordinator { Coordinator(key: key) }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.usePageViewController(false)
        if let doc = PDFDocument(url: url) {
            v.document = doc
            let saved = UserDefaults.standard.integer(forKey: key)
            if saved > 0, let p = doc.page(at: saved) { v.go(to: p) }
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed(_:)),
                                               name: .PDFViewPageChanged, object: v)
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {}

    static func dismantleUIView(_ v: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        let key: String
        init(key: String) { self.key = key }
        @objc func changed(_ n: Notification) {
            guard let v = n.object as? PDFView, let page = v.currentPage, let doc = v.document else { return }
            UserDefaults.standard.set(doc.index(for: page), forKey: key)
        }
    }
}
