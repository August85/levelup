import Foundation
import WebKit

/// Loads each Read Later page in an off-screen web view and keeps a web archive, so it reads offline.
@MainActor
final class OfflineSaver: NSObject, WKNavigationDelegate {
    static let shared = OfflineSaver()

    private var queue: [(LaterItem, Store)] = []
    private var busy = false
    private var webView: WKWebView?
    private var finished: CheckedContinuation<Bool, Never>?

    func enqueue(_ item: LaterItem, store: Store) {
        queue.append((item, store))
        Task { await drain() }
    }

    /// Retries items that were added while offline.
    func resume(store: Store) {
        for item in store.later where !item.hasArchive && !item.done && item.content == nil {
            if !queue.contains(where: { $0.0.id == item.id }) { queue.append((item, store)) }
        }
        Task { await drain() }
    }

    private func drain() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        while !queue.isEmpty {
            let (item, store) = queue.removeFirst()
            await save(item, store: store)
        }
        webView = nil
    }

    private func save(_ item: LaterItem, store: Store) async {
        guard let url = URL(string: item.url) else { return }
        let wv = webView ?? WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView = wv
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        let ok: Bool = await withCheckedContinuation { cont in
            finished = cont
            wv.load(URLRequest(url: url, timeoutInterval: 30))
        }
        guard ok else { return }
        // Give client-rendered pages a moment to fill in.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let data = try? await wv.webArchiveData() else { return }
        try? data.write(to: store.archiveURL(for: item), options: .atomic)
        guard var current = store.later.first(where: { $0.id == item.id }) else { return }
        current.hasArchive = true
        if current.title.isEmpty, let t = wv.title, !t.isEmpty { current.title = t }
        store.update(current)
    }

    private func finish(_ ok: Bool) {
        finished?.resume(returning: ok)
        finished = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finish(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(false) }
    }
}

private extension WKWebView {
    func webArchiveData() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            createWebArchiveData { result in cont.resume(with: result) }
        }
    }
}
