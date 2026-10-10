import SwiftUI

@main
struct LevelUPApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(Color.levelUp)
                .task {
                    store.ingestShared()
                    OfflineSaver.shared.resume(store: store)
                    await store.refresh()
                }
                .onChange(of: phase) { _, newPhase in
                    if newPhase == .active {
                        store.ingestShared()
                        Task { await store.refresh() }
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(0)
            PracticeView()
                .tabItem { Label("Practice", systemImage: "rectangle.on.rectangle.angled") }.tag(1)
            PrepView()
                .tabItem { Label("Interview Prep", systemImage: "briefcase") }.tag(2)
            FeedsView()
                .tabItem { Label("AI Feeds", systemImage: "dot.radiowaves.up.forward") }.tag(3)
            ReadLaterView()
                .tabItem { Label("Read Later", systemImage: "bookmark") }.tag(4)
                .badge(store.later.filter { !$0.done && !$0.read }.count)
        }
    }
}
