//
//  AudioPicker.swift
//  SubtitlePlayer
//
//  「选一个音频」的共享列表组件。裁剪音频、字幕配对、节拍器选音源、往专辑加歌
//  四处原本各写一份，UI 细节还各不相同（搜索框有的常驻有的要下拉、图标不一样、
//  有的带字幕标记有的不带）。统一到这里，以后再加选音频的地方直接复用。
//
//  搜索框一律常驻可见：SwiftUI 的 `.searchable` 默认藏在列表顶部，要下拉才露出来，
//  实际使用时容易被当成「没有搜索功能」。
//

import SwiftUI

// MARK: - 常驻搜索框

/// 音乐库通用搜索框（专辑列表、各音频选择器共用）。
struct LibrarySearchBar: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - 音频选择列表

/// 音频列表的一个分组。`title` 为 nil 时不显示分组头（平铺）。
struct AudioPickerSection: Identifiable {
    let id: String
    let title: String?
    let files: [URL]

    init(id: String? = nil, title: String? = nil, files: [URL]) {
        self.id = id ?? title ?? "__flat__"
        self.title = title
        self.files = files
    }
}

/// 通用「选音频」列表：常驻搜索 + 可选分组 + 可选行尾配件。
/// 点行走 `onTap`；需要 push 到子页的调用方自己用 `navigationDestination(item:)`。
struct AudioPickerList<Accessory: View>: View {
    let sections: [AudioPickerSection]
    var rowIcon: String = "waveform"
    var emptyTitle: String = "还没有音频"
    var emptyDescription: String = "先在专辑里导入音频，再回来使用"
    var searchPrompt: String = "搜索音频"
    /// 行尾配件（如字幕标记、多选勾选）。不需要就用无 accessory 的便利构造。
    @ViewBuilder var accessory: (URL) -> Accessory
    var onTap: (URL) -> Void

    @State private var searchText = ""

    private var isEmpty: Bool {
        sections.allSatisfy { $0.files.isEmpty }
    }

    /// 按关键词过滤，并丢掉过滤后为空的分组。
    private var filteredSections: [AudioPickerSection] {
        guard !searchText.isEmpty else {
            return sections.filter { !$0.files.isEmpty }
        }
        return sections.compactMap { section in
            let hits = section.files.filter {
                $0.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveContains(searchText)
            }
            return hits.isEmpty ? nil : AudioPickerSection(
                id: section.id, title: section.title, files: hits
            )
        }
    }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "waveform",
                    description: Text(emptyDescription)
                )
            } else {
                VStack(spacing: 0) {
                    LibrarySearchBar(text: $searchText, prompt: searchPrompt)

                    if filteredSections.isEmpty {
                        ContentUnavailableView(
                            "无匹配结果",
                            systemImage: "magnifyingglass",
                            description: Text("换个关键词试试")
                        )
                        .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(filteredSections) { section in
                                if let title = section.title {
                                    Section(title) { rows(of: section) }
                                } else {
                                    rows(of: section)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func rows(of section: AudioPickerSection) -> some View {
        ForEach(section.files, id: \.self) { url in
            Button {
                onTap(url)
            } label: {
                HStack {
                    Label {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: rowIcon)
                    }

                    Spacer()

                    accessory(url)
                }
            }
        }
    }
}

extension AudioPickerList where Accessory == EmptyView {
    /// 不需要行尾配件时用这个。
    init(
        sections: [AudioPickerSection],
        rowIcon: String = "waveform",
        emptyTitle: String = "还没有音频",
        emptyDescription: String = "先在专辑里导入音频，再回来使用",
        searchPrompt: String = "搜索音频",
        onTap: @escaping (URL) -> Void
    ) {
        self.init(
            sections: sections,
            rowIcon: rowIcon,
            emptyTitle: emptyTitle,
            emptyDescription: emptyDescription,
            searchPrompt: searchPrompt,
            accessory: { _ in EmptyView() },
            onTap: onTap
        )
    }
}

extension AudioPickerSection {
    /// 平铺一组文件（无分组头）。
    static func flat(_ files: [URL]) -> [AudioPickerSection] {
        [AudioPickerSection(files: files)]
    }

    /// 按专辑分组，末尾附上「未分类」。空专辑不显示。
    static func grouped(by albumStore: AlbumStore) -> [AudioPickerSection] {
        var result = albumStore.albums.compactMap { album -> AudioPickerSection? in
            let tracks = albumStore.tracks(in: album)
            return tracks.isEmpty ? nil : AudioPickerSection(
                id: album.id.uuidString, title: album.name, files: tracks
            )
        }
        let loose = albumStore.uncategorizedURLs()
        if !loose.isEmpty {
            result.append(AudioPickerSection(id: "__uncategorized__", title: "未分类", files: loose))
        }
        return result
    }
}
