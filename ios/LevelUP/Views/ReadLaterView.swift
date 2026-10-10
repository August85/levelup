import SwiftUI
import UIKit

/// Pages sent from Safari's share sheet (or pasted in), saved for offline reading.
struct ReadLaterView: View {
    @EnvironmentObject var store: Store
    @State private var showDone = false
    @State private var adding = false
    @State private var newURL = ""

    private var items: [LaterItem] {
        store.later.filter { $0.done == showDone }.sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $showDone) {
                    Text("To read").tag(false)
                    Text("Done").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                ForEach(items) { item in
                    NavigationLink { LaterReader(item: item) } label: { LaterRow(item: item) }
                        .swipeActions(edge: .leading) {
                            Button {
                                var copy = item
                                copy.done.toggle()
                                store.update(copy)
                            } label: {
                                Label(item.done ? "To read" : "Done", systemImage: item.done ? "arrow.uturn.backward" : "checkmark")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.delete(item) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
            .listStyle(.plain)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(showDone ? "Nothing finished yet" : "Your reading list is empty",
                                           systemImage: "bookmark",
                                           description: Text(showDone ? "Swipe right on an article when you've read it." : "In Safari, tap Share, then LevelUP. Pages are saved for offline reading."))
                }
            }
            .navigationTitle("Read Later")
            .toolbar {
                Button { newURL = ""; adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a link")
            }
            .refreshable {
                store.ingestShared()
                await store.refresh()
            }
            .sheet(isPresented: $adding) { addSheet.presentationDetents([.height(230)]) }
        }
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                TextField("https://…", text: $newURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Paste from clipboard") {
                    if let s = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string?.firstURL?.absoluteString { newURL = s }
                }
            }
            .navigationTitle("Add a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let s = newURL.firstURL?.absoluteString ?? URL(string: newURL)?.absoluteString, s.hasPrefix("http") {
                            store.addLater(url: s)
                        }
                        adding = false
                    }
                    .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct LaterRow: View {
    var item: LaterItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.read || item.done ? Color.clear : Color.levelUp)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? item.url : item.title)
                    .font(.system(.headline, design: .serif))
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(item.host).font(.caption.weight(.semibold)).foregroundStyle(Color.levelUp)
                    Text(item.addedAt.relative).font(.caption).foregroundStyle(.secondary)
                    if item.hasArchive {
                        Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Available offline")
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Reads a saved page: the offline copy when there is one, otherwise the live page.
struct LaterReader: View {
    var item: LaterItem
    @EnvironmentObject var store: Store
    @State private var showWeb = false

    private var current: LaterItem { store.later.first { $0.id == item.id } ?? item }

    var body: some View {
        let it = current
        Group {
            if it.hasArchive, let original = URL(string: it.url),
               FileManager.default.fileExists(atPath: store.archiveURL(for: it).path) {
                ArchiveView(fileURL: store.archiveURL(for: it), original: original)
                    .ignoresSafeArea(edges: .bottom)
            } else if let content = it.content, !content.isEmpty {
                ReaderView(html: """
                    <div class="eyebrow">\(it.host.htmlEscaped)</div>
                    <h1 class="title">\(it.title.htmlEscaped)</h1>
                    \(content)
                    """)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(it.host.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(it.title.isEmpty ? it.url : it.title).font(.system(.title2, design: .serif, weight: .bold))
                    Text("The offline copy is still being saved. You can read the live page now.").foregroundStyle(.secondary)
                    Button { showWeb = true } label: { Label("Open page", systemImage: "safari") }
                        .buttonStyle(.borderedProminent).tint(.levelUp)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fullScreenCover(isPresented: $showWeb) {
            if let url = URL(string: it.url) { SafariView(url: url).ignoresSafeArea() }
        }
        .navigationTitle(it.host)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                var copy = it
                copy.done.toggle()
                store.update(copy)
            } label: { Image(systemName: it.done ? "checkmark.circle.fill" : "checkmark.circle") }
                .accessibilityLabel(it.done ? "Move back to To read" : "Mark done")
            if let url = URL(string: it.url) {
                ShareLink(item: url)
                Button { showWeb = true } label: { Image(systemName: "safari") }.accessibilityLabel("Open original")
            }
        }
        .onAppear {
            if !it.read {
                var copy = it
                copy.read = true
                store.update(copy)
            }
        }
    }
}
