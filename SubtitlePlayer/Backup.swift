//
//  Backup.swift
//  SubtitlePlayer
//
//  备份的导出 / 导入。
//
//  为什么不用 JSON：旧实现把 Documents 里所有文件读成 [Data] 再 JSONEncoder 编码，
//  而 JSON 里的 Data 是 base64（×1.33），加上 FileDocument 的再一次拷贝，峰值内存
//  约为音频库大小的 3.5 倍 —— 库上 GB 就必被系统杀掉（表现为「点导出备份闪退」）。
//
//  现在的格式是自定义的流式容器：文件内容边读边写，清单放在末尾（类似 zip 的中央目录），
//  无论库多大，内存占用都固定在一个 1MB 的搬运缓冲区。
//
//  ┌──────────────┬───────────────┬──────────┬────────────────┐
//  │ 魔数 8 字节   │ 各文件内容依次 │ 清单 JSON │ 清单长度 8 字节 │
//  │ MELOHABK     │ 拼接（无分隔） │          │ （小端 UInt64） │
//  └──────────────┴───────────────┴──────────┴────────────────┘
//
//  清单记录每个文件的 name / offset / length，恢复时按偏移逐个 seek 出来。
//  末尾放长度是为了能先 seek 到文件尾读清单，不必扫描整个文件。
//
//  兼容性：旧的 JSON 备份（首字节 `{`）仍可导入，走 legacy 路径。
//

import Foundation
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 文件类型

/// 备份文件的类型。在 Info.plist 的 `UTExportedTypeDeclarations` 里声明，
/// 这里按标识符取回来。
///
/// 必须声明、不能只靠 `.data` 兜：未声明的扩展名在系统里只会解析成动态类型
/// （`dyn.xxxx`），「文件」选择器对这种类型的过滤很严，表现就是备份文件灰掉选不中。
nonisolated let backupContentType: UTType =
    UTType("com.hansen.SubtitlePlayer.backup")
    ?? UTType(filenameExtension: "melohabk", conformingTo: .data)
    ?? .data

// MARK: - 进度状态

/// 导出 / 导入的运行状态，驱动界面。
@MainActor
final class BackupTaskRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case exporting(Double)
        case importing(Double)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 导出完成、等待系统面板取走的文件。
    @Published var exportedFile: ExportedBackup?

    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .exporting, .importing: return true
        case .idle, .failed: return false
        }
    }

    var progressValue: Double? {
        switch phase {
        case .exporting(let p), .importing(let p): return p
        case .idle, .failed: return nil
        }
    }

    func export() {
        guard !isBusy else { return }
        phase = .exporting(0)

        // 进度回调在后台线程触发，这里先把发布逻辑包成一个 Sendable 闭包，
        // 避免在 detached 闭包里直接碰 self（那是 @MainActor 的）。
        let report = makeProgressReporter(for: .export)

        task = Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try BackupManager.writeBackup(progress: report)
                }.value
                guard !Task.isCancelled else {
                    BackupManager.cleanUpTemporary(url)
                    return
                }
                exportedFile = ExportedBackup(url: url)
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 恢复。`onFinish` 在成功后于主线程调用，用来刷新各个 store。
    func restore(from url: URL, onFinish: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        phase = .importing(0)

        let report = makeProgressReporter(for: .import)

        // security scope 必须在这里（选择器回调所在的同步上下文）就拿到，
        // 不能推迟到 Task 里 —— 那时回调已经返回，作用域可能已经失效。
        // 现在的调用方用 asCopy 拿到的是本地副本、本就不需要 scope，
        // 但保留这层兜底，免得以后换成别的来源时静默读不到。
        let accessing = url.startAccessingSecurityScopedResource()

        task = Task {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try BackupManager.restore(from: url, progress: report)
                }.value
                guard !Task.isCancelled else { return }
                onFinish()
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private enum Direction {
        case export
        case `import`
    }

    /// 造一个可以从后台线程调用的进度上报闭包。
    ///
    /// 它只捕获 `self`（一个引用）而不在后台碰它的属性：真正的赋值跳回主线程做。
    /// 这样既满足并发检查，也保证 `phase` 始终只在主线程改。
    private func makeProgressReporter(for direction: Direction) -> BackupManager.ProgressHandler {
        { [weak self] fraction in
            // 先解成 let 常量再交给 Task：直接在 Task 里 `guard let self` 会捕获
            // 外层的可变 self，Swift 6 下是错误。
            guard let runner = self else { return }
            Task { @MainActor in
                runner.updateProgress(direction: direction, fraction: fraction)
            }
        }
    }

    /// 只在主线程改 `phase`；方向对不上说明这次任务已取消或结束，丢弃迟到的进度。
    private func updateProgress(direction: Direction, fraction: Double) {
        switch (direction, phase) {
        case (.export, .exporting): phase = .exporting(fraction)
        case (.import, .importing): phase = .importing(fraction)
        default: break
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func clearError() {
        if case .failed = phase { phase = .idle }
    }
}

/// 导出完成的文件，交给系统面板。
struct ExportedBackup: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - 导出面板

/// 把已经落盘的备份文件交给系统「文件」界面。
///
/// 用 `UIDocumentPickerViewController(forExporting:)` 而不是 `.fileExporter`：后者要求
/// 把内容做成 `FileDocument`，也就是先整个读进内存 —— 正是要避免的东西。这里只递一个
/// URL 过去，系统自己搬。
struct BackupExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: BackupExportPicker
        init(_ parent: BackupExportPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onFinish(false)
        }
    }
}
