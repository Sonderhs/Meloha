import Foundation

nonisolated enum AudioCompressionQuality: Int, CaseIterable, Identifiable, Sendable {
    case compact = 128, balanced = 192, high = 256
    var id: Int { rawValue }
    var bitRate: Int { rawValue * 1000 }
    var label: String { "\(rawValue) kbps" }
}

nonisolated struct CompressedAudio: Identifiable, Sendable {
    let id = UUID()
    let reference: String
    let file: URL
    let originalBytes: Int64
    let originalModified: Date
    let compressedBytes: Int64
    let duration: TimeInterval
    let channels: UInt32
    var savedBytes: Int64 { max(0, originalBytes - compressedBytes) }
}

nonisolated struct LibraryFileImport: Sendable {
    let source: URL
    let destination: String
}
