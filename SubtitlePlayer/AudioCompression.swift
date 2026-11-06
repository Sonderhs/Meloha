import Foundation
@preconcurrency import AVFoundation

nonisolated enum AudioCompressionError: LocalizedError {
    case unsupportedChannels, invalidAudio, largerOutput, conversion(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedChannels: return "目前支持单声道和双声道，已保留原文件"
        case .invalidAudio: return "音频无法完整读取或压缩结果校验失败，已保留原文件"
        case .largerOutput: return "压缩后没有变小，已跳过并保留原文件"
        case .conversion(let message): return "压缩失败：" + message
        }
    }
}

nonisolated enum AudioCompression {
    /// Streaming decode/resample/encode. Audio buffers stay bounded even for multi-hour FLACs.
    static func prepare(source: URL, reference: String, quality: AudioCompressionQuality, directory: URL,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> CompressedAudio {
        try Task.checkCancellation()
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0,
              let modified = attributes[.modificationDate] as? Date else { throw AudioCompressionError.invalidAudio }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = directory.appendingPathComponent(UUID().uuidString + ".m4a")
        let destination = directory.appendingPathComponent(UUID().uuidString + ".m4a")
        var succeeded = false
        defer {
            try? fm.removeItem(at: raw)
            if !succeeded { try? fm.removeItem(at: destination) }
        }
        let info: (duration: Double, channels: UInt32)
        do {
            info = try autoreleasepool { try encode(source: source, destination: raw, quality: quality, progress: progress) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as AudioCompressionError { throw error }
        catch { throw AudioCompressionError.conversion("编码音频：" + error.localizedDescription) }
        try Task.checkCancellation()
        // Remux metadata without re-encoding so embedded artwork/title are retained.
        let metadata: [AVMetadataItem]
        do { metadata = try await AVURLAsset(url: source).load(.metadata) }
        catch { throw AudioCompressionError.conversion("读取音频标签：" + error.localizedDescription) }
        if metadata.isEmpty {
            try fm.moveItem(at: raw, to: destination)
        } else {
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: raw), presetName: AVAssetExportPresetPassthrough) else {
                throw AudioCompressionError.invalidAudio
            }
            session.metadata = metadata
            do { try await session.export(to: destination, as: .m4a) }
            catch { throw AudioCompressionError.conversion("保存音频标签：" + error.localizedDescription) }
        }
        try Task.checkCancellation()
        // Decode the entire result, rather than trusting a readable header or export success.
        do { try autoreleasepool { try validate(file: destination, duration: info.duration, channels: info.channels) } }
        catch is CancellationError { throw CancellationError() }
        catch { throw AudioCompressionError.conversion("校验压缩音频：" + error.localizedDescription) }
        let size = try fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
        guard let compressed = size?.int64Value, compressed > 0 else { throw AudioCompressionError.invalidAudio }
        guard compressed < bytes else { throw AudioCompressionError.largerOutput }
        succeeded = true
        progress(1)
        return CompressedAudio(reference: reference, file: destination, originalBytes: bytes,
            originalModified: modified, compressedBytes: compressed, duration: info.duration, channels: info.channels)
    }

    private static func encode(source: URL, destination: URL, quality: AudioCompressionQuality,
                               progress: @escaping @Sendable (Double) -> Void) throws -> (duration: Double, channels: UInt32) {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard input.length > 0, format.sampleRate > 0 else { throw AudioCompressionError.invalidAudio }
        guard (1...2).contains(format.channelCount) else { throw AudioCompressionError.unsupportedChannels }
        let rate: Double = format.sampleRate <= 44_100 ? 44_100 : 48_000
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                     channels: format.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: format, to: pcm),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8_192) else {
            throw AudioCompressionError.invalidAudio
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: quality.bitRate]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var reachedEnd = false
        var lastProgress = -1
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            var readError: Error?
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: &conversionError) { frames, state in
                if reachedEnd { state.pointee = .endOfStream; return nil }
                do {
                    try input.read(into: inputBuffer, frameCount: min(frames, inputBuffer.frameCapacity))
                    if inputBuffer.frameLength == 0 {
                        reachedEnd = true
                        state.pointee = .endOfStream
                        return nil
                    }
                    state.pointee = .haveData
                    return inputBuffer
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
            let percent = Int(Double(input.framePosition) / Double(input.length) * 90)
            if percent != lastProgress { lastProgress = percent; progress(Double(percent) / 100) }
            switch status {
            case .endOfStream: return (Double(input.length) / format.sampleRate, format.channelCount)
            case .error: throw AudioCompressionError.invalidAudio
            case .haveData, .inputRanDry: break
            @unknown default: throw AudioCompressionError.invalidAudio
            }
        }
    }

    private static func validate(file: URL, duration: Double, channels: UInt32) throws {
        let input = try AVAudioFile(forReading: file)
        guard input.processingFormat.channelCount == channels,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384) else {
            throw AudioCompressionError.invalidAudio
        }
        var frames: Int64 = 0
        while true {
            try Task.checkCancellation()
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            frames += Int64(buffer.frameLength)
        }
        let decodedDuration = Double(frames) / input.processingFormat.sampleRate
        guard decodedDuration.isFinite, abs(decodedDuration - duration) < 0.25 else { throw AudioCompressionError.invalidAudio }
    }
}
