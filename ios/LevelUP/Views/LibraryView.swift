import SwiftUI

extension Color {
    static let levelUp = Color(red: 0.04, green: 0.30, blue: 0.55)
}

struct LibraryView: View {
    @EnvironmentObject var store: Store
    @AppStorage("lastVol") private var lastVol: Int = 0
    @State private var showSettings = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            SearchSwitch(query: $query) {
                if let lib = store.library { content(lib) } else { ProgressView("Loading library…") }
            }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Search everything")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("Reading settings")
            }
            .sheet(isPresented: $showSettings) { SettingsView().presentationDetents([.medium, .large]) }
            .refreshable { await store.refresh() }
        }
    }

    /// The landing page: what to pick up again, then one tile per shelf.
    @ViewBuilder
    private func content(_ lib: Library) -> some View {
        let day = Int(Date().timeIntervalSince1970 / 86400)
        let catalog = (lib.principleCatalog ?? []).flatMap { c in c.items.map { (c.title, $0) } }
        let algos = (lib.algorithms ?? []).flatMap(\.items)
        let books = store.prep?.books ?? []
        let ready = lib.volumes.filter(\.ready).count
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KNOWLEDGE LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
                    Text(lib.title).font(.system(.title, design: .serif, weight: .bold))
                    Text(lib.subtitle).foregroundStyle(.secondary)
                }

                if let v = lib.volume(lastVol), v.ready {
                    shelfHeader("Continue reading")
                    NavigationLink { VolumeView(volume: v) } label: { VolumeRow(volume: v).padding(14).card() }
                        .buttonStyle(.plain)
                }

                shelfHeader("Shelves")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    NavigationLink { VolumesView() } label: {
                        ShelfTile(symbol: "books.vertical.fill", title: "DE Volumes", detail: "\(ready) of \(lib.volumes.count) ready", tint: .levelUp)
                    }
                    NavigationLink { BooksView() } label: {
                        ShelfTile(symbol: "book.closed.fill", title: "Books", detail: books.isEmpty ? "Added from your Mac" : "\(books.count) books", tint: .brown)
                    }
                    NavigationLink { PrinciplesView() } label: {
                        ShelfTile(symbol: "lightbulb.fill", title: "Design Principles", detail: "\(catalog.count + lib.principles.count) principles", tint: .orange)
                    }
                    NavigationLink { CollectionListView(title: "Algorithms", kind: "Algorithm", categories: lib.algorithms ?? []) } label: {
                        ShelfTile(symbol: "function", title: "Algorithms", detail: "\(algos.count) algorithms", tint: .teal)
                    }
                    NavigationLink { ReviewView() } label: {
                        ShelfTile(symbol: "checklist", title: "Review Mode", detail: "DE probes and checklists", tint: .purple)
                    }
                    NavigationLink { PrepView(embedded: true) } label: {
                        ShelfTile(symbol: "briefcase.fill", title: "Interview Prep", detail: store.prep.map { "\($0.chapters.count) chapters" } ?? "Added from your Mac", tint: .indigo)
                    }
                }
                .buttonStyle(.plain)

                if !catalog.isEmpty {
                    let pick = catalog[day % catalog.count]
                    shelfHeader("Principle of the day")
                    NavigationLink { ItemView(item: pick.1, kind: "Principle", category: pick.0) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pick.0.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Text(pick.1.name).font(.system(.title3, design: .serif, weight: .bold))
                            Text(pick.1.summary).font(.system(.body, design: .serif)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).card()
                    }
                    .buttonStyle(.plain)
                }

                if let ideas = lib.keyIdeas, !ideas.isEmpty {
                    let idea = ideas[(day * 7) % ideas.count]
                    shelfHeader("Key idea · Vol \(idea.vol)")
                    Text(idea.html.strippingTags).font(.system(.body, design: .serif))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).card()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func shelfHeader(_ title: String) -> some View {
        Text(title).font(.title3.weight(.bold)).padding(.bottom, -10)
    }
}

/// All 22 Distinguished Engineer volumes, grouped by part.
struct VolumesView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if let lib = store.library {
                List {
                    ForEach(lib.parts) { part in
                        Section("Part \(part.id) · \(part.title)") {
                            ForEach(part.volumes, id: \.self) { n in
                                if let v = lib.volume(n) {
                                    NavigationLink { VolumeView(volume: v) } label: { VolumeRow(volume: v) }
                                }
                            }
                        }
                    }
                    Section { Text(lib.howTo).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("DE Volumes")
    }
}

struct ShelfTile: View {
    var symbol: String
    var title: String
    var detail: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 0)
            Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2).minimumScaleFactor(0.85)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(14)
        .card()
    }
}

extension View {
    /// A white (or dark grey) rounded panel on the grouped background.
    func card() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct VolumeRow: View {
    var volume: Volume
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(volume.n)")
                .font(.subheadline.weight(.bold)).monospacedDigit()
                .frame(width: 34, height: 34)
                .background(volume.ready ? Color.levelUp.opacity(0.12) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(volume.ready ? Color.levelUp : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(volume.title).font(.headline)
                    if !volume.ready { Text("Queued").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                }
                Text(volume.scope).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CollectionRow: View {
    var symbol: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.levelUp).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("fontSize") private var fontSize: Double = 19
    @AppStorage("serif") private var serif: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: $fontSize, in: 15...25, step: 1)
                        Image(systemName: "textformat.size.larger")
                    }
                    Picker("Font", selection: $serif) {
                        Text("Serif").tag(true)
                        Text("Sans").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Text("The quick brown fox reads about consensus.")
                        .font(serif ? .system(size: fontSize, design: .serif) : .system(size: fontSize))
                }
                Section("Content") {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        HStack {
                            Text("Check for updates")
                            Spacer()
                            if store.refreshing { ProgressView() }
                        }
                    }
                    if let d = store.lastRefresh { Text("Last updated \(d.relative)").foregroundStyle(.secondary) }
                }
                Section {
                    Text("Light and dark mode follow your iPhone's setting.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
