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
            fileSort: defaults.string(forKey: "fileSort")
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

    /// PiP 小窗（黑底）绘制用的颜色，标准色用白色以保证对比。
    var uiColor: UIColor {
        switch self {
        case .standard, .white: return .white
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .pink: return .systemPink
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
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var exportDocument: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(backgroundStore.image == nil ? "选择背景图片" : "更换背景图片",
                              systemImage: "photo")
                    }

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
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.system(size: index == currentIndex ? subtitleFontSize + 3 : subtitleFontSize))
                                        .fontWeight(index == currentIndex ? .bold : .regular)
                                        .foregroundStyle(index == currentIndex ? (subtitleColor.color ?? Color.primary) : Color.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .id(index)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            onSeek(line.time)
                                        }
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
}

// MARK: - 数据模型

struct Album: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// 成员文件名（相对 Documents 的 lastPathComponent）。
    var fileNames: [String]
    /// 封面图文件名（相对 Documents），无封面时为 nil。
    var coverFileName: String?

    init(id: UUID = UUID(), name: String, fileNames: [String] = [], coverFileName: String? = nil) {
        self.id = id
        self.name = name
        self.fileNames = fileNames
        self.coverFileName = coverFileName
    }
}

/// 列出 Documents 内所有音频（含 bundle 里的 demo），按名称排序。
func documentsAudioURLs() -> [URL] {
    guard let documentsURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first else {
        return []
    }

    let supportedExtensions = ["mp3", "m4a", "wav", "aac", "aiff"]
    var files = (try? FileManager.default.contentsOfDirectory(
        at: documentsURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ))?.filter { supportedExtensions.contains($0.pathExtension.lowercased()) } ?? []

    if let demoURL = Bundle.main.url(forResource: "demo", withExtension: "wav"),
       !files.contains(where: { $0.lastPathComponent == demoURL.lastPathComponent }) {
        files.append(demoURL)
    }

    return files.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
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
        // 一并删除封面文件。
        if let name = album.coverFileName, let documentsURL = documentsDirectory {
            try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(name))
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

    /// 文件重命名后，同步更新所有专辑里的引用。
    func replaceFileName(_ oldName: String, with newName: String) {
        var changed = false
        for index in albums.indices {
            if let position = albums[index].fileNames.firstIndex(of: oldName) {
                albums[index].fileNames[position] = newName
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    /// 取某专辑内仍存在的音频文件 URL（顺序与 fileNames 一致）。
    func tracks(in album: Album) -> [URL] {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }
        return album.fileNames.compactMap { name in
            let url = documentsURL.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
}

// MARK: - 专辑详情

struct AlbumDetailView: View {
    let albumID: UUID
    @ObservedObject var albumStore: AlbumStore
    let onSelect: ([URL], Int, UIImage?) -> Void

    @State private var showAddSongs = false
    @State private var coverPickerItem: PhotosPickerItem?

    private var album: Album? {
        albumStore.albums.first { $0.id == albumID }
    }

    var body: some View {
        Group {
            if let album {
                let tracks = albumStore.tracks(in: album)
                List {
                    Section {
                        VStack(spacing: 12) {
                            coverView(for: album)

                            PhotosPicker(selection: $coverPickerItem, matching: .images) {
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

                    if tracks.isEmpty {
                        Text("还没有歌曲，点右上角 + 添加")
                            .foregroundStyle(.secondary)
                    } else {
                        Section("歌曲") {
                            ForEach(Array(tracks.enumerated()), id: \.element) { index, url in
                                Button {
                                    onSelect(tracks, index, albumStore.coverImage(for: album))
                                } label: {
                                    Label {
                                        Text(url.deletingPathExtension().lastPathComponent)
                                    } icon: {
                                        Image(systemName: "music.note")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        albumStore.removeFile(url.lastPathComponent, from: album)
                                    } label: {
                                        Label("移除", systemImage: "trash")
                                    }
                                }
                            }
                            .onMove { fromOffsets, toOffset in
                                albumStore.moveTracks(in: album, fromOffsets: fromOffsets, toOffset: toOffset)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("专辑不存在", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(album?.name ?? "专辑")
        .toolbar {
            if album != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSongs = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加歌曲")
                }
            }
        }
        .sheet(isPresented: $showAddSongs) {
            if let album {
                AddSongsView(albumID: album.id, albumStore: albumStore)
            }
        }
        .onChange(of: coverPickerItem) { _, item in
            guard let item, let album else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    albumStore.setCover(data: data, for: album)
                }
            }
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
            let allFiles = documentsAudioURLs()
            let memberNames = Set(album?.fileNames ?? [])

            Group {
                if allFiles.isEmpty {
                    ContentUnavailableView(
                        "还没有音频",
                        systemImage: "waveform",
                        description: Text("先在「文件」里导入音频")
                    )
                } else {
                    List(allFiles, id: \.self) { url in
                        let name = url.lastPathComponent
                        let isMember = memberNames.contains(name)
                        Button {
                            guard let album else { return }
                            if isMember {
                                albumStore.removeFile(name, from: album)
                            } else {
                                albumStore.addFiles([name], to: album)
                            }
                        } label: {
                            HStack {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: isMember ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(isMember ? .blue : .secondary)
                            }
                        }
                    }
                }
            }
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
