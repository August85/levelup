import SwiftUI
import WebKit

/// Renders library HTML (volumes, algorithms, articles) with reading typography.
/// Tapped links open in Safari; checklist ticks persist per `checkKey`.
struct ReaderView: UIViewRepresentable {
    var html: String
    var anchor: String? = nil
    var checkKey: String? = nil
    var highlight: String? = nil
    /// Relative links and images resolve against this; Interview Prep uses lvl://private/interview/.
    var baseURL: URL? = nil

    @AppStorage("fontSize") private var fontSize: Double = 19
    @AppStorage("serif") private var serif: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "check")
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        c.checkKey = checkKey
        let checks = checkKey.map(Checks.load) ?? []
        // Compare without the anchor so jumping within a page scrolls instead of reloading.
        let key = Self.page(html, fontSize: fontSize, serif: serif, checks: [], anchor: nil, highlight: highlight)
        if key != c.lastPage {
            c.lastPage = key
            wv.loadHTMLString(Self.page(html, fontSize: fontSize, serif: serif, checks: checks, anchor: anchor, highlight: highlight), baseURL: baseURL ?? Store.site)
        } else if let anchor, anchor != c.lastAnchor {
            wv.evaluateJavaScript("jump(\(Self.js(anchor)))")
        }
        c.lastAnchor = anchor
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "check")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastPage = ""
        var lastAnchor: String?
        var checkKey: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme?.hasPrefix("http") == true {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let key = checkKey, let body = message.body as? [Int] else { return }
            Checks.save(key, body)
        }
    }

    static func js(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    static func page(_ body: String, fontSize: Double, serif: Bool, checks: [Int], anchor: String?, highlight: String?) -> String {
        let font = serif ? "'Iowan Old Style', 'Charter', Georgia, serif" : "-apple-system, system-ui, sans-serif"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>\(css)
        body { font-family: \(font); font-size: \(Int(fontSize))px; }
        </style></head><body><article class="reader">\(body)</article>
        <script>
        const checks = new Set(\(checks));
        document.querySelectorAll('input[data-task]').forEach((cb, i) => {
          cb.checked = checks.has(i);
          cb.addEventListener('change', () => {
            cb.checked ? checks.add(i) : checks.delete(i);
            window.webkit.messageHandlers.check.postMessage([...checks]);
          });
        });
        function jump(id) { const el = document.getElementById(id); if (el) { el.scrollIntoView(); el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash'); } }
        function mark(q) {
          const terms = q.toLowerCase().split(/\\s+/).filter(t => t.length > 1); if (!terms.length) return;
          const re = new RegExp('(' + terms.map(t => t.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')).join('|') + ')', 'gi');
          const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); const nodes = [];
          while (w.nextNode()) if (re.test(w.currentNode.nodeValue) && !w.currentNode.parentElement.closest('script,style')) nodes.push(w.currentNode);
          nodes.slice(0, 200).forEach(n => { const s = document.createElement('span'); s.innerHTML = n.nodeValue.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])).replace(re, '<mark>$1</mark>'); n.replaceWith(s); });
        }
        \(highlight.map { "mark(\(js($0)));" } ?? "")
        \(anchor.map { "jump(\(js($0)));" } ?? "")
        </script></body></html>
        """
    }

    static let css = """
    :root { color-scheme: light dark; --ink:#1c2530; --ink2:#4c5966; --ink3:#7d8994; --line:#e4e1da; --accent:#0a4d8c; --code:#f3f1ec; --mark:#fff1a8;
      --de-bg:#fdf6ec; --de-line:#b7791f; --de-ink:#8a5a12; --war-bg:#f3f0fa; --war-line:#5b4a8a; }
    @media (prefers-color-scheme: dark) { :root { --ink:#e7e5e0; --ink2:#b4b8bd; --ink3:#868c93; --line:#2e343b; --accent:#7cb2ea; --code:#1f2429; --mark:#5c4d12;
      --de-bg:#2a2418; --de-line:#c99a45; --de-ink:#e2b866; --war-bg:#221f2e; --war-line:#8f7cc4; } }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; padding: 4px 18px 60px; background: transparent; color: var(--ink); line-height: 1.62; overflow-wrap: break-word; }
    a { color: var(--accent); }
    h2 { font-size: 1.38em; line-height: 1.22; margin: 1.8em 0 .5em; padding-top: .8em; border-top: 1px solid var(--line); }
    h3 { font-size: 1.14em; line-height: 1.3; margin: 1.5em 0 .4em; color: var(--accent); }
    p { margin: 0 0 1em; } ul, ol { padding-left: 1.25em; } li { margin: .3em 0; }
    blockquote { margin: 1.2em 0; padding: .2em 0 .2em 1em; border-left: 3px solid var(--accent); color: var(--ink2); }
    code { font-family: ui-monospace, Menlo, monospace; font-size: .82em; background: var(--code); padding: .1em .35em; border-radius: 5px; }
    pre { font-family: ui-monospace, Menlo, monospace; font-size: 12.5px; line-height: 1.45; background: var(--code); border: 1px solid var(--line); border-radius: 10px; padding: 12px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    img { max-width: 100%; height: auto; border-radius: 8px; }
    .table-wrap, table { display: block; overflow-x: auto; } .table-wrap table { display: table; }
    table { border-collapse: collapse; font-family: -apple-system, sans-serif; font-size: 14px; line-height: 1.4; margin: 1.2em 0; min-width: 100%; }
    th, td { text-align: left; vertical-align: top; padding: 8px 10px; border-bottom: 1px solid var(--line); } th { border-bottom: 2px solid var(--ink3); }
    .callout { border-radius: 12px; padding: 14px 16px; margin: 1.4em 0; font-size: .92em; line-height: 1.55; }
    .callout.de { background: var(--de-bg); border-left: 4px solid var(--de-line); } .callout.de > b:first-child { color: var(--de-ink); }
    .callout.warstory { background: var(--war-bg); border-left: 4px solid var(--war-line); }
    .fig { margin: 1.4em -18px; padding: 0 18px; overflow-x: auto; }
    .fig svg { display: block; width: 720px; max-width: none; height: auto; margin: 0 auto; background: #fff; border-radius: 10px; padding: 6px; }
    .figcap { font-family: -apple-system, sans-serif; font-size: 13px; color: var(--ink3); margin-top: 6px; }
    ol.tasks, ul.tasks { list-style: none; padding-left: 0; } li.task { list-style: none; margin-left: -1.25em; } ol.tasks li.task { margin-left: 0; }
    li.task label { display: flex; gap: 10px; align-items: flex-start; } li.task input { flex: none; width: 20px; height: 20px; margin-top: .2em; accent-color: var(--accent); }
    li.task label:has(input:checked) { color: var(--ink3); }
    p > strong:first-child { font-family: -apple-system, sans-serif; font-size: .78em; letter-spacing: .06em; text-transform: uppercase; color: var(--accent); display: block; margin-top: 1.4em; }
    .eyebrow { font-family: -apple-system, sans-serif; font-size: 12px; font-weight: 650; letter-spacing: .06em; text-transform: uppercase; color: var(--ink3); }
    .lede { font-style: italic; color: var(--ink2); font-size: 1.05em; }
    .muted { color: var(--ink3); }
    mark { background: var(--mark); color: inherit; border-radius: 3px; }
    .flash { animation: flash 1.6s ease-out; } @keyframes flash { from { background: var(--mark); } to { background: transparent; } }
    figure.shot { margin: 1.4em 0; text-align: center; }
    figure.shot img { display: block; width: 100%; background: #fff; border-radius: 10px; border: 1px solid var(--line); }
    figure.shot figcaption { font-family: -apple-system, sans-serif; font-size: 13px; color: var(--ink3); margin-top: 6px; }
    h1.title { font-size: 1.6em; line-height: 1.15; margin: .3em 0 .3em; }
    """
}

/// Checklist ticks, stored per volume.
enum Checks {
    static func load(_ key: String) -> [Int] { UserDefaults.standard.array(forKey: "checks." + key) as? [Int] ?? [] }
    static func save(_ key: String, _ value: [Int]) { UserDefaults.standard.set(value, forKey: "checks." + key) }
}

/// Shows a saved web archive (Read Later offline copy).
struct ArchiveView: UIViewRepresentable {
    var fileURL: URL
    var original: URL

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        if let data = try? Data(contentsOf: fileURL) {
            wv.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: original)
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
