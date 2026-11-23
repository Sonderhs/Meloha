import AVFoundation
import Foundation
import SwiftUI
import YouTubeKit

nonisolated struct YouTubeLink {
    static func videoID(from text: String) -> String? {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.split(separator: "/")
        let id: String?
        switch host {
        case "youtu.be": id = path.count == 1 ? String(path[0]) : nil
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            if path == ["watch"] { id = url.queryItems?.first { $0.name == "v" }?.value }
            else if path.count == 2, ["shorts", "embed", "live"].contains(path[0]) { id = String(path[1]) }
            else { id = nil }
        default: return nil
        }
        guard let id, id.utf8.count == 11, id.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }) else { return nil }
        return id
    }

    static func filename(title: String, id: String, extension ext: String) -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let safe = title.components(separatedBy: unsafe).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = String(safe.prefix(46))
        return base.isEmpty || base.utf8.count > 185 ? "YouTube-\(id).\(ext)" : "\(base) [\(id)].\(ext)"
    }
}

private struct YouTubeChoice: Identifiable {
    /// Zero represents an audio-only download.
    let id: Int
    let stream: YouTubeKit.Stream
    var label: String { id == 0 ? "仅音频 · M4A" : "\(id)p · MP4" }
}

private struct YouTubeDownloadPreview {
    let id: String
    let title: String
    let thumbnail: URL?
    let choices: [YouTubeChoice]
    let audio: YouTubeKit.Stream?

    static func load(_ id: String) async throws -> Self {
        let youtube = YouTube(videoID: id, methods: [.local])
        try await youtube.checkAvailability()
        guard try await !youtube.ageRestricted else {
            throw LibraryStorage.failure("此视频有年龄限制，无法直接下载")
        }
        let streams = try await youtube.streams.filter { $0.isNativelyPlayable && $0.url.scheme == "https" }
        let audio = streams.filter { $0.fileExtension == .m4a && $0.includesAudioTrack && !$0.includesVideoTrack }
            .max { ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0) }
        var candidates: [Int: YouTubeKit.Stream] = [:]
        for stream in streams where stream.fileExtension == .mp4 && stream.includesVideoTrack {
            guard let height = stream.videoResolution, stream.includesAudioTrack || (stream.isDash && audio != nil) else { continue }
            if let old = candidates[height] {
                if old.includesAudioTrack && !stream.includesAudioTrack { continue }
                if old.includesAudioTrack == stream.includesAudioTrack, (old.bitrate ?? 0) >= (stream.bitrate ?? 0) { continue }
            }
            candidates[height] = stream
        }
        var choices = candidates.map { YouTubeChoice(id: $0.key, stream: $0.value) }.sorted { $0.id > $1.id }
        if let audio { choices.append(YouTubeChoice(id: 0, stream: audio)) }
        guard !choices.isEmpty else { throw LibraryStorage.failure("没有找到此设备可以保存的 MP4 或 M4A 格式") }
        let metadata = try? await youtube.metadata
        try Task.checkCancellation()
        return Self(id: id, title: metadata?.title ?? "YouTube \(id)", thumbnail: metadata?.thumbnail?.url,
                    choices: choices, audio: audio)
    }
}

private nonisolated final class VideoDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Double?) -> Void

    init(report: @escaping @Sendable (Double?) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
}

private enum YouTubeFileDownload {
    static func fetch(_ stream: YouTubeKit.Stream, to file: URL,
                      progress: @escaping @Sendable (Double?) -> Void) async throws {
        progress(nil)
        var request = URLRequest(url: stream.url)
        request.httpShouldHandleCookies = false
        let delegate = VideoDownloadProgress(report: progress)
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
              (200..<300).contains(http.statusCode), http.statusCode != 206 else {
            throw LibraryStorage.failure("YouTube 下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），请重新解析后重试")
        }
        if let type = response.mimeType, !type.hasPrefix("audio/"), !type.hasPrefix("video/"), type != "application/octet-stream" {
            throw LibraryStorage.failure("服务器没有返回音视频文件")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    static func merge(video: URL, audio: URL, output: URL) async throws {
        let movie = AVURLAsset(url: video)
        let soundtrack = AVURLAsset(url: audio)
        let composition = AVMutableComposition()
        guard let picture = try await movie.loadTracks(withMediaType: .video).first,
              let sound = try await soundtrack.loadTracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LibraryStorage.failure("下载结果缺少视频或音轨")
        }
        let pictureRange = try await picture.load(.timeRange)
        let soundRange = try await sound.load(.timeRange)
        guard pictureRange.duration.seconds > 0, soundRange.duration.seconds > 0,
              abs(pictureRange.duration.seconds - soundRange.duration.seconds) <= 2 else {
            throw LibraryStorage.failure("视频和音轨时长不匹配，请选择其他清晰度")
        }
        try videoTrack.insertTimeRange(pictureRange, of: picture, at: .zero)
        videoTrack.preferredTransform = try await picture.load(.preferredTransform)
        try audioTrack.insertTimeRange(CMTimeRange(start: soundRange.start,
            duration: CMTimeMinimum(soundRange.duration, pictureRange.duration)), of: sound, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw LibraryStorage.failure("无法将视频和音轨合并为 MP4")
        }
        try await exporter.export(to: output, as: .mp4)
    }
}

struct YouTubeDownloadView: View {
    @ObservedObject var albumStore: AlbumStore
    @State private var input = ""
    @State private var preview: YouTubeDownloadPreview?
    @State private var selectedQuality: Int?
    @State private var albumID: UUID?
    @State private var confirmed = false
    @State private var task: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var progress: Double?
    @State private var stage: String?
    @State private var message: String?

    var body: some View {
        Form {
            linkSection
            if let preview { optionsSection(preview) }
            if let stage {
                Section {
                    if let progress { ProgressView(stage, value: progress) }
                    else { ProgressView(stage) }
                    Button("取消", role: .cancel) { task?.cancel() }
                }
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle("从 YouTube 下载")
        .onDisappear { task?.cancel() }
    }

    private var linkSection: some View {
        Section {
            TextField("粘贴 YouTube 视频链接", text: $input, axis: .vertical)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(task != nil)
                .onChange(of: input) { _, _ in preview = nil; selectedQuality = nil; message = nil }
            Button("解析视频") { resolve() }.disabled(task != nil)
        }
    }

    private func optionsSection(_ preview: YouTubeDownloadPreview) -> some View {
        Section {
            HStack(spacing: 12) {
                if let thumbnail = preview.thumbnail, thumbnail.scheme == "https" {
                    AsyncImage(url: thumbnail) { image in image.resizable().scaledToFill() } placeholder: {
                        Color.secondary.opacity(0.12)
                    }.frame(width: 82, height: 48).clipped()
                }
                Text(preview.title).lineLimit(3)
            }
            Picker("下载格式", selection: $selectedQuality) {
                ForEach(preview.choices) { choice in Text(choice.label).tag(Optional(choice.id)) }
            }
            Picker("保存到", selection: $albumID) {
                Text("未分类").tag(nil as UUID?)
                ForEach(albumStore.albums) { album in Text(album.name).tag(Optional(album.id)) }
            }
            Toggle("我有权下载并保存此内容", isOn: $confirmed)
            Button("下载并导入") { download(preview) }
                .disabled(task != nil || !confirmed || albumStore.isBusy || albumStore.isReadOnly)
        }
        .disabled(task != nil)
    }

    private func resolve() {
        guard task == nil else { return }
        guard let id = YouTubeLink.videoID(from: input) else { message = "请输入一条有效的 YouTube 单视频链接。"; return }
        preview = nil
        message = nil
        confirmed = false
        stage = "正在手机上解析…"
        task = Task {
            defer { finish() }
            do {
                let result = try await YouTubeDownloadPreview.load(id)
                try Task.checkCancellation()
                preview = result
                selectedQuality = result.choices.first?.id
            } catch {
                message = Task.isCancelled ? "已取消。" : "解析失败。请确认 YouTube 可访问，或尝试其他视频。\n" + error.localizedDescription
            }
        }
    }

    private func download(_ preview: YouTubeDownloadPreview) {
        guard task == nil, confirmed, let choice = preview.choices.first(where: { $0.id == selectedQuality }) else { return }
        let token = UUID()
        operationID = token
        let targetAlbum = albumID
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MelohaVideo-" + token.uuidString, isDirectory: true)
        let isAudio = choice.id == 0
        let ext = isAudio ? "m4a" : "mp4"
        let temp = folder.appendingPathComponent("download." + ext)
        message = nil
        stage = "正在下载…"
        task = Task {
            defer { try? FileManager.default.removeItem(at: folder); finish() }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try await YouTubeFileDownload.fetch(choice.stream, to: temp, progress: reporter(for: token, lower: 0,
                    upper: !isAudio && !choice.stream.includesAudioTrack ? 0.85 : 1))
                var output = temp
                if !isAudio, !choice.stream.includesAudioTrack, let audio = preview.audio {
                    stage = "正在下载音轨…"
                    let audioFile = folder.appendingPathComponent("sound.m4a")
                    try await YouTubeFileDownload.fetch(audio, to: audioFile, progress: reporter(for: token, lower: 0.85, upper: 1))
                    stage = "正在合并视频与音轨…"
                    progress = nil
                    output = folder.appendingPathComponent("combined.mp4")
                    try await YouTubeFileDownload.merge(video: temp, audio: audioFile, output: output)
                }
                try Task.checkCancellation()
                let asset = AVURLAsset(url: output)
                guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                    throw LibraryStorage.failure("下载结果缺少音轨，请重新解析")
                }
                stage = "正在保存到专辑…"
                progress = nil
                try await albumStore.importMediaFile(output, named: YouTubeLink.filename(title: preview.title, id: preview.id, extension: ext), albumID: targetAlbum)
                message = "已保存到\(targetAlbum.flatMap { id in albumStore.albums.first { $0.id == id }?.name } ?? "未分类")。"
            } catch {
                message = Task.isCancelled ? "已取消。" : error.localizedDescription
            }
        }
    }

    private func reporter(for token: UUID, lower: Double, upper: Double) -> @Sendable (Double?) -> Void {
        { fraction in
            Task { @MainActor in
                guard operationID == token, stage == "正在下载…" || stage == "正在下载音轨…" else { return }
                if let fraction { progress = max(progress ?? 0, lower + fraction * (upper - lower)) }
            }
        }
    }

    private func finish() {
        stage = nil
        task = nil
        operationID = nil
        progress = nil
    }
}
