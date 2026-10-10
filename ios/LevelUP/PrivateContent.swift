import Foundation
import WebKit
import UniformTypeIdentifiers

/// Interview Prep chapters and books live in a "Private" folder that the build copies into the app
/// from your Mac. They are never committed to the public repo, so a CI or App Store build has none.
enum PrivateContent {
    static let root: URL? = Bundle.main.url(forResource: "Private", withExtension: nil)

    static func load() -> PrepContent? {
        guard let url = root?.appendingPathComponent("interview/index.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PrepContent.self, from: data)
    }

    static func bookURL(_ book: PrepBook) -> URL? {
        root?.appendingPathComponent("books").appendingPathComponent(book.file)
    }
}

/// Serves files from the private content folder to the reader's web view (lvl://private/<path>).
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lvl"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = PrivateContent.root,
              let data = try? Data(contentsOf: root.appendingPathComponent(url.path)) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
