import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct Y2DownDownloadView: View {
    @ObservedObject var albumStore: AlbumStore
    @StateObject private var browser = Y2DownBrowser()
    @State private var showDestination = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Y2DownWebView(browser: browser)
            .safeAreaInset(edge: .bottom, spacing: 0) { downloadStatus }
            .navigationTitle("Y2Down 网页下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("用浏览器打开", systemImage: "safari") { openURL(Y2DownBrowser.home) }
                        Button("重新载入", systemImage: "arrow.clockwise") { browser.loadHome() }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel("网页操作")
                    }
                }
            }
            .onChange(of: browser.completedFile) { _, file in showDestination = file != nil }
            .sheet(isPresented: $showDestination, onDismiss: browser.discardFile) {
                if let file = browser.completedFile {
                    Y2DownImportSheet(albumStore: albumStore, file: file) { destination in
                        browser.imported(to: destination)
                        showDestination = false
                    }
                }
            }
    }

    @ViewBuilder
    private var downloadStatus: some View {
        if browser.isDownloading || browser.message != nil {
            HStack(spacing: 12) {
                if browser.isDownloading {
                    ProgressView("正在下载…").frame(maxWidth: .infinity, alignment: .leading)
                    Button("取消", action: browser.cancelDownload)
                } else if let message = browser.message {
                    Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    Button { browser.clearMessage() } label: {
                        Image(systemName: "xmark.circle.fill").accessibilityLabel("关闭提示")
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }
}

private struct Y2DownImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var albumStore: AlbumStore
    let file: URL
    let onImported: (String) -> Void
    @State private var albumID: UUID?
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(file.lastPathComponent)
                    Picker("保存到", selection: $albumID) {
                        Text("未分类").tag(nil as UUID?)
                        ForEach(albumStore.albums) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .disabled(isImporting)
                }
                if isImporting { ProgressView("正在导入…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("导入下载文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入", action: importFile)
                        .disabled(isImporting || albumStore.isBusy || albumStore.isReadOnly)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private func importFile() {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        let selectedAlbum = albumID
        Task {
            defer { isImporting = false }
            do {
                try await albumStore.importMediaFile(file, named: file.lastPathComponent, albumID: selectedAlbum)
                let name = albumStore.albums.first(where: { $0.id == selectedAlbum })?.name ?? "未分类"
                onImported(name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct Y2DownWebView: UIViewRepresentable {
    let browser: Y2DownBrowser

    func makeCoordinator() -> Y2DownBrowser { browser }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Y2DownBrowser) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.close()
    }
}

@MainActor
private final class Y2DownBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let home = URL(string: "https://y2down.to/zh1/")!
    @Published private(set) var message: String?
    @Published private(set) var isDownloading = false
    @Published private(set) var completedFile: URL?

    private weak var webView: WKWebView?
    private var activeDownload: WKDownload?
    private var destination: URL?
    private var popupDestination: URL?

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        view.load(URLRequest(url: Self.home))
        return view
    }

    func loadHome() {
        clearMessage()
        webView?.load(URLRequest(url: Self.home))
    }

    func clearMessage() { message = nil }

    func imported(to album: String) {
        message = "已导入到「\(album)」。"
    }

    func discardFile() {
        guard let completedFile else { return }
        try? FileManager.default.removeItem(at: completedFile.deletingLastPathComponent())
        self.completedFile = nil
    }

    func cancelDownload() {
        if let activeDownload { abandon(activeDownload) }
        message = "已取消下载。"
    }

    func close() {
        if let activeDownload { abandon(activeDownload) }
        discardFile()
        webView = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let siteFrame = action.sourceFrame.isMainFrame && Y2DownMedia.isSite(action.sourceFrame.request.url)
        let siteURL = Y2DownMedia.isSite(url)
        let downloadable = Y2DownMedia.isHTTPS(url) || Y2DownMedia.isSiteBlob(url)
        if siteFrame && action.shouldPerformDownload && downloadable {
            decisionHandler(.download)
        } else if siteURL {
            decisionHandler(.allow)
        } else if downloadable && (action.targetFrame?.isMainFrame ?? true)
                    && (popupDestination == url || (siteFrame && isMediaNavigation(action))) {
            if action.targetFrame != nil { popupDestination = nil }
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    private func isMediaNavigation(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated || Y2DownMedia.supportsExtension(action.request.url?.pathExtension)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url else { return nil }
        let fromSite = action.sourceFrame.isMainFrame && Y2DownMedia.isSite(action.sourceFrame.request.url)
        if Y2DownMedia.isSite(url) || (fromSite && Y2DownMedia.isHTTPS(url) && isMediaNavigation(action)) {
            popupDestination = url
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigation: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let response = navigation.response
        if navigation.isForMainFrame, Y2DownMedia.filename(response) != nil {
            decisionHandler(.download)
        } else if Y2DownMedia.isSite(response.url), navigation.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            if navigation.isForMainFrame { message = "无法接收这个下载，请尝试 MP4、M4A 或 MP3，或用浏览器打开。" }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        begin(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        begin(download)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFailed(error)
    }

    private func pageFailed(_ error: Error) {
        let error = error as NSError
        // WebKit interrupts navigation when a response becomes a download or is cancelled by policy.
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled),
              !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
        message = "网页加载失败。请重新载入或用浏览器打开。"
    }

    private func begin(_ download: WKDownload) {
        guard activeDownload == nil, completedFile == nil else {
            download.cancel { _ in }
            return
        }
        message = nil
        isDownloading = true
        activeDownload = download
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard activeDownload === download else { completionHandler(nil); return }
        guard let name = Y2DownMedia.filename(response, suggestedName: suggestedFilename) else {
            message = "网页没有返回可导入的音视频文件。请试试 MP4、M4A 或 MP3。"
            clear(download)
            completionHandler(nil)
            return
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MelohaWebDownload-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let file = folder.appendingPathComponent(name)
            destination = file
            completionHandler(file)
        } catch {
            message = "无法保存下载文件。请检查 iPhone 的可用空间。"
            clear(download)
            completionHandler(nil)
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(Y2DownMedia.isHTTPS(request.url) ? .allow : .cancel)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard activeDownload === download, let file = destination else { return }
        completedFile = file
        clear(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard activeDownload === download else { return }
        let folder = destination?.deletingLastPathComponent()
        clear(download)
        if let folder { try? FileManager.default.removeItem(at: folder) }
        message = "下载未完成。请返回网页重试，或用浏览器打开。"
    }

    private func abandon(_ download: WKDownload) {
        let folder = destination?.deletingLastPathComponent()
        clear(download)
        download.cancel { _ in
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private func clear(_ download: WKDownload) {
        download.delegate = nil
        activeDownload = nil
        destination = nil
        isDownloading = false
    }
}

private enum Y2DownMedia {
    static func isHTTPS(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    static func isSite(_ url: URL?) -> Bool {
        guard isHTTPS(url), let url, url.port == nil || url.port == 443 else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == "y2down.to" || host.hasSuffix(".y2down.to")
    }

    static func isSiteBlob(_ url: URL?) -> Bool {
        guard let url, url.scheme == "blob" else { return false }
        return isSite(URL(string: String(url.absoluteString.dropFirst("blob:".count))))
    }

    static func supportsExtension(_ fileExtension: String?) -> Bool {
        guard let ext = fileExtension?.lowercased() else { return false }
        return LibraryStorage.audioExtensions.contains(ext) || LibraryStorage.videoExtensions.contains(ext)
    }

    static func filename(_ response: URLResponse, suggestedName: String? = nil) -> String? {
        guard isHTTPS(response.url) || isSiteBlob(response.url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let mime = response.mimeType?.lowercased()
        let supported: [String]
        let preferred: String?
        switch mime {
        case "audio/mp4", "audio/x-m4a":
            supported = LibraryStorage.audioExtensions
            preferred = "m4a"
        case let type? where type.hasPrefix("audio/"):
            supported = LibraryStorage.audioExtensions
            preferred = UTType(mimeType: type)?.preferredFilenameExtension
        case let type? where type.hasPrefix("video/"):
            supported = LibraryStorage.videoExtensions
            preferred = UTType(mimeType: type)?.preferredFilenameExtension
        case nil, "application/octet-stream", "binary/octet-stream", "application/download", "application/force-download":
            supported = LibraryStorage.audioExtensions + LibraryStorage.videoExtensions
            preferred = nil
        default:
            return nil
        }
        let name = suggestedName ?? response.suggestedFilename ?? response.url?.lastPathComponent ?? ""
        let candidate = (name as NSString).pathExtension.lowercased()
        let urlExtension = response.url?.pathExtension.lowercased()
        guard let ext = [candidate, urlExtension, preferred].compactMap({ $0 }).first(where: supported.contains) else {
            return nil
        }
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let rawStem = (name as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping
        let stem = rawStem.components(separatedBy: unsafe).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var safe = ""
        var byteCount = 0
        for character in stem {
            let size = String(character).utf8.count
            guard byteCount + size <= 180 else { break }
            safe.append(character)
            byteCount += size
        }
        return (safe.isEmpty ? "Y2Down" : safe) + "." + ext
    }
}
