import SwiftUI
import Combine
import AVFoundation

struct CompressionSelection: Identifiable {
    let id = UUID()
    let references: [String]
}

@MainActor
final class AudioCompressionTask: ObservableObject {
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var currentName = ""
    @Published var results: [CompressedAudio] = []
    @Published var messages: [String] = []
    private var task: Task<Void, Never>?
    private var directory: URL?
    private var discarded = false

    func start(_ urls: [URL], quality: AudioCompressionQuality) {
        guard !isRunning else { return }
        cleanUp()
        discarded = false
        results = []
        messages = []
        progress = 0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MelohaCompression-" + UUID().uuidString)
        directory = folder
        isRunning = true
        task = Task {
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                currentName = "\(index + 1)/\(urls.count) · \(url.lastPathComponent)"
                let reference = storageReference(url)
                let report: @Sendable (Double) -> Void = { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.isRunning, !self.discarded else { return }
                        self.progress = (Double(index) + value) / Double(urls.count)
                    }
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try await AudioCompression.prepare(source: url, reference: reference, quality: quality, directory: folder, progress: report)
                }
                do {
                    let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    results.append(result)
                } catch is CancellationError {
                    break
                } catch {
                    messages.append(url.lastPathComponent + "：" + error.localizedDescription)
                }
                progress = Double(index + 1) / Double(urls.count)
            }
            currentName = Task.isCancelled ? "已取消，原音频未修改" : "压缩完成，原音频尚未修改"
            isRunning = false
            if discarded { cleanUp() }
            task = nil
        }
    }

    func cancel() { task?.cancel() }
    func close() {
        discarded = true
        task?.cancel()
        if !isRunning { cleanUp() }
    }
    private func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

struct AudioCompressionSheet: View {
    @ObservedObject var albumStore: AlbumStore
    /// nil = all library audio; an album or track entry limits the available candidates.
    var references: [String]? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var index = DocumentsIndex.shared
    @StateObject private var job = AudioCompressionTask()
    @State private var selection: Set<String> = []
    @State private var resultSelection: Set<UUID> = []
    @State private var quality: AudioCompressionQuality = .balanced
    @State private var initialized = false
    @State private var confirmReplacement = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var preview: AVAudioPlayer?
    @State private var previewID: UUID?
    @State private var previewIsOriginal = false
    @State private var previewPosition = 0.0
    @State private var previewPlaying = false

    private var candidates: [URL] {
        let all = documentsAudioURLs()
        guard let references else { return all }
        let lookup = Dictionary(uniqueKeysWithValues: all.map { (storageReference($0), $0) })
        return references.compactMap { lookup[$0] }
    }
    private var chosenResults: [CompressedAudio] { job.results.filter { resultSelection.contains($0.id) } }
    private var savedBytes: Int64 { chosenResults.reduce(0) { $0 + $1.savedBytes } }

    var body: some View {
        NavigationStack {
            compressionForm
                .navigationTitle("压缩音频")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(job.isRunning ? "取消压缩" : "关闭") {
                            if job.isRunning { job.cancel() } else { dismiss() }
                        }.disabled(isApplying)
                    }
                }
        }
        .interactiveDismissDisabled(job.isRunning || isApplying)
        .background(replacementAlert)
        .background(errorAlert)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if references != nil { selection = Set(candidates.map { storageReference($0) }) }
        }
        .onChange(of: job.results.map(\.id)) { _, ids in resultSelection = Set(ids) }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            if let preview { previewPosition = preview.currentTime; previewPlaying = preview.isPlaying }
        }
        .onDisappear { stopPreview(); job.close() }
    }

    private var compressionForm: some View {
        Form {
            if job.isRunning {
                Section("正在压缩") {
                    Text(job.currentName).font(.subheadline)
                    ProgressView(value: job.progress)
                    Text("请保持 App 在前台。取消不会修改原音频。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !job.results.isEmpty || !job.messages.isEmpty || !job.currentName.isEmpty {
                resultsSection
            } else {
                settingsSection
                selectionSection
            }
            if previewID != nil { previewSection }
        }
        .disabled(isApplying)
    }

    private var settingsSection: some View {
        Section {
            Picker("AAC 码率", selection: $quality) {
                ForEach(AudioCompressionQuality.allCases) { value in Text(value.label).tag(value) }
            }
            Text("输出 M4A，保留原单／双声道。压缩会损失部分音质；先试听，再决定替换。没有变小的文件会自动跳过。")
                .font(.caption).foregroundStyle(.secondary)
            Button("压缩选中的 \(selection.count) 首音频") {
                stopPreview()
                job.start(candidates.filter { selection.contains(storageReference($0)) }, quality: quality)
            }.disabled(selection.isEmpty || albumStore.isBusy || albumStore.isReadOnly)
        } header: { Text("音质设置") } footer: {
            Text("只有确认替换并删除原音频后，才会释放存储空间。多声道文件暂不处理。")
        }
    }

    private var selectionSection: some View {
        Section {
            if candidates.isEmpty {
                Text("音乐库中没有可压缩的音频").foregroundStyle(.secondary)
            } else {
                Button(selection.count == candidates.count ? "取消全选" : "全选") {
                    selection = selection.count == candidates.count ? [] : Set(candidates.map { storageReference($0) })
                }
                ForEach(candidates, id: \.self) { url in
                    Toggle(isOn: Binding(
                        get: { selection.contains(storageReference(url)) },
                        set: { value in
                            if value { selection.insert(storageReference(url)) } else { selection.remove(storageReference(url)) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                            if let names = index.albumNames(for: url) {
                                Text(names).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: { Text("选择音频") }
    }

    @ViewBuilder private var resultsSection: some View {
        Section {
            Text(job.currentName)
            if !chosenResults.isEmpty {
                Text("预计释放 \(size(savedBytes))")
                Button("替换选中的 \(chosenResults.count) 首原音频", role: .destructive) {
                    stopPreview()
                    confirmReplacement = true
                }
            }
        } header: { Text("压缩结果") } footer: {
            Text("试听文件暂时占用空间。关闭本页将清理未采用的结果，原音频保持不变。")
        }
        ForEach(job.results) { result in resultRow(result) }
        if !job.messages.isEmpty {
            Section("跳过或失败（原文件已保留）") {
                ForEach(Array(job.messages.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) }
            }
        }
    }

    private func resultRow(_ result: CompressedAudio) -> some View {
        Section {
            Toggle((result.reference as NSString).lastPathComponent, isOn: Binding(
                get: { resultSelection.contains(result.id) },
                set: { if $0 { resultSelection.insert(result.id) } else { resultSelection.remove(result.id) } }
            ))
            Text("\(size(result.originalBytes)) → \(size(result.compressedBytes)) · 节省 \(size(result.savedBytes))")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("试听原音") { playPreview(result, original: true) }.buttonStyle(.bordered)
                Button("试听压缩") { playPreview(result, original: false) }.buttonStyle(.bordered)
            }
        }
    }

    private var previewSection: some View {
        Section(previewIsOriginal ? "正在试听原音" : "正在试听压缩结果") {
            if let preview {
                Text(job.results.first { $0.id == previewID }.map { ($0.reference as NSString).lastPathComponent } ?? "")
                    .font(.caption)
                Slider(value: Binding(get: { previewPosition }, set: { previewPosition = $0; preview.currentTime = $0 }),
                       in: 0...max(preview.duration, 0.01))
                Button(previewPlaying ? "暂停试听" : "继续试听") {
                    if preview.isPlaying { preview.pause() } else { preview.play() }
                    previewPlaying = preview.isPlaying
                }
            }
        }
    }

    private var replacementAlert: some View {
        Color.clear.alert("替换并删除原音频？", isPresented: $confirmReplacement) {
            Button("替换并删除原文件", role: .destructive) { applyResults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将替换 \(chosenResults.count) 首音频，预计释放 \(size(savedBytes))。字幕、专辑和分组关联会保留；共用文件的专辑同步更新。删除后无法恢复原音质。")
        }
    }
    private var errorAlert: some View {
        Color.clear.alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func applyResults() {
        let chosen = chosenResults
        guard !chosen.isEmpty, !isApplying else { return }
        isApplying = true
        Task {
            do { try await albumStore.applyCompressedAudio(chosen); dismiss() }
            catch { errorMessage = error.localizedDescription }
            isApplying = false
        }
    }

    private func playPreview(_ result: CompressedAudio, original: Bool) {
        let position = previewID == result.id ? previewPosition : 0
        stopPreview()
        do {
            NotificationCenter.default.post(name: .libraryPreviewWillPlay, object: nil)
            guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = original ? try LibraryStorage.resolve(result.reference, in: root) : result.file
            let player = try AVAudioPlayer(contentsOf: url)
            try AVAudioSession.sharedInstance().setActive(true)
            player.currentTime = min(position, max(0, player.duration - 0.01))
            guard player.play() else { throw AudioCompressionError.invalidAudio }
            preview = player
            previewID = result.id
            previewIsOriginal = original
            previewPosition = player.currentTime
            previewPlaying = true
        } catch { errorMessage = error.localizedDescription }
    }
    private func stopPreview() {
        preview?.stop(); preview = nil; previewID = nil; previewPlaying = false; previewPosition = 0
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

extension Notification.Name {
    nonisolated static let libraryPreviewWillPlay = Notification.Name("Meloha.libraryPreviewWillPlay")
}
