//
//  ContentView.swift
//  SubtitlePlayer
//
//  Created by Hansen on 2026/7/15.
//

import SwiftUI
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

struct SubtitleLine {
    let time: TimeInterval
    let endTime: TimeInterval?
    let text: String

    init(time: TimeInterval, endTime: TimeInterval? = nil, text: String) {
        self.time = time
        self.endTime = endTime
        self.text = text
    }
}

struct ContentView: View {
    @State private var isPlaying = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playerMessage = "正在准备测试音频…"
    @State private var subtitles: [SubtitleLine] = []
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var showSubtitleImporter = false
    @State private var isPlayerMinimized = true
    @State private var currentAudioURL: URL?
    @State private var subtitleStatus = "正在准备字幕…"
    @State private var artwork: UIImage?
    /// 从专辑播放时的封面兜底（音频无内嵌封面时使用）。
    @State private var albumFallbackCover: UIImage?
    @State private var didConfigureAudioServices = false
    /// 字幕时间偏移（秒）。正值表示字幕延后显示，负值表示提前。
    @State private var subtitleOffset: TimeInterval = 0
    /// 当前播放队列及正在播放的索引，用于上/下一曲与自动连播。
    @State private var playlist: [URL] = []
    @State private var currentIndex: Int?
    @StateObject private var pipController = SubtitlePiPController()
    @StateObject private var albumStore = AlbumStore()
    @StateObject private var backgroundStore = BackgroundStore()
    /// 允许与其他应用同时播放（混音）。
    @AppStorage("allowMixWithOthers") private var mixWithOthers = false
    /// 外观主题（跟随系统 / 浅色 / 深色）。
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    /// 背景图不透明度（0~1，越小越透）。
    @AppStorage("backgroundOpacity") private var backgroundOpacity: Double = 0.6
    /// 播放速度。
    @AppStorage("playbackRate") private var playbackRate: Double = 1.0
    /// 播放模式（顺序/列表循环/单曲循环/随机）。
    @AppStorage("playMode") private var playMode: PlayMode = .sequential
    /// 字幕外观。
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 17
    @AppStorage("subtitleColor") private var subtitleColor: SubtitleColorChoice = .standard
    @AppStorage("subtitleLineCount") private var subtitleLineCount: Int = 3
    /// 睡眠定时器结束时间（nil 表示未开启）。
    @State private var sleepTimerEnd: Date?
    /// 上一拍仍在播放时的进度，用于可靠判断"自然播完"（AVAudioPlayer 播完会重置 currentTime）。
    @State private var lastPlayingTime: TimeInterval = 0
    /// 是否显示整篇歌词页。
    @State private var showLyrics = false
    /// 是否显示当前播放列表。
    @State private var showQueue = false
    /// 顶部轻提示。
    @State private var toastMessage: String?

    private var canGoPrevious: Bool {
        guard currentIndex != nil, !playlist.isEmpty else { return false }
        if playMode == .sequential {
            return (currentIndex ?? 0) > 0
        }
        return playlist.count > 1
    }

    private var canGoNext: Bool {
        guard let currentIndex, !playlist.isEmpty else { return false }
        if playMode == .sequential {
            return currentIndex < playlist.count - 1
        }
        return playlist.count > 1
    }

    private var currentSubtitle: String {
        // 用偏移后的有效时间匹配字幕：正偏移让字幕更晚出现。
        let effectiveTime = currentTime - subtitleOffset
        guard let line = subtitles.last(where: { $0.time <= effectiveTime }) else {
            return "等待字幕…"
        }

        // SRT 字幕有明确的结束时间，超过后进入间隙则清空显示。
        // LRC 没有结束时间（endTime 为 nil），保持显示直到下一句。
        if let endTime = line.endTime, effectiveTime > endTime {
            return "♪"
        }

        return line.text
    }

    /// 当前生效的字幕行索引（考虑偏移）。
    private var currentLineIndex: Int? {
        let effectiveTime = currentTime - subtitleOffset
        return subtitles.lastIndex(where: { $0.time <= effectiveTime })
    }

    /// 歌词式字幕：以当前句为中心显示若干行（1/3/5），当前句高亮。
    /// 切换时每一行各自小幅上滚淡入淡出，而不是整块字幕框移动。
    private var subtitleBox: some View {
        let index = currentLineIndex
        let half = max(0, subtitleLineCount / 2)
        let lineTransition = AnyTransition.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )

        return VStack(spacing: 6) {
            ForEach(Array(-half...half), id: \.self) { offset in
                let text = subtitleLineText(offset: offset, base: index)
                subtitleLine(text, prominent: offset == 0)
                    .id("line-\(offset)-\(text)")
                    .transition(lineTransition)
            }
        }
        .frame(maxWidth: .infinity, minHeight: subtitleBoxMinHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .clipped()
        .animation(.easeInOut(duration: 0.28), value: index)
    }

    /// 取相对当前句 offset 处的字幕文本；越界返回空占位，当前句无字幕返回提示。
    private func subtitleLineText(offset: Int, base: Int?) -> String {
        guard let base else {
            return offset == 0 ? "等待字幕…" : " "
        }
        let lineIndex = base + offset
        guard subtitles.indices.contains(lineIndex) else {
            return " "
        }
        let text = subtitles[lineIndex].text
        return text.isEmpty ? "♪" : text
    }

    private var subtitleBoxMinHeight: CGFloat {
        let current = CGFloat(subtitleFontSize) * 1.6
        let sides = CGFloat(subtitleLineCount - 1) * CGFloat(subtitleFontSize) * 0.95
        return current + sides + 12
    }

    private func subtitleLine(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(.system(size: prominent ? subtitleFontSize : subtitleFontSize * 0.8))
            .fontWeight(prominent ? .semibold : .regular)
            .foregroundStyle(prominent ? (subtitleColor.color ?? Color.primary) : Color.secondary)
            .lineLimit(prominent ? 2 : 1)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    var body: some View {
        ZStack {
            if isPlayerMinimized {
                AudioFilesView(albumStore: albumStore, backgroundStore: backgroundStore, showsDoneButton: false) { urls, index, cover in
                    playTrack(at: index, in: urls, fallbackCover: cover)
                    withAnimation(.easeInOut) {
                        isPlayerMinimized = false
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    miniPlayerBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
                .transition(.opacity)
            } else {
                playerView
                    .padding()
                    .transition(.move(edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // 播放器界面的背景图（音乐库由 AudioFilesView 自行绘制）。
            if !isPlayerMinimized, let background = backgroundStore.image {
                Image(uiImage: background)
                    .resizable()
                    .scaledToFill()
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .topLeading) {
            // PiP 源图层：始终留在视图层级并持续渲染，不随播放器收起而销毁，
            // 否则画中画会失去内容源、控件失效。1×1、透明、不挡点击。
            if pipController.isSupported {
                SubtitlePiPHostView(controller: pipController)
                    .frame(width: 1, height: 1)
                    .opacity(0.02)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut, value: isPlayerMinimized)
        .onAppear {
            if !didConfigureAudioServices {
                didConfigureAudioServices = true
                configureAudioSession()
                setupRemoteCommandCenter()
                pipController.onSetPlaying = { playing in
                    if playing {
                        play()
                    } else {
                        pause()
                    }
                }
                pipController.onSkip = { seconds in
                    skip(by: seconds)
                }
            }
            copyBundledDemoToDocuments()
            loadDemoAudio()
            pipController.setAppearance(textColor: subtitleColor.uiColor, fontScale: CGFloat(subtitleFontSize / 17))
            pipController.update(text: currentSubtitle)
        }
        .onChange(of: currentSubtitle) { _, newText in
            pipController.update(text: newText)
        }
        .onChange(of: subtitleColor) { _, _ in
            pipController.setAppearance(textColor: subtitleColor.uiColor, fontScale: CGFloat(subtitleFontSize / 17))
        }
        .onChange(of: subtitleFontSize) { _, _ in
            pipController.setAppearance(textColor: subtitleColor.uiColor, fontScale: CGFloat(subtitleFontSize / 17))
        }
        .onChange(of: mixWithOthers) { _, _ in
            configureAudioSession()
        }
        .onChange(of: playbackRate) { _, newRate in
            if isPlaying {
                audioPlayer?.rate = Float(newRate)
            }
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            // 睡眠定时器到点则暂停。
            if let end = sleepTimerEnd, Date() >= end {
                sleepTimerEnd = nil
                pause()
            }

            guard let audioPlayer else {
                return
            }

            currentTime = audioPlayer.currentTime

            // 播放状态变化（如自然播完）时同步锁屏信息。
            let playing = audioPlayer.isPlaying
            if playing != isPlaying {
                isPlaying = playing
                updateNowPlayingInfo()
                pipController.setPlaybackState(playing: playing)

                // 自然播放结束：上一拍还在播、且已接近片尾 → 按播放模式连播。
                // （AVAudioPlayer 播完会把 currentTime 重置，故用上一拍的进度判断。）
                if !playing, duration > 0, lastPlayingTime >= duration - 0.6 {
                    handleTrackFinished()
                }
            }

            if audioPlayer.isPlaying {
                lastPlayingTime = audioPlayer.currentTime
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
        .sheet(isPresented: $showLyrics) {
            LyricsView(subtitles: subtitles, currentIndex: currentLineIndex) { time in
                // line.time 是原始字幕时间；换算回播放时间需加上偏移。
                seek(to: time + subtitleOffset)
            }
        }
        .sheet(isPresented: $showQueue) {
            PlaylistQueueView(tracks: playlist, currentIndex: currentIndex) { index in
                playInCurrentPlaylist(index: index)
            }
        }
        .onOpenURL { url in
            importIncomingFile(url)
        }
        .toast($toastMessage)
    }

    private var playerView: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut) {
                        isPlayerMinimized = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3)
                }
                .accessibilityLabel("收起播放器")

                Spacer()
            }
            .padding(.bottom, 8)

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 0)

                        // 音频封面（无内嵌封面时用占位图）。
                        Group {
                            if let artwork {
                                Image(uiImage: artwork)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "music.note")
                                    .font(.system(size: 64))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .frame(width: 200, height: 200)
                        .background(.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        Text(playerMessage)
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        subtitleBox
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showLyrics = true
                            }

                        subtitleOffsetControls

                        VStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { currentTime },
                                    set: { seek(to: $0) }
                                ),
                                in: 0...max(duration, 1)
                            )

                            HStack {
                                Text(timeText(currentTime))
                                Spacer()
                                Text(timeText(duration))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        playbackControls

                        secondaryControls

                        Spacer(minLength: 0)
                            .frame(height: 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .bottom)
                }
            }
        }
    }

    private var miniPlayerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playerMessage)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(currentSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut) {
                    isPlayerMinimized = false
                }
            }

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }

            Button {
                withAnimation(.easeInOut) {
                    isPlayerMinimized = false
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var playbackControls: some View {
        HStack(spacing: 24) {
            Button {
                previousTrack()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
            }
            .disabled(!canGoPrevious)
            .accessibilityLabel("上一曲")

            Button {
                skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title)
            }
            .accessibilityLabel("快退 15 秒")

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .accessibilityLabel(isPlaying ? "暂停" : "播放")

            Button {
                skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.title)
            }
            .accessibilityLabel("快进 15 秒")

            Button {
                nextTrack()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title2)
            }
            .disabled(!canGoNext)
            .accessibilityLabel("下一曲")
        }
    }

    /// 播放模式 / 速度 / 睡眠定时器。
    private var secondaryControls: some View {
        HStack(spacing: 0) {
            Button {
                playMode = playMode.next
            } label: {
                Image(systemName: playMode.icon)
                    .font(.title3)
                    .foregroundStyle(playMode == .sequential ? Color.secondary : Color.accentColor)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("播放模式：\(playMode.label)")

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        playbackRate = rate
                    } label: {
                        if playbackRate == rate {
                            Label(speedLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(rate))
                        }
                    }
                }
            } label: {
                Text(speedLabel(playbackRate))
                    .font(.subheadline)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("播放速度 \(speedLabel(playbackRate))")

            Menu {
                Button("关闭") { sleepTimerEnd = nil }
                ForEach([15, 30, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) 分钟") {
                        sleepTimerEnd = Date().addingTimeInterval(Double(minutes) * 60)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: sleepTimerEnd == nil ? "moon.zzz" : "moon.zzz.fill")
                        .foregroundStyle(sleepTimerEnd == nil ? Color.secondary : Color.accentColor)
                    if let remaining = sleepRemainingMinutes {
                        Text("\(remaining)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("睡眠定时器")
        }
        .buttonStyle(.plain)
    }

    private func speedLabel(_ rate: Double) -> String {
        "\(String(format: "%g", rate))×"
    }

    private var sleepRemainingMinutes: Int? {
        guard let end = sleepTimerEnd else { return nil }
        let remaining = end.timeIntervalSinceNow
        return remaining > 0 ? Int(ceil(remaining / 60)) : nil
    }

    private var subtitleOffsetControls: some View {
        HStack(spacing: 0) {
            Menu {
                Button("字幕提前 1s") { adjustSubtitleOffset(by: -1) }
                Button("字幕提前 0.5s") { adjustSubtitleOffset(by: -0.5) }
                Button("字幕延后 0.5s") { adjustSubtitleOffset(by: 0.5) }
                Button("字幕延后 1s") { adjustSubtitleOffset(by: 1) }
                Divider()
                Button("字幕偏移归零") { subtitleOffset = 0 }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(offsetText)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("字幕偏移 \(offsetText)")

            Button {
                showQueue = true
            } label: {
                Image(systemName: "music.note.list")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("播放列表")

            Button {
                showSubtitleImporter = true
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("导入字幕 (LRC/SRT/VTT)")
            .fileImporter(
                isPresented: $showSubtitleImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "lrc") ?? .plainText,
                    UTType(filenameExtension: "srt") ?? .plainText,
                    UTType(filenameExtension: "vtt") ?? .plainText
                ],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        importSubtitle(from: url)
                    }
                    if !urls.isEmpty {
                        toastMessage = "已导入 \(urls.count) 个字幕"
                    }
                case .failure:
                    subtitleStatus = "导入字幕失败"
                }
            }

            if pipController.isSupported {
                Button {
                    pipController.toggle()
                } label: {
                    Image(systemName: pipController.isActive ? "pip.exit" : "pip.enter")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(pipController.isActive ? "关闭画中画" : "开启画中画字幕")
            }
        }
        .buttonStyle(.plain)
    }

    /// 字幕偏移的显示文本，如 "+1.5s" / "-0.5s" / "0.0s"。
    private var offsetText: String {
        let sign = subtitleOffset > 0 ? "+" : (subtitleOffset < 0 ? "-" : "")
        return String(format: "%@%.1fs", sign, abs(subtitleOffset))
    }

    /// 按步长调整字幕偏移，并规整到 0.1s 精度避免浮点误差累积。
    private func adjustSubtitleOffset(by delta: TimeInterval) {
        subtitleOffset = ((subtitleOffset + delta) * 10).rounded() / 10
    }

    private func loadDemoAudio() {
        let documentsDemoURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("demo.wav")
        let audioURL = documentsDemoURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? url : nil
        } ?? Bundle.main.url(forResource: "demo", withExtension: "wav")

        guard let audioURL else {
            playerMessage = "找不到 demo.wav"
            return
        }

        playlist = [audioURL]
        currentIndex = 0
        loadAudio(from: audioURL)
    }

    private func copyBundledDemoToDocuments() {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let filesToCopy = [
            ("demo", "wav"),
            ("demo", "lrc")
        ]

        for (name, fileExtension) in filesToCopy {
            guard let sourceURL = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
                continue
            }

            let destinationURL = documentsURL
                .appendingPathComponent(name)
                .appendingPathExtension(fileExtension)

            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        }
    }

    private func loadAudio(from url: URL) {
        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.enableRate = true
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0
            currentTime = 0
            isPlaying = false
            currentAudioURL = url
            playerMessage = url.lastPathComponent
            loadMatchingSubtitle(for: url)
            loadArtwork(for: url)
            updateNowPlayingInfo()
        } catch {
            playerMessage = "无法打开音频"
        }
    }

    /// 异步读取音频内嵌封面；无内嵌封面时用专辑封面兜底（界面显示占位图）。
    private func loadArtwork(for url: URL) {
        artwork = albumFallbackCover
        let asset = AVURLAsset(url: url)
        Task { @MainActor in
            guard let metadata = try? await asset.load(.commonMetadata) else {
                return
            }
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue),
                   let image = UIImage(data: data) {
                    // 期间可能已切歌，确认仍是当前音频再更新。
                    guard currentAudioURL == url else { return }
                    artwork = image
                    updateNowPlayingInfo()
                    return
                }
            }
        }
    }

    /// 处理由其他 App /「文件」分享或「用…打开」传入的文件（音频或字幕）。
    private func importIncomingFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ext = url.pathExtension.lowercased()
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "aiff"]
        let subtitleExtensions = ["lrc", "srt", "vtt"]
        guard audioExtensions.contains(ext) || subtitleExtensions.contains(ext) else {
            return
        }

        guard let documentsURL = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return
        }

        let destinationURL = uniqueFileURL(in: documentsURL, fileName: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: destinationURL)
        } catch {
            return
        }

        if audioExtensions.contains(ext) {
            // 音频：直接作为单曲队列播放。
            playTrack(at: 0, in: [destinationURL])
            withAnimation(.easeInOut) {
                isPlayerMinimized = false
            }
            toastMessage = "已导入并播放"
        } else if let currentAudioURL,
                  currentAudioURL.deletingPathExtension().lastPathComponent
                    == destinationURL.deletingPathExtension().lastPathComponent {
            // 字幕：与当前播放的音频同名则立即加载。
            loadSubtitle(from: destinationURL)
            toastMessage = "已导入字幕"
        } else {
            toastMessage = "已导入字幕"
        }
    }

    private func importSubtitle(from sourceURL: URL) {
        let canAccessFile = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if canAccessFile {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let destinationURL = uniqueFileURL(
                in: documentsURL,
                fileName: sourceURL.lastPathComponent
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            if let currentAudioURL,
               currentAudioURL.deletingPathExtension().lastPathComponent == sourceURL.deletingPathExtension().lastPathComponent {
                loadSubtitle(from: destinationURL)
            } else {
                subtitleStatus = "字幕已导入；载入同名音频时会自动匹配"
            }
        } catch {
            subtitleStatus = "无法导入字幕"
        }
    }

    private func uniqueFileURL(in folder: URL, fileName: String) -> URL {
        let originalURL = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return originalURL
        }

        let fileExtension = originalURL.pathExtension
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        var number = 2
        var candidateURL = originalURL

        while FileManager.default.fileExists(atPath: candidateURL.path) {
            let newName = "\(baseName) \(number)"
            candidateURL = folder
                .appendingPathComponent(newName)
                .appendingPathExtension(fileExtension)
            number += 1
        }

        return candidateURL
    }

    private func togglePlayback() {
        guard let audioPlayer else {
            return
        }

        if audioPlayer.isPlaying {
            pause()
        } else {
            play()
        }
    }

    private func play() {
        guard let audioPlayer else {
            return
        }

        if audioPlayer.currentTime >= audioPlayer.duration {
            seek(to: 0)
        }
        audioPlayer.play()
        audioPlayer.rate = Float(playbackRate)
        isPlaying = true
        updateNowPlayingInfo()
        pipController.setPlaybackState(playing: true)
    }

    private func pause() {
        audioPlayer?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        pipController.setPlaybackState(playing: false)
    }

    // MARK: - 播放队列与上/下一曲

    /// 以给定队列从指定索引开始播放。fallbackCover 为专辑封面（音频无内嵌封面时兜底）。
    private func playTrack(at index: Int, in urls: [URL], fallbackCover: UIImage? = nil) {
        guard urls.indices.contains(index) else {
            return
        }
        albumFallbackCover = fallbackCover
        playlist = urls
        currentIndex = index
        loadAudio(from: urls[index])
        play()
    }

    /// 在当前播放队列内跳到指定曲目（保持队列与专辑封面兜底不变）。
    private func playInCurrentPlaylist(index: Int) {        guard playlist.indices.contains(index) else {
            return
        }
        currentIndex = index
        loadAudio(from: playlist[index])
        play()
    }

    private func nextTrack() {
        if playMode == .shuffle {
            playRandomTrack()
        } else {
            advanceToNext(wrap: playMode != .sequential)
        }
    }

    private func previousTrack() {
        if playMode == .shuffle {
            playRandomTrack()
            return
        }
        guard let currentIndex, !playlist.isEmpty else {
            return
        }
        var previousIndex = currentIndex - 1
        if previousIndex < 0 {
            if playMode == .sequential { return }
            previousIndex = playlist.count - 1
        }
        self.currentIndex = previousIndex
        loadAudio(from: playlist[previousIndex])
        play()
    }

    /// 前进到下一曲；wrap 为 true 时到末尾回到开头。
    private func advanceToNext(wrap: Bool) {
        guard let currentIndex, !playlist.isEmpty else {
            return
        }
        var nextIndex = currentIndex + 1
        if nextIndex >= playlist.count {
            guard wrap else { return }
            nextIndex = 0
        }
        self.currentIndex = nextIndex
        loadAudio(from: playlist[nextIndex])
        play()
    }

    /// 随机播放一首（尽量与当前不同）。
    private func playRandomTrack() {
        guard !playlist.isEmpty else {
            return
        }
        if playlist.count == 1 {
            seek(to: 0)
            play()
            return
        }
        var index = currentIndex ?? 0
        while index == (currentIndex ?? -1) {
            index = Int.random(in: 0..<playlist.count)
        }
        currentIndex = index
        loadAudio(from: playlist[index])
        play()
    }

    /// 一曲自然播完时按播放模式处理。
    private func handleTrackFinished() {
        switch playMode {
        case .repeatOne:
            seek(to: 0)
            play()
        case .shuffle:
            playRandomTrack()
        case .repeatAll:
            advanceToNext(wrap: true)
        case .sequential:
            advanceToNext(wrap: false)
        }
    }

    private func seek(to time: TimeInterval) {
        let newTime = min(max(time, 0), duration)
        audioPlayer?.currentTime = newTime
        currentTime = newTime
        updateNowPlayingInfo()
    }

    /// 单曲内相对快进/快退（秒），自动夹在 [0, 时长] 内。
    private func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    // MARK: - 后台播放与锁屏控制

    /// 配置音频会话为播放类别，使音频在后台与锁屏时继续播放。
    /// 开启「允许与其他应用同时播放」时加入 .mixWithOthers，与其他 App 混音而非打断。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            let options: AVAudioSession.CategoryOptions = mixWithOthers ? [.mixWithOthers] : []
            try session.setCategory(.playback, mode: .default, options: options)
            try session.setActive(true)
        } catch {
            // 后台音频不可用时不影响前台播放，忽略即可。
        }
    }

    /// 注册锁屏 / 控制中心的播放、暂停、拖动进度命令。
    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            play()
            return .success
        }

        center.pauseCommand.addTarget { _ in
            pause()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { _ in
            togglePlayback()
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            seek(to: event.positionTime)
            return .success
        }

        center.nextTrackCommand.addTarget { _ in
            guard canGoNext else {
                return .noSuchContent
            }
            nextTrack()
            return .success
        }

        center.previousTrackCommand.addTarget { _ in
            guard canGoPrevious else {
                return .noSuchContent
            }
            previousTrack()
            return .success
        }
    }

    /// 更新锁屏 / 控制中心显示的曲目信息与播放进度。
    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentAudioURL?.deletingPathExtension().lastPathComponent ?? "Meloha"
        info[MPMediaItemPropertyArtist] = "Meloha"
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadMatchingSubtitle(for audioURL: URL) {
        let baseURL = audioURL.deletingPathExtension()
        // 同名字幕优先级：SRT → VTT → LRC。
        for fileExtension in ["srt", "vtt", "lrc"] {
            let subtitleURL = baseURL.appendingPathExtension(fileExtension)
            if FileManager.default.fileExists(atPath: subtitleURL.path) {
                loadSubtitle(from: subtitleURL)
                return
            }
        }

        subtitles = []
        subtitleStatus = "未找到同名字幕（LRC/SRT/VTT）"
    }

    private func loadSubtitle(from subtitleURL: URL) {
        guard let subtitleText = try? String(contentsOf: subtitleURL, encoding: .utf8) else {
            subtitleStatus = "无法读取字幕文件"
            return
        }

        let parsedLines: [SubtitleLine]
        switch subtitleURL.pathExtension.lowercased() {
        case "lrc":
            parsedLines = subtitleText
                .split(whereSeparator: \.isNewline)
                .compactMap(parseLRCLine)
        case "srt", "vtt":
            parsedLines = parseCueSubtitle(subtitleText)
        default:
            subtitleStatus = "暂不支持的字幕格式：.\(subtitleURL.pathExtension)"
            return
        }

        subtitles = parsedLines.sorted { $0.time < $1.time }
        subtitleStatus = subtitles.isEmpty
            ? "未能从 \(subtitleURL.lastPathComponent) 解析出字幕"
            : "已加载 \(subtitleURL.lastPathComponent)"
    }

    private func parseLRCLine(_ line: Substring) -> SubtitleLine? {
        guard let closingBracket = line.firstIndex(of: "]"), line.first == "[" else {
            return nil
        }

        let timestamp = line[line.index(after: line.startIndex)..<closingBracket]
        let timeParts = timestamp.split(separator: ":", maxSplits: 1)
        guard timeParts.count == 2,
              let minutes = Double(timeParts[0]),
              let seconds = Double(timeParts[1]) else {
            return nil
        }

        let textStart = line.index(after: closingBracket)
        let text = line[textStart...].trimmingCharacters(in: .whitespaces)
        return SubtitleLine(time: minutes * 60 + seconds, text: text)
    }

    /// 解析基于 cue 块的字幕（SRT 与 WebVTT 结构几乎一致）。
    /// 按空行切分字幕块，每块定位含 "-->" 的时间行，其余行合并为字幕文本。
    /// 自动跳过 VTT 的 "WEBVTT" 头、"NOTE"/"STYLE"/"REGION" 等无时间行的块，
    /// 以及 SRT/VTT 的序号或 cue 标识行。
    private func parseCueSubtitle(_ text: String) -> [SubtitleLine] {
        // 统一换行符，按空行切分字幕块。
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var lines: [SubtitleLine] = []
        for block in blocks {
            let rawLines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let timingIndex = rawLines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timingLine = rawLines[timingIndex]
            let timingParts = timingLine.components(separatedBy: "-->")
            guard timingParts.count == 2,
                  let start = parseCueTimestamp(timingParts[0]) else {
                continue
            }
            let end = parseCueTimestamp(timingParts[1])

            let textLines = rawLines[rawLines.index(after: timingIndex)...]
                .map { stripTags(String($0)).trimmingCharacters(in: .whitespaces) }
            let text = textLines.joined(separator: "\n")
            guard !text.isEmpty else {
                continue
            }

            lines.append(SubtitleLine(time: start, endTime: end, text: text))
        }

        return lines
    }

    /// 解析 cue 时间戳，兼容：
    /// - SRT "HH:MM:SS,mmm"（逗号毫秒）
    /// - VTT "HH:MM:SS.mmm" 或省略小时的 "MM:SS.mmm"
    /// - VTT 结束时间后附带的 cue 设置（如 "align:start position:10%"）——只取首个 token。
    private func parseCueTimestamp(_ raw: String) -> TimeInterval? {
        let token = raw
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")

        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else {
                return nil
            }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else {
                return nil
            }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }

    /// 去除字幕文本中的标签，如 SRT 的 `<i>`/`<b>` 与 VTT 的 `<v Roger>`/`<c.class>`。
    private func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func timeText(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

#Preview {
    ContentView()
}

struct AudioFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var albumStore: AlbumStore
    @ObservedObject var backgroundStore: BackgroundStore
    @State private var audioFiles: [URL] = []
    @State private var showAudioImporter = false
    @State private var libraryMode: LibraryMode = .files
    @State private var showNewAlbumAlert = false
    @State private var newAlbumName = ""
    @State private var showSettings = false
    @State private var searchText = ""
    @AppStorage("fileSort") private var fileSort: FileSort = .name
    @State private var renameFileURL: URL?
    @State private var renameAlbumTarget: Album?
    @State private var renameText = ""
    @State private var showRenameFile = false
    @State private var showRenameAlbum = false
    @State private var toastMessage: String?
    @AppStorage("backgroundOpacity") private var backgroundOpacity: Double = 0.6

    var showsDoneButton: Bool = true
    let onSelect: ([URL], Int, UIImage?) -> Void

    enum LibraryMode: String, CaseIterable, Identifiable {
        case files = "文件"
        case albums = "专辑"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("显示方式", selection: $libraryMode) {
                    ForEach(LibraryMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                searchBar

                switch libraryMode {
                case .files:
                    filesList
                case .albums:
                    albumsList
                }
            }
            .background {
                // 音乐库自己画背景图（NavigationStack 自带不透明背景，靠 ContentView 的背景透不过来）。
                if let background = backgroundStore.image {
                    Image(uiImage: background)
                        .resizable()
                        .scaledToFill()
                        .opacity(backgroundOpacity)
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("音乐库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
                if libraryMode == .files {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("排序方式", selection: $fileSort) {
                                ForEach(FileSort.allCases) { sort in
                                    Text(sort.label).tag(sort)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("排序")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        switch libraryMode {
                        case .files:
                            showAudioImporter = true
                        case .albums:
                            showNewAlbumAlert = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(libraryMode == .files ? "导入音频" : "新建专辑")
                }
                if showsDoneButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") {
                            dismiss()
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showAudioImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        importAudioFile(from: url)
                    }
                    if !urls.isEmpty {
                        toastMessage = "已导入 \(urls.count) 个音频"
                    }
                }
            }
            .alert("新建专辑", isPresented: $showNewAlbumAlert) {
                TextField("专辑名称", text: $newAlbumName)
                Button("创建") {
                    albumStore.createAlbum(name: newAlbumName)
                    newAlbumName = ""
                }
                Button("取消", role: .cancel) {
                    newAlbumName = ""
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(backgroundStore: backgroundStore, albumStore: albumStore)
            }
            .alert("重命名", isPresented: $showRenameFile) {
                TextField("名称", text: $renameText)
                Button("确定") {
                    if let url = renameFileURL {
                        renameFile(url, to: renameText)
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("重命名专辑", isPresented: $showRenameAlbum) {
                TextField("专辑名称", text: $renameText)
                Button("确定") {
                    if let album = renameAlbumTarget {
                        albumStore.renameAlbum(album, to: renameText)
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
        .onAppear {
            loadAudioFiles()
        }
        .onChange(of: fileSort) { _, _ in
            loadAudioFiles()
        }
        .toast($toastMessage)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(libraryMode == .files ? "搜索音频" : "搜索专辑", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var filesList: some View {
        let files = filteredFiles
        if files.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "还没有音频" : "无匹配结果",
                systemImage: "music.note.list",
                description: Text(searchText.isEmpty ? "点右上角 + 导入音频" : "换个关键词试试")
            )
        } else {
            List {
                ForEach(Array(files.enumerated()), id: \.element) { index, audioURL in
                    Button {
                        onSelect(files, index, nil)
                        dismiss()
                    } label: {
                        HStack {
                            Label {
                                Text(audioURL.deletingPathExtension().lastPathComponent)
                            } icon: {
                                Image(systemName: "waveform")
                            }

                            Spacer()

                            subtitleBadge(for: audioURL)
                        }
                    }
                    .listRowBackground(rowBackground)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if isDeletable(audioURL) {
                            Button(role: .destructive) {
                                deleteAudio(audioURL)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if isDeletable(audioURL) {
                            Button {
                                renameFileURL = audioURL
                                renameText = audioURL.deletingPathExtension().lastPathComponent
                                showRenameFile = true
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .scrollContentBackground(backgroundStore.image == nil ? .automatic : .hidden)
        }
    }

    private var filteredFiles: [URL] {
        guard !searchText.isEmpty else { return audioFiles }
        return audioFiles.filter {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredAlbums: [Album] {
        guard !searchText.isEmpty else { return albumStore.albums }
        return albumStore.albums.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// 有背景图时列表行用半透明底保证文字可读；无背景图时用系统默认。
    private var rowBackground: Color? {
        backgroundStore.image == nil ? nil : Color(.systemBackground).opacity(0.4)
    }

    @ViewBuilder
    private func albumThumbnail(for album: Album) -> some View {
        if let cover = albumStore.coverImage(for: album) {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var albumsList: some View {
        let albums = filteredAlbums
        if albums.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "还没有专辑" : "无匹配结果",
                systemImage: "square.stack",
                description: Text(searchText.isEmpty ? "点右上角 + 新建专辑，再往里添加歌曲" : "换个关键词试试")
            )
        } else {
            List {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(albumID: album.id, albumStore: albumStore) { urls, index, cover in
                            onSelect(urls, index, cover)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            albumThumbnail(for: album)

                            Text(album.name)

                            Spacer()

                            Text("\(album.fileNames.count) 首")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(rowBackground)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            albumStore.deleteAlbum(album)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            renameAlbumTarget = album
                            renameText = album.name
                            showRenameAlbum = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
            .scrollContentBackground(backgroundStore.image == nil ? .automatic : .hidden)
        }
    }

    @ViewBuilder
    private func subtitleBadge(for audioURL: URL) -> some View {
        if let format = subtitleFormat(for: audioURL) {
            Text(format)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue.opacity(0.15), in: Capsule())
                .foregroundStyle(.blue)
        } else {
            Image(systemName: "captions.bubble")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("无字幕")
        }
    }

    /// 查找与音频同名的字幕文件，返回其格式标签（SRT → VTT → LRC 优先），没有则返回 nil。
    private func subtitleFormat(for audioURL: URL) -> String? {
        let base = audioURL.deletingPathExtension()
        for fileExtension in ["srt", "vtt", "lrc"] {
            let subtitleURL = base.appendingPathExtension(fileExtension)
            if FileManager.default.fileExists(atPath: subtitleURL.path) {
                return fileExtension.uppercased()
            }
        }
        return nil
    }

    /// 仅允许删除 Documents 目录内的文件；App bundle 内的样例（demo）不可删。
    private func isDeletable(_ audioURL: URL) -> Bool {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }
        return audioURL.resolvingSymlinksInPath().path
            .hasPrefix(documentsURL.resolvingSymlinksInPath().path)
    }

    /// 删除音频文件，并一并移除同名的 .lrc / .srt 字幕。
    private func deleteAudio(_ audioURL: URL) {
        guard isDeletable(audioURL) else {
            return
        }

        let base = audioURL.deletingPathExtension()
        var urlsToDelete = [audioURL]
        for fileExtension in ["lrc", "srt", "vtt"] {
            let subtitleURL = base.appendingPathExtension(fileExtension)
            if FileManager.default.fileExists(atPath: subtitleURL.path) {
                urlsToDelete.append(subtitleURL)
            }
        }

        for url in urlsToDelete {
            try? FileManager.default.removeItem(at: url)
        }

        loadAudioFiles()
    }

    /// 从系统「文件」导入音频，复制到 Documents 后刷新列表。
    private func importAudioFile(from sourceURL: URL) {
        let canAccessFile = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if canAccessFile {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let destinationURL = uniqueFileURL(
                in: documentsURL,
                fileName: sourceURL.lastPathComponent
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            loadAudioFiles()
        } catch {
            // 导入失败时保持列表不变。
        }
    }

    /// 若目标文件名已存在，追加序号得到不冲突的 URL。
    private func uniqueFileURL(in folder: URL, fileName: String) -> URL {
        let originalURL = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return originalURL
        }

        let fileExtension = originalURL.pathExtension
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        var number = 2
        var candidateURL = originalURL

        while FileManager.default.fileExists(atPath: candidateURL.path) {
            let newName = "\(baseName) \(number)"
            candidateURL = folder
                .appendingPathComponent(newName)
                .appendingPathExtension(fileExtension)
            number += 1
        }

        return candidateURL
    }

    private func loadAudioFiles() {
        var files = documentsAudioURLs()
        if fileSort == .dateAdded {
            files.sort { fileCreationDate($0) > fileCreationDate($1) }
        }
        audioFiles = files
    }

    private func fileCreationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// 重命名音频文件，同步改名同名字幕并更新专辑引用。
    private func renameFile(_ url: URL, to newBaseName: String) {
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isDeletable(url) else { return }

        let folder = url.deletingLastPathComponent()
        let fileExtension = url.pathExtension
        let newURL = folder.appendingPathComponent(trimmed).appendingPathExtension(fileExtension)
        guard !FileManager.default.fileExists(atPath: newURL.path) else { return }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
        } catch {
            return
        }

        // 同名字幕一起改名。
        let base = url.deletingPathExtension()
        for subtitleExtension in ["lrc", "srt", "vtt"] {
            let subtitleURL = base.appendingPathExtension(subtitleExtension)
            if FileManager.default.fileExists(atPath: subtitleURL.path) {
                let newSubtitleURL = folder.appendingPathComponent(trimmed).appendingPathExtension(subtitleExtension)
                try? FileManager.default.moveItem(at: subtitleURL, to: newSubtitleURL)
            }
        }

        // 更新专辑里的文件引用。
        albumStore.replaceFileName(url.lastPathComponent, with: newURL.lastPathComponent)
        loadAudioFiles()
    }
}
