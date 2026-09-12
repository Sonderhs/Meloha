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

// MARK: - 容器格式

/// 备份里随文件一起保存的 UserDefaults 项。
nonisolated struct BackupSettings: Codable {
    var allowMixWithOthers: Bool?
    var appTheme: String?
    var backgroundOpacity: Double?
    var playbackRate: Double?
    var playMode: String?
    var subtitleFontSize: Double?
    var subtitleColor: String?
    var subtitleLineCount: Int?
    var fileSort: String?
    var chatSystemPrompt: String?

    /// 从 UserDefaults 采集当前设置。
    static func current() -> BackupSettings {
        let d = UserDefaults.standard
        return BackupSettings(
            allowMixWithOthers: d.object(forKey: "allowMixWithOthers") as? Bool,
            appTheme: d.string(forKey: "appTheme"),
            backgroundOpacity: d.object(forKey: "backgroundOpacity") as? Double,
            playbackRate: d.object(forKey: "playbackRate") as? Double,
            playMode: d.string(forKey: "playMode"),
            subtitleFontSize: d.object(forKey: "subtitleFontSize") as? Double,
            subtitleColor: d.string(forKey: "subtitleColor"),
            subtitleLineCount: d.object(forKey: "subtitleLineCount") as? Int,
            fileSort: d.string(forKey: "fileSort"),
            chatSystemPrompt: d.string(forKey: "chatSystemPrompt")
        )
    }

    /// 写回 UserDefaults。备份里没有的键保持原样，不覆盖成默认值。
    func apply() {
        let d = UserDefaults.standard
        if let v = allowMixWithOthers { d.set(v, forKey: "allowMixWithOthers") }
        if let v = appTheme { d.set(v, forKey: "appTheme") }
        if let v = backgroundOpacity { d.set(v, forKey: "backgroundOpacity") }
        if let v = playbackRate { d.set(v, forKey: "playbackRate") }
        if let v = playMode { d.set(v, forKey: "playMode") }
        if let v = subtitleFontSize { d.set(v, forKey: "subtitleFontSize") }
        if let v = subtitleColor { d.set(v, forKey: "subtitleColor") }
        if let v = subtitleLineCount { d.set(v, forKey: "subtitleLineCount") }
        if let v = fileSort { d.set(v, forKey: "fileSort") }
        if let v = chatSystemPrompt { d.set(v, forKey: "chatSystemPrompt") }
    }
}

/// 清单里的一条：文件在容器中的位置。
nonisolated struct BackupManifestEntry: Codable {
    var name: String
    var offset: UInt64
    var length: UInt64
}

/// 容器末尾的清单。
nonisolated struct BackupManifest: Codable {
    var version: Int
    var settings: BackupSettings
    var entries: [BackupManifestEntry]
}

// MARK: - 旧格式（仅用于导入）

nonisolated private struct LegacyBackupEntry: Codable {
    var name: String
    var data: Data
}

nonisolated private struct LegacyBackupFile: Codable {
    var version: Int
    var settings: BackupSettings
    var files: [LegacyBackupEntry]
}

// MARK: - 错误

nonisolated enum BackupError: LocalizedError {
    case documentsUnavailable
    case notABackup
    case corrupted(String)
    case insufficientSpace(needed: Int64, free: Int64)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            return "找不到文档目录"
        case .notABackup:
            return "这不是 Meloha 备份文件"
        case .corrupted(let detail):
            return "备份文件已损坏：\(detail)"
        case .insufficientSpace(let needed, let free):
            let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return "空间不足：需要约 \(n)，可用 \(f)"
        case .writeFailed(let reason):
            return "写入失败：\(reason)"
        }
    }
}

// MARK: - 导出 / 导入

/// 备份的读写全部是纯文件操作，必须能在后台线程跑。
/// 工程默认的 actor 隔离会把它推断成 MainActor，那样 `Task.detached` 里又会跳回主线程，
/// GB 级的库就会把界面卡死 —— 所以这里显式声明 nonisolated。
nonisolated enum BackupManager {
    /// 容器魔数。同时用来区分新旧格式（旧格式是 JSON，首字节为 `{`）。
    private static let magic = Data("MELOHABK".utf8)
    /// 搬运缓冲区大小。内存占用的上界基本就是它。
    private static let chunkSize = 1 << 20  // 1 MB
    /// 末尾清单长度字段的字节数。
    private static let footerSize = 8

    private static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    // MARK: 进度

    /// 导出 / 导入的进度回调（0...1）。在后台线程调用。
    typealias ProgressHandler = @Sendable (Double) -> Void

    // MARK: 导出

    /// 预估备份体积（= Documents 下所有普通文件之和）。用来提前判断空间是否够。
    static func estimatedSize() -> Int64 {
        guard let documentsURL else { return 0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        var total: Int64 = 0
        for name in names {
            let url = documentsURL.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.int64Value
            else { continue }
            total += size
        }
        return total
    }

    /// 流式写出备份到临时目录，返回生成的文件 URL。
    ///
    /// 调用方负责在系统的导出面板用完之后删掉它（`cleanUpTemporary`）。
    /// 必须在后台线程调用：GB 级的库要跑几十秒。
    static func writeBackup(
        progress: ProgressHandler? = nil
    ) throws -> URL {
        guard let documentsURL else { throw BackupError.documentsUnavailable }

        // 只备份普通文件；子目录（如模型缓存）跳过。
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        var sources: [(name: String, url: URL, size: UInt64)] = []
        var totalBytes: UInt64 = 0
        for name in names.sorted() {
            let url = documentsURL.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value
            else { continue }
            sources.append((name, url, size))
            totalBytes += size
        }

        // 先检查临时卷的可用空间，免得写到一半失败留下半个文件。
        let tempDir = FileManager.default.temporaryDirectory
        if let free = availableCapacity(at: tempDir), Int64(totalBytes) > free {
            throw BackupError.insufficientSpace(needed: Int64(totalBytes), free: free)
        }

        let destination = tempDir.appendingPathComponent("Meloha备份-\(Self.timestamp()).melohabk")
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw BackupError.writeFailed("无法创建临时文件")
        }

        let out = try FileHandle(forWritingTo: destination)
        // 中途抛错时别把半成品留在磁盘上。
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        try out.write(contentsOf: magic)
        var offset = UInt64(magic.count)
        var entries: [BackupManifestEntry] = []
        var written: UInt64 = 0

        for source in sources {
            try Task.checkCancellation()

            guard let input = try? FileHandle(forReadingFrom: source.url) else {
                // 读不了就跳过这个文件，不让整次备份失败。
                continue
            }
            defer { try? input.close() }

            var fileLength: UInt64 = 0
            var reachedEnd = false
            while !reachedEnd {
                // autoreleasepool 不能省：FileHandle.read 返回的是桥接来的 NSData，
                // 它被放进当前 autorelease pool，而这个循环中途不会排空。少了它，
                // 每个读过的 chunk 都会堆到循环结束 —— 实测搬 300MB 会攒下 300MB
                // 匿名内存，"流式"就名存实亡了。
                try autoreleasepool {
                    try Task.checkCancellation()
                    guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else {
                        reachedEnd = true
                        return
                    }
                    try out.write(contentsOf: chunk)
                    fileLength += UInt64(chunk.count)
                    written += UInt64(chunk.count)
                    if totalBytes > 0 {
                        progress?(Double(written) / Double(totalBytes))
                    }
                }
            }

            entries.append(BackupManifestEntry(name: source.name, offset: offset, length: fileLength))
            offset += fileLength
        }

        let manifest = BackupManifest(version: 2, settings: .current(), entries: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        try out.write(contentsOf: manifestData)
        try out.write(contentsOf: littleEndianBytes(UInt64(manifestData.count)))

        progress?(1)
        succeeded = true
        return destination
    }

    /// 删除导出时生成的临时文件。导出面板关闭后调用。
    static func cleanUpTemporary(_ url: URL) {
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: 导入

    /// 从备份文件恢复。新旧格式都支持。必须在后台线程调用。
    static func restore(
        from url: URL,
        progress: ProgressHandler? = nil
    ) throws {
        guard let documentsURL else { throw BackupError.documentsUnavailable }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BackupError.corrupted("无法打开文件")
        }
        defer { try? handle.close() }

        let head = (try? handle.read(upToCount: magic.count)) ?? Data()
        if head == magic {
            try restoreStreaming(handle: handle, to: documentsURL, progress: progress)
        } else if head.first == UInt8(ascii: "{") {
            // 旧的 JSON 备份。这类文件是老版本产生的，通常不大，整读可以接受。
            try handle.seek(toOffset: 0)
            try restoreLegacy(handle: handle, to: documentsURL, progress: progress)
        } else {
            throw BackupError.notABackup
        }
    }

    private static func restoreStreaming(
        handle: FileHandle,
        to documentsURL: URL,
        progress: ProgressHandler?
    ) throws {
        let fileSize = try handle.seekToEnd()
        guard fileSize > UInt64(magic.count + footerSize) else {
            throw BackupError.corrupted("文件过短")
        }

        try handle.seek(toOffset: fileSize - UInt64(footerSize))
        guard let footer = try handle.read(upToCount: footerSize), footer.count == footerSize else {
            throw BackupError.corrupted("读不到清单长度")
        }
        let manifestLength = readLittleEndian(footer)

        // 清单长度必须落在文件内。注意先校验再相减：截断的文件会读出一个很大的
        // 长度，直接 `fileSize - footer - manifestLength` 会让 UInt64 下溢并 trap
        // （表现为导入坏备份时闪退），所以这里用加法比较。
        let minimumTail = UInt64(magic.count) + UInt64(footerSize)
        guard manifestLength > 0,
              manifestLength <= fileSize - minimumTail
        else {
            throw BackupError.corrupted("清单长度异常")
        }
        let manifestStart = fileSize - UInt64(footerSize) - manifestLength

        try handle.seek(toOffset: manifestStart)
        guard let manifestData = try handle.read(upToCount: Int(manifestLength)),
              manifestData.count == Int(manifestLength)
        else {
            throw BackupError.corrupted("读不到清单")
        }

        let manifest: BackupManifest
        do {
            manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
        } catch {
            throw BackupError.corrupted("清单无法解析")
        }

        // 先把整份清单校验一遍再动手。清单里的数字全部来自文件，可能是任意值
        // （坏文件或恶意文件），必须在参与任何算术之前就框定范围，否则
        // `reduce(+)` 或 `Int64(...)` 会溢出并 trap —— 表现为导入时闪退。
        var validated: [(name: String, offset: UInt64, length: UInt64)] = []
        var totalBytes: UInt64 = 0
        for entry in manifest.entries {
            // 名字来自文件内容，不能直接拼路径：`../` 会写到 Documents 外面去。
            guard let safeName = sanitized(entry.name) else { continue }

            let (end, overflowed) = entry.offset.addingReportingOverflow(entry.length)
            guard !overflowed,
                  entry.offset >= UInt64(magic.count),
                  end <= manifestStart
            else {
                throw BackupError.corrupted("条目「\(safeName)」位置越界")
            }

            // 每条都已被 manifestStart 框住，累加不会溢出。
            totalBytes += entry.length
            validated.append((safeName, entry.offset, entry.length))
        }

        var restored: UInt64 = 0

        // 恢复会新增同等体积的文件，先确认 Documents 所在卷装得下。
        if let free = availableCapacity(at: documentsURL), Int64(totalBytes) > free {
            throw BackupError.insufficientSpace(needed: Int64(totalBytes), free: free)
        }

        for entry in validated {
            try Task.checkCancellation()
            let safeName = entry.name

            let destination = documentsURL.appendingPathComponent(safeName)
            // 先写到同目录的临时文件，成功后再替换，避免中途失败毁掉已有文件。
            let staging = documentsURL.appendingPathComponent(".restore-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
                throw BackupError.writeFailed("无法创建临时文件")
            }

            do {
                let out = try FileHandle(forWritingTo: staging)
                defer { try? out.close() }

                try handle.seek(toOffset: entry.offset)
                var remaining = entry.length
                while remaining > 0 {
                    // 同导出：每轮排空 autorelease pool，否则读过的分块会一直累积。
                    try autoreleasepool {
                        try Task.checkCancellation()
                        let want = Int(min(UInt64(chunkSize), remaining))
                        guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                            throw BackupError.corrupted("条目「\(safeName)」内容不完整")
                        }
                        try out.write(contentsOf: chunk)
                        remaining -= UInt64(chunk.count)
                        restored += UInt64(chunk.count)
                        if totalBytes > 0 {
                            progress?(Double(restored) / Double(totalBytes))
                        }
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }

            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw BackupError.writeFailed(error.localizedDescription)
            }
        }

        manifest.settings.apply()
        progress?(1)
    }

    private static func restoreLegacy(
        handle: FileHandle,
        to documentsURL: URL,
        progress: ProgressHandler?
    ) throws {
        // 旧格式没法流式读（base64 嵌在 JSON 里），只能整读。加个上限：
        // 真按 2GB 的旧备份去解，解出来就是必然的 OOM，不如明确报错。
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard size <= 512 * 1024 * 1024 else {
            throw BackupError.corrupted("这是旧版备份且体积过大，无法导入")
        }
        guard let data = try handle.readToEnd() else {
            throw BackupError.corrupted("文件为空")
        }
        let backup: LegacyBackupFile
        do {
            backup = try JSONDecoder().decode(LegacyBackupFile.self, from: data)
        } catch {
            throw BackupError.notABackup
        }

        let total = max(backup.files.count, 1)
        for (index, entry) in backup.files.enumerated() {
            try Task.checkCancellation()
            guard let safeName = sanitized(entry.name) else { continue }
            let url = documentsURL.appendingPathComponent(safeName)
            try? entry.data.write(to: url, options: .atomic)
            progress?(Double(index + 1) / Double(total))
        }

        backup.settings.apply()
        progress?(1)
    }

    // MARK: 工具

    /// 把清单里的名字压成安全的单层文件名。含路径分隔符或 `..` 的一律拒绝。
    private static func sanitized(_ name: String) -> String? {
        guard !name.isEmpty,
              !name.hasPrefix("."),
              !name.contains("/"),
              !name.contains("\\"),
              name != "..",
              !name.contains("\0")
        else { return nil }
        return name
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func littleEndianBytes(_ value: UInt64) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    private static func readLittleEndian(_ data: Data) -> UInt64 {
        var result: UInt64 = 0
        for (index, byte) in data.enumerated() {
            result |= UInt64(byte) << (8 * UInt64(index))
        }
        return result
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}

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

        task = Task {
            // 从「文件」选来的 URL 需要 security scope 才能读。
            let accessing = url.startAccessingSecurityScopedResource()
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
