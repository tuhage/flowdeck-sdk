#if os(iOS)
import StoreKit
import UIKit
import WebKit

@MainActor
public extension Flowdeck {
    func makeViewController(placementID: String) async throws -> FlowdeckViewController {
        FlowdeckViewController(flowdeck: self, content: try await prepare(placementID: placementID))
    }

    @discardableResult
    func present(placementID: String, from presenter: UIViewController,
                 animated: Bool = true) async throws -> FlowdeckViewController {
        let controller = try await makeViewController(placementID: placementID)
        presenter.present(controller, animated: animated)
        return controller
    }
}

@MainActor
public final class FlowdeckViewController: UIViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    public let content: FlowdeckContent
    private let flowdeck: Flowdeck
    private var webView: WKWebView!
    private var router: BridgeRouter!
    private let errorView = UIStackView()
    private let errorLabel = UILabel()
    private var didClose = false
    private var observationID: UUID?
    var onDismiss: (() -> Void)?
    // The content controller retains its handler; the handler holds only a weak reference back.
    private final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        weak var owner: FlowdeckViewController?
        init(owner: FlowdeckViewController) { self.owner = owner }
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard let owner else { replyHandler(nil, "Flowdeck presentation closed."); return }
            owner.receive(message, reply: replyHandler)
        }
    }

    init(flowdeck: Flowdeck, content: FlowdeckContent) {
        self.flowdeck = flowdeck
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use Flowdeck.makeViewController") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(Handler(owner: self), contentWorld: .page, name: "flowdeck")
        if let script = try? BridgeScript.userScript(parameters: content.parameters) {
            configuration.userContentController.addUserScript(script)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        router = BridgeRouter(content: content, commerce: flowdeck.commerce, emit: { [weak self] event in
            self?.flowdeck.emit(event)
        }, review: { [weak self] in
            guard let scene = self?.view.window?.windowScene, scene.activationState == .foregroundActive else {
                throw FlowdeckError.unavailableScene
            }
            SKStoreReviewController.requestReview(in: scene)
        }, openURL: { url in await UIApplication.shared.open(url) })
        configureErrorView()
        reload()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
        if observationID == nil {
            observationID = flowdeck.observe { [weak self] event in
                guard case .entitlementsChanged(let values) = event else { return }
                self?.sendEntitlements(values)
            }
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let observationID { flowdeck.removeObserver(observationID) }
        observationID = nil
        if isBeingDismissed || parent?.isBeingDismissed == true { reportClosed() }
    }

    private func sendEntitlements(_ values: [FlowdeckEntitlement]) {
        guard let json = try? JSONValue.encoded(values), let data = try? JSONEncoder().encode(json),
              let object = try? JSONSerialization.jsonObject(with: data) else { return }
        webView.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent('flowdeck:entitlements', {detail: values}));",
            arguments: ["values": object], in: nil, in: .page, completionHandler: nil)
    }

    private func configureErrorView() {
        errorView.axis = .vertical
        errorView.spacing = 16
        errorView.alignment = .center
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorView.addArrangedSubview(errorLabel)
        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.addTarget(self, action: #selector(reload), for: .touchUpInside)
        errorView.addArrangedSubview(retry)
        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addTarget(self, action: #selector(closePresentation), for: .touchUpInside)
        errorView.addArrangedSubview(close)
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            errorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48)
        ])
    }

    @objc private func reload() {
        errorView.isHidden = true
        webView.isHidden = false
        webView.loadFileURL(content.indexURL, allowingReadAccessTo: content.indexURL.deletingLastPathComponent())
    }

    static func isPackageURL(_ url: URL?, root: URL) -> Bool {
        guard let url, url.isFileURL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    private func receive(_ message: WKScriptMessage, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard !didClose, message.frameInfo.isMainFrame,
              Self.isPackageURL(message.frameInfo.request.url, root: content.indexURL.deletingLastPathComponent()),
              JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let parsed = try? BridgeMessage.parse(data) else {
            flowdeck.emit(.failed(placementID: content.placementID, message: FlowdeckError.invalidMessage.localizedDescription))
            reply(nil, FlowdeckError.invalidMessage.localizedDescription)
            return
        }
        // Keep in-flight StoreKit work alive if the user dismisses the presentation.
        Task {
            let response = await router.handle(parsed)
            do {
                let bytes = try JSONEncoder().encode(response)
                reply(try JSONSerialization.jsonObject(with: bytes), nil)
            } catch { reply(nil, error.localizedDescription) }
            if parsed.method == .close, response.error == nil { closePresentation() }
        }
    }

    @objc private func closePresentation() {
        reportClosed()
        if let onDismiss { onDismiss() } else { dismiss(animated: true) }
    }
    func reportClosed() {
        guard !didClose else { return }
        didClose = true
        flowdeck.emit(.closed(placementID: content.placementID))
    }
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { reportClosed() }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = Self.isPackageURL(navigationAction.request.url, root: content.indexURL.deletingLastPathComponent())
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed {
            flowdeck.emit(.failed(placementID: content.placementID,
                                     message: FlowdeckError.navigationBlocked.localizedDescription))
        }
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { flowdeck.emit(.loaded(content)) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { show(error) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { show(error) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { show(FlowdeckError.invalidResponse) }
    private func show(_ error: any Error) {
        webView.isHidden = true
        errorLabel.text = error.localizedDescription
        errorView.isHidden = false
        flowdeck.emit(.failed(placementID: content.placementID, message: error.localizedDescription))
    }
}
#endif
