//
//  ChatView.swift
//  SubtitlePlayer
//
//  本地聊天机器人的界面：模型下载/状态、消息气泡、输入栏、以及
//  「带入当前歌曲/歌词」开关（做音乐助手）。
//

import SwiftUI

struct ChatBotView: View {
    @ObservedObject var controller: ChatController
    /// 当前播放歌曲名与歌词纯文本，供「带入当前歌曲」使用。
    let songTitle: String
    let lyricsText: String

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var includeMusic = false
    @State private var showDeleteConfirm = false
    @FocusState private var inputFocused: Bool

    private var hasSong: Bool { !lyricsText.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modelBar
                Divider()
                messagesList
                inputBar
            }
            .navigationTitle("AI 助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .confirmationDialog(
                "删除「\(controller.modelChoice.displayName)」的下载？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    controller.deleteDownloadedModel(controller.modelChoice)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除该模型的本地权重以释放存储，需要时可重新下载。")
            }
        }
    }

    // MARK: 顶部模型状态栏

    @ViewBuilder
    private var modelBar: some View {
        switch controller.loadState {
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 8) {
                Picker("模型", selection: modelBinding) {
                    ForEach(ChatModelChoice.allCases) { choice in
                        Text("\(choice.displayName)  ·  \(choice.sizeLabel)").tag(choice)
                    }
                }
                .pickerStyle(.menu)

                Picker("下载源", selection: sourceBinding) {
                    ForEach(DownloadSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.menu)

                if case .failed(let message) = controller.loadState {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("加载失败：\(message)")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text("若是网络 / TLS 错误，把「下载源」切到国内镜像再重试。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    controller.loadModel()
                } label: {
                    Label(controller.selectedModelDownloaded ? "加载模型" : "下载并加载模型",
                          systemImage: controller.selectedModelDownloaded ? "arrow.up.circle" : "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text(controller.selectedModelDownloaded
                     ? "模型已下载到本机，点击直接加载，无需联网。"
                     : "首次使用需联网下载权重（建议 Wi-Fi），之后完全离线运行。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if controller.selectedModelDownloaded {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除已下载的模型", systemImage: "trash")
                            .font(.caption)
                    }
                }
            }
            .padding(12)

        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction) {
                        Text("下载模型中… \(Int(fraction * 100))%")
                            .font(.caption)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("准备下载模型…").font(.caption)
                    }
                }
            }
            .padding(12)

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("加载模型到内存中…").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("已就绪 · \(controller.modelChoice.displayName)")
                    .font(.caption)
                Spacer()
                Menu {
                    ForEach(ChatModelChoice.allCases) { choice in
                        Button {
                            controller.modelChoice = choice
                        } label: {
                            if choice == controller.modelChoice {
                                Label(choice.displayName, systemImage: "checkmark")
                            } else {
                                Text(choice.displayName)
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除该模型（释放空间）", systemImage: "trash")
                    }
                } label: {
                    Text("更换模型").font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var modelBinding: Binding<ChatModelChoice> {
        Binding(get: { controller.modelChoice }, set: { controller.modelChoice = $0 })
    }

    private var sourceBinding: Binding<DownloadSource> {
        Binding(get: { controller.downloadSource }, set: { controller.downloadSource = $0 })
    }

    // MARK: 消息列表

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if controller.messages.isEmpty {
                        emptyHint
                    }
                    ForEach(controller.messages) { message in
                        messageBubble(message).id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: controller.messages.last?.text) { _, _ in
                if let lastID = controller.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(hasSong ? "开启「带入当前歌曲」后，可让我翻译或解释这首歌的歌词。" : "本地运行的 AI 助手，问我任何问题吧。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        let showTyping = !isUser && message.text.isEmpty && controller.isResponding
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Group {
                if showTyping {
                    ProgressView()
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isUser ? Color.accentColor.opacity(0.9) : Color.gray.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(isUser ? Color.white : Color.primary)
            if !isUser { Spacer(minLength: 40) }
        }
    }

    // MARK: 输入栏

    private var inputBar: some View {
        VStack(spacing: 8) {
            if hasSong {
                Toggle(isOn: $includeMusic) {
                    Label("带入当前歌曲 / 歌词", systemImage: "music.note")
                        .font(.caption)
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField(controller.isReady ? "输入消息…" : "请先下载并加载模型", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .disabled(!controller.isReady)
                    .onSubmit(sendCurrentInput)

                if controller.isResponding {
                    Button(role: .destructive) {
                        controller.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                } else {
                    Button(action: sendCurrentInput) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(!controller.isReady || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("完成") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                controller.clear()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(controller.messages.isEmpty)
        }
    }

    private func sendCurrentInput() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        controller.send(text, includeMusic: includeMusic && hasSong, songTitle: songTitle, lyrics: lyricsText)
    }
}
