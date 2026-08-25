//
//  AudioDownloader.swift
//  SubtitlePlayer
//
//  从 URL 直链下载音频到音乐库。适用于自己的云盘直链、播客音频、免费音效站等。
//
//  ⚠️ 只做「直链下载」：给一个指向音频文件本身的 http(s) 地址就下它。不解析视频站/
//  音乐平台的播放页——那需要绕过平台的访问控制，既违反服务条款也涉及版权。
//
//  下载完成后走与手动导入相同的落地规则（Documents、同名加序号），所以下来的文件
//  会自动出现在「未分类」里，可以直接播放、配字幕、加进专辑。
//

import AVFoundation
import Combine
import SwiftUI

// MARK: - 下载引擎

enum AudioDownloadError: LocalizedError {
    case invalidURL
    case notHTTP
    case httpStatus(Int)
    case notAudio(String?)
    case undecodable
    case documentsUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "链接格式不对，请检查是否完整（需以 http:// 或 https:// 开头）"
        case .notHTTP:
            return "只支持 http/https 链接"
        case .httpStatus(let code):
            switch code {
            case 401, 403:
                return "服务器拒绝访问（\(code)）：这个链接可能需要登录，或不允许直接下载"
            case 404:
                return "文件不存在（404），请检查链接是否正确"
            default:
                return "服务器返回错误（\(code)）"
            }
        case .notAudio(let type):
            // 最常见的情况：链接指向网页而不是音频文件。
            let detail = type.map { "（服务器返回的是 \($0)）" } ?? ""
            return "这个链接不是音频文件\(detail)。需要指向音频本身的直链，不是播放页面。"
        case .undecodable:
            return "文件下载完成但无法解码，可能不是受支持的音频格式（mp3/m4a/wav/aac/aiff）"
        case .documentsUnavailable:
            return "找不到文档目录，无法保存"
        case .writeFailed(let reason):
            return "保存失败：\(reason)"
        }
    }
}

/// 下载状态，驱动界面显示。
enum AudioDownloadState: Equatable {
    case idle
    /// 进度 0...1；服务器没给 Content-Length 时为 nil（显示不确定进度）。
    case downloading(Double?)
    case finished(String)
    case failed(String)
}

@MainActor
final class AudioDownloader: NSObject, ObservableObject {
    @Published private(set) var state: AudioDownloadState = .idle

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    /// 落地后的文件名，完成时回调给界面。
    private var suggestedName: String?
    private var continuation: CheckedContinuation<URL, Error>?

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    /// 开始下载。成功后文件已落在 Documents，返回其 URL。
    func download(from text: String) async {
        guard !isDownloading else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            state = .failed(AudioDownloadError.invalidURL.localizedDescription)
            return
        }
        guard scheme == "http" || scheme == "https" else {
            state = .failed(AudioDownloadError.notHTTP.localizedDescription)
            return
        }

        state = .downloading(nil)

        do {
            let saved = try await performDownload(from: url)
            state = .finished(saved.deletingPathExtension().lastPathComponent)
        } catch is CancellationError {
            // 用户主动取消：cancel() 已经把状态设回 .idle，别覆盖成错误提示。
        } catch let error as URLError where error.code == .cancelled {
            // URLSession 侧的取消同理。
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        // 必须 resume 后再清空：只置 nil 会让等待中的 performDownload 永远挂着，
        // isDownloading 一直是 true，之后再也发不起新的下载。
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
        state = .idle
    }

    func reset() {
        guard !isDownloading else { return }
        state = .idle
    }

    private func performDownload(from url: URL) async throws -> URL {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
            self.task = nil
        }

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            self.task = task
            task.resume()
        }

        // 校验：拿到的必须是能解码的音频，否则大概率是网页或错误页。
        guard (try? AVAudioFile(forReading: tempURL)) != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioDownloadError.undecodable
        }

        guard let documentsURL = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else {
            throw AudioDownloadError.documentsUnavailable
        }

        let fileName = suggestedName ?? Self.fileName(from: url)
        var destination = documentsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            let ext = destination.pathExtension
            let base = destination.deletingPathExtension().lastPathComponent
            var number = 2
            repeat {
                destination = documentsURL
                    .appendingPathComponent("\(base) \(number)")
                    .appendingPathExtension(ext)
                number += 1
            } while FileManager.default.fileExists(atPath: destination.path)
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioDownloadError.writeFailed(error.localizedDescription)
        }
        return destination
    }

    /// 从 URL 推断文件名；没有可用扩展名时补 mp3（最常见）。
    private static func fileName(from url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        let base = raw.isEmpty ? "下载的音频" : raw
        let ext = url.pathExtension.lowercased()
        return audioFileExtensions.contains(ext) ? "\(base).\(ext)" : "\(base).mp3"
    }
}

// MARK: URLSession delegate

extension AudioDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil
        Task { @MainActor in
            guard self.isDownloading else { return }
            self.state = .downloading(fraction)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 系统会在本回调返回后删除 location，必须先搬到自己的临时位置。
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let moved = (try? FileManager.default.moveItem(at: location, to: temp)) != nil

        let response = downloadTask.response as? HTTPURLResponse
        let mime = response?.mimeType
        let headerName = response?.suggestedFilename

        Task { @MainActor in
            guard let continuation = self.continuation else { return }
            self.continuation = nil

            if let code = response?.statusCode, !(200..<300).contains(code) {
                try? FileManager.default.removeItem(at: temp)
                continuation.resume(throwing: AudioDownloadError.httpStatus(code))
                return
            }
            guard moved else {
                continuation.resume(throwing: AudioDownloadError.writeFailed("无法读取下载内容"))
                return
            }
            // MIME 明确不是音频就早退，省去解码尝试（下载到 HTML 错误页时最常见）。
            if let mime, !mime.hasPrefix("audio"), !mime.hasPrefix("application/octet-stream") {
                try? FileManager.default.removeItem(at: temp)
                continuation.resume(throwing: AudioDownloadError.notAudio(mime))
                return
            }
            // 优先用服务器给的文件名（Content-Disposition），它通常比 URL 路径更准。
            if let headerName, !headerName.isEmpty,
               audioFileExtensions.contains(URL(fileURLWithPath: headerName).pathExtension.lowercased()) {
                self.suggestedName = headerName
            }
            continuation.resume(returning: temp)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - 界面

struct AudioDownloadView: View {
    @StateObject private var downloader = AudioDownloader()
    @State private var urlText = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("https://example.com/song.mp3", text: $urlText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($urlFocused)
                    .disabled(downloader.isDownloading)

                if !urlText.isEmpty && !downloader.isDownloading {
                    Button("清空", systemImage: "xmark.circle") {
                        urlText = ""
                        downloader.reset()
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("音频链接")
            } footer: {
                Text("需要指向音频文件本身的直链（结尾通常是 .mp3/.m4a/.wav 等），不是播放页面的网址。")
            }

            Section {
                if downloader.isDownloading {
                    progressRow
                    Button(role: .destructive) {
                        downloader.cancel()
                    } label: {
                        Label("取消下载", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        urlFocused = false
                        Task { await downloader.download(from: urlText) }
                    } label: {
                        Label("开始下载", systemImage: "arrow.down.circle")
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("下载完成后会出现在「专辑 → 未分类」，可以直接播放或配字幕。")
            }

            resultSection
        }
        .navigationTitle("从链接下载")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var progressRow: some View {
        if case .downloading(let fraction) = downloader.state {
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    // 服务器没给 Content-Length，只能显示不确定进度。
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("下载中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch downloader.state {
        case .finished(let name):
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已保存")
                            .font(.subheadline)
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        case .failed(let message):
            Section {
                Label {
                    Text(message)
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        case .idle, .downloading:
            EmptyView()
        }
    }
}
