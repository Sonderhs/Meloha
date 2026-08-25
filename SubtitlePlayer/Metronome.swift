//
//  Metronome.swift
//  SubtitlePlayer
//
//  小工具页里的节拍器：可调 BPM 与每小节拍数，第一拍重音。
//  节拍声默认由 AVAudioEngine 程序生成（正弦爆破音 + 快速衰减），也可由用户上传音频替换；
//  计时用高优先级 DispatchSourceTimer（比 Timer 抖动小）。
//

import SwiftUI
import AVFoundation
import Combine

// MARK: - 节拍器引擎

/// 非 @MainActor：计时回调在后台队列执行，@Published 更新统一切回主线程。
final class Metronome: ObservableObject {
    /// 每分钟拍数。取值范围（40–240）由 UI 侧限制（滑杆/加减按钮均已夹取）。
    /// ⚠️ 不要在 didSet 里回写 bpm 自身做夹取——那会再次触发 didSet 造成无限递归而闪退。
    @Published var bpm: Int = 100 {
        didSet {
            if isRunning && bpm != oldValue { rescheduleTimer(firstBeatNow: false) }
        }
    }
    /// 每小节拍数（1–8，由 Stepper 限定范围），第一拍重音。
    @Published var beatsPerBar: Int = 4 {
        didSet {
            // 镜像到加锁存储供后台计时回调读取（别在这里回写 beatsPerBar 自身，会无限递归）。
            stateLock.withLock { beatsPerBarStorage = beatsPerBar }
        }
    }
    @Published private(set) var isRunning = false
    /// 当前处在小节里的第几拍（0 起），供界面点亮节拍点。
    @Published private(set) var currentBeat = 0
    /// 自定义节拍声的显示名（来源文件的原名，如「Hotel California」）；nil 表示用内置咔哒声。
    /// 注意与磁盘上的存储名区分：存储名固定是 `click.<ext>`，不适合展示。
    @Published private(set) var customSoundName: String?

    var hasCustomSound: Bool { customSoundName != nil }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// 播放节点固定用这个格式连接；所有 buffer（内置或自定义转换后）都必须是它，否则调度会崩。
    private let clickFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    /// 保护下面这三个跨线程共享的值：主线程写（换音效、改拍数），timerQueue 上的 fire() 读。
    private let stateLock = NSLock()
    private var accentBuffer: AVAudioPCMBuffer?
    private var normalBuffer: AVAudioPCMBuffer?
    /// beatsPerBar 的加锁镜像（@Published 本身不是线程安全的，后台不能直接读）。
    private var beatsPerBarStorage = 4
    private var engineReady = false

    private let timerQueue = DispatchQueue(label: "com.hansen.SubtitlePlayer.metronome", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var beatCounter = 0

    private static let soundKey = "metronomeCustomSoundFile"
    /// 单独存显示名：存储名固定 click.<ext>，展示出来看不出是哪首歌。
    private static let soundDisplayNameKey = "metronomeCustomSoundDisplayName"

    init() {
        loadDefaultClicks()
        // 恢复上次设定的自定义音效（若文件仍在且能解码）。
        if let name = UserDefaults.standard.string(forKey: Self.soundKey),
           let url = Self.soundDirectory()?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: url.path),
           applyCustomSound(from: url) {
            customSoundName = UserDefaults.standard.string(forKey: Self.soundDisplayNameKey) ?? name
        }
    }

    // MARK: 播放控制

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        setupEngineIfNeeded()
        // 确保音频会话激活（可能此前没有播放过歌曲，会话处于未激活态）。
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        beatCounter = 0
        currentBeat = 0
        isRunning = true
        rescheduleTimer(firstBeatNow: true)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        player.stop()
        engine.stop()
        isRunning = false
        currentBeat = 0
    }

    deinit {
        timer?.cancel()
        engine.stop()
    }

    // MARK: 音效设定

    /// 用所选音频作为节拍声。成功返回 true；解码失败（格式不支持等）返回 false 且不改变现状。
    func setCustomSound(from pickedURL: URL) -> Bool {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        // 先确认可解码，避免存了个用不了的文件。
        guard (try? AVAudioFile(forReading: pickedURL)) != nil,
              let dir = Self.soundDirectory() else {
            return false
        }

        // 清掉旧的自定义文件，拷入 App Support（固定名 click.<ext>，不进 Documents 免得混入音乐库）。
        if let old = UserDefaults.standard.string(forKey: Self.soundKey) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
        }
        let ext = pickedURL.pathExtension.isEmpty ? "caf" : pickedURL.pathExtension
        let destName = "click." + ext
        let dest = dir.appendingPathComponent(destName)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: pickedURL, to: dest)
        } catch {
            return false
        }

        guard applyCustomSound(from: dest) else {
            try? FileManager.default.removeItem(at: dest)
            return false
        }
        UserDefaults.standard.set(destName, forKey: Self.soundKey)
        // 显示用来源原名（去扩展名），从音乐库选时就能看出是哪首歌。
        let display = pickedURL.deletingPathExtension().lastPathComponent
        UserDefaults.standard.set(display, forKey: Self.soundDisplayNameKey)
        customSoundName = display
        return true
    }

    /// 恢复内置咔哒声。
    func resetSound() {
        if let old = UserDefaults.standard.string(forKey: Self.soundKey),
           let dir = Self.soundDirectory() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
        }
        UserDefaults.standard.removeObject(forKey: Self.soundKey)
        UserDefaults.standard.removeObject(forKey: Self.soundDisplayNameKey)
        customSoundName = nil
        loadDefaultClicks()
    }

    // MARK: 引擎 / 计时

    private func setupEngineIfNeeded() {
        guard !engineReady else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: clickFormat)
        engine.prepare()
        engineReady = true
    }

    /// 按当前 BPM 重排计时器。firstBeatNow 为 true 时立刻响第一拍（用于开始）。
    private func rescheduleTimer(firstBeatNow: Bool) {
        timer?.cancel()
        let interval = 60.0 / Double(max(1, bpm))
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: firstBeatNow ? .now() : .now() + interval,
                   repeating: interval,
                   leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.fire() }
        timer = t
        t.resume()
    }

    /// 计时回调（timerQueue）：播放对应的节拍声并更新当前拍。
    /// 用 .interrupts 调度，避免自定义音效较长时在快速节拍下叠加。
    ///
    /// buffer 与拍数经 `stateLock` 读取：运行中也允许更换节拍声（setCustomSound/resetSound
    /// 在主线程写），不加锁的话后台队列可能读到半更新的一对 buffer。
    private func fire() {
        let (perBar, accent, normal) = stateLock.withLock {
            (max(1, beatsPerBarStorage), accentBuffer, normalBuffer)
        }
        let beatInBar = beatCounter % perBar
        let buffer = beatInBar == 0 ? accent : normal
        if let buffer, player.isPlaying {
            player.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        }
        beatCounter += 1
        DispatchQueue.main.async { [weak self] in
            self?.currentBeat = beatInBar
        }
    }

    // MARK: buffer 构建

    private func loadDefaultClicks() {
        let accent = Self.makeClick(frequency: 1_500, format: clickFormat)
        let normal = Self.makeClick(frequency: 1_000, format: clickFormat)
        stateLock.withLock {
            accentBuffer = accent
            normalBuffer = normal
        }
    }

    /// 读取音频文件 → 转成 clickFormat → 重拍用原音量、其余拍稍轻。成功返回 true。
    private func applyCustomSound(from url: URL) -> Bool {
        guard let full = Self.loadBuffer(from: url, to: clickFormat) else { return false }
        let quiet = Self.scaled(full, by: 0.6)
        // 两个 buffer 一起换，避免 fire() 读到「新重拍 + 旧普通拍」的混搭。
        stateLock.withLock {
            accentBuffer = full
            normalBuffer = quiet
        }
        return true
    }

    /// 把任意音频文件解码并转换成目标格式的一段 PCM buffer。
    /// 只取开头 `maxSeconds` 秒：节拍声是短音，而用户可能从音乐库选一首几分钟的歌，
    /// 整首解码成 PCM 会吃掉几十 MB 内存，而且每拍都被 `.interrupts` 打断根本听不完。
    private static func loadBuffer(
        from url: URL,
        to format: AVAudioFormat,
        maxSeconds: Double = 2.0
    ) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        let limit = AVAudioFrameCount(min(
            Double(file.length),
            inFormat.sampleRate * maxSeconds
        ))
        guard limit > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: limit) else {
            return nil
        }
        do { try file.read(into: inBuffer, frameCount: limit) } catch { return nil }
        if inFormat == format { return inBuffer }

        guard let converter = AVAudioConverter(from: inFormat, to: format) else { return nil }
        let ratio = format.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(limit) * ratio) + 4_096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inStatus in
            if fed {
                inStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return inBuffer
        }
        return status == .error ? nil : outBuffer
    }

    /// 按增益缩放一段 buffer（用于把重拍音效调轻作为普通拍）。
    private static func scaled(_ buffer: AVAudioPCMBuffer, by gain: Float) -> AVAudioPCMBuffer {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData,
              let dst = out.floatChannelData else {
            return buffer
        }
        out.frameLength = buffer.frameLength
        for ch in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) {
                dst[ch][i] = src[ch][i] * gain
            }
        }
        return out
    }

    /// 生成一段短促的「咔哒」声：正弦音 + 指数衰减包络。
    private static func makeClick(frequency: Double,
                                  format: AVAudioFormat,
                                  duration: Double = 0.05) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-30.0 * t)                       // 快速衰减，听感干脆
            channel[i] = Float(sin(2.0 * .pi * frequency * t) * envelope) * 0.9
        }
        return buffer
    }

    /// 自定义节拍声的存放目录：App Support/metronome（不放 Documents，避免出现在音乐库）。
    private static func soundDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("metronome", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
                return nil
            }
        }
        return dir
    }
}

// MARK: - 节拍器界面

struct MetronomeView: View {
    @StateObject private var metronome = Metronome()
    @State private var showSoundPicker = false
    @State private var showLibraryPicker = false
    @State private var showSoundError = false

    var body: some View {
        VStack(spacing: 24) {
            // 节拍点：运行时点亮当前拍，第一拍用橙色重音。
            HStack(spacing: 14) {
                ForEach(0..<metronome.beatsPerBar, id: \.self) { index in
                    Circle()
                        .fill(beatColor(index))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(height: 24)
            .animation(.easeOut(duration: 0.08), value: metronome.currentBeat)

            VStack(spacing: 2) {
                Text("\(metronome.bpm)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("BPM")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Button {
                    metronome.bpm = max(40, metronome.bpm - 1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                Slider(
                    value: Binding(get: { Double(metronome.bpm) },
                                   set: { metronome.bpm = Int($0.rounded()) }),
                    in: 40...240,
                    step: 1
                )
                Button {
                    metronome.bpm = min(240, metronome.bpm + 1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .font(.title2)
            .buttonStyle(.plain)

            Stepper("每小节 \(metronome.beatsPerBar) 拍", value: $metronome.beatsPerBar, in: 1...8)

            // 节拍声：默认内置咔哒声，可上传音频替换。
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                    Text(metronome.customSoundName ?? "内置咔哒声")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Menu {
                        Button {
                            showLibraryPicker = true
                        } label: {
                            Label("从音乐库选择", systemImage: "music.note.list")
                        }
                        Button {
                            showSoundPicker = true
                        } label: {
                            Label("从文件上传", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("更换节拍声", systemImage: "speaker.badge.exclamationmark")
                    }
                    .buttonStyle(.bordered)

                    if metronome.hasCustomSound {
                        Button(role: .destructive) {
                            metronome.resetSound()
                        } label: {
                            Label("恢复默认", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.callout)
            }

            Button {
                metronome.toggle()
            } label: {
                Label(metronome.isRunning ? "停止" : "开始",
                      systemImage: metronome.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(metronome.isRunning ? .red : .accentColor)

            Spacer()
        }
        .padding(24)
        .navigationTitle("节拍器")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { metronome.stop() }
        .sheet(isPresented: $showSoundPicker) {
            AudioDocumentPicker(isPresented: $showSoundPicker) { urls in
                guard let url = urls.first else { return }
                if !metronome.setCustomSound(from: url) {
                    showSoundError = true
                }
            }
        }
        // 从音乐库选：与上面的 .sheet 分开挂，同节点叠多个 presentation 会互相顶掉。
        .background(
            Color.clear.sheet(isPresented: $showLibraryPicker) {
                MetronomeSoundLibraryPicker { url in
                    if !metronome.setCustomSound(from: url) {
                        showSoundError = true
                    }
                }
            }
        )
        // alert 与上面的 .sheet 不能叠在同一节点（会互相顶掉），挂到独立的 Color.clear 节点。
        .background(
            Color.clear.alert("无法使用该音频", isPresented: $showSoundError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请选择常见音频格式（如 m4a / wav / mp3 / caf）。")
            }
        )
    }

    private func beatColor(_ index: Int) -> Color {
        if metronome.isRunning && index == metronome.currentBeat {
            return index == 0 ? .orange : .accentColor
        }
        return .secondary.opacity(0.3)
    }
}

// MARK: - 从音乐库选节拍声

/// 从已导入的音频里挑一个当节拍声。按专辑分组显示，也可以直接搜。
/// 只取音频开头两秒（见 `Metronome.loadBuffer`），所以选整首歌也不会占大内存。
struct MetronomeSoundLibraryPicker: View {
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var albumStore = AlbumStore()

    var body: some View {
        NavigationStack {
            AudioPickerList(
                sections: AudioPickerSection.grouped(by: albumStore),
                emptyDescription: "先在专辑里导入音频，再回来选节拍声"
            ) { url in
                onPick(url)
                dismiss()
            }
            .navigationTitle("选节拍声")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("只会用音频开头约 2 秒作为节拍声。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }
}
