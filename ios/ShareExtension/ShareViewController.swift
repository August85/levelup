import UIKit
import UniformTypeIdentifiers

/// Safari share sheet → "LevelUP": files the page in Read Later and closes.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Saving to LevelUP…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        Task { await handle() }
    }

    private func handle() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var url: URL?
        var title = ""
        for item in items {
            if title.isEmpty { title = item.attributedContentText?.string ?? item.attributedTitle?.string ?? "" }
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let found = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    url = found
                }
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    url = text.firstURL
                    if title.isEmpty { title = text }
                }
            }
        }
        if let url, url.scheme?.hasPrefix("http") == true {
            if title == url.absoluteString { title = "" }
            SharedQueue.push(url: url.absoluteString, title: title)
            label.text = "Saved to Read Later"
        } else {
            label.text = "There's no web link to save here."
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }
}
