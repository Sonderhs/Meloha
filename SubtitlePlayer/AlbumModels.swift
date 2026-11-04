import Foundation

/// 专辑内曲目排序方式。存进 albums.json，每张专辑各自记住。
nonisolated enum AlbumSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case nameAscending
    case nameDescending
    case dateAddedNewest
    case dateAddedOldest
    case durationShortest
    case durationLongest
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAscending: return "名称 A→Z"
        case .nameDescending: return "名称 Z→A"
        case .dateAddedNewest: return "导入时间（新→旧）"
        case .dateAddedOldest: return "导入时间（旧→新）"
        case .durationShortest: return "时长（短→长）"
        case .durationLongest: return "时长（长→短）"
        case .manual: return "手动排序"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAscending, .nameDescending: return "textformat"
        case .dateAddedNewest, .dateAddedOldest: return "clock"
        case .durationShortest, .durationLongest: return "timer"
        case .manual: return "hand.draw"
        }
    }
}

/// 专辑内的分组（如 CD1/CD2、原曲/伴奏）。只有一层，分组里不能再套分组。
nonisolated struct AlbumGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// 本组的成员文件名。歌曲要么在某个组里，要么散在专辑根（不属于任何组）。
    var fileNames: [String]

    init(id: UUID = UUID(), name: String, fileNames: [String] = []) {
        self.id = id
        self.name = name
        self.fileNames = fileNames
    }
}

nonisolated struct Album: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// 成员文件名（相对 Documents 的路径）。这是专辑的**全部**歌曲，
    /// 分组只是给其中一部分打上归属，不重复存储也不改变这里的顺序。
    var fileNames: [String]
    /// 封面图文件名（相对 Documents），无封面时为 nil。
    var coverFileName: String?
    /// 专辑内分组。解码旧数据时为 nil，用 `groupList` 读取以免到处判空。
    var groups: [AlbumGroup]?
    /// 专辑图片集（歌词本拍照、内页、乐谱等），与封面无关。旧数据为 nil。
    var imageFileNames: [String]?
    /// 曲目排序方式。旧数据为 nil —— 用 `sortMode` 读取，默认按名称升序。
    var sort: AlbumSort?
    /// 备注（社团、声优、来源等自由文本）。参与专辑搜索。旧数据为 nil。
    var note: String?
    /// 标签（如「治愈」「已听完」）。一张专辑可有多个，参与搜索与筛选。旧数据为 nil。
    var tags: [String]?
    /// nil 表示未置顶；数字越小越靠前。
    var pinRank: Int?

    /// 标签列表（旧数据视为空）。
    var tagList: [String] {
        get { tags ?? [] }
        set { tags = newValue.isEmpty ? nil : newValue }
    }

    /// 搜索用的可匹配文本：名称 + 备注 + 标签。
    var searchableText: String {
        ([name, note ?? ""] + tagList).joined(separator: " ")
    }

    /// 排序方式（旧数据默认按名称升序）。
    var sortMode: AlbumSort {
        get { sort ?? .nameAscending }
        set { sort = newValue }
    }

    /// 分组列表（旧数据视为空）。
    var groupList: [AlbumGroup] {
        get { groups ?? [] }
        set { groups = newValue.isEmpty ? nil : newValue }
    }

    /// 图片列表（旧数据视为空）。
    var imageList: [String] {
        get { imageFileNames ?? [] }
        set { imageFileNames = newValue.isEmpty ? nil : newValue }
    }

    /// 不属于任何分组的歌（显示在分组上方）。
    var ungroupedFileNames: [String] {
        let grouped = Set(groupList.flatMap(\.fileNames))
        return fileNames.filter { !grouped.contains($0) }
    }

    init(
        id: UUID = UUID(),
        name: String,
        fileNames: [String] = [],
        coverFileName: String? = nil,
        groups: [AlbumGroup]? = nil,
        imageFileNames: [String]? = nil,
        sort: AlbumSort? = nil,
        note: String? = nil,
        tags: [String]? = nil,
        pinRank: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.fileNames = fileNames
        self.coverFileName = coverFileName
        self.groups = groups
        self.imageFileNames = imageFileNames
        self.sort = sort
        self.note = note
        self.tags = tags
        self.pinRank = pinRank
    }
}
