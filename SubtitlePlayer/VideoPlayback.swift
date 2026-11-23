import AVKit
import SwiftUI
import UIKit

struct VideoPlaybackTarget: Identifiable {
    let url: URL
    var id: URL { url }

    static let requested = Notification.Name("Meloha.videoPlaybackRequested")
    static func open(_ url: URL) {
        NotificationCenter.default.post(name: requested, object: url)
    }
}

@MainActor
enum VideoResume {
    private static let key = "meloha.videoPlaybackPositions"

    static func position(for reference: String) -> Double {
        UserDefaults.standard.dictionary(forKey: key)?[reference] as? Double ?? 0
    }

    static func save(_ position: Double, for reference: String) {
        guard position.isFinite, position >= 0 else { return }
        var positions = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        positions[reference] = position >= 1 ? position : nil
        UserDefaults.standard.set(positions, forKey: key)
    }

    static func rename(from old: String, to new: String) {
        guard old != new else { return }
        let saved = position(for: old)
        if saved > 0 { save(saved, for: new); save(0, for: old) }
    }
}

struct VideoThumbnail: View {
    let url: URL
    @State private var thumbnail: CGImage?
    private static let cache = NSCache<NSURL, UIImage>()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
            Image(systemName: "video.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .padding(2)
        }
        .frame(width: 50, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
        .task(id: url) {
            thumbnail = nil
            if let cached = Self.cache.object(forKey: url as NSURL)?.cgImage { thumbnail = cached; return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 100)
            if let frame = try? await generator.image(at: .zero), !Task.isCancelled {
                Self.cache.countLimit = 180
                Self.cache.setObject(UIImage(cgImage: frame.image), forKey: url as NSURL)
                thumbnail = frame.image
            }
        }
    }
}

struct MediaRowTitle: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            if LibraryStorage.isVideoReference(storageReference(url)) {
                VideoThumbnail(url: url)
            } else {
                Image(systemName: "music.note")
            }
            Text(url.deletingPathExtension().lastPathComponent)
        }
    }
}

struct LocalVideoView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var errorMessage: String?
    @State private var showSubtitles = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.deletingPathExtension().lastPathComponent).lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer()
                if matchingSubtitleURL(for: url) != nil {
                    Button { showSubtitles.toggle() } label: {
                        Image(systemName: showSubtitles ? "captions.bubble.fill" : "captions.bubble")
                    }.accessibilityLabel(showSubtitles ? "隐藏外挂字幕" : "显示外挂字幕")
                }
                Button("完成") { dismiss() }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            VideoPlayerController(url: url, showSubtitles: showSubtitles, onError: { errorMessage = $0 })
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .alert("无法播放视频", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("关闭", role: .cancel) { dismiss() }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct VideoPlayerController: UIViewControllerRepresentable {
    let url: URL
    let showSubtitles: Bool
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onError: onError) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = context.coordinator.player
        controller.delegate = context.coordinator
        controller.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        context.coordinator.start(in: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.showSubtitles = showSubtitles
        context.coordinator.updateSubtitle()
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop()
        controller.player = nil
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let player: AVPlayer
        private let reference: String
        private let onError: (String) -> Void
        private let subtitleLabel = UILabel()
        private var lines: [SubtitleLine] = []
        private var periodic: Any?
        private var observation: NSKeyValueObservation?
        private var ready = false
        private var started = false
        private var lastSave = Date.distantPast
        var showSubtitles = true

        init(url: URL, onError: @escaping (String) -> Void) {
            player = AVPlayer(url: url)
            reference = storageReference(url)
            self.onError = onError
            if let subtitle = matchingSubtitleURL(for: url) { lines = (try? MediaSubtitles.read(subtitle)) ?? [] }
        }

        func start(in controller: AVPlayerViewController) {
            if let overlay = controller.contentOverlayView {
                subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
                subtitleLabel.numberOfLines = 0
                subtitleLabel.textAlignment = .center
                subtitleLabel.textColor = .white
                subtitleLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
                subtitleLabel.font = .preferredFont(forTextStyle: .headline)
                subtitleLabel.adjustsFontForContentSizeCategory = true
                subtitleLabel.isHidden = true
                overlay.addSubview(subtitleLabel)
                NSLayoutConstraint.activate([
                    subtitleLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                    subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.88),
                    subtitleLabel.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -64)
                ])
            }
            guard let item = player.currentItem else { return }
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                let error = item.error?.localizedDescription
                Task { @MainActor [weak self] in self?.handle(status, error: error) }
            }
            periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        }

        func stop() {
            savePosition()
            ready = false
            player.pause()
            observation = nil
            if let periodic { player.removeTimeObserver(periodic); self.periodic = nil }
        }

        private func handle(_ status: AVPlayerItem.Status, error: String?) {
            if status == .failed {
                onError(error ?? "iPhone 无法解码这个视频，请尝试 MP4（H.264/AAC）。")
                return
            }
            guard status == .readyToPlay, !started, observation != nil else { return }
            started = true
            let saved = VideoResume.position(for: reference)
            let duration = player.currentItem?.duration.seconds ?? 0
            if saved > 0, duration.isFinite, saved < duration - 2 {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let time = CMTime(seconds: saved, preferredTimescale: 600)
                    _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard observation != nil else { return }
                    ready = true
                    player.play()
                }
            } else {
                ready = true
                player.play()
            }
        }

        private func tick() {
            updateSubtitle()
            if Date.now.timeIntervalSince(lastSave) >= 5 { savePosition(); lastSave = .now }
        }

        private func savePosition() {
            guard ready else { return }
            let time = player.currentTime().seconds
            let duration = player.currentItem?.duration.seconds ?? .infinity
            VideoResume.save(duration.isFinite && time >= duration - 2 ? 0 : time, for: reference)
        }

        func updateSubtitle() {
            let time = player.currentTime().seconds
            var lower = 0
            var upper = lines.count
            while lower < upper {
                let mid = (lower + upper) / 2
                if lines[mid].time <= time { lower = mid + 1 } else { upper = mid }
            }
            let line = lower > 0 ? lines[lower - 1] : nil
            let visible = showSubtitles && (line?.endTime ?? .infinity) > time ? line?.text : nil
            subtitleLabel.text = visible.map { "  " + $0 + "  " }
            subtitleLabel.isHidden = visible == nil
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(playerViewController.viewIfLoaded?.window != nil)
        }
    }
}
