//
//  AudioTrimmer.swift
//  SubtitlePlayer
//
//  音频裁剪工具：选一个音频 → 圈定时间段 → 导出成新文件（原文件不动）。
//
//  ⚠️ 格式说明：AVAssetExportSession 在 iOS 上不能写 MP3，所以一律导出 M4A（AAC）。
//  音乐库读 mp3/m4a/wav/aac/aiff 都行，所以裁出来的 M4A 能直接播；只是扩展名会变。
//

import AVFoundation
import Combine
import SwiftUI

// MARK: - 裁剪引擎

/// 裁剪一段音频并导出为 M4A。返回落地后的文件名（在 Documents 里），失败抛错。
enum AudioTrimError: LocalizedError {
    case noAudioTrack
    case invalidRange
    case exportUnsupported
    case exportFailed(String)
    case documentsUnavailable

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "这个文件里没有可用的音频轨道"
        case .invalidRange:
            return "时间段不合法：结束时间要大于开始时间"
        case .exportUnsupported:
            return "系统无法导出这个音频格式"
        case .exportFailed(let reason):
            return "导出失败：\(reason)"
        case .documentsUnavailable:
            return "找不到文档目录，无法保存"
        }
    }
}

/// 把 sourceURL 的 [start, end] 区间导出成 Documents 下的新 M4A 文件。
/// 返回新文件的 URL。整个过程不修改源文件。
func trimAudio(
    from sourceURL: URL,
    start: TimeInterval,
    end: TimeInterval,
    outputBaseName: String
) async throws -> URL {
    guard end > start else { throw AudioTrimError.invalidRange }

    let asset = AVURLAsset(url: sourceURL)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard !tracks.isEmpty else { throw AudioTrimError.noAudioTrack }

    guard let documentsURL = try? FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ) else {
        throw AudioTrimError.documentsUnavailable
    }

    // 导出器只能写 M4A（不支持 MP3），扩展名固定 m4a。
    var destination = documentsURL
        .appendingPathComponent(outputBaseName)
        .appendingPathExtension("m4a")
    if FileManager.default.fileExists(atPath: destination.path) {
        var number = 2
        repeat {
            destination = documentsURL
                .appendingPathComponent("\(outputBaseName) \(number)")
                .appendingPathExtension("m4a")
            number += 1
        } while FileManager.default.fileExists(atPath: destination.path)
    }

    guard let session = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetAppleM4A
    ) else {
        throw AudioTrimError.exportUnsupported
    }

    // 用音频轨的原始时间刻度构造区间，避免 600 默认刻度带来的取整误差。
    let scale = try await tracks[0].load(.naturalTimeScale)
    session.timeRange = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: scale),
        end: CMTime(seconds: end, preferredTimescale: scale)
    )

    do {
        try await session.export(to: destination, as: .m4a)
    } catch {
        // 导出中断可能留下半个文件，清掉免得污染音乐库。
        try? FileManager.default.removeItem(at: destination)
        throw AudioTrimError.exportFailed(error.localizedDescription)
    }

    DocumentsIndex.refreshSoon()
    return destination
}

// MARK: - 时间输入解析

/// 解析时间输入，支持：
/// - `90` / `90.5`（纯秒，可带小数）
/// - `1:30` / `1:30.25`（mm:ss，秒可带小数）
/// - `1:02:30.5`（h:mm:ss）
/// 分隔符也接受中文冒号「：」。解析不出返回 nil。
func parseTimeInput(_ text: String) -> TimeInterval? {
    let normalized = text
        .trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "：", with: ":")
    guard !normalized.isEmpty else { return nil }

    let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)

    /// 各段都必须是合法非负数字；`Double("")` 是 nil，所以空段会被自然拒绝。
    func value(_ part: Substring) -> Double? {
        guard let v = Double(part), v >= 0, v.isFinite else { return nil }
        return v
    }

    switch parts.count {
    case 1:
        return value(parts[0])
    case 2:
        guard let minutes = value(parts[0]), let seconds = value(parts[1]),
              seconds < 60 else { return nil }
        return minutes * 60 + seconds
    case 3:
        guard let hours = value(parts[0]), let minutes = value(parts[1]),
              let seconds = value(parts[2]),
              minutes < 60, seconds < 60 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    default:
        return nil
    }
}

/// 秒数格式化为 mm:ss.SSS（超过一小时用 h:mm:ss.SSS）。
/// 保留毫秒：裁剪要能精确到帧级，取整会把用户输入的小数抹掉。
func formatTrimTime(_ time: TimeInterval) -> String {
    let clamped = max(0, time)
    // 先按毫秒取整，再拆分，避免 59.9995 这类值进位后显示成 60.000。
    let totalMilliseconds = Int((clamped * 1000).rounded())
    let milliseconds = totalMilliseconds % 1000
    let totalSeconds = totalMilliseconds / 1000
    let seconds = totalSeconds % 60
    let minutes = (totalSeconds / 60) % 60
    let hours = totalSeconds / 3600

    if hours > 0 {
        return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }
    return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
}

/// 只到秒的简短格式（用于「选中时长」等不需要毫秒的地方）。
func formatTrimTimeShort(_ time: TimeInterval) -> String {
    let total = max(0, Int(time.rounded()))
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%02d:%02d", total / 60, total % 60)
}

// MARK: - 选择要裁剪的音频

/// 第一步：从音乐库里挑一个音频。选中后 push 到裁剪页。
struct AudioTrimPickerView: View {
    @State private var files: [URL] = []
    /// 选中要裁剪的音频（驱动 push）。
    @State private var selected: URL?

    var body: some View {
        AudioPickerList(
            sections: AudioPickerSection.flat(files),
            emptyDescription: "先在专辑里导入音频，再回来裁剪"
        ) { url in
            selected = url
        }
        .navigationTitle("选择音频")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { url in
            AudioTrimView(sourceURL: url) { reload() }
        }
        .onAppear { reload() }
    }

    private func reload() {
        files = documentsAudioURLs()
    }
}

// MARK: - 裁剪界面

struct AudioTrimView: View {
    let sourceURL: URL
    /// 导出成功后通知上层刷新列表。
    let onExported: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var duration: TimeInterval = 0
    @State private var start: TimeInterval = 0
    @State private var end: TimeInterval = 0
    /// 输入框文本与滑杆分开存：输入中途（如 "1:"）不该立刻改滑杆。
    @State private var startText = "00:00"
    @State private var endText = "00:00"
    @State private var startInvalid = false
    @State private var endInvalid = false
    /// 当前聚焦的输入框。焦点离开时才提交——输入过程中提交会让「3」被当成 3 秒，
    /// 从而把另一端挤走（输结束时间时开始时间被改坏就是这个原因）。
    @FocusState private var focusedField: TimeField?

    enum TimeField: Hashable {
        case start, end
    }

    @State private var isExporting = false
    @State private var isLoadingDuration = true
    @State private var errorMessage: String?
    @State private var toastMessage: String?

    /// 试听用的播放器（只播选中段）。
    @State private var previewPlayer: AVAudioPlayer?
    @State private var isPreviewing = false
    @State private var previewTask: Task<Void, Never>?
    /// 试听时的播放头位置（绝对时间，非 nil 表示正在试听）。
    @State private var previewTime: TimeInterval?

    private var selectedDuration: TimeInterval { max(0, end - start) }
    private var canExport: Bool {
        !isExporting && !isLoadingDuration && selectedDuration >= minimumSelection && duration > 0
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("文件") {
                    Text(sourceURL.deletingPathExtension().lastPathComponent)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("总时长") {
                    Text(isLoadingDuration ? "读取中…" : formatTrimTime(duration))
                        .monospacedDigit()
                }
            }

            Section {
                timeField("开始", text: $startText, invalid: startInvalid,
                          field: .start, commit: commitStart)
                nudgeRow(isStart: true)

                timeField("结束", text: $endText, invalid: endInvalid,
                          field: .end, commit: commitEnd)
                nudgeRow(isStart: false)

                if duration > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("开始 \(formatTrimTime(start))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $start, in: 0...max(duration, 0.1)) { editing in
                            if !editing { normalizeAfterSliderChange(movedStart: true) }
                        }
                        Text("结束 \(formatTrimTime(end))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $end, in: 0...max(duration, 0.1)) { editing in
                            if !editing { normalizeAfterSliderChange(movedStart: false) }
                        }
                    }
                }

                LabeledContent("选中时长") {
                    Text(formatTrimTime(selectedDuration))
                        .monospacedDigit()
                        .foregroundStyle(selectedDuration < minimumSelection ? .red : .primary)
                }
            } header: {
                Text("时间段")
            } footer: {
                Text("可精确到毫秒：输入 1:30.25 或用 ±0.01/±0.1/±1s 微调。滑杆用于粗定位。")
            }

            Section {
                Button {
                    togglePreview()
                } label: {
                    Label(isPreviewing ? "停止试听" : "试听选中段",
                          systemImage: isPreviewing ? "stop.fill" : "play.fill")
                }
                .disabled(selectedDuration < minimumSelection || isLoadingDuration)

                if isPreviewing {
                    previewProgress
                }

                Button {
                    export()
                } label: {
                    HStack {
                        Label("导出为新音频", systemImage: "square.and.arrow.down")
                        if isExporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canExport)
            } footer: {
                Text("导出为 M4A 存到音乐库，原文件不动。（系统不支持写 MP3，所以统一存 M4A。）")
            }
        }
        .navigationTitle("裁剪音频")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 数字键盘没有回车键，给个「完成」收键盘并触发提交。
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        // 焦点离开某个框时才把文本落成数值，避免边打字边纠正另一端。
        .onChange(of: focusedField) { previous, _ in
            switch previous {
            case .start: commitStart()
            case .end: commitEnd()
            case nil: break
            }
        }
        .task { await loadDuration() }
        .onDisappear { stopPreview() }
        .alert("裁剪失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .toast($toastMessage)
    }

    /// 试听进度：段内已播/总长 + 进度条。时间显示为段内相对时间，比绝对时间好懂。
    @ViewBuilder
    private var previewProgress: some View {
        let elapsed = max(0, (previewTime ?? start) - start)
        let total = max(selectedDuration, minimumSelection)

        VStack(spacing: 6) {
            ProgressView(value: min(elapsed, total), total: total)
                .progressViewStyle(.linear)

            HStack {
                Text(formatTrimTime(elapsed))
                Spacer()
                Text("-" + formatTrimTime(max(0, total - elapsed)))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 微调步长（秒）。0.01 足够对齐到歌词字级，1s 用于快速跨句。
    private let nudgeSteps: [TimeInterval] = [0.01, 0.1, 1]
    /// 允许的最短选段。低于这个值导出没意义，也会让 UI 显红。
    private let minimumSelection: TimeInterval = 0.01

    /// 某个端点的微调按钮行：-1s / -0.1 / -0.01 / +0.01 / +0.1 / +1s。
    @ViewBuilder
    private func nudgeRow(isStart: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(nudgeSteps.reversed(), id: \.self) { step in
                nudgeButton(isStart: isStart, delta: -step)
            }
            Divider().frame(height: 18)
            ForEach(nudgeSteps, id: \.self) { step in
                nudgeButton(isStart: isStart, delta: step)
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(isLoadingDuration || duration <= 0)
    }

    private func nudgeButton(isStart: Bool, delta: TimeInterval) -> some View {
        Button {
            nudge(isStart: isStart, by: delta)
        } label: {
            Text(nudgeLabel(delta))
                .font(.caption)
                .monospacedDigit()
                .frame(minWidth: 42)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func nudgeLabel(_ delta: TimeInterval) -> String {
        let sign = delta < 0 ? "−" : "+"
        let magnitude = abs(delta)
        if magnitude >= 1 {
            return "\(sign)\(Int(magnitude))s"
        }
        // 去掉前导 0，"0.01" → ".01"，窄屏也放得下。
        return sign + String(format: "%.2f", magnitude).replacingOccurrences(
            of: "0.", with: "."
        )
    }

    /// 微调某个端点，并保持 start < end、不越界。
    private func nudge(isStart: Bool, by delta: TimeInterval) {
        guard duration > 0 else { return }
        stopPreview()

        if isStart {
            let upperBound = max(0, end - minimumSelection)
            start = min(max(0, start + delta), upperBound)
        } else {
            let lowerBound = min(duration, start + minimumSelection)
            end = max(min(duration, end + delta), lowerBound)
        }

        startInvalid = false
        endInvalid = false
        startText = formatTrimTime(start)
        endText = formatTrimTime(end)
    }

    private func timeField(
        _ label: String,
        text: Binding<String>,
        invalid: Bool,
        field: TimeField,
        commit: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("mm:ss.SSS", text: text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .keyboardType(.numbersAndPunctuation)
                .foregroundStyle(invalid ? .red : .primary)
                .frame(maxWidth: 130)
                .focused($focusedField, equals: field)
                .onSubmit(commit)
        }
    }

    // MARK: 时长读取

    private func loadDuration() async {
        let asset = AVURLAsset(url: sourceURL)
        do {
            let loaded = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(loaded)
            guard seconds.isFinite, seconds > 0 else {
                errorMessage = "无法读取音频时长，文件可能已损坏"
                isLoadingDuration = false
                return
            }
            duration = seconds
            start = 0
            end = seconds
            startText = formatTrimTime(0)
            endText = formatTrimTime(seconds)
            isLoadingDuration = false
        } catch {
            errorMessage = "无法读取音频：\(error.localizedDescription)"
            isLoadingDuration = false
        }
    }

    // MARK: 输入框 ↔ 滑杆同步

    /// 提交「开始」输入。你敲的值优先保留；只有当它越过结束时间时才把结束往后推。
    private func commitStart() {
        guard let parsed = parseTimeInput(startText) else {
            startInvalid = true
            return
        }
        startInvalid = false
        guard duration > 0 else { return }

        // 留出最短选段的余量，保证 start 后面至少还能放下一个 minimumSelection。
        start = min(max(0, parsed), max(0, duration - minimumSelection))
        if end < start + minimumSelection {
            end = min(duration, start + minimumSelection)
        }
        startText = formatTrimTime(start)
        endText = formatTrimTime(end)
        stopPreview()
    }

    /// 提交「结束」输入。同理：优先保留你敲的值，必要时才把开始往前挪。
    private func commitEnd() {
        guard let parsed = parseTimeInput(endText) else {
            endInvalid = true
            return
        }
        endInvalid = false
        guard duration > 0 else { return }

        end = min(max(minimumSelection, parsed), duration)
        if start > end - minimumSelection {
            start = max(0, end - minimumSelection)
        }
        startText = formatTrimTime(start)
        endText = formatTrimTime(end)
        stopPreview()
    }

    /// 拖完滑杆后保证 start < end，并回写输入框。
    private func normalizeAfterSliderChange(movedStart: Bool) {
        if movedStart, start >= end {
            end = min(duration, start + minimumSelection)
            if end <= start { start = max(0, end - minimumSelection) }
        } else if !movedStart, end <= start {
            start = max(0, end - minimumSelection)
            if start >= end { end = min(duration, start + minimumSelection) }
        }
        startInvalid = false
        endInvalid = false
        startText = formatTrimTime(start)
        endText = formatTrimTime(end)
        stopPreview()
    }

    // MARK: 试听

    private func togglePreview() {
        if isPreviewing {
            stopPreview()
        } else {
            startPreview()
        }
    }

    private func startPreview() {
        stopPreview()
        do {
            let player = try AVAudioPlayer(contentsOf: sourceURL)
            player.currentTime = start
            player.prepareToPlay()
            player.play()
            previewPlayer = player
            isPreviewing = true
            previewTime = start

            // AVAudioPlayer 没有区间播放能力，自己轮询播放头：既驱动进度条，
            // 也负责到选中段末尾时停下。20ms 一次，进度条看着是连续的。
            let stopAt = end
            previewTask = Task { @MainActor in
                while !Task.isCancelled {
                    guard let player = previewPlayer, player.isPlaying else { break }
                    previewTime = player.currentTime
                    if player.currentTime >= stopAt { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard !Task.isCancelled else { return }
                stopPreview()
            }
        } catch {
            errorMessage = "无法试听：\(error.localizedDescription)"
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewing = false
        previewTime = nil
    }

    // MARK: 导出

    private func export() {
        guard canExport else { return }
        stopPreview()
        isExporting = true

        let base = sourceURL.deletingPathExtension().lastPathComponent
        // 文件名用秒级（毫秒会让名字太长），冒号在文件名里也不合适。
        let name = "\(base) 片段 \(formatTrimTimeShort(start))-\(formatTrimTimeShort(end))"
            .replacingOccurrences(of: ":", with: "")
        let from = start
        let to = end

        Task { @MainActor in
            do {
                let url = try await trimAudio(
                    from: sourceURL, start: from, end: to, outputBaseName: name
                )
                isExporting = false
                toastMessage = "已保存「\(url.deletingPathExtension().lastPathComponent)」"
                onExported()
            } catch {
                isExporting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
