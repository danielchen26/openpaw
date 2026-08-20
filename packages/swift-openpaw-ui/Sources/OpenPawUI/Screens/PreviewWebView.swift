import OpenPawProtocol
import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Origin and navigation policy

/// Scheme, host and port — the three things that decide whether two addresses are the same place.
public struct PreviewOrigin: Sendable, Hashable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? Self.defaultPort(for: scheme)
        guard let port else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }

    public var description: String { "\(scheme)://\(host):\(port)" }
}

/// Refuses to leave the proxy.
///
/// The preview points at a loopback port that only forwards one dev server. A page that navigates away — an
/// analytics redirect, an OAuth hop, a `target=_blank` to a CDN — would leave the tunnel and load off the open
/// internet inside a view the reader believes is their own machine. So it does not get to.
public struct PreviewNavigationPolicy: Sendable, Hashable {

    public enum Decision: Sendable, Hashable {
        case allow
        case refuse(reason: String)

        public var isAllowed: Bool {
            if case .allow = self { return true }
            return false
        }
    }

    public let origin: PreviewOrigin

    public init(origin: PreviewOrigin) {
        self.origin = origin
    }

    public init?(proxyURL: URL) {
        guard let origin = PreviewOrigin(url: proxyURL) else { return nil }
        self.origin = origin
    }

    public func decide(for url: URL) -> Decision {
        // WebKit's own empty page. Refusing it would leave the view stuck before the first load.
        if url.absoluteString == "about:blank" { return .allow }

        guard let candidate = PreviewOrigin(url: url) else {
            return .refuse(reason: "OpenPaw could not read “\(url.absoluteString)” as an address, so it did not open it.")
        }
        guard candidate == origin else {
            return .refuse(
                reason: "This preview only shows \(origin). The page tried to open \(candidate), which is "
                    + "outside the tunnel, so OpenPaw stopped it."
            )
        }
        return .allow
    }
}

// MARK: - Errors

/// The three ways a preview fails, each with the single thing to do about it.
public enum PreviewError: Error, Sendable, Equatable {
    /// The chosen port is not one the host agreed to proxy — or the host agreed to proxy nothing.
    case portNotAllowlisted(port: Int, allowlisted: [Int])
    /// The port is forwarded but nothing is listening on the far end.
    case devServerNotRunning(port: Int)
    /// A page tried to leave the proxy origin.
    case blockedOrigin(attempted: String, reason: String)
    /// The tunnel itself could not produce a local address.
    case proxyUnavailable(String)

    public var title: String {
        switch self {
        case .portNotAllowlisted(_, let allowlisted):
            allowlisted.isEmpty ? "This host proxies no ports" : "That port is not allowlisted"
        case .devServerNotRunning(let port):
            "Nothing is listening on port \(port)"
        case .blockedOrigin:
            "OpenPaw blocked that navigation"
        case .proxyUnavailable:
            "The preview tunnel is not available"
        }
    }

    /// One instruction. Not a list of things it might be.
    public var direction: String {
        switch self {
        case .portNotAllowlisted(let port, let allowlisted):
            if allowlisted.isEmpty {
                return "Add the port to `preview_ports` in the host's config and restart `openpaw-host`."
            }
            return "The host allows \(allowlisted.map(String.init).joined(separator: ", ")). "
                + "Pick one of those, or add \(port) to `preview_ports` in the host's config."
        case .devServerNotRunning(let port):
            return "Start the dev server on the host so it listens on \(port), then reload."
        case .blockedOrigin(_, let reason):
            return reason
        case .proxyUnavailable(let detail):
            return "Reconnect the host to restore the forwarded port. \(detail)"
        }
    }

    public var glyph: String {
        switch self {
        case .portNotAllowlisted: "lock.shield"
        case .devServerNotRunning: "bolt.slash"
        case .blockedOrigin: "hand.raised.fill"
        case .proxyUnavailable: "network.slash"
        }
    }

    /// Maps the daemon's own answer on the proxy route.
    ///
    /// The tunnel is up in both of these cases, so the navigation *succeeds* as far as WebKit is concerned and
    /// no `NSURLError` is ever raised — without this the reader would get the daemon's raw error body rendered
    /// inside a view that claims to be their dev server. 403 is the allowlist refusing the port; 502, 503 and
    /// 504 are a live tunnel with nothing answering behind it, which is upstream's fault and a different
    /// sentence.
    public init?(proxyStatus status: Int, port: Int, allowlisted: [Int]) {
        switch status {
        case 403:
            self = .portNotAllowlisted(port: port, allowlisted: allowlisted)
        case 502, 503, 504:
            self = .devServerNotRunning(port: port)
        default:
            return nil
        }
    }
}

// MARK: - Remote address

public enum PreviewAddress {
    /// The address as it exists on the host.
    ///
    /// The local forwarded port is an accident of the tunnel — it changes between connections and means nothing
    /// to the person reading. Showing `studio:5173/settings` instead of `127.0.0.1:49871/settings` is the
    /// difference between a correct mental model and a confusing one.
    public static func remote(proxyURL: URL?, hostLabel: String, port: Int) -> String {
        var suffix = "/"
        if let proxyURL, let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false) {
            suffix = components.path.isEmpty ? "/" : components.path
            if let query = components.query, !query.isEmpty { suffix += "?\(query)" }
            if let fragment = components.fragment, !fragment.isEmpty { suffix += "#\(fragment)" }
        }
        return "\(hostLabel):\(port)\(suffix)"
    }
}

// MARK: - Navigator

/// The bit of web-view state SwiftUI needs to draw a toolbar, plus the commands that drive it.
///
/// One object, owned by the screen, shared with the single coordinator that both platform representables use.
@MainActor
@Observable
public final class PreviewNavigator {
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isLoading = false
    public private(set) var currentURL: URL?
    public private(set) var failure: PreviewError?

    /// Set by the representable. Weak, because the web view outlives no screen.
    weak var webView: WKWebView?
    var policy: PreviewNavigationPolicy?
    /// The last URL the screen asked for, so a port change reloads but in-page navigation does not.
    var requestedURL: URL?
    /// The remote port behind the proxy and the ports the host agreed to forward. Held so that a proxy error can
    /// name them: the local URL only carries the ephemeral loopback port, which is not what a reader needs told.
    private(set) var remotePort: Int?
    private(set) var allowlistedPorts: [Int] = []

    public init() {}

    public func goBack() { webView?.goBack() }
    public func goForward() { webView?.goForward() }

    public func reload() {
        failure = nil
        if let webView, webView.url != nil {
            webView.reload()
        } else if let requestedURL, let remotePort {
            load(requestedURL, remotePort: remotePort, allowlisted: allowlistedPorts)
        }
    }

    func load(_ url: URL, remotePort: Int, allowlisted: [Int]) {
        failure = nil
        requestedURL = url
        self.remotePort = remotePort
        self.allowlistedPorts = allowlisted
        policy = PreviewNavigationPolicy(proxyURL: url)
        webView?.load(URLRequest(url: url))
    }

    /// A non-2xx answer from the daemon's own proxy route, translated into the state the screen shows.
    func proxyError(status: Int) -> PreviewError? {
        guard let remotePort else { return nil }
        return PreviewError(proxyStatus: status, port: remotePort, allowlisted: allowlistedPorts)
    }

    func report(_ error: PreviewError) {
        failure = error
        isLoading = false
    }

    func clearFailure() {
        failure = nil
    }

    func observe(_ webView: WKWebView, isLoading loading: Bool) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
        isLoading = loading
    }
}

// MARK: - Coordinator

/// One coordinator for both platforms. `WKWebView` is the same class on iOS and macOS; only the representable
/// wrapper differs, so only the wrapper is behind `#if`.
@MainActor
final class PreviewWebCoordinator: NSObject, WKNavigationDelegate {

    private let navigator: PreviewNavigator

    init(navigator: PreviewNavigator) {
        self.navigator = navigator
    }

    static func makeWebView(coordinator: PreviewWebCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A preview is a window onto the dev server, not a browser profile. Nothing persists.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    // MARK: WKNavigationDelegate

    /// `WKNavigationDelegate` is `@MainActor` and its `decisionHandler` is a `@MainActor` block. The signature
    /// has to match that exactly: a near-miss compiles, never gets called, and the origin check silently
    /// stops existing — which is the one failure this screen cannot afford.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard let policy = navigator.policy else {
            decisionHandler(.allow)
            return
        }
        switch policy.decide(for: url) {
        case .allow:
            navigator.clearFailure()
            decisionHandler(.allow)
        case .refuse(let reason):
            navigator.report(.blockedOrigin(attempted: url.absoluteString, reason: reason))
            decisionHandler(.cancel)
        }
    }

    /// The daemon answers the proxy route itself when the port is refused or the dev server is down. That is a
    /// perfectly successful navigation as far as WebKit is concerned, so it has to be caught here rather than in
    /// the failure callbacks — otherwise the daemon's raw error body renders inside a view the reader believes
    /// is their dev server. Sub-resources are left alone: one dead asset must not blank the whole page.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        guard
            navigationResponse.isForMainFrame,
            let http = navigationResponse.response as? HTTPURLResponse,
            let error = navigator.proxyError(status: http.statusCode)
        else {
            decisionHandler(.allow)
            return
        }
        navigator.report(error)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigator.observe(webView, isLoading: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigator.observe(webView, isLoading: false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        handle(error, webView: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        handle(error, webView: webView)
    }

    /// A refused connection on a forwarded port means the tunnel is up and the dev server is down. That is a
    /// different problem from a broken tunnel, and it deserves a different sentence.
    private func handle(_ error: any Error, webView: WKWebView) {
        navigator.observe(webView, isLoading: false)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, Self.connectionFailures.contains(nsError.code) {
            let port = navigator.requestedURL?.port ?? webView.url?.port ?? 0
            navigator.report(.devServerNotRunning(port: port))
            return
        }
        // A cancel we issued ourselves already reported a better error.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        navigator.report(.proxyUnavailable(nsError.localizedDescription))
    }

    private static let connectionFailures: Set<Int> = [
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorTimedOut,
    ]
}

// MARK: - Platform surface

#if canImport(UIKit)
struct PreviewWebSurface: UIViewRepresentable {
    let navigator: PreviewNavigator
    let url: URL
    let remotePort: Int
    let allowlistedPorts: [Int]

    func makeCoordinator() -> PreviewWebCoordinator {
        PreviewWebCoordinator(navigator: navigator)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = PreviewWebCoordinator.makeWebView(coordinator: context.coordinator)
        navigator.webView = webView
        navigator.load(url, remotePort: remotePort, allowlisted: allowlistedPorts)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        navigator.webView = webView
        if navigator.requestedURL != url {
            navigator.load(url, remotePort: remotePort, allowlisted: allowlistedPorts)
        }
    }
}
#else
struct PreviewWebSurface: NSViewRepresentable {
    let navigator: PreviewNavigator
    let url: URL
    let remotePort: Int
    let allowlistedPorts: [Int]

    func makeCoordinator() -> PreviewWebCoordinator {
        PreviewWebCoordinator(navigator: navigator)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = PreviewWebCoordinator.makeWebView(coordinator: context.coordinator)
        navigator.webView = webView
        navigator.load(url, remotePort: remotePort, allowlisted: allowlistedPorts)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        navigator.webView = webView
        if navigator.requestedURL != url {
            navigator.load(url, remotePort: remotePort, allowlisted: allowlistedPorts)
        }
    }
}
#endif

// MARK: - Screen

/// The dev server, on the phone, over the tunnel.
///
/// Everything on this screen is deliberately honest about where the bytes come from: the address bar shows the
/// host's own address, the port picker offers only ports the host agreed to forward, and a page that tries to
/// leave the proxy is stopped and says so.
public struct PreviewWebView: View {

    @Bindable private var model: OpenPawModel
    @State private var navigator = PreviewNavigator()
    @State private var selectedPort: Int?

    public init(model: OpenPawModel, port: Int? = nil) {
        self._model = Bindable(model)
        self._selectedPort = State(initialValue: port)
    }

    private var allowlistedPorts: [Int] {
        model.health?.previewPorts ?? []
    }

    private var hostLabel: String {
        model.selectedHost?.nickname ?? "host"
    }

    /// The port in play, defaulting to the first the host offered.
    private var port: Int? {
        selectedPort ?? allowlistedPorts.first
    }

    /// Configuration failures outrank runtime ones: there is no point reporting a dead dev server on a port the
    /// host was never going to forward.
    private var blockingError: PreviewError? {
        guard let port else {
            return .portNotAllowlisted(port: 0, allowlisted: allowlistedPorts)
        }
        guard allowlistedPorts.contains(port) else {
            return .portNotAllowlisted(port: port, allowlisted: allowlistedPorts)
        }
        return nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(OpenPawTheme.line)
            addressBar
            Divider().overlay(OpenPawTheme.line)
            content
        }
        .background(OpenPawTheme.ink)
        .navigationTitle("Preview")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Button(action: navigator.goBack) {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!navigator.canGoBack)
            .accessibilityLabel("Back")

            Button(action: navigator.goForward) {
                Image(systemName: "chevron.forward")
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!navigator.canGoForward)
            .accessibilityLabel("Forward")

            Button(action: navigator.reload) {
                Image(systemName: navigator.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(navigator.isLoading ? "Stop loading" : "Reload")

            portPicker

            Spacer(minLength: OpenPawTheme.Space.small)

            if navigator.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading the page")
            }

            Button(action: openInSafari) {
                Image(systemName: "safari")
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(proxyURL == nil)
            .accessibilityLabel("Open in Safari")
        }
        .font(OpenPawTheme.Machine.body)
        .foregroundStyle(OpenPawTheme.textSecondary)
        .padding(.horizontal, OpenPawTheme.Space.medium)
    }

    @ViewBuilder private var portPicker: some View {
        if allowlistedPorts.isEmpty {
            Text("no ports").microLabel(OpenPawTheme.warn)
        } else {
            Menu {
                ForEach(allowlistedPorts, id: \.self) { candidate in
                    Button {
                        selectedPort = candidate
                    } label: {
                        if candidate == port {
                            Label("\(candidate)", systemImage: "checkmark")
                        } else {
                            Text("\(candidate)")
                        }
                    }
                }
            } label: {
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Text("Port").microLabel()
                    Text(port.map(String.init) ?? "—")
                        .font(OpenPawTheme.Machine.headline)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                }
                .padding(.horizontal, OpenPawTheme.Space.small)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                        .fill(OpenPawTheme.panel)
                )
            }
            .accessibilityLabel("Port, currently \(port.map(String.init) ?? "none selected")")
        }
    }

    // MARK: Address

    private var addressBar: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Image(systemName: "lock.laptopcomputer")
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textTertiary)
                .accessibilityHidden(true)
            Text(remoteAddress)
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OpenPawTheme.Space.medium)
        .frame(minHeight: 44)
        .background(OpenPawTheme.well)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Showing \(remoteAddress) on \(hostLabel)")
    }

    private var remoteAddress: String {
        guard let port else { return "no port selected" }
        return PreviewAddress.remote(proxyURL: navigator.currentURL, hostLabel: hostLabel, port: port)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let blockingError {
            errorState(blockingError)
        } else if let proxyURL, let port {
            ZStack {
                PreviewWebSurface(
                    navigator: navigator,
                    url: proxyURL,
                    remotePort: port,
                    allowlistedPorts: allowlistedPorts
                )
                if let failure = navigator.failure {
                    errorState(failure)
                        .background(OpenPawTheme.ink)
                }
            }
        } else if let port {
            errorState(.proxyUnavailable("OpenPaw could not build a local address for port \(port)."))
        }
    }

    private func errorState(_ error: PreviewError) -> some View {
        EmptyStateView(
            glyph: error.glyph,
            title: error.title,
            message: error.direction,
            actionTitle: "Reload"
        ) {
            navigator.reload()
        }
    }

    // MARK: Proxy address

    private var proxyURL: URL? {
        guard let port, let backend = model.backend else { return nil }
        return try? backend.previewURL(port: port, path: "/")
    }

    /// Safari reaches the forwarded port over loopback while OpenPaw is running, so this hands over the local
    /// address rather than the remote one the address bar shows.
    private func openInSafari() {
        guard let url = navigator.currentURL ?? proxyURL else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Preview

#Preview("Dev server preview") {
    NavigationStack {
        PreviewWebView(model: PreviewBackend.model(.populated))
    }
}
