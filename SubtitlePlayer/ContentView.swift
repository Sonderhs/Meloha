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
    @State private var playerMessage = "还没有选择音频"
    /// 下滑收起播放器时的实时位移（0 表示未拖动）。
    @State private var dragOffset: CGFloat = 0
    /// 当前从播放页打开的小游戏（nil 表示没开）。
    @State private var activeMiniGame: MiniGame?
    /// 内嵌元数据里的艺术家/社团名（无则 nil），显示在标题下方。
    @State private var embeddedArtist: String?
    @State private var subtitles: [SubtitleLine] = []
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var showSubtitleImporter = false
    @State private var isPlayerMinimized = true
    @State private var currentAudioURL: URL?
    @State private var subtitleStatus = "从音乐库选一首开始"
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
    @StateObject private var chatController = ChatController()
    /// 是否显示本地 AI 聊天面板。
    @State private var showChat = false
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
    @AppStorage("pipWindowSize") private var pipWindowSize: PiPWindowSize = .standard
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

        // SRT 字幕有明确的结束时间，超过后进入间隙则清空显示（不显示占位符号）。
        // LRC 没有结束时间（endTime 为 nil），保持显示直到下一句。
        if let endTime = line.endTime, effectiveTime > endTime {
            return ""
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
        // 空行（字幕文件里的空歌词/间奏）用空白占位保留行高，不显示音符符号。
        return text.isEmpty ? " " : text
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
                libraryView
                    .transition(.opacity)
            } else {
                playerView
                    .padding()
                    // 跟随下滑手势整页位移，松手时由手势回调决定收起或弹回。
                    .offset(y: dragOffset)
                    .transition(.move(edge: .bottom))
                    // 播放器有多个展开入口，统一在出现时归零，避免带着上次的位移显示。
                    .onAppear { dragOffset = 0 }
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
                // 让 AI 助手能控制播放：把 AI 下达的指令映射到播放器动作。
                chatController.onPlaybackCommand = { command in
                    switch command {
                    case .play: play()
                    case .pause: pause()
                    case .toggle: togglePlayback()
                    case .next: nextTrack()
                    case .prev: previousTrack()
                    case .forward: skip(by: 10)
                    case .back: skip(by: -10)
                    }
                }
            }
            removeLegacyDemoFiles()
            pipController.setAppearance(textColor: subtitleColor.uiColor, fontScale: CGFloat(subtitleFontSize / 17))
            pipController.setWindowSize(pipWindowSize.frameSize)
            pipController.update(text: currentSubtitle)
        }
        .onChange(of: currentSubtitle) { _, newText in
            pipController.update(text: newText)
        }
        .onChange(of: pipWindowSize) { _, newSize in
            pipController.setWindowSize(newSize.frameSize)
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
        // 0.25s 而非 0.1s：currentTime 是顶层 @State，每次写入都会重算整个 body（含音乐库）。
        // 字幕与进度条在 250ms 粒度下观感无差别，而重绘次数降到原来的 2/5。
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            // 睡眠定时器到点则暂停。
            if let end = sleepTimerEnd, Date() >= end {
                sleepTimerEnd = nil
                pause()
            }

            guard let audioPlayer else {
                return
            }

            let playing = audioPlayer.isPlaying
            // 暂停时进度不会变，写它只会白白触发重绘。
            if playing {
                currentTime = audioPlayer.currentTime
            }

            // 播放状态变化（如自然播完）时同步锁屏信息。
            if playing != isPlaying {
                isPlaying = playing
                updateNowPlayingInfo()
                pipController.setPlaybackState(playing: playing)

                // 自然播放结束：上一拍还在播、且已接近片尾 → 按播放模式连播。
                // （AVAudioPlayer 播完会把 currentTime 重置，故用上一拍的进度判断。）
                if !playing, duration > 0, lastPlayingTime >= duration - 0.9 {
                    handleTrackFinished()
                }
            }

            if playing {
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
        .sheet(isPresented: $showChat) {
            ChatBotView(
                controller: chatController,
                songTitle: playerMessage,
                lyricsText: subtitles.map(\.text).joined(separator: "\n")
            )
        }
        // 小游戏挂独立节点：这个视图上已经叠了多个 sheet，同节点再加容易互相顶掉。
        .background(
            Color.clear.sheet(item: $activeMiniGame) { game in
                MiniGameSheet(game: game)
            }
        )
        .onOpenURL { url in
            importIncomingFile(url)
        }
        .toast($toastMessage)
    }

    private var libraryView: some View {
        // 音乐库包含 NavigationStack：直接划分可用高度，让所有 push 的子页
        // 都在播放器上方布局，不依赖外层 safeAreaInset 向导航页面传递底部留白。
        VStack(spacing: 0) {
            AudioFilesView(albumStore: albumStore, backgroundStore: backgroundStore, showsDoneButton: false) { urls, index, cover in
                playTrack(at: index, in: urls, fallbackCover: cover)
                withAnimation(.easeInOut) {
                    isPlayerMinimized = false
                }
            }

            miniPlayerBar
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }

    private var playerView: some View {
        VStack(spacing: 0) {
            collapseBar
                .gesture(collapseDragGesture)

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 0)

                        coverArt
                            .gesture(collapseDragGesture)

                        VStack(spacing: 4) {
                            Text(playerMessage)
                                .font(.headline)
                                .multilineTextAlignment(.center)

                            if let embeddedArtist {
                                Text(embeddedArtist)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }

                        subtitleBox
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showLyrics = true
                            }

                        subtitleOffsetControls

                        progressSection

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

    private var collapseBar: some View {
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
        // 顶部整条都可下滑收起（不只是箭头），命中区域大一些更好按。
        .contentShape(Rectangle())
        .padding(.bottom, 8)
    }

    /// 下滑收起播放器的手势。跟着手指走，松手时按位移和速度决定收起还是弹回。
    /// 只挂在不滚动的区域（收起条、封面），否则会和 ScrollView 抢手势。
    private var collapseDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 只跟随向下的位移；向上拖不动，免得把播放页拉出屏幕。
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let shouldCollapse = value.translation.height > 120
                    || value.predictedEndTranslation.height > 250
                if shouldCollapse {
                    withAnimation(.easeInOut) {
                        isPlayerMinimized = true
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private var coverArt: some View {
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
    }

    private var progressSection: some View {
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
                showChat = true
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("AI 助手")

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

            // 小游戏：听着音声顺手掷个骰子/抽张牌，不用收起播放器回音乐库。
            Menu {
                Button {
                    activeMiniGame = .dice
                } label: {
                    Label("掷骰子", systemImage: "dice.fill")
                }
                Button {
                    activeMiniGame = .cards
                } label: {
                    Label("抽纸牌", systemImage: "suit.spade.fill")
                }
                Button {
                    activeMiniGame = .lottery
                } label: {
                    Label("抽签", systemImage: "wand.and.stars")
                }
            } label: {
                Image(systemName: "dice")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("小游戏")

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

    /// 一次性清理早期版本自动拷进 Documents 的示例文件（demo.wav / demo.lrc）。
    /// 内置示例已移除，这些残留只会混在音乐库里。清理过后置标记，之后不再扫。
    private func removeLegacyDemoFiles() {
        let cleanupKey = "didRemoveLegacyDemoFiles"
        guard !UserDefaults.standard.bool(forKey: cleanupKey) else { return }

        if let documentsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            for name in ["demo.wav", "demo.lrc"] {
                try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(name))
            }
        }
        // 旧的隐藏标记不再有用（demo 已彻底移除），顺手清掉。
        UserDefaults.standard.removeObject(forKey: "hideDemoTrack")
        UserDefaults.standard.set(true, forKey: cleanupKey)
        DocumentsIndex.shared.refresh()
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
            // 先用文件名兜底；内嵌标题读到后会在 loadArtwork 里替换掉。
            playerMessage = url.deletingPathExtension().lastPathComponent
            loadMatchingSubtitle(for: url)
            loadArtwork(for: url)
            updateNowPlayingInfo()
        } catch {
            playerMessage = "无法打开音频"
        }
    }

    /// 异步读取音频内嵌元数据：封面、标题、艺术家。
    /// 音声作品常以 RJ 号命名文件，内嵌标题比文件名可读得多，所以优先用它。
    /// 无内嵌封面时用专辑封面兜底（界面显示占位图）。
    private func loadArtwork(for url: URL) {
        artwork = albumFallbackCover
        embeddedArtist = nil
        let asset = AVURLAsset(url: url)
        Task { @MainActor in
            guard let metadata = try? await asset.load(.commonMetadata) else {
                return
            }
            for item in metadata {
                // 期间可能已切歌，每次写回前都确认仍是当前音频。
                guard currentAudioURL == url else { return }
                switch item.commonKey {
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue),
                       let image = UIImage(data: data) {
                        guard currentAudioURL == url else { return }
                        artwork = image
                    }
                case .commonKeyTitle:
                    if let title = try? await item.load(.stringValue),
                       !title.trimmingCharacters(in: .whitespaces).isEmpty {
                        guard currentAudioURL == url else { return }
                        playerMessage = title
                    }
                case .commonKeyArtist, .commonKeyAlbumName:
                    if let value = try? await item.load(.stringValue),
                       !value.trimmingCharacters(in: .whitespaces).isEmpty {
                        guard currentAudioURL == url else { return }
                        // 艺术家优先；只有专辑名时用专辑名（音声常把社团名放这里）。
                        if item.commonKey == .commonKeyArtist || embeddedArtist == nil {
                            embeddedArtist = value
                        }
                    }
                default:
                    break
                }
            }
            guard currentAudioURL == url else { return }
            updateNowPlayingInfo()
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
        let audioExtensions = audioFileExtensions
        let subtitleExtensions = subtitleFileExtensions
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
            DocumentsIndex.shared.refresh()
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
            DocumentsIndex.shared.refresh()

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
        // 锁屏/控制中心显示内嵌标题与艺术家（读到的话），比文件名可读。
        info[MPMediaItemPropertyTitle] = playerMessage
        info[MPMediaItemPropertyArtist] = embeddedArtist ?? "Meloha"
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadMatchingSubtitle(for audioURL: URL) {
        // 同名字幕查找与优先级见 matchingSubtitleURL（与列表里的字幕标记共用同一套规则）。
        if let subtitleURL = matchingSubtitleURL(for: audioURL) {
            loadSubtitle(from: subtitleURL)
            return
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
            // 跳过空歌词行（间奏 / 无字的时间戳），让上一句持续显示到下一句真正的歌词。
            parsedLines = subtitleText
                .split(whereSeparator: \.isNewline)
                .compactMap(parseLRCLine)
                .filter { !$0.text.isEmpty }
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
    @State private var libraryMode: LibraryMode = .albums
    @State private var showNewAlbumAlert = false
    @State private var newAlbumName = ""
    @State private var showSettings = false
    @State private var searchText = ""
    /// 当前选中的标签筛选（nil 表示不筛）。
    @State private var selectedTag: String?
    @State private var renameAlbumTarget: Album?
    @State private var renameText = ""
    @State private var showRenameAlbum = false
    @State private var toastMessage: String?
    // 小工具页「掷骰子 / 抽纸牌 / 抽签」的上次结果（在行尾显示，由各子页面写入）。
    @AppStorage("lastDiceResult") private var lastDiceResult: String = ""
    @AppStorage("lastCardResult") private var lastCardResult: String = ""
    @AppStorage("lastLotteryResult") private var lastLotteryResult: String = ""
    @AppStorage("backgroundOpacity") private var backgroundOpacity: Double = 0.6

    var showsDoneButton: Bool = true
    let onSelect: ([URL], Int, UIImage?) -> Void

    enum LibraryMode: String, CaseIterable, Identifiable {
        case albums = "专辑"
        case tools = "小工具"
        var id: String { rawValue }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
                Picker("显示方式", selection: $libraryMode) {
                    ForEach(LibraryMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if libraryMode == .albums {
                    searchBar
                    tagFilterBar
                        .onChange(of: albumStore.albums) { _, _ in
                            // 选中的标签可能因编辑/删除专辑而不再存在，否则会一直筛出空列表。
                            if let selectedTag,
                               !albumStore.allTags().contains(where: {
                                   $0.caseInsensitiveCompare(selectedTag) == .orderedSame
                               }) {
                                self.selectedTag = nil
                            }
                        }
                }

                switch libraryMode {
                case .albums:
                    albumsList
                case .tools:
                    toolsList
                }
            }
            .background {
                libraryBackground
            }
            .navigationTitle("音乐库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                libraryToolbar
            }
    }

    var body: some View {
        NavigationStack {
            libraryContent
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
                // 「重命名专辑」alert 与「新建专辑」alert 不能叠在同一节点（会互相顶掉），单独挂到 Color.clear 节点。
                .background(
                    Color.clear.alert("重命名专辑", isPresented: $showRenameAlbum) {
                        TextField("专辑名称", text: $renameText)
                        Button("确定") {
                            if let album = renameAlbumTarget {
                                albumStore.renameAlbum(album, to: renameText)
                            }
                        }
                        Button("取消", role: .cancel) {}
                    }
                )
        }
        .toast($toastMessage)
    }

    @ViewBuilder
    private var libraryBackground: some View {
        // 音乐库自己画背景图（NavigationStack 自带不透明背景，靠 ContentView 的背景透不过来）。
        if let background = backgroundStore.image {
            Image(uiImage: background)
                .resizable()
                .scaledToFill()
                .opacity(backgroundOpacity)
                .ignoresSafeArea()
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
        if libraryMode == .albums {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewAlbumAlert = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建专辑")
            }
        }
        if showsDoneButton {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }

    private var searchBar: some View {
        LibrarySearchBar(text: $searchText, prompt: "搜索专辑")
    }

    private var filteredAlbums: [Album] {
        var result = albumStore.albums
        // 标签筛选与关键词是「与」关系：先按选中的标签收窄，再在结果里搜。
        if let selectedTag {
            result = result.filter { album in
                album.tagList.contains { $0.caseInsensitiveCompare(selectedTag) == .orderedSame }
            }
        }
        guard !searchText.isEmpty else { return result }
        // 搜名称 + 备注 + 标签：收藏多的时候常靠社团名/声优/标签找，光搜名称不够。
        return result.filter {
            $0.searchableText.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// 标签筛选条：库里有标签时显示，可横向滚动，点一下切换选中。
    @ViewBuilder
    private var tagFilterBar: some View {
        let tags = albumStore.allTags()
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        let isSelected = selectedTag?.caseInsensitiveCompare(tag) == .orderedSame
                        Button {
                            selectedTag = isSelected ? nil : tag
                        } label: {
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial),
                                    in: Capsule()
                                )
                                .foregroundStyle(isSelected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 4)
        }
    }

    /// 有背景图时列表行用半透明底保证文字可读；无背景图时用系统默认。
    private var rowBackground: Color? {
        backgroundStore.image == nil ? nil : Color(.systemBackground).opacity(0.4)
    }

    @ViewBuilder
    private func albumThumbnail(for album: Album) -> some View {
        // 只要 44 点的缩略图：传 maxSide 让缓存存缩放后的小图，别把原图整张解码进内存。
        if let cover = albumStore.coverImage(for: album, maxSide: 44) {
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
        let isFiltering = !searchText.isEmpty || selectedTag != nil
        // 「未分类」虚拟专辑：把不在任何专辑里的音频聚在一起。筛选时不显示（它没有标签也没名字可搜）。
        let uncategorized = isFiltering ? [] : albumStore.uncategorizedURLs()
        if albums.isEmpty && uncategorized.isEmpty {
            ContentUnavailableView(
                isFiltering ? "无匹配结果" : "还没有专辑",
                systemImage: isFiltering ? "magnifyingglass" : "square.stack",
                description: Text(isFiltering
                    ? "换个关键词或标签试试"
                    : "点右上角 + 新建专辑，再往里添加歌曲")
            )
        } else {
            List {
                if !uncategorized.isEmpty {
                    NavigationLink {
                        UncategorizedView(albumStore: albumStore) { urls, index, cover in
                            onSelect(urls, index, cover)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.full")
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .background(.gray.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text("未分类")

                            Spacer()

                            Text("\(uncategorized.count) 首")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(rowBackground)
                }

                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(albumID: album.id, albumStore: albumStore) { urls, index, cover in
                            onSelect(urls, index, cover)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            albumThumbnail(for: album)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(album.name)

                                // 备注/标签是找作品的主要线索，列表里直接给一行摘要。
                                if let note = album.note, !note.isEmpty {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if !album.tagList.isEmpty {
                                    Text(album.tagList.map { "#\($0)" }.joined(separator: " "))
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                        .lineLimit(1)
                                }
                            }

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

    // MARK: - 小工具页

    @ViewBuilder
    private var toolsList: some View {
        List {
            Section {
                NavigationLink {
                    DiceRollerView()
                } label: {
                    toolRow("掷骰子", systemImage: "dice.fill", result: lastDiceResult)
                }
                .listRowBackground(rowBackground)

                NavigationLink {
                    CardDrawView()
                } label: {
                    toolRow("抽纸牌", systemImage: "suit.spade.fill", result: lastCardResult)
                }
                .listRowBackground(rowBackground)

                NavigationLink {
                    LotteryView()
                } label: {
                    toolRow("抽签", systemImage: "wand.and.stars", result: lastLotteryResult)
                }
                .listRowBackground(rowBackground)
            } header: {
                Text("小游戏")
            } footer: {
                Text("完全本地、真随机。以后新的小工具也会加在这里。")
            }

            Section("工具") {
                NavigationLink {
                    MetronomeView()
                } label: {
                    Label("节拍器", systemImage: "metronome")
                }
                .listRowBackground(rowBackground)

                NavigationLink {
                    AudioTrimPickerView()
                } label: {
                    Label("裁剪音频", systemImage: "scissors")
                }
                .listRowBackground(rowBackground)

                NavigationLink {
                    AudioDownloadView()
                } label: {
                    Label("从链接下载", systemImage: "arrow.down.circle")
                }
                .listRowBackground(rowBackground)
            }
        }
        .scrollContentBackground(backgroundStore.image == nil ? .automatic : .hidden)
    }

    /// 小工具行：图标 + 名称，行尾显示上次结果（没有就不显示）。
    private func toolRow(_ title: String, systemImage: String, result: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if !result.isEmpty {
                Text(result)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
