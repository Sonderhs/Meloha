//
//  SubtitlePiP.swift
//  SubtitlePlayer
//
//  用系统「画中画」显示字幕小窗。
//  纯音频 App 没有视频图层，故采用 AVSampleBufferDisplayLayer + 自定义内容源（iOS 15+）：
//  把当前字幕文字渲染成像素帧推进显示图层，PiP 悬浮窗即显示该图层内容。
//
//  关键结构：让宿主 UIView 的 backing layer 直接是 AVSampleBufferDisplayLayer
//  （layerClass 方案），由 UIKit 完整托管，PiP 更可靠地识别该内容源。
//

import SwiftUI
import AVKit
import Combine
import UIKit

// MARK: - PiP 控制器

@MainActor
final class SubtitlePiPController: NSObject, ObservableObject {
    /// PiP 是否正在显示。
    @Published private(set) var isActive = false

    /// 面向用户的状态/错误提示。
    @Published private(set) var statusMessage = ""

    /// 当前设备是否支持 PiP。
    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    /// 小窗播放/暂停按钮回调（true=请求播放）。
    var onSetPlaying: ((Bool) -> Void)?
    /// 小窗快进/快退按钮回调（参数为秒，可正可负）。
    var onSkip: ((TimeInterval) -> Void)?

    /// 实际播放状态，供小窗控件显示正确的播放/暂停图标。
    private var playing = false

    /// 由外部在播放状态变化时调用，刷新小窗控件。
    func setPlaybackState(playing: Bool) {
        self.playing = playing
        pipController?.invalidatePlaybackState()
    }

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var keepAliveTimer: Timer?
    private var latestText = "♪"
    private let frameSize = CGSize(width: 480, height: 200)
    private var textColor: UIColor = .white
    private var fontScale: CGFloat = 1.0

    /// 更新字幕外观并立即重绘。
    func setAppearance(textColor: UIColor, fontScale: CGFloat) {
        self.textColor = textColor
        self.fontScale = fontScale
        render(text: latestText)
    }

    deinit {
        keepAliveTimer?.invalidate()
    }

    /// 由宿主视图在其 backing layer 进入窗口且有尺寸后调用：绑定图层并创建 PiP 控制器（只创建一次）。
    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        guard pipController == nil, isSupported else {
            return
        }

        // 先推首帧，再基于该图层创建 PiP 内容源。不设置 controlTimebase，交由 AVKit 管理时序。
        render(text: latestText)

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller

        startKeepAlive()
    }

    /// 定时刷新 PiP 激活状态。渲染只在字幕变化时进行（见 update(text:)），
    /// 不再每帧重绘，避免主线程持续绘制位图导致的卡顿。
    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func tick() {
        guard let pipController else {
            return
        }
        isActive = pipController.isPictureInPictureActive
    }

    /// 开启 / 关闭画中画。
    func toggle() {
        guard let pipController else {
            statusMessage = "画中画尚未就绪"
            return
        }

        if pipController.isPictureInPictureActive {
            statusMessage = "已请求关闭画中画…"
            pipController.stopPictureInPicture()
        } else {
            statusMessage = "已请求开启画中画…"
            pipController.startPictureInPicture()
        }
    }

    /// 更新要显示的字幕文本，并重绘一帧（文本未变则跳过）。
    func update(text: String) {
        guard text != latestText else {
            return
        }
        latestText = text
        render(text: text)
    }

    private func render(text: String) {
        guard let displayLayer else {
            return
        }
        guard let sampleBuffer = SubtitleFrameRenderer.makeSampleBuffer(text: text, size: frameSize, fontScale: fontScale, textColor: textColor) else {
            statusMessage = "字幕帧渲染失败"
            return
        }

        if displayLayer.status == .failed {
            statusMessage = "显示图层出错：\(displayLayer.error?.localizedDescription ?? "未知")"
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}

// MARK: - PiP 生命周期回调

extension SubtitlePiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        statusMessage = "画中画启动中…"
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        statusMessage = "画中画已开启"
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        statusMessage = "画中画已关闭"
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        statusMessage = "画中画启动失败：\(error.localizedDescription)"
    }
}

// MARK: - PiP 播放代理（字幕无固定时长，按「直播」处理）

extension SubtitlePiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        onSetPlaying?(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !playing
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        onSkip?(skipInterval.seconds)
        completionHandler()
    }
}

// MARK: - 字幕帧渲染

enum SubtitleFrameRenderer {
    /// 把一段文字渲染成可推入显示图层的 CMSampleBuffer。
    static func makeSampleBuffer(text: String, size: CGSize, fontScale: CGFloat, textColor: UIColor) -> CMSampleBuffer? {
        guard let pixelBuffer = makePixelBuffer(text: text, size: size, fontScale: fontScale, textColor: textColor) else {
            return nil
        }
        return makeSampleBuffer(from: pixelBuffer)
    }

    private static func makePixelBuffer(text: String, size: CGSize, fontScale: CGFloat, textColor: UIColor) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        // 必须声明 IOSurface 支持，否则 AVSampleBufferDisplayLayer 无法显示该帧。
        let attributes: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        // 深色背景。
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 翻转坐标系以配合 UIKit 文本绘制（CGContext 原点在左下）。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let displayText = text.isEmpty ? "♪" : text
        let fontSize = max(18, size.height * 0.22) * fontScale
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: displayText, attributes: textAttributes)

        let inset: CGFloat = 16
        let maxSize = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        let textRect = attributed.boundingRect(
            with: maxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let originY = max(inset, (size.height - textRect.height) / 2)
        let drawRect = CGRect(
            x: inset,
            y: originY,
            width: size.width - inset * 2,
            height: textRect.height
        )
        attributed.draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        return pixelBuffer
    }

    private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            return nil
        }

        // PTS 用 CACurrentMediaTime()，交由 AVKit 管理时序（与已知可用实现一致）。
        let presentationTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard bufferStatus == noErr, let sampleBuffer else {
            return nil
        }

        return sampleBuffer
    }
}

// MARK: - SwiftUI 宿主视图

/// 把 PiP 显示图层嵌入 SwiftUI，作为字幕小窗预览，同时满足 PiP 内容源须在视图层级中的要求。
struct SubtitlePiPHostView: UIViewRepresentable {
    let controller: SubtitlePiPController

    func makeUIView(context: Context) -> SubtitlePiPDisplayView {
        SubtitlePiPDisplayView(controller: controller)
    }

    func updateUIView(_ uiView: SubtitlePiPDisplayView, context: Context) {}
}

/// backing layer 直接是 AVSampleBufferDisplayLayer，由 UIKit 完整托管。
final class SubtitlePiPDisplayView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private let controller: SubtitlePiPController
    private var didAttach = false

    init(controller: SubtitlePiPController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachIfReady()
    }

    private func attachIfReady() {
        guard !didAttach, window != nil, bounds.width > 0, bounds.height > 0 else {
            return
        }
        didAttach = true
        controller.attach(displayLayer: displayLayer)
    }
}
