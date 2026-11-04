import Foundation
import ImageIO

nonisolated struct FolderImportGroup: Sendable {
    var name: String
    var fileNames: [String]
}

nonisolated struct FolderImportResult: Sendable {
    var name: String
    var albumID: UUID = UUID()
    var tracks: [String] = []
    var groups: [FolderImportGroup] = []
    var images: [String] = []
    var cover: String?
    var subtitleCount = 0
    var issues: [String] = []
    var createdFiles: [URL] = []
}

nonisolated private struct FolderSourceFile {
    var url: URL
    var path: String
    var directory: String
    var ext: String { url.pathExtension.lowercased() }
    var stem: String { FolderImportEngine.key(url.deletingPathExtension().lastPathComponent) }
}

/// File IO stays off the main actor. Only files created by this import are rolled back.
nonisolated enum FolderImportEngine {
    static let audioExtensions = ["mp3", "m4a", "wav", "aac", "aiff"]
    static let subtitleExtensions = ["srt", "vtt", "lrc"]
    static let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"]

    static func key(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func coordinated<T>(_ url: URL, _ action: (URL) throws -> T) throws -> T {
        var outcome: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            outcome = Result { try action(readable) }
        }
        if let outcome { return try outcome.get() }
        throw coordinationError ?? NSError(domain: "FolderImport", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法读取文件，请确认已下载到本机且允许访问。"])
    }

    private static func scan(_ root: URL, issues: inout [String]) throws -> [FolderSourceFile] {
        var queue: [(URL, String)] = [(root, "")]
        var files: [FolderSourceFile] = []
        while let (directory, relative) = queue.popLast() {
            try Task.checkCancellation()
            do {
                // Retain original provider URLs, not the coordinator's temporary snapshot URLs.
                let entries: [(String, Bool)] = try coordinated(directory) { readable in
                    let children = try FileManager.default.contentsOfDirectory(at: readable,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey],
                        options: [.skipsHiddenFiles])
                    return try children.compactMap { child in
                        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
                        guard values.isSymbolicLink != true, values.isPackage != true,
                              values.isDirectory == true || values.isRegularFile == true else { return nil }
                        return (child.lastPathComponent, values.isDirectory == true)
                    }
                }
                for (name, isDirectory) in entries {
                    let path = relative.isEmpty ? name : relative + "/" + name
                    let url = directory.appendingPathComponent(name, isDirectory: isDirectory)
                    if isDirectory {
                        queue.append((url, path))
                    } else {
                        files.append(FolderSourceFile(url: url, path: path, directory: relative))
                    }
                }
            } catch {
                if relative.isEmpty { throw error }
                issues.append("\(relative)：\(error.localizedDescription)")
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Coordinated, streaming copy with cancellation between chunks and an atomic final move.
    static func copy(_ source: URL, to destination: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try coordinated(source) { readable in
            try Task.checkCancellation()
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let input = try FileHandle(forReadingFrom: readable)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                let finished = try autoreleasepool {
                    let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                    if chunk.isEmpty { return true }
                    try output.write(contentsOf: chunk)
                    return false
                }
                if finished { break }
            }
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func cleanup(_ files: [URL], documents: URL? = nil) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
            if let root = documents ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                LibraryStorage.removeEmptyParents(of: file, root: root)
            }
        }
    }

    static func run(folder: URL, documents: URL, duplicatePolicy: DuplicateImportPolicy = .keepBoth,
                    progress: @Sendable (String, Double?) -> Void) throws -> FolderImportResult {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        var result = FolderImportResult(name: folder.lastPathComponent)
        var completed = false
        defer { if !completed { cleanup(result.createdFiles, documents: documents) } }
        progress("正在扫描文件夹…", nil)
        let files = try scan(folder, issues: &result.issues)
        let audio = files.filter { audioExtensions.contains($0.ext) }
        guard !audio.isEmpty else {
            throw NSError(domain: "FolderImport", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "文件夹中没有支持的音频。支持 MP3、M4A、WAV、AAC、AIFF。"])
        }
        let subtitles = files.filter { subtitleExtensions.contains($0.ext) }
        let byStem = Dictionary(grouping: subtitles, by: \.stem)
        let audioCounts = Dictionary(grouping: audio, by: \.stem).mapValues(\.count)
        var usedSubtitles = Set<String>()
        var importedNames = Set<String>()
        let images = files.filter { imageExtensions.contains($0.ext) }.sorted {
            let left = coverRank($0), right = coverRank($1)
            return left != right ? left < right : $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let total = audio.count + images.count
        var count = 0
        for file in audio {
            try Task.checkCancellation()
            progress("正在导入 \(file.path)", Double(count) / Double(total))
            let filename = file.url.lastPathComponent
            if duplicatePolicy == .skip && importedNames.contains(key(filename)) {
                result.issues.append("\(file.path)：已按所选规则跳过同名音频")
                count += 1
                continue
            }
            let name = LibraryStorage.trackPath(albumID: result.albumID, name: filename)
            let destination = try LibraryStorage.resolve(name, in: documents)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try copy(file.url, to: destination)
                result.createdFiles.append(destination)
                importedNames.insert(key(filename))
                result.tracks.append(name)
                if !file.directory.isEmpty {
                    if let i = result.groups.firstIndex(where: { $0.name == file.directory }) {
                        result.groups[i].fileNames.append(name)
                    } else {
                        result.groups.append(FolderImportGroup(name: file.directory, fileNames: [name]))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.issues.append("\(file.path)：\(error.localizedDescription)")
                count += 1
                continue
            }
            let matches = byStem[file.stem] ?? []
            for ext in subtitleExtensions {
                let local = matches.filter { $0.ext == ext && key($0.directory) == key(file.directory) }
                let global = matches.filter { $0.ext == ext }
                // Separate subtitle folders are supported only when the pairing is unambiguous.
                let match = local.count == 1 ? local.first
                    : (local.isEmpty && audioCounts[file.stem] == 1 && global.count == 1 ? global.first : nil)
                guard let subtitle = match else { continue }
                let subtitleDestination = destination.deletingPathExtension().appendingPathExtension(ext)
                do {
                    try copy(subtitle.url, to: subtitleDestination)
                    result.createdFiles.append(subtitleDestination)
                    usedSubtitles.insert(subtitle.path)
                    result.subtitleCount += 1
                } catch is CancellationError { throw CancellationError() }
                catch {
                    usedSubtitles.insert(subtitle.path)
                    result.issues.append("\(subtitle.path)：\(error.localizedDescription)")
                }
            }
            count += 1
        }
        guard !result.tracks.isEmpty else {
            throw NSError(domain: "FolderImport", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "音频全部导入失败。" + (result.issues.first.map { "\n" + $0 } ?? "")])
        }
        for image in images {
            try Task.checkCancellation()
            progress("正在导入 \(image.path)", Double(count) / Double(total))
            let path = LibraryStorage.imagePath(albumID: result.albumID, name: UUID().uuidString + "." + image.ext)
            let destination = try LibraryStorage.resolve(path, in: documents)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try copy(image.url, to: destination)
                guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
                      CGImageSourceGetCount(source) > 0 else {
                    throw NSError(domain: "FolderImport", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "无法识别图片内容"])
                }
                result.createdFiles.append(destination)
                if result.cover == nil { result.cover = path }
                else { result.images.append(path) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try? FileManager.default.removeItem(at: destination)
                result.issues.append("\(image.path)：\(error.localizedDescription)")
            }
            count += 1
        }
        for subtitle in subtitles where !usedSubtitles.contains(subtitle.path) {
            result.issues.append("\(subtitle.path)：未找到唯一对应的音频，已跳过")
        }
        try Task.checkCancellation()
        progress("正在保存专辑…", 1)
        completed = true
        return result
    }

    private static func coverRank(_ image: FolderSourceFile) -> Int {
        let preferred = ["cover", "folder", "front", "artwork01", "artwork", "封面"]
        return (preferred.firstIndex(of: image.stem) ?? preferred.count) * 2
            + (image.directory.isEmpty ? 0 : 1)
    }
}
