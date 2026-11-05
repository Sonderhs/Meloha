import Foundation

@main
struct LibraryStorageChecks {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MelohaLibraryChecks-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func directory(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ root: URL, _ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func text(_ root: URL, _ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        func exists(_ root: URL, _ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }

        // Regression: an existing FLAC/AIF/etc. entry must not lock the entire library on upgrade.
        let formats = try directory("LegacyFormats")
        let media = ["song.FLAC", "book.m4b", "track.AIF", "track.aifc", "recording.caf", "extensionless", "legacy.custom"]
        for name in media { try write(formats, name, "original bytes: " + name) }
        try write(formats, "song.lrc", "FLAC subtitle")
        try write(formats, "metadata.json", "preserve metadata")
        try fm.createDirectory(at: formats.appendingPathComponent("directory.mp3"), withIntermediateDirectories: true)
        let oldFormats = Album(name: "Mixed formats", fileNames: media + ["metadata.json", "directory.mp3", "missing.flac"],
            groups: [AlbumGroup(name: "FLAC", fileNames: ["song.FLAC"])])
        try JSONEncoder().encode([oldFormats]).write(to: formats.appendingPathComponent("albums.json"))
        let newFormats = try LibraryStorage.migrate([oldFormats], root: formats)
        precondition(newFormats[0].fileNames.filter { $0.hasPrefix("Albums/") }.count == media.count)
        for name in media {
            let path = newFormats[0].fileNames.first { ($0 as NSString).lastPathComponent == name }!
            precondition(LibraryStorage.isAudioReference(path))
            precondition(tryText(formats, path) == "original bytes: " + name)
        }
        let flac = newFormats[0].groupList[0].fileNames[0]
        precondition(tryText(formats, (flac as NSString).deletingPathExtension + ".lrc") == "FLAC subtitle")
        precondition(exists(formats, "metadata.json") && exists(formats, "directory.mp3"))
        let formatPlan = try LibraryStorage.deletionPlan(newFormats, ids: [oldFormats.id], root: formats)
        precondition(!formatPlan.paths.contains("metadata.json") && !formatPlan.paths.contains("directory.mp3"))
        try LibraryStorage.transact(root: formats, next: [], removals: formatPlan.paths)
        precondition(!exists(formats, flac) && exists(formats, "metadata.json") && exists(formats, "directory.mp3"))
        print("Legacy format regression checks passed: FLAC, M4B, AIF, AIFC, CAF, missing/extensionless/unlisted files, subtitles and protected metadata.")

        // Old shared flat files become independent copies and retain group membership and subtitles.
        let root = try directory("Migration")
        try write(root, "01 ケ\u{3099}ーム.mp3", "audio")
        try write(root, "01 ゲーム.LRC", "subtitles")
        try write(root, "01 ゲーム.wav", "loose audio with shared old subtitle")
        try write(root, "cover.jpg", "cover")
        let a = Album(name: "A", fileNames: ["01 ゲーム.mp3"], coverFileName: "cover.jpg",
                      groups: [AlbumGroup(name: "CD1", fileNames: ["01 ゲーム.mp3"])], pinRank: 0)
        let b = Album(name: "B", fileNames: a.fileNames)
        try JSONEncoder().encode([a, b]).write(to: root.appendingPathComponent("albums.json"))
        let migrated = try LibraryStorage.migrate([a, b], root: root)
        let pathA = migrated[0].fileNames[0], pathB = migrated[1].fileNames[0]
        precondition(pathA != pathB)
        precondition((pathA as NSString).lastPathComponent == "01 ゲーム.mp3")
        let audioA = try text(root, pathA), audioB = try text(root, pathB)
        precondition(audioA == "audio" && audioB == "audio")
        precondition(migrated[0].groupList[0].fileNames == [pathA])
        let subtitleA = (pathA as NSString).deletingPathExtension + ".lrc"
        precondition(tryText(root, subtitleA) == "subtitles")
        precondition(!exists(root, "01 ゲーム.mp3"))
        precondition(exists(root, "01 ゲーム.LRC")) // Still used by the loose WAV.
        precondition(migrated[0].pinRank == 0)
        let migratedAgain = try LibraryStorage.migrate(migrated, root: root)
        precondition(migratedAgain == migrated)
        let stored = try JSONDecoder().decode([Album].self, from: Data(contentsOf: root.appendingPathComponent("albums.json")))
        precondition(stored == migrated)
        let files = try LibraryStorage.files(in: root)
        precondition(files.contains(pathA) && files.contains(pathB))

        // An explicitly shared track survives deleting one album; selecting both deletes it once.
        var sharedB = migrated[1]
        sharedB.fileNames.append(pathA)
        let plan = try LibraryStorage.deletionPlan([migrated[0], sharedB], ids: [a.id], root: root)
        precondition(plan.sharedCount == 1 && plan.trackCount == 0)
        precondition(!plan.paths.contains(pathA) && !plan.paths.contains(subtitleA))
        try LibraryStorage.transact(root: root, next: plan.remaining, removals: plan.paths)
        precondition(exists(root, pathA) && exists(root, subtitleA))
        let both = try LibraryStorage.deletionPlan([migrated[0], sharedB], ids: [a.id, b.id], root: root)
        precondition(both.trackCount == 2 && both.sharedCount == 0)
        try LibraryStorage.transact(root: root, next: both.remaining, removals: both.paths)
        precondition(!exists(root, pathA) && !exists(root, pathB) && !exists(root, subtitleA))
        precondition(exists(root, "01 ゲーム.wav") && exists(root, "01 ゲーム.LRC"))

        // Failed metadata commit restores staged files, without publishing half an operation.
        let failed = try directory("FailedCommit")
        try write(failed, "song.mp3", "keep")
        try fm.createDirectory(at: failed.appendingPathComponent("albums.json"), withIntermediateDirectories: true)
        do {
            try LibraryStorage.transact(root: failed, next: [], removals: ["song.mp3"])
            fatalError("Invalid metadata destination accepted")
        } catch {}
        precondition(tryText(failed, "song.mp3") == "keep")
        precondition(!exists(failed, ".library-transaction"))

        // Simulate termination after files were staged, before metadata was committed.
        let interrupted = try directory("Interrupted")
        let copied = LibraryStorage.trackPath(albumID: UUID(), name: "song.mp3")
        let journal = interrupted.appendingPathComponent(".library-transaction")
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        try write(interrupted, ".library-transaction/removed-0", "original")
        try write(interrupted, copied, "partial migration copy")
        let state = LibraryTransaction(nextAlbums: Data("[]".utf8),
            copies: [LibraryFileCopy(source: "song.mp3", destination: copied)], removals: ["song.mp3"])
        try JSONEncoder().encode(state).write(to: journal.appendingPathComponent("state.json"))
        try LibraryStorage.recover(root: interrupted)
        precondition(tryText(interrupted, "song.mp3") == "original" && !exists(interrupted, copied))
        try LibraryStorage.recover(root: interrupted) // Idempotent.

        // A committed operation never rolls back, even after subsequent metadata changes.
        let committed = try directory("Committed")
        try write(committed, ".library-transaction/removed-0", "deleted")
        try write(committed, ".library-transaction/committed", "")
        try write(committed, "albums.json", "subsequent metadata")
        try JSONEncoder().encode(state).write(to: committed.appendingPathComponent(".library-transaction/state.json"))
        try LibraryStorage.recover(root: committed)
        precondition(!exists(committed, "song.mp3") && !exists(committed, ".library-transaction"))

        // Path validation and symlink containment apply equally to backup and deletion.
        for path in ["../escape", "/absolute", "Albums/../escape", "Albums//song.mp3", "Albums/a/../../escape", "x/y.mp3", "Albums/a\\b.mp3", ".library-transaction/state.json"] {
            precondition(!LibraryStorage.safePath(path))
        }
        let outside = try directory("Outside")
        let malicious = try directory("Symlink")
        try fm.createSymbolicLink(at: malicious.appendingPathComponent("Albums"), withDestinationURL: outside)
        do { _ = try LibraryStorage.resolve("Albums/song.mp3", in: malicious); fatalError("Symlink accepted") }
        catch {}

        // Pinned ordering is stable, persisted by Codable, and supports reordering/unpinning.
        var pins = [Album(name: "first"), Album(name: "second"), Album(name: "third")]
        LibraryStorage.togglePin(pins[2].id, in: &pins)
        LibraryStorage.togglePin(pins[1].id, in: &pins)
        precondition(LibraryStorage.ordered(pins).map(\.name) == ["third", "second", "first"])
        LibraryStorage.movePin(pins[1].id, by: -1, in: &pins)
        precondition(LibraryStorage.ordered(pins).map(\.name) == ["second", "third", "first"])
        pins = try JSONDecoder().decode([Album].self, from: JSONEncoder().encode(pins))
        LibraryStorage.togglePin(pins[1].id, in: &pins)
        precondition(LibraryStorage.ordered(pins).map(\.name) == ["third", "first", "second"])
        let oldJSON = Data("[{\"id\":\"\(UUID().uuidString)\",\"name\":\"old\",\"fileNames\":[]}]".utf8)
        precondition(tryDecode(oldJSON)[0].pinRank == nil)

        // New nested backup round-trip, legacy flat backup, invalid paths and symlink refusal.
        let backupRoot = try directory("Backup")
        let backupPath = LibraryStorage.trackPath(albumID: pins[0].id, name: "01.mp3")
        try write(backupRoot, backupPath, "backup audio")
        try write(backupRoot, (backupPath as NSString).deletingPathExtension + ".lrc", "backup subtitle")
        pins[0].fileNames = [backupPath]
        try JSONEncoder().encode(pins).write(to: backupRoot.appendingPathComponent("albums.json"))
        let backup = try BackupManager.writeBackup(documents: backupRoot)
        defer { BackupManager.cleanUpTemporary(backup) }
        let restored = try directory("Restored")
        try BackupManager.restore(from: backup, documents: restored)
        precondition(tryText(restored, backupPath) == "backup audio")
        let restoredAlbums = try JSONDecoder().decode([Album].self, from: Data(contentsOf: restored.appendingPathComponent("albums.json")))
        precondition(restoredAlbums == pins)

        let legacyRoot = try directory("Legacy")
        let legacy: [String: Any] = ["version": 1, "settings": [:], "files": [["name": "old.mp3", "data": Data("old".utf8).base64EncodedString()]]]
        let legacyURL = base.appendingPathComponent("legacy.melohabk")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
        try BackupManager.restore(from: legacyURL, documents: legacyRoot)
        precondition(tryText(legacyRoot, "old.mp3") == "old")
        // Rewrite only a manifest, keeping the original audio payload intact.
        var archive = try Data(contentsOf: backup)
        let footer = archive.suffix(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * $1.offset)) }
        let start = archive.count - 8 - Int(footer)
        var manifest = try JSONDecoder().decode(BackupManifest.self, from: archive.subdata(in: start..<(archive.count - 8)))
        manifest.entries[0].name = "Albums/../../escape.mp3"
        let altered = try JSONEncoder().encode(manifest)
        archive = archive.prefix(start)
        archive.append(altered)
        var size = UInt64(altered.count).littleEndian
        archive.append(withUnsafeBytes(of: &size) { Data($0) })
        let bad = base.appendingPathComponent("bad.melohabk")
        try archive.write(to: bad)
        let badRoot = try directory("BadRestore")
        do { try BackupManager.restore(from: bad, documents: badRoot); fatalError("Traversal backup accepted") }
        catch {}
        precondition((try? LibraryStorage.files(in: badRoot).isEmpty) == true)
        print("Library checks passed: migration, shared deletion, batch deletion, rollback, crash recovery, pin persistence, backup round-trip, legacy restore, path safety.")
    }

    static func tryText(_ root: URL, _ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "<missing>" }
    static func tryDecode(_ data: Data) -> [Album] { (try? JSONDecoder().decode([Album].self, from: data)) ?? [] }
}
