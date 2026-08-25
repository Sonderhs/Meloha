//
//  Library.swift
//  SubtitlePlayer
//
//  音乐库：文件（全部音频）与专辑（用户自建、可添加文件的合集）。
//  播放专辑时，播放队列即该专辑内的文件。
//

import SwiftUI
import Combine
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - 轻提示 Toast

extension View {
    /// 顶部短暂提示，约 1.8 秒后自动消失。
    func toast(_ message: Binding<String?>) -> some View {
        overlay(alignment: .top) {
            if let text = message.wrappedValue {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { message.wrappedValue = nil }
                    }
            }
        }
        .animation(.easeInOut, value: message.wrappedValue)
    }
}

// MARK: - 备份（导出 / 导入）

struct BackupSettings: Codable {
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
}

struct BackupEntry: Codable {
    var name: String
    var data: Data
}

struct BackupFile: Codable {
    var version: Int
    var settings: BackupSettings
    var files: [BackupEntry]
}

enum BackupManager {
    private static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// 打包 Documents 内所有文件 + 设置为一份备份数据。
    static func makeBackupData() throws -> Data {
        guard let documentsURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        var entries: [BackupEntry] = []
        for name in names {
            let url = documentsURL.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }
            if let data = try? Data(contentsOf: url) {
                entries.append(BackupEntry(name: name, data: data))
            }
        }

        let defaults = UserDefaults.standard
        let settings = BackupSettings(
            allowMixWithOthers: defaults.object(forKey: "allowMixWithOthers") as? Bool,
            appTheme: defaults.string(forKey: "appTheme"),
            backgroundOpacity: defaults.object(forKey: "backgroundOpacity") as? Double,
            playbackRate: defaults.object(forKey: "playbackRate") as? Double,
            playMode: defaults.string(forKey: "playMode"),
            subtitleFontSize: defaults.object(forKey: "subtitleFontSize") as? Double,
            subtitleColor: defaults.string(forKey: "subtitleColor"),
            subtitleLineCount: defaults.object(forKey: "subtitleLineCount") as? Int,
            fileSort: defaults.string(forKey: "fileSort"),
            chatSystemPrompt: defaults.string(forKey: "chatSystemPrompt")
        )

        let backup = BackupFile(version: 1, settings: settings, files: entries)
        return try JSONEncoder().encode(backup)
    }

    /// 用备份数据覆盖恢复。
    static func restore(from data: Data) throws {
        let backup = try JSONDecoder().decode(BackupFile.self, from: data)
        guard let documentsURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        for entry in backup.files {
            let url = documentsURL.appendingPathComponent(entry.name)
            try? entry.data.write(to: url, options: .atomic)
        }

        let defaults = UserDefaults.standard
        let s = backup.settings
        if let v = s.allowMixWithOthers { defaults.set(v, forKey: "allowMixWithOthers") }
        if let v = s.appTheme { defaults.set(v, forKey: "appTheme") }
        if let v = s.backgroundOpacity { defaults.set(v, forKey: "backgroundOpacity") }
        if let v = s.playbackRate { defaults.set(v, forKey: "playbackRate") }
        if let v = s.playMode { defaults.set(v, forKey: "playMode") }
        if let v = s.subtitleFontSize { defaults.set(v, forKey: "subtitleFontSize") }
        if let v = s.subtitleColor { defaults.set(v, forKey: "subtitleColor") }
        if let v = s.subtitleLineCount { defaults.set(v, forKey: "subtitleLineCount") }
        if let v = s.fileSort { defaults.set(v, forKey: "fileSort") }
        if let v = s.chatSystemPrompt { defaults.set(v, forKey: "chatSystemPrompt") }
    }
}

/// 备份文件包装（用于 .fileExporter）。
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - 背景图片

@MainActor
final class BackgroundStore: ObservableObject {
    @Published private(set) var image: UIImage?

    private let fileURL: URL = {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documentsURL.appendingPathComponent("background.jpg")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL) {
            image = UIImage(data: data)
        }
    }

    /// 从磁盘重新载入（导入备份后调用）。
    func reload() {
        if let data = try? Data(contentsOf: fileURL) {
            image = UIImage(data: data)
        } else {
            image = nil
        }
    }

    func setImage(data: Data) {
        guard let uiImage = UIImage(data: data) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
        image = uiImage
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        image = nil
    }
}

// MARK: - 文件排序

enum FileSort: String, CaseIterable, Identifiable {
    case name
    case dateAdded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "名称"
        case .dateAdded: return "添加时间"
        }
    }
}

// MARK: - 播放模式
enum PlayMode: String, CaseIterable, Identifiable {
    case sequential
    case repeatAll
    case repeatOne
    case shuffle

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sequential: return "arrow.forward"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    var label: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }

    var next: PlayMode {
        let all = PlayMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

// MARK: - 主题

enum AppTheme: String, CaseIterable, Identifiable {    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 字幕颜色

enum SubtitleColorChoice: String, CaseIterable, Identifiable {
    case standard
    case white
    case yellow
    case orange
    case blue
    case green
    case pink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "默认"
        case .white: return "白色"
        case .yellow: return "黄色"
        case .orange: return "橙色"
        case .blue: return "蓝色"
        case .green: return "绿色"
        case .pink: return "粉色"
        }
    }

    /// nil 表示跟随系统主色（primary）。
    var color: Color? {
        switch self {
        case .standard: return nil
        case .white: return .white
        case .yellow: return .yellow
        case .orange: return .orange
        case .blue: return .blue
        case .green: return .green
        case .pink: return .pink
        }
    }

    /// PiP 小窗（白底）绘制用的颜色，标准色用黑色以保证对比。
    var uiColor: UIColor {
        switch self {
        case .standard, .white: return .black
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .pink: return .systemPink
        }
    }
}

/// 画中画小窗尺寸预设：宽度固定、改变高度即改变宽高比，
/// 帧越「高」系统给的浮窗越大越高（也能多显示几行字）。
enum PiPWindowSize: String, CaseIterable, Identifiable {
    case compact, standard, large, extraLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "小（扁条）"
        case .standard: return "标准"
        case .large: return "大"
        case .extraLarge: return "特大（方形）"
        }
    }

    var frameSize: CGSize {
        switch self {
        case .compact: return CGSize(width: 480, height: 110)
        case .standard: return CGSize(width: 480, height: 200)
        case .large: return CGSize(width: 480, height: 270)
        case .extraLarge: return CGSize(width: 480, height: 360)
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var backgroundStore: BackgroundStore
    @ObservedObject var albumStore: AlbumStore
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("allowMixWithOthers") private var mixWithOthers = false
    @AppStorage("backgroundOpacity") private var backgroundOpacity: Double = 0.6
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 17
    @AppStorage("subtitleColor") private var subtitleColor: SubtitleColorChoice = .standard
    @AppStorage("subtitleLineCount") private var subtitleLineCount: Int = 3
    @AppStorage("pipWindowSize") private var pipWindowSize: PiPWindowSize = .standard
    @AppStorage("chatSystemPrompt") private var chatSystemPrompt: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var exportDocument: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupMessage: String?

    /// 背景图片选择器。标题在闭包外算好（此处是 @MainActor），
    /// 再把 String 传进 PhotosPicker 的 @Sendable label 闭包，避免在闭包里读 @MainActor 属性 `image`。
    private var backgroundPicker: some View {
        let title = backgroundStore.image == nil ? "选择背景图片" : "更换背景图片"
        return PhotosPicker(selection: $pickerItem, matching: .images) {
            Label(title, systemImage: "photo")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }

                    backgroundPicker

                    if backgroundStore.image != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("背景不透明度")
                                Spacer()
                                Text("\(Int(backgroundOpacity * 100))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $backgroundOpacity, in: 0.1...1.0)
                        }

                        Button(role: .destructive) {
                            backgroundStore.clear()
                        } label: {
                            Label("移除背景图片", systemImage: "trash")
                        }
                    }
                }

                Section("字幕") {
                    Picker("显示行数", selection: $subtitleLineCount) {
                        Text("1 行").tag(1)
                        Text("3 行").tag(3)
                        Text("5 行").tag(5)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("字号")
                            Spacer()
                            Text("\(Int(subtitleFontSize))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $subtitleFontSize, in: 12...30, step: 1)
                    }

                    Picker("当前句颜色", selection: $subtitleColor) {
                        ForEach(SubtitleColorChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                }

                Section {
                    Picker("小窗大小", selection: $pipWindowSize) {
                        ForEach(PiPWindowSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                } header: {
                    Text("画中画")
                } footer: {
                    Text("调整画中画小窗的比例：越「大」浮窗越高、能显示的字幕越多。修改后需重新开启一次画中画才会生效；小窗显示时也可用双指捏合缩放。")
                }

                Section {
                    TextField(
                        "例如：你是一位温柔耐心的音乐老师，说话简洁、偶尔用 emoji。",
                        text: $chatSystemPrompt,
                        axis: .vertical
                    )
                    .lineLimit(3...10)

                    if !chatSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(role: .destructive) {
                            chatSystemPrompt = ""
                        } label: {
                            Label("清除人设", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("AI 助手人设")
                } footer: {
                    Text("自定义 AI 的身份、语气与风格（作为系统提示）。留空则使用默认助手设定。修改会在下一条消息生效，正在进行的对话会重新开始。")
                }

                Section {
                    Toggle("允许与其他应用同时播放", isOn: $mixWithOthers)
                } footer: {
                    Text("开启后，本应用的声音会与其他应用混合播放，而不会中断它们。注意：混音模式下，锁屏 / 控制中心的播放控制可能不可用。")
                }

                Section {
                    Button {
                        exportBackup()
                    } label: {
                        Label("导出备份", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入备份", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("数据")
                } footer: {
                    Text("导出会把所有音频、字幕、专辑、封面、背景与设置打包成一个文件（可存到「文件」/iCloud）；导入会用备份覆盖当前数据，用于重装后恢复。")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        backgroundStore.setImage(data: data)
                    }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "Meloha备份"
            ) { result in
                if case .success = result {
                    backupMessage = "备份已导出"
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json]
            ) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url)
                    try BackupManager.restore(from: data)
                    albumStore.reload()
                    backgroundStore.reload()
                    backupMessage = "导入成功，已恢复数据"
                } catch {
                    backupMessage = "导入失败：文件无法读取或格式不对"
                }
            }
            .alert("提示", isPresented: Binding(
                get: { backupMessage != nil },
                set: { if !$0 { backupMessage = nil } }
            )) {
                Button("好") { backupMessage = nil }
            } message: {
                Text(backupMessage ?? "")
            }
        }
    }

    private func exportBackup() {
        do {
            let data = try BackupManager.makeBackupData()
            exportDocument = BackupDocument(data: data)
            showExporter = true
        } catch {
            backupMessage = "导出失败"
        }
    }
}

// MARK: - 当前播放列表（播放队列）

struct PlaylistQueueView: View {
    let tracks: [URL]
    let currentIndex: Int?
    /// 点击某曲时回调其索引。
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if tracks.isEmpty {
                    ContentUnavailableView(
                        "播放列表为空",
                        systemImage: "music.note.list",
                        description: Text("从音乐库或专辑选一首开始播放")
                    )
                } else {
                    List(Array(tracks.enumerated()), id: \.offset) { index, url in
                        Button {
                            onSelect(index)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                if index == currentIndex {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.blue)
                                        .frame(width: 24)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                }

                                Text(url.deletingPathExtension().lastPathComponent)
                                    .foregroundStyle(index == currentIndex ? .blue : .primary)
                                    .lineLimit(1)

                                Spacer()

                                SubtitleBadge(audioURL: url)
                            }
                        }
                    }
                }
            }
            .navigationTitle("播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 整篇歌词页

struct LyricsView: View {
    let subtitles: [SubtitleLine]
    let currentIndex: Int?
    /// 点击某句时回调其时间戳（秒）。
    let onSeek: (TimeInterval) -> Void

    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 17
    @AppStorage("subtitleColor") private var subtitleColor: SubtitleColorChoice = .standard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if subtitles.isEmpty {
                    ContentUnavailableView(
                        "暂无歌词",
                        systemImage: "text.quote",
                        description: Text("当前音频没有匹配的字幕")
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 18) {
                                ForEach(Array(subtitles.enumerated()), id: \.offset) { index, line in
                                    lyricLine(index: index, line: line)
                                }
                            }
                            .padding()
                            .padding(.vertical, 40)
                        }
                        .onChange(of: currentIndex) { _, newIndex in
                            guard let newIndex else { return }
                            withAnimation(.easeInOut) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                        .onAppear {
                            if let currentIndex {
                                proxy.scrollTo(currentIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
            .navigationTitle("歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func lyricLine(index: Int, line: SubtitleLine) -> some View {
        let isCurrent = index == currentIndex
        let size: CGFloat = isCurrent ? subtitleFontSize + 3 : subtitleFontSize
        let color: Color = isCurrent ? (subtitleColor.color ?? Color.primary) : Color.secondary

        return Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: size))
            .fontWeight(isCurrent ? .bold : .regular)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .id(index)
            .contentShape(Rectangle())
            .onTapGesture {
                onSeek(line.time)
            }
    }
}

// MARK: - 数据模型

/// 专辑内曲目排序方式。存进 albums.json，每张专辑各自记住。
enum AlbumSort: String, Codable, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case dateAddedNewest
    case dateAddedOldest
    case durationShortest
    case durationLongest
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAscending: return "名称 A→Z"
        case .nameDescending: return "名称 Z→A"
        case .dateAddedNewest: return "导入时间（新→旧）"
        case .dateAddedOldest: return "导入时间（旧→新）"
        case .durationShortest: return "时长（短→长）"
        case .durationLongest: return "时长（长→短）"
        case .manual: return "手动排序"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAscending, .nameDescending: return "textformat"
        case .dateAddedNewest, .dateAddedOldest: return "clock"
        case .durationShortest, .durationLongest: return "timer"
        case .manual: return "hand.draw"
        }
    }
}

/// 专辑内的分组（如 CD1/CD2、原曲/伴奏）。只有一层，分组里不能再套分组。
struct AlbumGroup: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// 本组的成员文件名。歌曲要么在某个组里，要么散在专辑根（不属于任何组）。
    var fileNames: [String]

    init(id: UUID = UUID(), name: String, fileNames: [String] = []) {
        self.id = id
        self.name = name
        self.fileNames = fileNames
    }
}

struct Album: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// 成员文件名（相对 Documents 的 lastPathComponent）。这是专辑的**全部**歌曲，
    /// 分组只是给其中一部分打上归属，不重复存储也不改变这里的顺序。
    var fileNames: [String]
    /// 封面图文件名（相对 Documents），无封面时为 nil。
    var coverFileName: String?
    /// 专辑内分组。解码旧数据时为 nil，用 `groupList` 读取以免到处判空。
    var groups: [AlbumGroup]?
    /// 专辑图片集（歌词本拍照、内页、乐谱等），与封面无关。旧数据为 nil。
    var imageFileNames: [String]?
    /// 曲目排序方式。旧数据为 nil —— 用 `sortMode` 读取，默认按名称升序。
    var sort: AlbumSort?

    /// 排序方式（旧数据默认按名称升序）。
    var sortMode: AlbumSort {
        get { sort ?? .nameAscending }
        set { sort = newValue }
    }

    /// 分组列表（旧数据视为空）。
    var groupList: [AlbumGroup] {
        get { groups ?? [] }
        set { groups = newValue.isEmpty ? nil : newValue }
    }

    /// 图片列表（旧数据视为空）。
    var imageList: [String] {
        get { imageFileNames ?? [] }
        set { imageFileNames = newValue.isEmpty ? nil : newValue }
    }

    /// 不属于任何分组的歌（显示在分组上方）。
    var ungroupedFileNames: [String] {
        let grouped = Set(groupList.flatMap(\.fileNames))
        return fileNames.filter { !grouped.contains($0) }
    }

    init(
        id: UUID = UUID(),
        name: String,
        fileNames: [String] = [],
        coverFileName: String? = nil,
        groups: [AlbumGroup]? = nil,
        imageFileNames: [String]? = nil,
        sort: AlbumSort? = nil
    ) {
        self.id = id
        self.name = name
        self.fileNames = fileNames
        self.coverFileName = coverFileName
        self.groups = groups
        self.imageFileNames = imageFileNames
        self.sort = sort
    }
}

/// 音乐库识别的音频扩展名（导入、下载校验、分享打开都用这一份）。
let audioFileExtensions = ["mp3", "m4a", "wav", "aac", "aiff"]

/// 列出 Documents 内所有音频（含 bundle 里的 demo），按名称排序。
func documentsAudioURLs() -> [URL] {
    guard let documentsURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first else {
        return []
    }

    var files = (try? FileManager.default.contentsOfDirectory(
        at: documentsURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ))?.filter { audioFileExtensions.contains($0.pathExtension.lowercased()) } ?? []

    // 内置示例 demo：随包只读，无法真正删除。用户在「未分类」里删过后置 hideDemoTrack，
    // 之后不再补回；否则默认补上（首次使用时有内容可试听）。
    if !UserDefaults.standard.bool(forKey: "hideDemoTrack"),
       let demoURL = Bundle.main.url(forResource: "demo", withExtension: "wav"),
       !files.contains(where: { $0.lastPathComponent == demoURL.lastPathComponent }) {
        files.append(demoURL)
    }

    return files.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
}

/// 支持的字幕扩展名，顺序即匹配优先级：SRT → VTT → LRC。
let subtitleFileExtensions = ["srt", "vtt", "lrc"]

/// 查找与音频同名的字幕文件（同目录、仅扩展名不同），返回优先级最高的那个；都不存在返回 nil。
func matchingSubtitleURL(for audioURL: URL) -> URL? {
    let base = audioURL.deletingPathExtension()
    for ext in subtitleFileExtensions {
        let subtitleURL = base.appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: subtitleURL.path) {
            return subtitleURL
        }
    }
    return nil
}

/// 字幕文件的可选类型（给文档选择器用）。LRC/SRT/VTT 没有系统 UTType，
/// 用 `filenameExtension:` 动态构造；构造不出时退回 .text 以免选择器什么都选不了。
var subtitleContentTypes: [UTType] {
    let types = subtitleFileExtensions.compactMap { UTType(filenameExtension: $0) }
    return types.isEmpty ? [.text] : types + [.text]
}

/// 把外部字幕拷进 Documents。`renameToMatch` 非 nil 时改名成该音频的同名字幕
/// （音频 `song.mp3` + 字幕 `xxx.lrc` → `song.lrc`），从而被同名匹配规则找到。
/// 返回落地后的文件名；失败返回 nil。
func importSubtitleToDocuments(from sourceURL: URL, renameToMatch audioURL: URL? = nil) -> String? {
    let canAccess = sourceURL.startAccessingSecurityScopedResource()
    defer { if canAccess { sourceURL.stopAccessingSecurityScopedResource() } }

    guard let documentsURL = try? FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ) else {
        return nil
    }

    let ext = sourceURL.pathExtension
    let fileName: String
    if let audioURL {
        // 与音频同名（只换扩展名）。已存在的同名字幕直接覆盖——用户就是要给这首歌配这份字幕。
        fileName = audioURL.deletingPathExtension().lastPathComponent + "." + ext
    } else {
        fileName = sourceURL.lastPathComponent
    }

    var destination = documentsURL.appendingPathComponent(fileName)
    if audioURL != nil {
        try? FileManager.default.removeItem(at: destination)
    } else if FileManager.default.fileExists(atPath: destination.path) {
        let base = destination.deletingPathExtension().lastPathComponent
        var number = 2
        repeat {
            destination = documentsURL
                .appendingPathComponent("\(base) \(number)")
                .appendingPathExtension(ext)
            number += 1
        } while FileManager.default.fileExists(atPath: destination.path)
    }

    do {
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination.lastPathComponent
    } catch {
        // 同 importAudioToDocuments：云端占位符直接拷会失败，用协调读取兜底。
        var copied = false
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: readURL, to: destination)
                copied = true
            } catch {
                copied = false
            }
        }
        return copied ? destination.lastPathComponent : nil
    }
}

/// 歌曲行尾的字幕状态标记：已配字幕显示蓝色实心气泡 + 格式，未配显示灰色空心气泡。
struct SubtitleBadge: View {
    let audioURL: URL

    var body: some View {
        if let subtitleURL = matchingSubtitleURL(for: audioURL) {
            let format = subtitleURL.pathExtension.uppercased()
            HStack(spacing: 4) {
                Image(systemName: "captions.bubble.fill")
                Text(format)
                    .font(.caption2)
            }
            .foregroundStyle(.blue)
            .accessibilityLabel("已配字幕 \(format)")
        } else {
            Image(systemName: "captions.bubble")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("未配字幕")
        }
    }
}

/// 把外部音频拷贝进 Documents，返回落地后的文件名（用于加入专辑等）；失败返回 nil。
/// 若同名已存在，自动追加序号避免覆盖。
func importAudioToDocuments(from sourceURL: URL) -> String? {
    let canAccess = sourceURL.startAccessingSecurityScopedResource()
    defer { if canAccess { sourceURL.stopAccessingSecurityScopedResource() } }

    guard let documentsURL = try? FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ) else {
        return nil
    }

    var destination = documentsURL.appendingPathComponent(sourceURL.lastPathComponent)
    if FileManager.default.fileExists(atPath: destination.path) {
        let ext = destination.pathExtension
        let base = destination.deletingPathExtension().lastPathComponent
        var number = 2
        repeat {
            destination = documentsURL
                .appendingPathComponent("\(base) \(number)")
                .appendingPathExtension(ext)
            number += 1
        } while FileManager.default.fileExists(atPath: destination.path)
    }

    do {
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination.lastPathComponent
    } catch {
        // 直接拷贝失败：文件很可能在 iCloud / 第三方云盘、本地只有占位符（深层、较老的文件
        // 常被系统「优化存储」清到云端）。改用 NSFileCoordinator 协调读取，会先触发下载再
        // 给出稳定快照，然后从该快照拷贝。
        var copied = false
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: readURL, to: destination)
                copied = true
            } catch {
                copied = false
            }
        }
        return copied ? destination.lastPathComponent : nil
    }
}

// MARK: - 文档选择器（UIKit 包装）

/// UIKit 文档选择器。名字里的 Audio 是历史遗留——现在音频、字幕、图片都用它，
/// 通过 `contentTypes` 指定类型（默认音频）。
///
/// 为什么不用 SwiftUI 的 `.fileImporter`：在被 push 的导航子页里不可靠——
/// 祖先视图（AudioFilesView）已挂了多个 `.fileImporter`，同一导航栈里祖先/子级的
/// presentation 会互相干扰，导致子页 fileImporter「选完点打开」的完成回调被吞掉。
/// 改用 `UIDocumentPickerViewController`（`asCopy` 直接拿到可读副本）经 `.sheet` 呈现，
/// 回调走 delegate，不受导航层级影响。
struct AudioDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    /// 可选择的文件类型，默认音频。导字幕时传 `subtitleContentTypes`。
    var contentTypes: [UTType] = [.audio]
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes, asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: AudioDocumentPicker
        init(_ parent: AudioDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
            parent.isPresented = false
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

// MARK: - 专辑存储（持久化到 Documents/albums.json）

@MainActor
final class AlbumStore: ObservableObject {
    @Published private(set) var albums: [Album] = []

    private let storeURL: URL = {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documentsURL.appendingPathComponent("albums.json")
    }()

    private var documentsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    init() {
        load()
    }

    /// 从磁盘重新载入专辑（导入备份后调用）。
    func reload() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Album].self, from: data) else {
            return
        }
        albums = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(albums) else {
            return
        }
        try? data.write(to: storeURL, options: .atomic)
    }

    func createAlbum(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        albums.append(Album(name: trimmed))
        save()
    }

    func deleteAlbum(_ album: Album) {
        // 一并删除封面与图片集文件（它们只属于这张专辑，留着就成了孤儿文件）。
        if let documentsURL = documentsDirectory {
            if let name = album.coverFileName {
                try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(name))
            }
            for name in album.imageList {
                try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(name))
            }
        }
        albums.removeAll { $0.id == album.id }
        save()
    }

    /// 设置专辑封面（图片数据写入 Documents）。
    func setCover(data: Data, for album: Album) {
        guard UIImage(data: data) != nil,
              let index = albums.firstIndex(where: { $0.id == album.id }),
              let documentsURL = documentsDirectory else {
            return
        }
        let name = "cover-\(album.id.uuidString).jpg"
        try? data.write(to: documentsURL.appendingPathComponent(name), options: .atomic)
        albums[index].coverFileName = name
        save()
    }

    func removeCover(for album: Album) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else {
            return
        }
        if let name = albums[index].coverFileName, let documentsURL = documentsDirectory {
            try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(name))
        }
        albums[index].coverFileName = nil
        save()
    }

    func coverImage(for album: Album) -> UIImage? {
        guard let name = album.coverFileName,
              let documentsURL = documentsDirectory,
              let data = try? Data(contentsOf: documentsURL.appendingPathComponent(name)) else {
            return nil
        }
        return UIImage(data: data)
    }

    // MARK: 专辑图片集（与封面无关，纯内容图：歌词本、内页、乐谱等）

    /// 追加一张图片。写盘成功才记进 JSON，避免留下指向不存在文件的名字。
    func addImage(data: Data, to album: Album) {
        guard UIImage(data: data) != nil,
              let index = albums.firstIndex(where: { $0.id == album.id }),
              let documentsURL = documentsDirectory else {
            return
        }
        let name = "albumimg-\(album.id.uuidString)-\(UUID().uuidString).jpg"
        do {
            try data.write(to: documentsURL.appendingPathComponent(name), options: .atomic)
        } catch {
            return
        }
        albums[index].imageList.append(name)
        save()
    }

    func removeImage(_ fileName: String, from album: Album) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        if let documentsURL = documentsDirectory {
            try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(fileName))
        }
        albums[index].imageList.removeAll { $0 == fileName }
        save()
    }

    func image(named fileName: String) -> UIImage? {
        guard let documentsURL = documentsDirectory,
              let data = try? Data(contentsOf: documentsURL.appendingPathComponent(fileName)) else {
            return nil
        }
        return UIImage(data: data)
    }

    // MARK: 专辑内分组（只有一层）

    func createGroup(name: String, in album: Album) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        albums[index].groupList.append(AlbumGroup(name: trimmed))
        save()
    }

    func renameGroup(_ group: AlbumGroup, to newName: String, in album: Album) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let albumIndex = albums.firstIndex(where: { $0.id == album.id }),
              let groupIndex = albums[albumIndex].groupList.firstIndex(where: { $0.id == group.id })
        else { return }
        var groups = albums[albumIndex].groupList
        groups[groupIndex].name = trimmed
        albums[albumIndex].groupList = groups
        save()
    }

    /// 删除分组。组里的歌**不删**，回到专辑根（未分组）——分组只是归类，不该连歌一起丢。
    func deleteGroup(_ group: AlbumGroup, in album: Album) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        albums[index].groupList.removeAll { $0.id == group.id }
        save()
    }

    /// 把歌移动到某个分组；`group` 为 nil 表示移出分组（回到专辑根）。
    /// 一首歌同时只能属于一个组，所以先从所有组里摘掉再加。
    func moveFile(_ fileName: String, to group: AlbumGroup?, in album: Album) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        var groups = albums[index].groupList
        for i in groups.indices {
            groups[i].fileNames.removeAll { $0 == fileName }
        }
        if let group, let target = groups.firstIndex(where: { $0.id == group.id }) {
            groups[target].fileNames.append(fileName)
        }
        albums[index].groupList = groups
        save()
    }

    /// 某个分组内的曲目（过滤掉已不在磁盘上的）。排序方式跟随所属专辑。
    func tracks(in group: AlbumGroup, sortedBy mode: AlbumSort = .manual) -> [URL] {
        guard let documentsURL = documentsDirectory else { return [] }
        let urls = group.fileNames.compactMap { name -> URL? in
            let url = documentsURL.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return Self.sorted(urls, by: mode)
    }

    func addFiles(_ fileNames: [String], to album: Album) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else {
            return
        }
        for name in fileNames where !albums[index].fileNames.contains(name) {
            albums[index].fileNames.append(name)
        }
        save()
    }

    func removeFile(_ fileName: String, from album: Album) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else {
            return
        }
        albums[index].fileNames.removeAll { $0 == fileName }
        // 同步从分组里摘掉，否则分组会残留指向已移出专辑的歌。
        var groups = albums[index].groupList
        for i in groups.indices {
            groups[i].fileNames.removeAll { $0 == fileName }
        }
        albums[index].groupList = groups
        save()
    }

    func renameAlbum(_ album: Album, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = albums.firstIndex(where: { $0.id == album.id }) else {
            return
        }
        albums[index].name = trimmed
        save()
    }

    func moveTracks(in album: Album, fromOffsets: IndexSet, toOffset: Int) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else {
            return
        }
        albums[index].fileNames.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    /// 拖动排序「未分组」区。偏移量是相对未分组子集的，得映射回 fileNames 的全局下标，
    /// 否则有分组时会挪错歌。
    func moveUngrouped(in album: Album, fromOffsets: IndexSet, toOffset: Int) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        let ungrouped = albums[index].ungroupedFileNames
        guard !ungrouped.isEmpty else { return }

        var reordered = ungrouped
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)

        // 把重排后的未分组序列按原有位置回填，分组内的歌保持原位不动。
        let ungroupedSet = Set(ungrouped)
        var iterator = reordered.makeIterator()
        albums[index].fileNames = albums[index].fileNames.map { name in
            ungroupedSet.contains(name) ? (iterator.next() ?? name) : name
        }
        save()
    }

    /// 文件重命名后，同步更新所有专辑里的引用（含分组内的引用）。
    func replaceFileName(_ oldName: String, with newName: String) {
        var changed = false
        for index in albums.indices {
            if let position = albums[index].fileNames.firstIndex(of: oldName) {
                albums[index].fileNames[position] = newName
                changed = true
            }
            var groups = albums[index].groupList
            var groupChanged = false
            for i in groups.indices {
                if let position = groups[i].fileNames.firstIndex(of: oldName) {
                    groups[i].fileNames[position] = newName
                    groupChanged = true
                }
            }
            if groupChanged {
                albums[index].groupList = groups
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    /// 取某专辑内仍存在的音频文件 URL，按专辑当前的排序方式返回。
    func tracks(in album: Album) -> [URL] {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }
        let urls = album.fileNames.compactMap { name -> URL? in
            let url = documentsURL.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return Self.sorted(urls, by: album.sortMode)
    }

    /// 按指定方式排序音频 URL。`.manual` 原样返回（顺序即 fileNames 的顺序）。
    static func sorted(_ urls: [URL], by mode: AlbumSort) -> [URL] {
        switch mode {
        case .manual:
            return urls
        case .nameAscending:
            return urls.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
        case .nameDescending:
            return urls.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedDescending }
        case .dateAddedNewest, .dateAddedOldest:
            // 先把修改时间取出来缓存，避免排序比较时反复访问文件系统。
            let dated = urls.map { ($0, modificationDate(of: $0)) }
            let ordered = dated.sorted { mode == .dateAddedNewest ? $0.1 > $1.1 : $0.1 < $1.1 }
            return ordered.map(\.0)
        case .durationShortest, .durationLongest:
            let timed = urls.map { ($0, Self.cachedDuration(of: $0)) }
            let ordered = timed.sorted { mode == .durationShortest ? $0.1 < $1.1 : $0.1 > $1.1 }
            return ordered.map(\.0)
        }
    }

    private static func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// 时长缓存：读时长要解析文件头，歌一多每次排序都读会明显卡顿。
    /// 键用「路径 + 修改时间」，文件被替换后能自动失效。
    private static var durationCache: [String: TimeInterval] = [:]

    private static func cachedDuration(of url: URL) -> TimeInterval {
        let key = "\(url.path)|\(modificationDate(of: url).timeIntervalSince1970)"
        if let cached = durationCache[key] { return cached }
        // AVAudioFile 只读文件头，比 AVAsset 异步加载轻，够排序用。
        let seconds: TimeInterval
        if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            seconds = Double(file.length) / file.fileFormat.sampleRate
        } else {
            seconds = 0
        }
        durationCache[key] = seconds
        return seconds
    }

    /// 设置排序方式。切到非手动时不改动 fileNames，只改显示顺序；
    /// 切回手动时把当前可见顺序固化下来，避免顺序突然跳回很久以前的样子。
    func setSort(_ mode: AlbumSort, for album: Album) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        if mode == .manual, albums[index].sortMode != .manual {
            let visible = tracks(in: album).map(\.lastPathComponent)
            // 保留当前可见顺序，磁盘上已消失的文件名附在后面不丢。
            let missing = albums[index].fileNames.filter { !visible.contains($0) }
            albums[index].fileNames = visible + missing
        }
        albums[index].sortMode = mode
        save()
    }

    /// 不属于任何专辑的音频：Documents 里的全部音频减去各专辑已收录的。
    /// 供「未分类」虚拟专辑使用，让删掉文件页后松散音频仍可被浏览、播放。
    func uncategorizedURLs() -> [URL] {
        let member = Set(albums.flatMap { $0.fileNames })
        return documentsAudioURLs().filter { !member.contains($0.lastPathComponent) }
    }
}

// MARK: - 专辑详情

struct AlbumDetailView: View {
    let albumID: UUID
    @ObservedObject var albumStore: AlbumStore
    let onSelect: ([URL], Int, UIImage?) -> Void

    @State private var showAddSongs = false
    @State private var showAudioImporter = false
    @StateObject private var subtitleImport = SubtitleImportCoordinator()
    @State private var coverPickerItem: PhotosPickerItem?
    /// 封面来源：相册 / 「文件」。
    @State private var showCoverPhotoPicker = false
    @State private var showCoverFileImporter = false
    /// 图片集选择（一次最多 10 张）。
    @State private var imagePickerItems: [PhotosPickerItem] = []
    /// 相册选择器 / 「文件」选择器的开关（两种来源）。
    @State private var showPhotoPicker = false
    @State private var showImageFileImporter = false
    /// 正在看大图的图片文件名。
    @State private var previewImageName: String?
    /// 展开的分组（默认全部展开，见 onAppear）。
    @State private var expandedGroups: Set<UUID> = []
    /// 新建分组的输入。
    @State private var showNewGroupAlert = false
    @State private var groupNameInput = ""
    /// 正在重命名的分组（非 nil 时弹输入框）。
    @State private var renameGroupTarget: AlbumGroup?
    /// 正在选分组的歌（文件名，非 nil 时弹分组选择）。
    @State private var moveTarget: String?
    @State private var toastMessage: String?

    private var album: Album? {
        albumStore.albums.first { $0.id == albumID }
    }

    var body: some View {
        importLayer(
            content
                .navigationTitle(album?.name ?? "专辑")
                .toolbar { toolbarContent }
        )
    }

    /// 导入相关的 presentation（加歌、音频导入、字幕导入、封面/图片选择）。
    /// 拆成独立函数是为了缩短单个表达式——全挂在 body 上会让类型检查超时。
    private func importLayer<V: View>(_ view: V) -> some View {
        dialogLayer(
            view
                .sheet(isPresented: $showAddSongs) {
                    if let album {
                        AddSongsView(albumID: album.id, albumStore: albumStore)
                    }
                }
                // 音频导入用 UIKit 文档选择器（见 AudioDocumentPicker）：被 push 的子页里 SwiftUI 的
                // .fileImporter 完成回调会被祖先的 presentation 吞掉。挂独立节点避免与上面的 sheet 冲突。
                .background(
                    Color.clear.sheet(isPresented: $showAudioImporter) {
                        AudioDocumentPicker(isPresented: $showAudioImporter) { urls in
                            handleImportedAudio(urls)
                        }
                        .ignoresSafeArea()
                    }
                )
                // 字幕导入：专辑内的候选优先本专辑曲目。
                .subtitleImportFlow(subtitleImport, candidates: { albumTracks }, toast: $toastMessage)
                .onChange(of: coverPickerItem) { _, item in
                    guard let item, let album else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            albumStore.setCover(data: data, for: album)
                        } else {
                            toastMessage = "无法读取这张图片"
                        }
                        coverPickerItem = nil
                    }
                }
                // 封面：相册来源。
                .background(
                    Color.clear.photosPicker(
                        isPresented: $showCoverPhotoPicker,
                        selection: $coverPickerItem,
                        matching: .images
                    )
                )
                // 封面：「文件」来源（iCloud/云盘里的图）。
                .background(
                    Color.clear.sheet(isPresented: $showCoverFileImporter) {
                        AudioDocumentPicker(
                            isPresented: $showCoverFileImporter,
                            contentTypes: [.image]
                        ) { urls in
                            handleImportedCoverFile(urls)
                        }
                        .ignoresSafeArea()
                    }
                )
                .onChange(of: imagePickerItems) { _, items in
                    handlePickedImages(items)
                }
                // 相册选择器：挂在独立节点上，与下面的「文件」选择器互不干扰。
                .background(
                    Color.clear.photosPicker(
                        isPresented: $showPhotoPicker,
                        selection: $imagePickerItems,
                        maxSelectionCount: 10,
                        matching: .images
                    )
                )
                // 从「文件」选图（iCloud/云盘里的图片走这条）。
                .background(
                    Color.clear.sheet(isPresented: $showImageFileImporter) {
                        AudioDocumentPicker(
                            isPresented: $showImageFileImporter,
                            contentTypes: [.image]
                        ) { urls in
                            handleImportedImageFiles(urls)
                        }
                        .ignoresSafeArea()
                    }
                )
        )
    }

    /// 分组相关的弹窗 + 图片大图。每个都挂独立节点：同节点叠多个 presentation 会互相顶掉。
    private func dialogLayer<V: View>(_ view: V) -> some View {
        view
            .background(
                Color.clear.alert("新建分组", isPresented: $showNewGroupAlert) {
                    TextField("分组名称（如 CD1）", text: $groupNameInput)
                    Button("创建") { createGroup() }
                    Button("取消", role: .cancel) { groupNameInput = "" }
                }
            )
            .background(
                Color.clear.alert("重命名分组", isPresented: Binding(
                    get: { renameGroupTarget != nil },
                    set: { if !$0 { renameGroupTarget = nil } }
                )) {
                    TextField("分组名称", text: $groupNameInput)
                    Button("保存") { commitGroupRename() }
                    Button("取消", role: .cancel) {
                        renameGroupTarget = nil
                        groupNameInput = ""
                    }
                }
            )
            .background(
                Color.clear.confirmationDialog(
                    "移到哪个分组？",
                    isPresented: Binding(
                        get: { moveTarget != nil },
                        set: { if !$0 { moveTarget = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    moveDialogButtons
                }
            )
            .background(
                Color.clear.sheet(item: Binding(
                    get: { previewImageName.map { ImagePreviewTarget(fileName: $0) } },
                    set: { previewImageName = $0?.fileName }
                )) { target in
                    imageViewer(for: target)
                }
            )
            .onAppear {
                // 首次进入默认展开所有分组，避免以为歌丢了。
                if expandedGroups.isEmpty, let album {
                    expandedGroups = Set(album.groupList.map(\.id))
                }
            }
            .toast($toastMessage)
    }

    @ViewBuilder
    private var moveDialogButtons: some View {
        if let album, let fileName = moveTarget {
            ForEach(album.groupList) { group in
                Button(group.name) {
                    albumStore.moveFile(fileName, to: group, in: album)
                    expandedGroups.insert(group.id)
                    moveTarget = nil
                }
            }
            Button("移出分组") {
                albumStore.moveFile(fileName, to: nil, in: album)
                moveTarget = nil
            }
            Button("取消", role: .cancel) { moveTarget = nil }
        }
    }

    @ViewBuilder
    private func imageViewer(for target: ImagePreviewTarget) -> some View {
        if let album {
            AlbumImageViewer(
                fileName: target.fileName,
                albumStore: albumStore,
                onDelete: {
                    albumStore.removeImage(target.fileName, from: album)
                    previewImageName = nil
                }
            )
        }
    }

    // MARK: 动作

    private func handleImportedAudio(_ urls: [URL]) {
        guard let album else { return }
        // 拷贝进 Documents 后直接加入本专辑，省去先进「文件」页再挑选。
        let names = urls.compactMap { importAudioToDocuments(from: $0) }
        if !names.isEmpty {
            albumStore.addFiles(names, to: album)
        }
        // 显式反馈：失败多半是文件在 iCloud 未下载，别再静默无反应。
        let failed = urls.count - names.count
        if failed > 0 {
            toastMessage = names.isEmpty
                ? "导入失败：文件可能在 iCloud 未下载，请先在「文件」中下载后重试"
                : "已导入 \(names.count) 首，\(failed) 个失败（可能未下载到本机）"
        } else if !names.isEmpty {
            toastMessage = "已导入 \(names.count) 首"
        }
    }

    private func handlePickedImages(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, let album else { return }
        Task {
            var added = 0
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    albumStore.addImage(data: data, to: album)
                    added += 1
                }
            }
            imagePickerItems = []
            let failed = items.count - added
            if failed > 0 {
                toastMessage = added > 0
                    ? "已添加 \(added) 张，\(failed) 张失败"
                    : "图片添加失败"
            } else if added > 0 {
                toastMessage = "已添加 \(added) 张图片"
            }
        }
    }

    /// 从「文件」App 选中的封面（只取第一张）。
    private func handleImportedCoverFile(_ urls: [URL]) {
        guard let url = urls.first, let album else { return }
        // 云端占位符可能读不到，失败要明确提示，别静默什么都不发生。
        guard let data = try? Data(contentsOf: url), UIImage(data: data) != nil else {
            toastMessage = "无法读取这张图片：可能在 iCloud 未下载"
            return
        }
        albumStore.setCover(data: data, for: album)
        toastMessage = "已更新封面"
    }

    /// 从「文件」App 选中的图片：读进来后与相册来源走同一套落地逻辑。
    private func handleImportedImageFiles(_ urls: [URL]) {
        guard !urls.isEmpty, let album else { return }
        var added = 0
        for url in urls {
            // asCopy 已经给了本地副本，但云端占位符仍可能读不到，失败就跳过并计数。
            guard let data = try? Data(contentsOf: url), UIImage(data: data) != nil else {
                continue
            }
            albumStore.addImage(data: data, to: album)
            added += 1
        }
        let failed = urls.count - added
        if failed > 0 {
            toastMessage = added > 0
                ? "已添加 \(added) 张，\(failed) 张失败（可能未下载到本机）"
                : "图片添加失败：文件可能在 iCloud 未下载"
        } else if added > 0 {
            toastMessage = "已添加 \(added) 张图片"
        }
    }

    private func createGroup() {
        guard let album else { return }
        albumStore.createGroup(name: groupNameInput, in: album)
        // 新建的分组默认展开，否则建完看不到任何变化。
        if let created = albumStore.albums
            .first(where: { $0.id == albumID })?.groupList.last {
            expandedGroups.insert(created.id)
        }
        groupNameInput = ""
    }

    private func commitGroupRename() {
        if let album, let target = renameGroupTarget {
            albumStore.renameGroup(target, to: groupNameInput, in: album)
        }
        renameGroupTarget = nil
        groupNameInput = ""
    }

    @ViewBuilder
    private var content: some View {
        if let album {
            List {
                coverSection(album)
                imagesSection(album)
                tracksSections(album)
            }
        } else {
            ContentUnavailableView("专辑不存在", systemImage: "questionmark.folder")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let album {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: Binding(
                        get: { album.sortMode },
                        set: { albumStore.setSort($0, for: album) }
                    )) {
                        ForEach(AlbumSort.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("排序方式")
            }
            if album.sortMode == .manual {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAudioImporter = true
                    } label: {
                        Label("从文件导入音频", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showAddSongs = true
                    } label: {
                        Label("从已有音频选择", systemImage: "music.note.list")
                    }
                    Divider()
                    Button {
                        groupNameInput = ""
                        showNewGroupAlert = true
                    } label: {
                        Label("新建分组", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        subtitleImport.showPicker = true
                    } label: {
                        Label("导入字幕", systemImage: "captions.bubble")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加")
            }
        }
    }

    /// 本专辑的曲目（配对字幕时作为候选）。
    private var albumTracks: [URL] {
        guard let album else { return [] }
        return albumStore.tracks(in: album)
    }

    // MARK: 封面

    private func coverSection(_ album: Album) -> some View {
        Section {
            VStack(spacing: 12) {
                coverView(for: album)

                Menu {
                    Button {
                        showCoverPhotoPicker = true
                    } label: {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showCoverFileImporter = true
                    } label: {
                        Label("从文件选择", systemImage: "folder")
                    }
                } label: {
                    Label(album.coverFileName == nil ? "设置封面" : "更换封面",
                          systemImage: "photo")
                }

                if album.coverFileName != nil {
                    Button(role: .destructive) {
                        albumStore.removeCover(for: album)
                    } label: {
                        Text("移除封面")
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: 图片集

    /// 专辑图片：与封面无关的内容图（歌词本、内页、乐谱等）。横向缩略图，点开看大图。
    @ViewBuilder
    private func imagesSection(_ album: Album) -> some View {
        let images = album.imageList
        Section {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images, id: \.self) { name in
                            Button {
                                previewImageName = name
                            } label: {
                                thumbnail(for: name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            Menu {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("从相册选择", systemImage: "photo.on.rectangle")
                }
                Button {
                    showImageFileImporter = true
                } label: {
                    Label("从文件选择", systemImage: "folder")
                }
            } label: {
                Label(images.isEmpty ? "添加图片" : "继续添加", systemImage: "photo.badge.plus")
            }
        } header: {
            Text(images.isEmpty ? "图片" : "图片（\(images.count)）")
        } footer: {
            if !images.isEmpty {
                Text("点图片看大图，在大图里可以删除。")
            }
        }
    }

    private func thumbnail(for name: String) -> some View {
        Group {
            if let image = albumStore.image(named: name) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // 文件缺失（手动删过或恢复备份不全）时给个占位，别显示空白。
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.gray.opacity(0.15))
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 歌曲 / 分组

    /// 歌曲区：未分组的歌在前，随后每个分组一个 Section（可折叠）。
    /// 播放队列始终是整张专辑（`albumStore.tracks(in:)` 的顺序），所以在分组里点歌也能连着往下听。
    @ViewBuilder
    private func tracksSections(_ album: Album) -> some View {
        let allTracks = albumStore.tracks(in: album)
        let mode = album.sortMode
        // 未分组的歌也要按当前排序显示，所以从已排序的 allTracks 里筛，而不是直接用 fileNames。
        let groupedNames = Set(album.groupList.flatMap(\.fileNames))
        let ungrouped = allTracks.filter { !groupedNames.contains($0.lastPathComponent) }

        if allTracks.isEmpty {
            Section {
                Text("还没有歌曲，点右上角 + 添加")
                    .foregroundStyle(.secondary)
            }
        } else {
            if !ungrouped.isEmpty {
                Section(album.groupList.isEmpty ? "歌曲" : "未分组") {
                    ForEach(ungrouped, id: \.self) { url in
                        trackRow(url: url, album: album, allTracks: allTracks)
                    }
                    // 拖动排序只在手动模式下有意义：其他模式下顺序由规则决定，拖了也会被覆盖。
                    .onMove(perform: mode == .manual ? { fromOffsets, toOffset in
                        albumStore.moveUngrouped(in: album, fromOffsets: fromOffsets, toOffset: toOffset)
                    } : nil)
                }
            }

            ForEach(album.groupList) { group in
                Section {
                    if expandedGroups.contains(group.id) {
                        let groupTracks = albumStore.tracks(in: group, sortedBy: mode)
                        if groupTracks.isEmpty {
                            Text("这个分组还没有歌，从上面左滑歌曲加进来")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(groupTracks, id: \.self) { url in
                                trackRow(url: url, album: album, allTracks: allTracks)
                            }
                        }
                    }
                } header: {
                    groupHeader(group, album: album)
                }
            }
        }
    }

    private func groupHeader(_ group: AlbumGroup, album: Album) -> some View {
        HStack {
            Button {
                toggleGroup(group.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expandedGroups.contains(group.id)
                          ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(group.name)
                    Text("\(group.fileNames.count)")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Button {
                    renameGroupTarget = group
                    groupNameInput = group.name
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    albumStore.deleteGroup(group, in: album)
                } label: {
                    Label("删除分组", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// 一行歌曲。点播放（队列=整张专辑）；左滑移除；右滑选分组。
    private func trackRow(url: URL, album: Album, allTracks: [URL]) -> some View {
        let fileName = url.lastPathComponent
        return Group {
            if let index = allTracks.firstIndex(of: url) {
                Button {
                    onSelect(allTracks, index, albumStore.coverImage(for: album))
                } label: {
                    HStack {
                        Label {
                            Text(url.deletingPathExtension().lastPathComponent)
                        } icon: {
                            Image(systemName: "music.note")
                        }

                        Spacer()

                        SubtitleBadge(audioURL: url)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        albumStore.removeFile(fileName, from: album)
                    } label: {
                        Label("移除", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    if !album.groupList.isEmpty {
                        Button {
                            moveTarget = fileName
                        } label: {
                            Label("分组", systemImage: "folder")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
    }

    private func toggleGroup(_ id: UUID) {
        if expandedGroups.contains(id) {
            expandedGroups.remove(id)
        } else {
            expandedGroups.insert(id)
        }
    }

    @ViewBuilder
    private func coverView(for album: Album) -> some View {
        if let cover = albumStore.coverImage(for: album) {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "square.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .frame(width: 150, height: 150)
                .background(.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - 专辑图片大图

/// `.sheet(item:)` 需要 Identifiable，字符串文件名包一层。
struct ImagePreviewTarget: Identifiable {
    let fileName: String
    var id: String { fileName }
}

/// 看大图：可双指缩放/拖动，右上角可删除。
struct AlbumImageViewer: View {
    let fileName: String
    @ObservedObject var albumStore: AlbumStore
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if let image = albumStore.image(named: fileName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { scale = max(1, $0.magnification) }
                                .onEnded { _ in
                                    // 缩回原始大小时把位移也归零，否则图会偏在一边回不来。
                                    if scale <= 1 {
                                        withAnimation(.easeOut) { offset = .zero }
                                    }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard scale > 1 else { return }
                                    offset = value.translation
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut) {
                                scale = scale > 1 ? 1 : 2.5
                                offset = .zero
                            }
                        }
                } else {
                    ContentUnavailableView(
                        "图片已丢失",
                        systemImage: "photo",
                        description: Text("文件可能被手动删除了")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .confirmationDialog("删除这张图片？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

// MARK: - 字幕配对（名字对不上时选歌）

/// 待配对的字幕：文件名跟库里任何音频都不同名，需要用户指定配给哪首歌。
struct PendingSubtitle: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

/// 字幕导入流程的共享状态机。专辑详情页与未分类页都用它，避免两处各写一份逐渐走偏。
///
/// 用法：`@StateObject private var subtitleImport = SubtitleImportCoordinator()`，
/// 然后 `.subtitleImportFlow(subtitleImport, candidates: ..., toast: $toastMessage)`。
@MainActor
final class SubtitleImportCoordinator: ObservableObject {
    /// 是否正在显示文件选择器。
    @Published var showPicker = false
    /// 名字对不上、等用户指定配给哪首歌的字幕队列。
    @Published var pending: [PendingSubtitle] = []
    /// 当前正在配对的那一个（队列逐个处理）。
    @Published var current: PendingSubtitle?

    /// 处理选中的字幕文件：同名音频存在的直接落地，找不到的排队等用户指定。
    /// 返回要显示的 toast 文本（没有则 nil）。
    func handlePicked(_ urls: [URL]) -> String? {
        // 同名判定按全库来：字幕可能对应专辑外的音频，这种情况也该直接落地。
        let audioBaseNames = Set(
            documentsAudioURLs().map { $0.deletingPathExtension().lastPathComponent }
        )

        var matched = 0
        var failed = 0
        var needsPicking: [PendingSubtitle] = []

        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            if audioBaseNames.contains(base) {
                if importSubtitleToDocuments(from: url) != nil {
                    matched += 1
                } else {
                    failed += 1
                }
            } else {
                needsPicking.append(PendingSubtitle(url: url))
            }
        }

        pending = needsPicking
        presentNext()

        if failed > 0 {
            return matched > 0
                ? "已导入 \(matched) 个字幕，\(failed) 个失败（可能未下载到本机）"
                : "导入失败：文件可能在 iCloud 未下载"
        }
        return matched > 0 ? "已导入 \(matched) 个字幕" : nil
    }

    /// 用户为待配对字幕选定了音频（或跳过）。返回 toast 文本。
    func resolve(_ item: PendingSubtitle, matchedTo audioURL: URL?) -> String? {
        var message: String?
        if let audioURL {
            if importSubtitleToDocuments(from: item.url, renameToMatch: audioURL) != nil {
                message = "已配给「\(audioURL.deletingPathExtension().lastPathComponent)」"
            } else {
                message = "配对失败（文件可能在 iCloud 未下载）"
            }
        }
        pending.removeAll { $0.id == item.id }
        current = nil
        // 等上一个 sheet 收起再弹下一个，否则两个 sheet 会互相顶掉。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.45))
            presentNext()
        }
        return message
    }

    private func presentNext() {
        guard current == nil else { return }
        current = pending.first
    }
}

extension View {
    /// 挂上字幕导入所需的两个 sheet（文件选择器 + 配对页）。
    /// `candidates` 是配对页的候选音频；`onFinish` 在每步结束后调用，便于刷新列表。
    func subtitleImportFlow(
        _ coordinator: SubtitleImportCoordinator,
        candidates: @escaping () -> [URL],
        toast: Binding<String?>,
        onFinish: @escaping () -> Void = {}
    ) -> some View {
        self
            // 两个 sheet 各挂独立节点：同节点叠多个 presentation 会互相顶掉。
            .background(
                Color.clear.sheet(isPresented: Binding(
                    get: { coordinator.showPicker },
                    set: { coordinator.showPicker = $0 }
                )) {
                    AudioDocumentPicker(
                        isPresented: Binding(
                            get: { coordinator.showPicker },
                            set: { coordinator.showPicker = $0 }
                        ),
                        contentTypes: subtitleContentTypes
                    ) { urls in
                        if let message = coordinator.handlePicked(urls) {
                            toast.wrappedValue = message
                        }
                        onFinish()
                    }
                    .ignoresSafeArea()
                }
            )
            .background(
                Color.clear.sheet(item: Binding(
                    get: { coordinator.current },
                    set: { coordinator.current = $0 }
                )) { pending in
                    SubtitleMatchView(pending: pending, candidates: candidates()) { audioURL in
                        if let message = coordinator.resolve(pending, matchedTo: audioURL) {
                            toast.wrappedValue = message
                        }
                        onFinish()
                    }
                }
            )
    }
}

/// 让用户选「这份字幕配给哪首歌」。选中后字幕会被改名成该音频的同名字幕。
struct SubtitleMatchView: View {
    let pending: PendingSubtitle
    /// 候选音频。专辑内传本专辑曲目（更贴近意图），未分类页传全库。
    let candidates: [URL]
    /// 选定音频后回调；跳过则回调 nil。
    let onPick: (URL?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AudioPickerList(
                sections: AudioPickerSection.flat(candidates),
                rowIcon: "music.note",
                emptyDescription: "先导入音频，再给它配字幕",
                accessory: { SubtitleBadge(audioURL: $0) },
                onTap: { url in
                    onPick(url)
                    dismiss()
                }
            )
            .navigationTitle("配给哪首歌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("跳过") {
                        onPick(nil)
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Text("字幕「\(pending.name)」找不到同名音频，选一首要配的歌。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }
}

// MARK: - 未分类音频（虚拟专辑）

/// 「未分类」虚拟专辑：列出不属于任何专辑的音频，点按直接播放、左滑删除。
/// 它不是持久化的 Album，内容按当前 Documents 与专辑收录情况实时计算。
struct UncategorizedView: View {
    @ObservedObject var albumStore: AlbumStore
    /// 播放回调（含关闭音乐库），由 AudioFilesView 注入，与专辑详情一致。
    let onSelect: ([URL], Int, UIImage?) -> Void

    @State private var files: [URL] = []
    @State private var showAudioImporter = false
    @StateObject private var subtitleImport = SubtitleImportCoordinator()
    @State private var toastMessage: String?

    var body: some View {
        Group {
            if files.isEmpty {
                ContentUnavailableView {
                    Label("没有未分类音频", systemImage: "tray")
                } description: {
                    Text("所有音频都已归入专辑。点右上角 + 可以导入音频或字幕。")
                } actions: {
                    Button {
                        showAudioImporter = true
                    } label: {
                        Label("从文件导入音频", systemImage: "square.and.arrow.down")
                    }
                }
            } else {
                List {
                    ForEach(Array(files.enumerated()), id: \.element) { index, url in
                        Button {
                            onSelect(files, index, nil)
                        } label: {
                            Label {
                                Text(url.deletingPathExtension().lastPathComponent)
                            } icon: {
                                Image(systemName: "waveform")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                delete(url)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("未分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAudioImporter = true
                    } label: {
                        Label("导入音频", systemImage: "waveform")
                    }
                    Button {
                        subtitleImport.showPicker = true
                    } label: {
                        Label("导入字幕", systemImage: "captions.bubble")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("导入")
            }
        }
        // 用 UIKit 选择器：被 push 的子页里 SwiftUI 的 .fileImporter 完成回调会被祖先的
        // presentation 吞掉。导入的文件默认不属于任何专辑，所以天然就落在本页。
        .sheet(isPresented: $showAudioImporter) {
            AudioDocumentPicker(isPresented: $showAudioImporter) { urls in
                let names = urls.compactMap { importAudioToDocuments(from: $0) }
                let failed = urls.count - names.count
                if failed > 0 {
                    toastMessage = names.isEmpty
                        ? "导入失败：文件可能在 iCloud 未下载，请先在「文件」中下载后重试"
                        : "已导入 \(names.count) 首，\(failed) 个失败（可能未下载到本机）"
                } else if !names.isEmpty {
                    toastMessage = "已导入 \(names.count) 首"
                }
                reload()
            }
            .ignoresSafeArea()
        }
        // 字幕导入（选择器 + 配对页）。未分类页的候选是全库音频：字幕可能给任意一首歌配。
        .subtitleImportFlow(
            subtitleImport,
            candidates: { documentsAudioURLs() },
            toast: $toastMessage,
            onFinish: { reload() }
        )
        .toast($toastMessage)
        .onAppear { reload() }
    }

    private func reload() {
        files = albumStore.uncategorizedURLs()
    }

    /// 仅允许删除 Documents 内的文件；App 内置样例（demo）不可删。
    private func isDeletable(_ url: URL) -> Bool {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return false }
        return url.resolvingSymlinksInPath().path
            .hasPrefix(documentsURL.resolvingSymlinksInPath().path)
    }

    /// 删除音频。Documents 内的真实文件连同同名字幕（.lrc/.srt/.vtt）一并删除；
    /// App 内置样例（demo）无法真正删除，改为持久隐藏（置 hideDemoTrack），之后不再出现。
    private func delete(_ url: URL) {
        if isDeletable(url) {
            let base = url.deletingPathExtension()
            var urlsToDelete = [url]
            for ext in subtitleFileExtensions {
                let sub = base.appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: sub.path) {
                    urlsToDelete.append(sub)
                }
            }
            for u in urlsToDelete {
                try? FileManager.default.removeItem(at: u)
            }
        } else {
            UserDefaults.standard.set(true, forKey: "hideDemoTrack")
        }
        reload()
    }
}

// MARK: - 添加歌曲到专辑

struct AddSongsView: View {
    let albumID: UUID
    @ObservedObject var albumStore: AlbumStore
    @Environment(\.dismiss) private var dismiss

    private var album: Album? {
        albumStore.albums.first { $0.id == albumID }
    }

    var body: some View {
        NavigationStack {
            let memberNames = Set(album?.fileNames ?? [])

            AudioPickerList(
                sections: AudioPickerSection.flat(documentsAudioURLs()),
                rowIcon: "music.note",
                emptyDescription: "先在专辑里用「从文件导入音频」添加",
                accessory: { url in
                    // 已在本专辑里的显示勾选；点行切换加入/移出。
                    Image(systemName: memberNames.contains(url.lastPathComponent)
                          ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(memberNames.contains(url.lastPathComponent)
                                         ? .blue : .secondary)
                },
                onTap: { url in
                    guard let album else { return }
                    let name = url.lastPathComponent
                    if memberNames.contains(name) {
                        albumStore.removeFile(name, from: album)
                    } else {
                        albumStore.addFiles([name], to: album)
                    }
                }
            )
            .navigationTitle("添加歌曲")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}
