import Foundation
import AVFoundation
import AudioToolbox

enum PlaybackVolumeBoost {
    static let key = "playbackVolumeBoostDB"
    static let maximumDB = 12.0

    static func bounded(_ decibels: Double) -> Double {
        decibels.isFinite ? min(max(0, decibels), maximumDB) : 0
    }
}

/// Keeps regular playback on AVAudioPlayer and switches at the current position when boost is enabled.
@MainActor
final class LocalAudioPlayback {
    static let enhancedPlaybackDidFinish = Notification.Name("Meloha.enhancedPlaybackDidFinish")

    private let url: URL
    private let standard: AVAudioPlayer
    private var enhanced: EnhancedAudioPlayback?
    private var requestedGainDB = 0.0

    var rate: Float = 1 {
        didSet {
            standard.rate = rate
            enhanced?.rate = rate
        }
    }

    var duration: TimeInterval { standard.duration }
    var isPlaying: Bool { enhanced?.isPlaying ?? standard.isPlaying }
    var isBoosted: Bool { enhanced != nil }
    var boostUnavailable: Bool { requestedGainDB > 0 && enhanced == nil }

    var currentTime: TimeInterval {
        get {
            if enhanced?.didFinish == true { return duration }
            return min(enhanced?.currentTime ?? standard.currentTime, duration)
        }
        set {
            guard let enhanced else {
                standard.currentTime = newValue
                return
            }
            let wasPlaying = enhanced.isPlaying
            enhanced.pause()
            enhanced.currentTime = newValue
            if wasPlaying && newValue < duration { play() }
        }
    }

    init(url: URL, gainDB: Double) throws {
        self.url = url
        standard = try AVAudioPlayer(contentsOf: url)
        standard.enableRate = true
        setGain(gainDB)
        if !isBoosted { standard.prepareToPlay() }
    }

    func setGain(_ decibels: Double) {
        requestedGainDB = PlaybackVolumeBoost.bounded(decibels)
        if requestedGainDB == 0 {
            guard let enhanced else { return }
            let wasPlaying = enhanced.isPlaying
            returnToStandard()
            if wasPlaying { play() }
        } else if let enhanced {
            enhanced.gainDB = Float(requestedGainDB)
        } else if let player = EnhancedAudioPlayback(url: url) {
            let wasPlaying = standard.isPlaying
            player.currentTime = standard.currentTime
            player.rate = rate
            player.gainDB = Float(requestedGainDB)
            standard.stop()
            enhanced = player
            if wasPlaying { play() }
        }
    }

    func play() {
        if let enhanced {
            if enhanced.play() { return }
            returnToStandard()
        }
        standard.play()
        standard.rate = rate
    }

    func pause() {
        if let enhanced {
            enhanced.pause()
        } else {
            standard.pause()
        }
    }

    func stop() {
        enhanced?.pause()
        standard.stop()
    }

    func didFinishBoostedPlayback(_ notification: Notification) -> Bool {
        guard let enhanced, let source = notification.object as? EnhancedAudioPlayback else { return false }
        return source === enhanced && enhanced.didFinish
    }

    private func returnToStandard() {
        guard let enhanced else { return }
        let position = currentTime
        enhanced.pause()
        self.enhanced = nil
        standard.currentTime = position
    }
}

@MainActor
private final class EnhancedAudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 1)
    private let limiter: AVAudioUnitEffect
    private let file: AVAudioFile
    private let length: AVAudioFramePosition
    private let sampleRate: Double
    private var scheduledFrame: AVAudioFramePosition = 0
    private var position: TimeInterval = 0
    private var generation = 0
    private(set) var didFinish = false

    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    var gainDB: Float {
        get { equalizer.globalGain }
        set { equalizer.globalGain = newValue }
    }

    var isPlaying: Bool { engine.isRunning && player.isPlaying && !didFinish }

    var currentTime: TimeInterval {
        get {
            if isPlaying, let renderTime = player.lastRenderTime,
               let playerTime = player.playerTime(forNodeTime: renderTime), playerTime.isSampleTimeValid {
                let elapsed = max(0, playerTime.sampleTime)
                position = Double(min(scheduledFrame + elapsed, length)) / sampleRate
            }
            return position
        }
        set {
            didFinish = false
            position = min(max(newValue, 0), Double(length) / sampleRate)
        }
    }

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let length = file.length
        // The limiter supports mono/stereo. A scheduled segment's length is a UInt32.
        guard (1...2).contains(format.channelCount), format.sampleRate > 0,
              length > 0, length <= Int64(UInt32.max) else { return nil }

        var component = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &component) != nil else { return nil }
        limiter = AVAudioUnitEffect(audioComponentDescription: component)
        self.file = file
        self.length = length
        sampleRate = format.sampleRate

        equalizer.bands[0].bypass = true
        let nodes: [AVAudioNode] = [player, timePitch, equalizer, limiter]
        for node in nodes { engine.attach(node) }
        for (source, destination) in zip(nodes, nodes.dropFirst()) {
            engine.connect(source, to: destination, format: format)
        }
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
    }

    func play() -> Bool {
        if isPlaying { return true }
        pause()
        scheduledFrame = min(AVAudioFramePosition(position * sampleRate), length)
        guard scheduledFrame < length else { return false }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            return false
        }

        let token = generation
        player.scheduleSegment(file, startingFrame: scheduledFrame,
                               frameCount: AVAudioFrameCount(length - scheduledFrame), at: nil,
                               completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == token, engine.isRunning else { return }
                position = Double(length) / sampleRate
                didFinish = true
                player.stop()
                engine.stop()
                NotificationCenter.default.post(name: LocalAudioPlayback.enhancedPlaybackDidFinish, object: self)
            }
        }
        player.play()
        return true
    }

    func pause() {
        position = currentTime
        generation += 1
        didFinish = false
        player.stop()
        engine.stop()
    }
}
