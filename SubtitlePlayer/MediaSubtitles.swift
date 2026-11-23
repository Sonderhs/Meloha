import Foundation

nonisolated struct SubtitleLine: Sendable {
    let time: TimeInterval
    let endTime: TimeInterval?
    let text: String

    init(time: TimeInterval, endTime: TimeInterval? = nil, text: String) {
        self.time = time
        self.endTime = endTime
        self.text = text
    }
}

nonisolated enum MediaSubtitles {
    static func read(_ url: URL) throws -> [SubtitleLine] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines: [SubtitleLine]
        switch url.pathExtension.lowercased() {
        case "lrc":
            lines = text.split(whereSeparator: \.isNewline).compactMap(parseLRCLine).filter { !$0.text.isEmpty }
        case "srt", "vtt":
            lines = parseCueSubtitle(text)
        default:
            return []
        }
        return lines.filter { $0.time.isFinite && $0.time >= 0 }.sorted { $0.time < $1.time }
    }

    private static func parseLRCLine(_ line: Substring) -> SubtitleLine? {
        guard let closingBracket = line.firstIndex(of: "]"), line.first == "[" else {
            return nil
        }

        let timestamp = line[line.index(after: line.startIndex)..<closingBracket]
        let timeParts = timestamp.split(separator: ":", maxSplits: 1)
        guard timeParts.count == 2,
              let minutes = Double(timeParts[0]),
              let seconds = Double(timeParts[1]) else {
            return nil
        }

        let textStart = line.index(after: closingBracket)
        let text = line[textStart...].trimmingCharacters(in: .whitespaces)
        return SubtitleLine(time: minutes * 60 + seconds, text: text)
    }

    /// 解析基于 cue 块的字幕（SRT 与 WebVTT 结构几乎一致）。
    /// 按空行切分字幕块，每块定位含 "-->" 的时间行，其余行合并为字幕文本。
    /// 自动跳过 VTT 的 "WEBVTT" 头、"NOTE"/"STYLE"/"REGION" 等无时间行的块，
    /// 以及 SRT/VTT 的序号或 cue 标识行。
    private static func parseCueSubtitle(_ text: String) -> [SubtitleLine] {
        // 统一换行符，按空行切分字幕块。
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var lines: [SubtitleLine] = []
        for block in blocks {
            let rawLines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let timingIndex = rawLines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timingLine = rawLines[timingIndex]
            let timingParts = timingLine.components(separatedBy: "-->")
            guard timingParts.count == 2,
                  let start = parseCueTimestamp(timingParts[0]) else {
                continue
            }
            let end = parseCueTimestamp(timingParts[1])

            let textLines = rawLines[rawLines.index(after: timingIndex)...]
                .map { stripTags(String($0)).trimmingCharacters(in: .whitespaces) }
            let text = textLines.joined(separator: "\n")
            guard !text.isEmpty else {
                continue
            }

            lines.append(SubtitleLine(time: start, endTime: end, text: text))
        }

        return lines
    }

    /// 解析 cue 时间戳，兼容：
    /// - SRT "HH:MM:SS,mmm"（逗号毫秒）
    /// - VTT "HH:MM:SS.mmm" 或省略小时的 "MM:SS.mmm"
    /// - VTT 结束时间后附带的 cue 设置（如 "align:start position:10%"）——只取首个 token。
    private static func parseCueTimestamp(_ raw: String) -> TimeInterval? {
        let token = raw
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")

        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else {
                return nil
            }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else {
                return nil
            }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }

    /// 去除字幕文本中的标签，如 SRT 的 `<i>`/`<b>` 与 VTT 的 `<v Roger>`/`<c.class>`。
    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

}
