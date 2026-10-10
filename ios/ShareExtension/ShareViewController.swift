import UIKit
import UniformTypeIdentifiers

/// Share sheet → "LevelUP": files the page in Read Later, shows what happened, and closes.
final class ShareViewController: UIViewController {
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private var closed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20

        icon.image = UIImage(systemName: "bookmark.fill")
        icon.tintColor = .systemIndigo
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = .init(pointSize: 34, weight: .semibold)

        titleLabel.text = "Saving to LevelUP…"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 3

        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, doneButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 290),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
        findLink { [weak self] url, title in self?.save(url: url, title: title) }
    }

    /// Collects the shared link. Safari, Chrome and other apps hand it over in different shapes
    /// (a URL, a string, or raw data), so every provider is asked and the first web link wins.
    private func findLink(_ done: @escaping (URL?, String) -> Void) {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var title = items.lazy.compactMap { $0.attributedContentText?.string ?? $0.attributedTitle?.string }.first ?? ""
        var urls: [URL] = [], texts: [String] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            for type in [UTType.url, UTType.plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                    lock.lock(); defer { lock.unlock(); group.leave() }
                    switch value {
                    case let u as URL: urls.append(u)
                    case let s as String: texts.append(s)
                    case let d as Data:
                        if let u = URL(dataRepresentation: d, relativeTo: nil), u.scheme != nil { urls.append(u) }
                        else if let s = String(data: d, encoding: .utf8) { texts.append(s) }
                    default: break
                    }
                }
            }
        }
        group.notify(queue: .main) {
            let web = urls.first { $0.scheme?.hasPrefix("http") == true } ?? texts.lazy.compactMap(\.firstURL).first
            if title.isEmpty, let t = texts.first(where: { $0.firstURL == nil }) { title = t }
            done(web, title)
        }
    }

    private func save(url: URL?, title: String) {
        guard let url else {
            show("No web link here", "LevelUP saves web pages. Try sharing from the page itself.", symbol: "link.badge.plus", color: .systemOrange)
            return
        }
        let name = title == url.absoluteString ? "" : title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SharedQueue.push(url: url.absoluteString, title: name) else {
            show("Couldn't save", "This build can't reach LevelUP's shared storage. In Xcode, check that both targets list the App Group group.com.august85.levelup under Signing & Capabilities.",
                 symbol: "exclamationmark.triangle.fill", color: .systemRed)
            return
        }
        show("Saved to Read Later", name.isEmpty ? (url.host ?? url.absoluteString) : name, symbol: "checkmark.circle.fill", color: .systemGreen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.close() }
    }

    private func show(_ title: String, _ detail: String, symbol: String, color: UIColor) {
        titleLabel.text = title
        detailLabel.text = detail
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = color
    }

    @objc private func close() {
        guard !closed else { return }
        closed = true
        extensionContext?.completeRequest(returningItems: nil)
    }
}
