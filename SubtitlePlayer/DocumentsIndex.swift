//
//  DocumentsIndex.swift
//  SubtitlePlayer
//
//  Documents 目录的内存索引 + 封面缩略图缓存。
//
//  为什么需要它：SwiftUI 的 body 每次状态变化都会重新求值，而播放进度是 10Hz 更新的，
//  于是列表里每行的 `FileManager.fileExists`、`Data(contentsOf:)` + `UIImage(data:)`
//  会以每秒上百次的频率打在主线程上 —— 这是「用起来卡」的主要来源。
//
//  索引把「这个文件在不在」「这首歌有没有字幕」变成字典查询，封面则解码一次并缩放到
//  实际显示尺寸后缓存。两者都需要在文件发生变化后 refresh()/invalidate()。
//

import SwiftUI
import Combine
import UIKit

@MainActor
final class DocumentsIndex: ObservableObject {
    static let shared = DocumentsIndex()

    /// Documents 下所有文件名（含扩展名）。
    private var fileNames: Set<String> = []
    /// 其中的音频文件名（供 documentsAudioURLs 直接用，省一次过滤）。
    private(set) var audioFileNames: [String] = []
    /// 音频基名 → 字幕格式（大写，如 "LRC"）。按 srt → vtt → lrc 优先级取第一个存在的。
    private var subtitleFormatByBase: [String: String] = [:]
    /// 变更计数：SwiftUI 视图观察它来触发重绘（比发布整个字典便宜）。
    @Published private(set) var revision = 0

    private var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private init() {
        refresh()
    }

    /// 重新扫描 Documents（一次 contentsOfDirectory）。文件增删改后必须调用。
    func refresh() {
        guard let documentsURL else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        fileNames = Set(names)
        audioFileNames = names.filter {
            audioFileExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }

        // 预先算好每个音频基名对应的字幕格式，省得每行现查。
        var formats: [String: String] = [:]
        for name in names {
            let url = URL(fileURLWithPath: name)
            let ext = url.pathExtension.lowercased()
            guard subtitleFileExtensions.contains(ext) else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            // 已有更高优先级的格式就不覆盖。
            if let existing = formats[base],
               let existingRank = subtitleFileExtensions.firstIndex(of: existing.lowercased()),
               let newRank = subtitleFileExtensions.firstIndex(of: ext),
               existingRank <= newRank {
                continue
            }
            formats[base] = ext.uppercased()
        }
        subtitleFormatByBase = formats
        // 文件有变动，按路径缓存的修改时间/时长也可能失效。
        AlbumStore.clearFileAttributeCaches()
        revision += 1
    }

    /// 给非主 actor 的调用点用（全局导入函数等）。已在主线程则立即刷新，否则排到主线程。
    nonisolated static func refreshSoon() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.refresh() }
        } else {
            Task { @MainActor in shared.refresh() }
        }
    }

    /// 文件是否存在（相对 Documents 的文件名）。
    func contains(_ fileName: String) -> Bool {
        fileNames.contains(fileName)
    }

    /// 该音频是否已配字幕，返回格式名（如 "LRC"）；没有则 nil。
    func subtitleFormat(for audioURL: URL) -> String? {
        subtitleFormatByBase[audioURL.deletingPathExtension().lastPathComponent]
    }
}

// MARK: - 封面缩略图缓存

/// 专辑封面的解码缓存。列表里显示的是 44×44，但磁盘上的原图往往上百 KB 到几 MB，
/// 每帧重新读盘+全尺寸解码是列表卡顿的主因。这里解码一次、缩放到显示尺寸后留住。
@MainActor
final class CoverImageCache {
    static let shared = CoverImageCache()

    /// 键为「文件名 + 目标边长」，同一封面的大小两版各存一份。
    private var cache: [String: UIImage] = [:]

    private var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private init() {}

    /// 取缩放后的图。`maxSide` 是目标最大边长（点），按屏幕缩放比换算成像素。
    func image(named fileName: String, maxSide: CGFloat) -> UIImage? {
        let key = "\(fileName)|\(Int(maxSide))"
        if let cached = cache[key] { return cached }
        guard let documentsURL,
              let full = UIImage(contentsOfFile: documentsURL.appendingPathComponent(fileName).path)
        else {
            return nil
        }
        let scaled = full.downscaled(maxSide: maxSide)
        cache[key] = scaled
        return scaled
    }

    /// 某个封面文件变了或被删了，丢掉它的所有尺寸。
    func invalidate(fileName: String) {
        for key in cache.keys where key.hasPrefix("\(fileName)|") {
            cache.removeValue(forKey: key)
        }
    }

    /// 内存告急或恢复备份后整体丢弃。
    func removeAll() {
        cache.removeAll()
    }
}

extension UIImage {
    /// 等比缩放到最大边不超过 maxSide（点）。已经足够小就原样返回。
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return self }
        let ratio = maxSide / longest
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
