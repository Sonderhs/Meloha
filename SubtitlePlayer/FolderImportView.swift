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

    func start(_ access: SelectedFolderAccess, store: AlbumStore, policy: DuplicateImportPolicy) {
        guard !running else { return }
        guard !store.isReadOnly else {
            status = "音乐库尚未整理完成，暂时无法导入"
            issues = ["请先处理音乐库的整理错误，再选择文件夹。"]
            finished = true
            return
        }
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
            try withExtendedLifetime(access) {
                try FolderImportEngine.run(folder: access.url, documents: documents, duplicatePolicy: policy, progress: report)
            }
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

    func selectionCancelled() {
        guard !running else { return }
        status = "已取消文件夹选择，可重新选择"
    }

    func selectionStarted() {
        status = "请选择作品文件夹，并点系统窗口中的“打开”"
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
                    Text("选择一个已解压的作品文件夹。支持 MP3、M4A、WAV、FLAC、M4B、AIFF 等音频和 SRT、VTT、LRC 字幕。不同专辑的同名音频保留原名；原文件保留。")
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
                            controller.selectionStarted()
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
            .background {
                FolderDocumentPicker(isPresented: $showPicker) { access in
                    if let access { controller.start(access, store: albumStore, policy: duplicatePolicy) }
                    else { controller.selectionCancelled() }
                }
                .frame(width: 0, height: 0)
            }
        }
        .interactiveDismissDisabled(controller.running)
    }
}

/// Keep the delegate alive in an embedded presenter. UIKit may dismiss its picker automatically;
/// that must not destroy a SwiftUI sheet and its coordinator before selection is delivered.
private struct FolderDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (SelectedFolderAccess?) -> Void

    func makeUIViewController(context: Context) -> FolderPickerHost { FolderPickerHost() }

    func updateUIViewController(_ host: FolderPickerHost, context: Context) {
        host.onFinish = { access in
            onPick(access)
            isPresented = false
        }
        host.requested = isPresented
        host.presentWhenReady()
    }
}

private final class FolderPickerHost: UIViewController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    var requested = false
    var onFinish: ((SelectedFolderAccess?) -> Void)?
    private var picker: UIDocumentPickerViewController?
    private var delivered = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentWhenReady()
    }

    func presentWhenReady() {
        guard requested, viewIfLoaded?.window != nil, picker == nil, presentedViewController == nil else { return }
        delivered = false
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.picker = picker
        present(picker, animated: true) {
            picker.presentationController?.delegate = self
        }
    }

    private func finish(_ url: URL?) {
        guard !delivered else { return }
        delivered = true
        requested = false
        // Acquire access inside the delegate callback, before UIKit releases the selection context.
        let access = url.map { SelectedFolderAccess(url: $0) }
        onFinish?(access)
        let current = picker
        picker = nil
        current?.dismiss(animated: true) { [weak self] in self?.presentWhenReady() }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(nil) }
}
