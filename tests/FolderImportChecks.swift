import Foundation

@main
struct FolderImportChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MelohaFolderChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("作品")
        let documents = root.appendingPathComponent("Documents")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("01 ケ\u{3099}ーム.mp3", "audio-one")
        try write("01 ゲーム.lrc", "[00:00.00]subtitle-one")
        try write("CD1/track.mp3", "audio-two")
        try write("CD1/track.vtt", "WEBVTT")
        try write("CD2/track.mp3", "audio-three")
        try write("Subs/track.lrc", "ambiguous")
        try write("Subs/unique.srt", "subtitle-four")
        try write("unique.wav", "audio-four")
        try write("orphan.lrc", "orphan")
        try write("cover.jpg", "invalid-image")
        try write("README.txt", "ignored")
        try write(".hidden/hidden.mp3", "ignored")
        try fm.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: documents)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try png.write(to: folder.appendingPathComponent("artwork01.png"))
        try png.write(to: folder.appendingPathComponent("page.png"))
        let existing = documents.appendingPathComponent("01 ゲーム.wav")
        try Data("keep-existing".utf8).write(to: existing)
        let selected = SelectedFolderAccess(url: folder)
        let result = try await Task.detached {
            try withExtendedLifetime(selected) {
                try FolderImportEngine.run(folder: selected.url, documents: documents) { _, _ in }
            }
        }.value
        precondition(result.tracks.count == 4)
        precondition(result.subtitleCount == 3)
        precondition(result.groups.count == 2)
        precondition(result.images.count == 1 && result.cover != nil)
        let first = result.tracks.first { URL(fileURLWithPath: $0).lastPathComponent == "01 ゲーム.mp3" }!
        precondition(first.hasPrefix("Albums/"))
        let paired = try String(contentsOf: documents.appendingPathComponent(first).deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8)
        let preserved = try String(contentsOf: existing, encoding: .utf8)
        precondition(paired == "[00:00.00]subtitle-one")
        precondition(preserved == "keep-existing")
        precondition(result.issues.contains { $0.contains("Subs/track.lrc") })
        precondition(result.issues.contains { $0.contains("orphan.lrc") })
        precondition(result.issues.contains { $0.contains("cover.jpg") })
        precondition(!result.tracks.contains { $0.contains("hidden") })
        precondition(!result.createdFiles.contains { $0.lastPathComponent.hasSuffix(".jpg") })
        // Import the same folder again: reserve new names and keep every subtitle with its new audio.
        let again = try await Task.detached {
            try FolderImportEngine.run(folder: folder, documents: documents) { _, _ in }
        }.value
        precondition(Set(result.tracks).isDisjoint(with: again.tracks))
        precondition(again.subtitleCount == 3)
        precondition(result.tracks.map { URL(fileURLWithPath: $0).lastPathComponent } == again.tracks.map { URL(fileURLWithPath: $0).lastPathComponent })
        let skipped = try await Task.detached {
            try FolderImportEngine.run(folder: folder, documents: documents, duplicatePolicy: .skip) { _, _ in }
        }.value
        precondition(skipped.tracks.count == 3 && skipped.subtitleCount == 3)
        // Cancel after the first file landed, before the next audio copy; everything is rolled back.
        let before = Set(try LibraryStorage.files(in: documents))
        let cancelled = Task.detached {
            try FolderImportEngine.run(folder: folder, documents: documents) { status, _ in
                if status.contains("CD1/track.mp3") {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await cancelled.value
            fatalError("Cancellation was ignored")
        } catch is CancellationError {}
        let after = Set(try LibraryStorage.files(in: documents))
        precondition(after == before)
        let empty = root.appendingPathComponent("Empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        do {
            _ = try await Task.detached {
                try FolderImportEngine.run(folder: empty, documents: documents) { _, _ in }
            }.value
            fatalError("Empty folder was accepted")
        } catch { precondition((error as NSError).domain == "FolderImport") }
        print("Folder import checks passed: Unicode, collisions, pairing, groups, images, repeat import, cancellation rollback, empty folder.")
    }
}
