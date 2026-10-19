import UIKit
/// Shown when the web view cannot load a page. It exists because a modal
/// "can't reach" alert told us nothing: the same URL can fail in WKWebView
/// while answering perfectly to a normal HTTP client. This panel probes the
/// URL with URLSession and shows BOTH results side by side, plus two recovery
/// actions, so a screenshot is a complete diagnosis.
final class DiagnosticViewController: UIViewController {

    private let url: URL
    private let webKitError: String
    private let onRetry: () -> Void
    private let onReset: () -> Void
    private let textView = UITextView()

    init(url: URL, webKitError: String, onRetry: @escaping () -> Void, onReset: @escaping () -> Void) {
        self.url = url
        self.webKitError = webKitError
        self.onRetry = onRetry
        self.onReset = onReset
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "Page could not load"
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textAlignment = .center

        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = false
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.text = "URL: \(url.absoluteString)\nWebKit: \(webKitError)\n\nChecking the same URL over HTTP…"

        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let reset = UIButton(type: .system)
        reset.setTitle("Clear website data & retry", for: .normal)
        reset.titleLabel?.font = .systemFont(ofSize: 15)
        reset.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, textView, retry, reset])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])

        probe()
    }

    /// A plain HTTP client hitting the same URL — if this succeeds while
    /// WebKit fails, the network/content is fine and the fault is in WebKit
    /// (or in what we asked it to load).
    private func probe() {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let started = Date()
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            var lines: [String] = []
            lines.append("URL: \(self.url.absoluteString)")
            lines.append("WebKit: \(self.webKitError)")
            lines.append("")
            if let error {
                lines.append("HTTP probe: FAILED after \(ms)ms")
                lines.append("  \((error as NSError).domain) \((error as NSError).code)")
                lines.append("  \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                lines.append("HTTP probe: \(http.statusCode) in \(ms)ms, \(data?.count ?? 0) bytes")
                lines.append("  content-type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "-")")
                lines.append("  cache-control: \(http.value(forHTTPHeaderField: "Cache-Control") ?? "-")")
                lines.append("  location: \(http.value(forHTTPHeaderField: "Location") ?? "-")")
            } else {
                lines.append("HTTP probe: no response (\(ms)ms)")
            }
            lines.append("")
            lines.append("Interpretation:")
            lines.append("  probe OK + WebKit failed  => WebKit-side (clear data / retry)")
            lines.append("  probe failed             => network, DNS or TLS")
            DispatchQueue.main.async { self.textView.text = lines.joined(separator: "\n") }
        }.resume()
    }

    @objc private func retryTapped() {
        dismiss(animated: false) { [onRetry] in onRetry() }
    }

    @objc private func resetTapped() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [onReset] in
            DispatchQueue.main.async { self.dismiss(animated: false) { onReset() } }
        }
    }
}

