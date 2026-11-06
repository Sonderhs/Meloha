import Foundation
import AVFoundation

@main
struct AudioCompressionChecks {
    static func main() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("MelohaCompressionChecks-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav")
        try makeWave(source, channels: 2)
        let compact = try await AudioCompression.prepare(source: source, reference: "source.wav", quality: .compact, directory: folder)
        precondition(compact.channels == 2 && compact.savedBytes > 0)
        precondition(abs(compact.duration - 8) < 0.01)
        let decoded = try AVAudioFile(forReading: compact.file)
        precondition(decoded.processingFormat.channelCount == 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 8_192)!
        try decoded.read(into: buffer)
        let data = buffer.floatChannelData!
        let difference = (0..<Int(buffer.frameLength)).reduce(0.0) { sum, i in sum + pow(Double(data[0][i] - data[1][i]), 2) }
        precondition(difference / Double(buffer.frameLength) > 0.01, "Stereo channels were merged")
        print("Compression stereo and duration checks passed.")

        let mono = folder.appendingPathComponent("mono.wav")
        try makeWave(mono, channels: 1)
        let monoResult = try await AudioCompression.prepare(source: mono, reference: "mono.wav", quality: .balanced, directory: folder)
        precondition(monoResult.channels == 1 && monoResult.compressedBytes < monoResult.originalBytes)
        let high = try await AudioCompression.prepare(source: source, reference: "source.wav", quality: .high, directory: folder)
        precondition(high.compressedBytes > compact.compressedBytes)

        // Existing compressed audio can be recompressed, retaining its embedded title.
        let annotated = folder.appendingPathComponent("annotated.m4a")
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Meloha compression check" as NSString
        let session = AVAssetExportSession(asset: AVURLAsset(url: high.file), presetName: AVAssetExportPresetPassthrough)!
        session.metadata = [title]
        try await session.export(to: annotated, as: .m4a)
        let recompressed = try await AudioCompression.prepare(source: annotated, reference: "annotated.m4a", quality: .compact, directory: folder)
        let metadata = try await AVURLAsset(url: recompressed.file).load(.commonMetadata)
        let titles = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
        let resultTitle = try await titles.first?.load(.stringValue)
        precondition(resultTitle == "Meloha compression check")
        do {
            _ = try await AudioCompression.prepare(source: compact.file, reference: "already-small.m4a", quality: .high, directory: folder)
            fatalError("Larger output should be skipped")
        } catch AudioCompressionError.largerOutput {}

        let surround = folder.appendingPathComponent("surround.wav")
        try makeWave(surround, channels: 3)
        do {
            _ = try await AudioCompression.prepare(source: surround, reference: "surround.wav", quality: .compact, directory: folder)
            fatalError("Multichannel input should not silently lose channels")
        } catch AudioCompressionError.unsupportedChannels {}
        let bad = folder.appendingPathComponent("bad.mp3")
        try Data("invalid audio".utf8).write(to: bad)
        do {
            _ = try await AudioCompression.prepare(source: bad, reference: "bad.mp3", quality: .compact, directory: folder)
            fatalError("Invalid audio accepted")
        } catch {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AudioCompression.prepare(source: source, reference: "source.wav", quality: .compact, directory: folder)
        }
        do { _ = try await cancelled.value; fatalError("Cancelled compression completed") }
        catch is CancellationError {}
        let beforeCancellation = Set(try fm.contentsOfDirectory(atPath: folder.path))
        let midCancelled = Task {
            try await AudioCompression.prepare(source: source, reference: "source.wav", quality: .compact, directory: folder) { fraction in
                if fraction > 0.1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await midCancelled.value; fatalError("Mid-stream cancellation completed") }
        catch is CancellationError {}
        let afterCancellation = Set(try fm.contentsOfDirectory(atPath: folder.path))
        precondition(afterCancellation == beforeCancellation)
        precondition(fm.fileExists(atPath: source.path) && fm.fileExists(atPath: compact.file.path))
        print("Compression checks passed: stereo, mono, bitrate choices, duration, AAC recompression, metadata, larger-output skip, unsupported input, cancellation, originals retained.")
    }

    static func makeWave(_ url: URL, channels: AVAudioChannelCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<8 {
            for c in 0..<Int(channels) {
                for i in 0..<48_000 { buffer.floatChannelData![c][i] = Float(0.4 * sin(2 * .pi * Double(440 + c * 220) * Double(i) / 48_000)) }
            }
            try file.write(from: buffer)
        }
    }
}
