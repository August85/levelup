import SwiftUI

/// A volume: the author's text, with Claude's companion notes one tap away.
struct VolumeView: View {
    var volume: Volume
    var anchor: String? = nil
    var highlight: String? = nil

    @EnvironmentObject var store: Store
    @AppStorage("lastVol") private var lastVol: Int = 0
    @State private var companion = false
    @State private var jump: String?
    @State private var showSettings = false

    private var sections: [DocSection] { (companion ? volume.companion?.sections : volume.sections) ?? [] }

    var body: some View {
        Group {
            if volume.ready, let html = companion ? volume.companion?.html : volume.html {
                ReaderView(html: header + html, anchor: jump, checkKey: companion ? "c\(volume.n)" : "\(volume.n)", highlight: highlight)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                queued
            }
        }
        .navigationTitle("Vol \(volume.n)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            if volume.companion != nil {
                Picker("Text", selection: $companion) {
                    Text("Volume").tag(false)
                    Text("Companion notes").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 6)
                .background(.bar)
            }
        }
        .toolbar {
            if volume.ready {
                Menu {
                    ForEach(sections.filter { $0.level <= (sections.count > 30 ? 2 : 3) }) { s in
                        Button(s.level == 2 ? tidy(s.title) : "    " + tidy(s.title)) { go(s.id) }
                    }
                } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel("Contents")
            }
            Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                .accessibilityLabel("Reading settings")
        }
        .sheet(isPresented: $showSettings) { SettingsView().presentationDetents([.medium]) }
        .onAppear {
            if volume.ready { lastVol = volume.n }
            if let anchor {
                companion = anchor.hasPrefix("c\(volume.n)-")
                jump = anchor
            }
        }
        .onChange(of: companion) { _, _ in jump = nil }
    }

    private func go(_ id: String) {
        jump = nil
        DispatchQueue.main.async { jump = id }
    }

    private func tidy(_ t: String) -> String {
        t.replacingOccurrences(of: #"^\d+(\.\d+)*\.?\s+"#, with: "", options: .regularExpression)
    }

    private var header: String {
        """
        <div class="eyebrow">Part \(volume.part) · \(volume.partTitle.htmlEscaped)</div>
        <h1 class="title">\(volume.title.htmlEscaped)</h1>
        \(volume.summary.map { "<p class=\"lede\">\($0.htmlEscaped)</p>" } ?? "")
        <p class="muted" style="font-size:14px">\(companion ? "Companion notes · " : "")\((companion ? volume.companion?.words : volume.words).map { "\(max(1, $0 / 230)) min read" } ?? "")</p>
        """
    }

    private var queued: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PART \(volume.part) · \(volume.partTitle.uppercased())").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(volume.title).font(.system(.title, design: .serif, weight: .bold))
                    Text("Queued").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule())
                }
            }
            Section("Scope") {
                ForEach(volume.scope.components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }, id: \.self) { Text($0) }
            }
            Section { Text("This volume hasn't been written yet. It appears here automatically once it's added to the library.").foregroundStyle(.secondary) }
        }
    }
}

/// One algorithm or design principle.
struct ItemView: View {
    var item: CollectionItem
    var kind: String
    var category: String
    var highlight: String? = nil

    var body: some View {
        ReaderView(html: """
            <div class="eyebrow">\(kind) · \(category.htmlEscaped)</div>
            <h1 class="title">\(item.name.htmlEscaped)</h1>
            <p class="lede">\(item.summary.htmlEscaped)</p>
            \(item.html)
            """, highlight: highlight)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(kind)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct CollectionListView: View {
    var title: String
    var kind: String
    var categories: [Category]

    var body: some View {
        List {
            ForEach(categories) { c in
                Section("\(c.title) · \(c.items.count)") {
                    ForEach(c.items) { i in
                        NavigationLink { ItemView(item: i, kind: kind, category: c.title) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(i.name).font(.headline)
                                Text(i.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .overlay { if categories.isEmpty { ContentUnavailableView("Coming soon", systemImage: "hourglass", description: Text("This collection is being written.")) } }
        .navigationTitle(title)
    }
}

struct PrinciplesView: View {
    @EnvironmentObject var store: Store
    @State private var fromVolumes = false
    @State private var random: (String, CollectionItem)?

    var body: some View {
        let lib = store.library
        List {
            Picker("Source", selection: $fromVolumes) {
                Text("Catalog").tag(false)
                Text("From the volumes").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if fromVolumes {
                ForEach(lib?.volumes.filter { ($0.principleCount ?? 0) > 0 } ?? []) { v in
                    Section("Vol \(v.n) · \(v.title)") {
                        ForEach(lib?.principles.filter { $0.vol == v.n } ?? []) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.system(.headline, design: .serif))
                                Text(p.html.strippingTags).font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            } else {
                ForEach(lib?.principleCatalog ?? []) { c in
                    Section("\(c.title) · \(c.items.count)") {
                        ForEach(c.items) { i in
                            NavigationLink { ItemView(item: i, kind: "Principle", category: c.title) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(i.name).font(.headline)
                                    Text(i.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Design Principles")
        .toolbar {
            Button {
                let all = (lib?.principleCatalog ?? []).flatMap { c in c.items.map { (c.title, $0) } }
                random = all.randomElement()
            } label: { Image(systemName: "shuffle") }
            .accessibilityLabel("Random principle")
        }
        .navigationDestination(isPresented: Binding(get: { random != nil }, set: { if !$0 { random = nil } })) {
            if let r = random { ItemView(item: r.1, kind: "Principle", category: r.0) }
        }
    }
}

/// Every DE probe box and checklist, grouped by volume.
struct ReviewView: View {
    @EnvironmentObject var store: Store
    @State private var vol = 0

    var body: some View {
        let lib = store.library
        let vols = lib?.volumes.filter(\.ready) ?? []
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    chip("All", 0)
                    ForEach(vols) { v in chip("\(v.n) · \(v.title)", v.n) }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            ReaderView(html: html(lib, vols.filter { vol == 0 || $0.n == vol }))
                .ignoresSafeArea(edges: .bottom)
        }
        .navigationTitle("Review Mode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chip(_ title: String, _ n: Int) -> some View {
        Button(title) { vol = n }
            .buttonStyle(.bordered)
            .tint(vol == n ? Color.levelUp : .secondary)
            .font(.subheadline)
    }

    private func html(_ lib: Library?, _ vols: [Volume]) -> String {
        let intro = "<p class=\"muted\">The questions that expose weak designs. Read these before an architecture review; each volume's checklist follows its probes.</p>"
        return intro + vols.map { v in
            let probes = (lib?.probes ?? []).filter { $0.vol == v.n }.map { p in
                "<div class=\"callout de\">\(p.section.isEmpty ? "" : "<div class=\"eyebrow\" style=\"margin-bottom:6px\">\(p.section.htmlEscaped)</div>")\(p.html)</div>"
            }.joined()
            let checklist = extractChecklist(v.html ?? "")
            return "<h2>Vol \(v.n) · \(v.title.htmlEscaped)</h2>\(probes)\(checklist.isEmpty ? "" : "<h3>Review checklist</h3>" + checklist)"
        }.joined()
    }

    /// The volume's checklist list, shown read-only here (tick it inside the volume).
    private func extractChecklist(_ html: String) -> String {
        guard let start = html.range(of: "<ol class=\"tasks\">") ?? html.range(of: "<ul class=\"tasks\">"),
              let end = html.range(of: "</ol>", range: start.upperBound..<html.endIndex) ?? html.range(of: "</ul>", range: start.upperBound..<html.endIndex)
        else { return "" }
        return String(html[start.lowerBound..<end.upperBound]).replacingOccurrences(of: "data-task", with: "disabled")
    }
}
