import Foundation

nonisolated enum DuplicateImportPolicy: String, CaseIterable, Sendable {
    case skip, keepBoth
    var label: String { self == .skip ? "跳过同名音频" : "保留两份" }
}

nonisolated struct LibraryFileCopy: Codable, Sendable {
    var source: String
    var destination: String
}

nonisolated struct LibraryTransaction: Codable {
    var nextAlbums: Data
    var copies: [LibraryFileCopy]
    var removals: [String]
    var moves: [LibraryFileCopy]? = nil
}

nonisolated struct AlbumDeletionPlan: Sendable {
    var remaining: [Album]
    var paths: [String]
    var albumCount: Int
    var trackCount: Int
    var sharedCount: Int
}

/// Stored references are paths relative to Documents. Display names always use the leaf name.
nonisolated enum LibraryStorage {
    static let audioExtensions = ["mp3", "m4a", "wav", "aac", "aiff", "flac", "m4b", "aif", "aifc", "caf"]
    static let subtitleExtensions = ["srt", "vtt", "lrc"]
    static let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "bmp"]

    /// Old album membership is the source of truth during migration, not a playback-format whitelist.
    /// Never reinterpret library metadata, subtitles, images or backup archives as audio.
    static func isLegacyMediaName(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let protectedExtensions = imageExtensions + subtitleExtensions
            + ["json", "plist", "melohabk", "txt", "xml", "db", "sqlite", "sqlite3", "zip", "pdf", "safetensors"]
        return !protectedExtensions.contains(ext)
    }

    static func isAudioReference(_ path: String) -> Bool {
        if audioExtensions.contains((path as NSString).pathExtension.lowercased()) { return true }
        let parts = path.split(separator: "/")
        return parts.count == 5 && parts[0] == "Albums" && parts[2] == "Audio" && isLegacyMediaName(path)
    }

    static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":") }),
              parts.count == 1 || parts.first == "Albums" else { return false }
        return true
    }

    static func resolve(_ path: String, in root: URL) throws -> URL {
        guard safePath(path) else { throw failure("文件路径不安全：\(path)") }
        var current = root
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            let attributes = try? FileManager.default.attributesOfItem(atPath: current.path)
            if (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw failure("不支持符号链接：\(path)")
            }
        }
        return current
    }

    static func reference(_ url: URL, in root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    static func trackPath(albumID: UUID, name: String, trackID: UUID = UUID()) -> String {
        "Albums/\(albumID.uuidString)/Audio/\(trackID.uuidString)/\(name)"
    }

    static func imagePath(albumID: UUID, name: String = UUID().uuidString + ".jpg") -> String {
        "Albums/\(albumID.uuidString)/Images/\(name)"
    }

    /// Only the managed album tree is recursive; caches and arbitrary provider directories are excluded.
    static func files(in root: URL) throws -> [String] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var result: [String] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { result.append(entry.lastPathComponent) }
        }
        let albums = root.appendingPathComponent("Albums", isDirectory: true)
        if fm.fileExists(atPath: albums.path) {
            _ = try resolve("Albums", in: root)
            var enumerationError: Error?
            let iterator = fm.enumerator(at: albums, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false })
            while let file = iterator?.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { iterator?.skipDescendants(); continue }
                if values.isRegularFile == true { result.append(reference(file, in: root)) }
            }
            if let enumerationError { throw enumerationError }
        }
        return result.sorted()
    }

    static func sidecars(_ audio: String, root: URL) throws -> [String] {
        let url = try resolve(audio, in: root)
        let stem = key(url.deletingPathExtension().lastPathComponent)
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { subtitleExtensions.contains($0.pathExtension.lowercased()) && key($0.deletingPathExtension().lastPathComponent) == stem }
            .map { reference($0, in: root) }
    }

    static func deletionPlan(_ albums: [Album], ids: Set<UUID>, root: URL) throws -> AlbumDeletionPlan {
        let selected = albums.filter { ids.contains($0.id) }
        let remaining = albums.filter { !ids.contains($0.id) }
        let retained = Set(remaining.flatMap(\.fileNames).map(key))
        let tracks = Set(selected.flatMap(\.fileNames))
        let exclusive = tracks.filter { !retained.contains(key($0)) }
        let exclusiveKeys = Set(exclusive.map(key))
        let otherAudio = try files(in: root).filter {
            isAudioReference($0) && !exclusiveKeys.contains(key($0))
        }
        let retainedBases = Set((remaining.flatMap(\.fileNames) + otherAudio).map { key(($0 as NSString).deletingPathExtension) })
        var paths = Set<String>()
        for track in exclusive {
            guard isAudioReference(track) else { continue }
            let file = try resolve(track, in: root)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               (attributes[.type] as? FileAttributeType) != .typeRegular { continue }
            paths.insert(track)
            if !retainedBases.contains(key((track as NSString).deletingPathExtension)) {
                paths.formUnion(try sidecars(track, root: root))
            }
        }
        let retainedImages = Set(remaining.flatMap { $0.imageList + [$0.coverFileName].compactMap { $0 } }.map(key))
        for path in selected.flatMap({ $0.imageList + [$0.coverFileName].compactMap { $0 } }) where !retainedImages.contains(key(path)) {
            guard imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { throw failure("专辑包含无效的图片路径") }
            _ = try resolve(path, in: root)
            paths.insert(path)
        }
        return AlbumDeletionPlan(remaining: remaining, paths: paths.sorted(), albumCount: selected.count,
            trackCount: exclusive.count, sharedCount: tracks.count - exclusive.count)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Meloha.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// A write-ahead journal makes copying/moving files and publishing albums.json recoverable.
    static func transact(root: URL, next: [Album], copies: [LibraryFileCopy] = [], removals: [String] = [], moves: [LibraryFileCopy] = [],
                         progress: @Sendable (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        try recover(root: root)
        let transaction = LibraryTransaction(nextAlbums: try JSONEncoder().encode(next), copies: copies, removals: removals, moves: moves)
        for copy in copies + moves {
            _ = try resolve(copy.source, in: root)
            let destination = try resolve(copy.destination, in: root)
            guard !fm.fileExists(atPath: destination.path) else { throw failure("目标文件已存在，操作已停止") }
        }
        for path in removals { _ = try resolve(path, in: root) }
        let journal = root.appendingPathComponent(".library-transaction", isDirectory: true)
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        try JSONEncoder().encode(transaction).write(to: journal.appendingPathComponent("state.json"), options: .atomic)
        do {
            for (i, copy) in copies.enumerated() {
                progress("正在整理文件 \(i + 1)/\(copies.count)")
                let destination = try resolve(copy.destination, in: root)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: resolve(copy.source, in: root), to: destination)
            }
            for (i, move) in moves.enumerated() {
                let destination = try resolve(move.destination, in: root)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: resolve(move.source, in: root), to: journal.appendingPathComponent("renamed-\(i)"))
            }
            for (i, move) in moves.enumerated() {
                try fm.moveItem(at: journal.appendingPathComponent("renamed-\(i)"), to: resolve(move.destination, in: root))
            }
            for (i, path) in removals.enumerated() {
                let file = try resolve(path, in: root)
                if fm.fileExists(atPath: file.path) {
                    try fm.moveItem(at: file, to: journal.appendingPathComponent("removed-\(i)"))
                }
            }
            try transaction.nextAlbums.write(to: root.appendingPathComponent("albums.json"), options: .atomic)
        } catch {
            try recover(root: root)
            throw error
        }
        // Logical commit has succeeded. Retry physical cleanup at the next launch if necessary.
        try? recover(root: root)
    }

    static func recover(root: URL) throws {
        let fm = FileManager.default
        let journal = root.appendingPathComponent(".library-transaction", isDirectory: true)
        let state = journal.appendingPathComponent("state.json")
        guard fm.fileExists(atPath: journal.path) else { return }
        guard fm.fileExists(atPath: state.path) else { try fm.removeItem(at: journal); return }
        let transaction = try JSONDecoder().decode(LibraryTransaction.self, from: Data(contentsOf: state))
        let marker = journal.appendingPathComponent("committed")
        let committed = fm.fileExists(atPath: marker.path)
            || (try? Data(contentsOf: root.appendingPathComponent("albums.json"))) == transaction.nextAlbums
        if committed && !fm.fileExists(atPath: marker.path) {
            try Data().write(to: marker, options: .atomic)
        }
        if !committed {
            for (i, path) in transaction.removals.enumerated() {
                let staged = journal.appendingPathComponent("removed-\(i)")
                if fm.fileExists(atPath: staged.path) {
                    let destination = try resolve(path, in: root)
                    guard !fm.fileExists(atPath: destination.path) else { throw failure("恢复中发现同名文件，请保留数据后重试") }
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: staged, to: destination)
                }
            }
            for (i, move) in (transaction.moves ?? []).enumerated().reversed() {
                let staged = journal.appendingPathComponent("renamed-\(i)")
                let destination = try resolve(move.destination, in: root)
                let original = try resolve(move.source, in: root)
                let saved = fm.fileExists(atPath: staged.path) ? staged : destination
                if fm.fileExists(atPath: saved.path) {
                    guard !fm.fileExists(atPath: original.path) else { throw failure("恢复重命名时发现同名文件") }
                    try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: saved, to: original)
                }
                removeEmptyParents(of: destination, root: root)
            }
            for copy in transaction.copies {
                let path = try resolve(copy.destination, in: root)
                if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
                removeEmptyParents(of: path, root: root)
            }
        }
        try fm.removeItem(at: journal)
        if committed {
            for move in transaction.moves ?? [] { removeEmptyParents(of: try resolve(move.source, in: root), root: root) }
            for path in transaction.removals { removeEmptyParents(of: try resolve(path, in: root), root: root) }
        }
    }

    static func removeEmptyParents(of url: URL, root: URL) {
        let fm = FileManager.default
        let albums = root.appendingPathComponent("Albums").standardizedFileURL.path + "/"
        var parent = url.deletingLastPathComponent()
        while parent.standardizedFileURL.path.hasPrefix(albums) {
            guard (try? fm.contentsOfDirectory(atPath: parent.path).isEmpty) == true else { break }
            try? fm.removeItem(at: parent)
            parent.deleteLastPathComponent()
        }
    }

    /// Old shared files become independent copies per album, retaining every reference and sidecar.
    static func migrate(_ albums: [Album], root: URL, progress: @Sendable (String) -> Void = { _ in }) throws -> [Album] {
        var updated = albums
        var copies: [LibraryFileCopy] = []
        var obsolete = Set<String>()
        let fm = FileManager.default
        for i in updated.indices {
            var mapping: [String: String] = [:]
            for name in updated[i].fileNames where !name.hasPrefix("Albums/") {
                let source = try resolve(name, in: root)
                guard let attributes = try? fm.attributesOfItem(atPath: source.path),
                      (attributes[.type] as? FileAttributeType) == .typeRegular,
                      isLegacyMediaName(name) else { continue }
                let destination = trackPath(albumID: updated[i].id, name: source.lastPathComponent)
                mapping[name] = destination
                copies.append(LibraryFileCopy(source: name, destination: destination))
                obsolete.insert(name)
                for subtitle in try sidecars(name, root: root) {
                    let dest = (destination as NSString).deletingPathExtension + "." + (subtitle as NSString).pathExtension.lowercased()
                    copies.append(LibraryFileCopy(source: subtitle, destination: dest))
                    obsolete.insert(subtitle)
                }
            }
            updated[i].fileNames = updated[i].fileNames.map { mapping[$0] ?? $0 }
            updated[i].groupList = updated[i].groupList.map {
                var group = $0
                group.fileNames = group.fileNames.map { mapping[$0] ?? $0 }
                return group
            }
            var imageMapping: [String: String] = [:]
            for path in updated[i].imageList + [updated[i].coverFileName].compactMap({ $0 }) where !path.hasPrefix("Albums/") {
                guard imageMapping[path] == nil else { continue }
                let source = try resolve(path, in: root)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = imagePath(albumID: updated[i].id, name: UUID().uuidString + "." + source.pathExtension)
                imageMapping[path] = destination
                copies.append(LibraryFileCopy(source: path, destination: destination))
                obsolete.insert(path)
            }
            updated[i].imageList = updated[i].imageList.map { imageMapping[$0] ?? $0 }
            if let cover = updated[i].coverFileName { updated[i].coverFileName = imageMapping[cover] ?? cover }
        }
        guard !copies.isEmpty else { return albums }
        let retained = Set(updated.flatMap { $0.fileNames + $0.imageList + [$0.coverFileName].compactMap { $0 } }.map(key))
        let obsoleteKeys = Set(obsolete.map(key))
        let looseAudio = try files(in: root).filter {
            isAudioReference($0) && !obsoleteKeys.contains(key($0))
        }
        let retainedBases = Set((updated.flatMap(\.fileNames) + looseAudio).map { key(($0 as NSString).deletingPathExtension) })
        let removals = obsolete.filter {
            !retained.contains(key($0)) && !(subtitleExtensions.contains(($0 as NSString).pathExtension.lowercased())
                && retainedBases.contains(key(($0 as NSString).deletingPathExtension)))
        }.sorted()
        try transact(root: root, next: updated, copies: copies, removals: removals, progress: progress)
        return updated
    }

    static func reordered(_ values: [String], from offsets: IndexSet, to destination: Int) -> [String] {
        guard !offsets.isEmpty, offsets.allSatisfy(values.indices.contains), (0...values.count).contains(destination) else { return values }
        let moving = offsets.sorted().map { values[$0] }
        var result = values.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        result.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        return result
    }

    static func reorderGroup(_ album: Album, groupID: UUID, visible: [String], from offsets: IndexSet, to destination: Int) -> Album {
        var result = album
        guard let index = result.groupList.firstIndex(where: { $0.id == groupID }), album.sortMode == .manual else { return result }
        let reordered = reordered(visible, from: offsets, to: destination)
        var groups = result.groupList
        groups[index].fileNames = reordered + groups[index].fileNames.filter { !visible.contains($0) }
        result.groupList = groups
        let members = Set(visible)
        var iterator = reordered.makeIterator()
        result.fileNames = result.fileNames.map { members.contains($0) ? (iterator.next() ?? $0) : $0 }
        return result
    }

    static func playbackAlbum(preferred: UUID?, file: String, albums: [Album]) -> UUID? {
        if let preferred, albums.contains(where: { $0.id == preferred && $0.fileNames.contains(file) }) { return preferred }
        return albums.first(where: { $0.fileNames.contains(file) })?.id
    }

    static func renameAudio(_ reference: String, to input: String, albumID: UUID, albums: [Album], root: URL) throws -> (albums: [Album], reference: String) {
        let source = try resolve(reference, in: root)
        let ext = source.pathExtension
        var base = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty && base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
        guard !base.isEmpty, !base.hasPrefix("."), !base.contains("/"), !base.contains("\\"),
              !base.contains(":"), !base.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw failure("名称不能为空，不能以点开头或包含斜杠、冒号、换行等控制字符")
        }
        let name = base + (ext.isEmpty ? "" : "." + ext)
        if source.lastPathComponent == name { return (albums, reference) }
        let shared = albums.filter { $0.fileNames.contains(reference) }
        guard !shared.isEmpty else { throw failure("音频不在专辑中") }
        for album in shared where album.fileNames.contains(where: { $0 != reference && key(($0 as NSString).lastPathComponent) == key(name) }) {
            throw failure("专辑「\(album.name)」已有同名音频，请换一个名称")
        }
        let new = trackPath(albumID: albumID, name: name)
        var moves = [LibraryFileCopy(source: reference, destination: new)]
        for subtitle in try sidecars(reference, root: root) {
            moves.append(LibraryFileCopy(source: subtitle, destination: (new as NSString).deletingPathExtension + "." + (subtitle as NSString).pathExtension.lowercased()))
        }
        var updated = albums
        for i in updated.indices {
            updated[i].fileNames = updated[i].fileNames.map { $0 == reference ? new : $0 }
            updated[i].groupList = updated[i].groupList.map {
                var group = $0
                group.fileNames = group.fileNames.map { $0 == reference ? new : $0 }
                return group
            }
        }
        try transact(root: root, next: updated, moves: moves)
        return (updated, new)
    }

    static func ordered(_ albums: [Album]) -> [Album] {
        albums.enumerated().sorted {
            let a = $0.element.pinRank, b = $1.element.pinRank
            if let a, let b, a != b { return a < b }
            if (a != nil) != (b != nil) { return a != nil }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    static func togglePin(_ id: UUID, in albums: inout [Album]) {
        normalizePins(&albums)
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        if albums[index].pinRank != nil { albums[index].pinRank = nil }
        else { albums[index].pinRank = albums.compactMap(\.pinRank).count }
        normalizePins(&albums)
    }

    static func movePin(_ id: UUID, by offset: Int, in albums: inout [Album]) {
        var pinned = ordered(albums).filter { $0.pinRank != nil }.map(\.id)
        guard let index = pinned.firstIndex(of: id), pinned.indices.contains(index + offset) else { return }
        pinned.swapAt(index, index + offset)
        for i in albums.indices { if let rank = pinned.firstIndex(of: albums[i].id) { albums[i].pinRank = rank } }
    }

    private static func normalizePins(_ albums: inout [Album]) {
        let order = ordered(albums).filter { $0.pinRank != nil }.map(\.id)
        for i in albums.indices { albums[i].pinRank = order.firstIndex(of: albums[i].id) }
    }
}

nonisolated func storageReference(_ url: URL) -> String {
    guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return url.lastPathComponent }
    return LibraryStorage.reference(url, in: root)
}

extension Notification.Name {
    nonisolated static let libraryFilesChanged = Notification.Name("Meloha.libraryFilesChanged")
}

extension Notification.Name {
    nonisolated static let libraryAudioRenamed = Notification.Name("Meloha.libraryAudioRenamed")
    nonisolated static let libraryAlbumOrderChanged = Notification.Name("Meloha.libraryAlbumOrderChanged")
}
