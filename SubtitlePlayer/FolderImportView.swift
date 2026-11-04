import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers

@MainActor
final class FolderImportController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var status = "选择一个作品文件夹，自动建立专辑"
    @Published private(set) var fraction: Double?
    @Published private(set) var summary: String?
    @Published private(set) var issues: [String] = []
    private var worker: Task<FolderImportResult, Error>?

    func start(_ folder: URL, store: AlbumStore, policy: DuplicateImportPolicy) {
        guard !running else { return }
        running = true
        finished = false
        fraction = nil
        summary = nil
        issues = []
        status = "正在扫描文件夹…"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report: @Sendable (String, Double?) -> Void = { [weak self] status, fraction in
            guard let controller = self else { return }
            Task { @MainActor in
                guard controller.running, controller.worker?.isCancelled != true else { return }
                controller.status = status
                controller.fraction = fraction
            }
        }
        let job = Task.detached(priority: .userInitiated) {
            try FolderImportEngine.run(folder: folder, documents: documents, duplicatePolicy: policy, progress: report)
        }
        worker = job
        Task {
            do {
                let result = try await job.value
                do {
                    if job.isCancelled { throw CancellationError() }
                    try store.addImportedFolder(result)
                } catch {
                    await Task.detached { FolderImportEngine.cleanup(result.createdFiles) }.value
                    throw error
                }
                status = "已创建专辑「\(result.name)」"
                summary = "\(result.tracks.count) 首音频 · \(result.subtitleCount) 份字幕 · \(result.images.count + (result.cover == nil ? 0 : 1)) 张图片"
                issues = result.issues
                fraction = 1
            } catch is CancellationError {
                status = "已取消导入"
                summary = "本次已复制的文件已清理。"
            } catch {
                status = "导入失败"
                issues = [error.localizedDescription]
            }
            running = false
            finished = true
            worker = nil
        }
    }

    func cancel() {
        worker?.cancel()
        status = "正在取消并清理文件…"
    }
}

struct FolderImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var albumStore: AlbumStore
    @StateObject private var controller = FolderImportController()
    @State private var showPicker = false
    @State private var duplicatePolicy: DuplicateImportPolicy = .keepBoth

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("文件夹名作为专辑名", systemImage: "folder")
                    Label("包含子文件夹，曲目按目录分组", systemImage: "square.stack")
                    Label("同名字幕自动配对", systemImage: "captions.bubble")
                    Label("优先选用 cover、folder、artwork01 等封面，其余图片加入图片集", systemImage: "photo")
                } footer: {
                    Text("选择一个已解压的作品文件夹。支持 MP3、M4A、WAV、AAC、AIFF 和 SRT、VTT、LRC 字幕。不同专辑的同名音频保留原名；原文件保留。")
                }
                Section {
                    Picker("同一专辑内出现同名音频", selection: $duplicatePolicy) {
                        ForEach(DuplicateImportPolicy.allCases, id: \.self) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .disabled(controller.running)
                }
                Section {
                    if controller.running {
                        if let fraction = controller.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    }
                    Text(controller.status)
                    if let summary = controller.summary {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !controller.running {
                        Button(controller.finished ? "再导入一个文件夹" : "选择作品文件夹") {
                            showPicker = true
                        }
                    }
                }
                if !controller.issues.isEmpty {
                    Section("未导入或需要检查（\(controller.issues.count)）") {
                        ForEach(Array(controller.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(.footnote).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("导入作品文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if controller.running {
                        Button("取消导入") { controller.cancel() }
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .background(
                Color.clear.sheet(isPresented: $showPicker) {
                    FolderDocumentPicker { url in
                        showPicker = false
                        if let url { controller.start(url, store: albumStore, policy: duplicatePolicy) }
                    }
                    .ignoresSafeArea()
                }
            )
        }
        .interactiveDismissDisabled(controller.running)
    }
}

/// Folder access is granted in place; do not ask the provider to duplicate the whole directory.
private struct FolderDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}
