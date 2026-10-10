import SwiftUI

extension Color {
    static let levelUp = Color(red: 0.04, green: 0.30, blue: 0.55)
}

struct LibraryView: View {
    @EnvironmentObject var store: Store
    @AppStorage("lastVol") private var lastVol: Int = 0
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if let lib = store.library { content(lib) } else { ProgressView("Loading library…") }
            }
            .navigationTitle("Library")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("Reading settings")
            }
            .sheet(isPresented: $showSettings) { SettingsView().presentationDetents([.medium, .large]) }
            .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder
    private func content(_ lib: Library) -> some View {
        let day = Int(Date().timeIntervalSince1970 / 86400)
        let catalog = (lib.principleCatalog ?? []).flatMap { c in c.items.map { (c.title, $0) } }
        let algos = (lib.algorithms ?? []).flatMap(\.items)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KNOWLEDGE LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
                    Text(lib.title).font(.system(.title, design: .serif, weight: .bold))
                    Text(lib.subtitle).foregroundStyle(.secondary)
                    Text("\(lib.volumes.filter(\.ready).count) of \(lib.volumes.count) volumes ready · \(catalog.count + lib.principles.count) principles · \(algos.count) algorithms")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            if let v = lib.volume(lastVol), v.ready {
                Section("Continue reading") {
                    NavigationLink { VolumeView(volume: v) } label: { VolumeRow(volume: v) }
                }
            }

            if !catalog.isEmpty {
                let pick = catalog[day % catalog.count]
                let cat = pick.0
                let p = pick.1
                Section("Principle of the day") {
                    NavigationLink { ItemView(item: p, kind: "Principle", category: cat) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cat.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Text(p.name).font(.system(.title3, design: .serif, weight: .bold))
                            Text(p.summary).font(.system(.body, design: .serif)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if let ideas = lib.keyIdeas, !ideas.isEmpty {
                let idea = ideas[(day * 7) % ideas.count]
                Section("Key idea · Vol \(idea.vol)") {
                    Text(idea.html.strippingTags).font(.system(.body, design: .serif)).padding(.vertical, 4)
                }
            }

            Section("Collections") {
                NavigationLink { PrinciplesView() } label: {
                    CollectionRow(symbol: "lightbulb", title: "Design Principles", subtitle: "\(catalog.count + lib.principles.count) principles: a catalog plus those from each volume")
                }
                NavigationLink { CollectionListView(title: "Algorithms", kind: "Algorithm", categories: lib.algorithms ?? []) } label: {
                    CollectionRow(symbol: "function", title: "Algorithms", subtitle: "\(algos.count) algorithms, from Raft to HNSW")
                }
                NavigationLink { ReviewView() } label: {
                    CollectionRow(symbol: "checklist", title: "Review Mode", subtitle: "Every DE probe and checklist, for architecture-review prep")
                }
            }

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
