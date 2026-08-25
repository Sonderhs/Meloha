//
//  ChatBot.swift
//  SubtitlePlayer
//
//  本地聊天机器人：用 MLX Swift 在设备上运行一个开源小模型（4-bit 量化）。
//  首次使用从 Hugging Face 下载权重，之后完全离线、免费、隐私。
//
//  依赖（见 project.pbxproj）：mlx-swift-lm（MLXLLM/MLXLMCommon/MLXHuggingFace）
//  + swift-huggingface（HuggingFace）+ swift-transformers（Tokenizers）。
//  ⚠️ MLX 依赖 Metal GPU，无法在 iOS 模拟器运行，只能真机。
//

import Foundation
import SwiftUI
import Combine
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

// MARK: - 可选模型

/// 可供下载运行的小模型。宽泛地覆盖体积 / 中文表现两档需求。
enum ChatModelChoice: String, CaseIterable, Identifiable {
    case qwen3_0_6b
    case llama3_2_1b
    case qwen2_5_1_5b
    case qwen2_5_3b

    var id: String { rawValue }

    /// 对应 MLXLLM 的模型配置（含 Hugging Face 仓库 id）。
    var configuration: ModelConfiguration {
        switch self {
        case .qwen3_0_6b: return LLMRegistry.qwen3_0_6b_4bit
        case .llama3_2_1b: return LLMRegistry.llama3_2_1B_4bit
        case .qwen2_5_1_5b: return LLMRegistry.qwen2_5_1_5b
        case .qwen2_5_3b:
            // 注册表没有 3B 预设，直接用 HF 仓库 id 自定义（Qwen2.5 无「思考」模式，输出干净）。
            return ModelConfiguration(
                id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
                defaultPrompt: "Why is the sky blue?",
                extraEOSTokens: ["<|im_end|>"]
            )
        }
    }

    var displayName: String {
        switch self {
        case .qwen3_0_6b: return "Qwen3 0.6B"
        case .llama3_2_1b: return "Llama 3.2 1B"
        case .qwen2_5_1_5b: return "Qwen2.5 1.5B"
        case .qwen2_5_3b: return "Qwen2.5 3B"
        }
    }

    /// 近似下载体积，供 UI 提示。
    var sizeLabel: String {
        switch self {
        case .qwen3_0_6b: return "≈0.4 GB · 轻量最快"
        case .llama3_2_1b: return "≈0.7 GB · 均衡"
        case .qwen2_5_1_5b: return "≈1.0 GB · 中文较好"
        case .qwen2_5_3b: return "≈1.8 GB · 最聪明·推荐"
        }
    }
}

// MARK: - 下载源

/// 模型权重下载源。国内直连 huggingface.co 常被干扰导致 TLS 握手失败，
/// 可切到镜像 hf-mirror.com。切换通过设置环境变量 `HF_ENDPOINT` 生效
/// （swift-huggingface 的 HubClient 与 swift-transformers 的 HubApi 都会读取它）。
enum DownloadSource: String, CaseIterable, Identifiable {
    case mirror
    case official

    var id: String { rawValue }

    var endpoint: String {
        switch self {
        case .mirror: return "https://hf-mirror.com"
        case .official: return "https://huggingface.co"
        }
    }

    var displayName: String {
        switch self {
        case .mirror: return "国内镜像 (hf-mirror.com)"
        case .official: return "官方 (huggingface.co)"
        }
    }
}

// MARK: - 播放控制指令

/// AI 可下达的播放控制指令。模型在回复里输出 `<<PLAY>>` 之类的标记，
/// ChatController 解析后通过 `onPlaybackCommand` 回调交给播放器执行。
enum PlaybackCommand: String {
    case play = "PLAY"
    case pause = "PAUSE"
    case toggle = "TOGGLE"
    case next = "NEXT"
    case prev = "PREV"
    case forward = "FORWARD"
    case back = "BACK"
}

// MARK: - 消息模型

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

// MARK: - 控制器

@MainActor
final class ChatController: ObservableObject {
    /// 模型加载状态。
    enum LoadState: Equatable {
        case idle
        case downloading(Double?)   // nil 表示进度未知
        case loading
        case ready
        case failed(String)
    }

    @Published var messages: [ChatMessage] = []
    @Published var loadState: LoadState = .idle
    @Published var isResponding = false
    /// 当前所选模型是否已下载到持久缓存（决定按钮显示「加载」还是「下载并加载」）。
    @Published private(set) var selectedModelDownloaded = false

    /// 记住上次选择的模型。
    @AppStorage("chatModel") private var modelChoiceRaw: String = ChatModelChoice.qwen2_5_1_5b.rawValue

    /// 记住下载源（默认国内镜像，规避 huggingface.co 的 TLS 干扰）。
    @AppStorage("hfDownloadSource") private var downloadSourceRaw: String = DownloadSource.mirror.rawValue

    /// 用户在设置里自定义的 AI 人设 / 系统提示。留空则用默认助手设定。
    @AppStorage("chatSystemPrompt") private var customPersona: String = ""

    private var container: ModelContainer?
    private var session: ChatSession?
    private var generateTask: Task<Void, Never>?
    /// 当前会话所基于的上下文标识；变化时需重建会话。
    private var sessionContextKey = "__none__"

    /// 播放控制回调：由 ContentView 注入，把 AI 下达的指令映射到播放器动作。
    var onPlaybackCommand: ((PlaybackCommand) -> Void)?

    /// 匹配 AI 回复里的控制标记，如 `<<PAUSE>>`。
    private static let commandRegex = try! NSRegularExpression(pattern: "<<\\s*([A-Za-z_]+)\\s*>>")

    var modelChoice: ChatModelChoice {
        get { ChatModelChoice(rawValue: modelChoiceRaw) ?? .qwen2_5_1_5b }
        set {
            guard newValue.rawValue != modelChoiceRaw else { return }
            modelChoiceRaw = newValue.rawValue
            // 换模型：丢弃已加载的，回到未加载态。
            container = nil
            session = nil
            sessionContextKey = "__none__"
            loadState = .idle
            refreshDownloadedState()
        }
    }

    init() {
        // 限制 MLX 的 Metal 缓存峰值内存。8GB 设备单进程内存预算约 3GB，
        // 缓存无上限时大模型 + 增长的 KV cache 很容易冲破上限被系统强杀（表现为聊天时闪退）。
        MLX.Memory.cacheLimit = 20 * 1024 * 1024   // 20 MB
        refreshDownloadedState()
    }

    /// 刷新「当前所选模型是否已下载」，供 UI 决定按钮文案。
    func refreshDownloadedState() {
        selectedModelDownloaded = isDownloaded(modelChoice)
    }

    /// 判断某模型是否已下载到持久缓存：查该仓库快照目录下是否有权重文件。
    func isDownloaded(_ choice: ChatModelChoice) -> Bool {
        guard let hub = Self.persistentModelCacheDirectory()?.appendingPathComponent("hub") else {
            return false
        }
        let repoDir = "models--" + choice.configuration.name.replacingOccurrences(of: "/", with: "--")
        let snapshots = hub.appendingPathComponent(repoDir).appendingPathComponent("snapshots")
        let fm = FileManager.default
        guard let revisions = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) else {
            return false
        }
        for revision in revisions {
            if let files = try? fm.contentsOfDirectory(atPath: revision.path),
               files.contains(where: { $0.hasSuffix(".safetensors") }) {
                return true
            }
        }
        return false
    }

    var isReady: Bool { loadState == .ready }

    /// 删除某模型已下载的权重（释放存储）。若删的是当前已加载的模型，则一并卸载并回到未加载态。
    func deleteDownloadedModel(_ choice: ChatModelChoice) {
        if let hub = Self.persistentModelCacheDirectory()?.appendingPathComponent("hub") {
            let repoDir = "models--" + choice.configuration.name.replacingOccurrences(of: "/", with: "--")
            try? FileManager.default.removeItem(at: hub.appendingPathComponent(repoDir))
        }
        if choice == modelChoice {
            stop()
            container = nil
            session = nil
            sessionContextKey = "__none__"
            loadState = .idle
        }
        refreshDownloadedState()
    }

    /// 当前下载源。切换后若之前加载失败，重新点下载即用新源。
    var downloadSource: DownloadSource {
        get { DownloadSource(rawValue: downloadSourceRaw) ?? .mirror }
        set {
            guard newValue.rawValue != downloadSourceRaw else { return }
            downloadSourceRaw = newValue.rawValue
        }
    }

    // MARK: 加载模型

    /// 模型权重的持久缓存目录：`Library/hf-models`，并标记为不进 iCloud 备份。
    /// 用 `Library/` 下的自定义子目录（不是会被系统清理的 `Library/Caches`，也避开
    /// `Application Support` 名字里的空格），退出重进后模型仍在；权重可重下，故排除出备份。
    static func persistentModelCacheDirectory() -> URL? {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        var dir = library.appendingPathComponent("hf-models", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
                return nil
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    func loadModel() {
        switch loadState {
        case .downloading, .loading, .ready:
            return  // 正在进行或已就绪
        case .idle, .failed:
            break
        }
        let choice = modelChoice
        // 把下载源写入环境变量：本次下载新建的 HubClient()/HubApi 会实时读取它，
        // 从而把权重与分词器的下载都导向所选源（默认国内镜像）。
        setenv("HF_ENDPOINT", downloadSource.endpoint, 1)
        // 把模型缓存指向持久目录。默认落在 Library/Caches，会被 iOS 清理导致每次重开都要重下。
        // 只设 HF_HOME 一个变量：swift-huggingface 会用 HF_HOME/hub 作为缓存根，避免多变量不一致。
        if let cacheDir = Self.persistentModelCacheDirectory() {
            setenv("HF_HOME", cacheDir.path, 1)
        }
        // 已缓存则直接进入「加载中」，否则显示下载进度。
        loadState = isDownloaded(choice) ? .loading : .downloading(nil)
        Task {
            do {
                let loaded = try await downloadContainer(for: choice)
                self.container = loaded
                self.session = nil
                self.sessionContextKey = "__none__"
                self.loadState = .ready
                self.selectedModelDownloaded = true
            } catch {
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    /// 用默认 Hugging Face 下载器 + 分词器加载模型容器（首次会联网下载权重）。
    private func downloadContainer(for choice: ChatModelChoice) async throws -> ModelContainer {
        try await #huggingFaceLoadModelContainer(configuration: choice.configuration) { progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                self.loadState = fraction >= 1.0 ? .loading : .downloading(fraction)
            }
        }
    }

    // MARK: 发送 / 生成

    func send(_ text: String, includeMusic: Bool, songTitle: String, lyrics: String) {
        guard isReady, let container, !isResponding else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        rebuildSessionIfNeeded(container: container, includeMusic: includeMusic, songTitle: songTitle, lyrics: lyrics)
        guard let session else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        let placeholder = ChatMessage(role: .assistant, text: "")
        messages.append(placeholder)
        let assistantID = placeholder.id
        isResponding = true

        generateTask = Task {
            var raw = ""
            do {
                for try await chunk in session.streamResponse(to: trimmed) {
                    if Task.isCancelled { break }
                    raw += chunk
                    // 展示时剥掉控制标记（含尚未闭合的半个标记），避免用户看到 <<PAUSE>> 之类。
                    self.setAssistantText(self.strippedForDisplay(raw), id: assistantID)
                }
            } catch {
                self.appendChunk("\n〔出错：\(error.localizedDescription)〕", to: assistantID)
            }
            // 生成结束后统一执行 AI 下达的播放控制指令。
            self.executeCommands(in: raw)
            self.finishResponding()
        }
    }

    func stop() {
        generateTask?.cancel()
        generateTask = nil
        isResponding = false
    }

    func clear() {
        stop()
        messages.removeAll()
        session = nil
        sessionContextKey = "__none__"
    }

    // MARK: 私有

    /// 上下文（通用 / 某首歌的歌词 / 自定义人设）变化时重建 ChatSession；相同则复用以保留多轮记忆。
    /// 重建时把已完成的对话轮次「回灌」进新会话，这样换歌 / 换人设也不会丢失上下文。
    private func rebuildSessionIfNeeded(container: ModelContainer, includeMusic: Bool, songTitle: String, lyrics: String) {
        let persona = customPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = includeMusic && !lyrics.isEmpty ? "music:\(songTitle)#\(lyrics.count)" : "general"
        let key = "\(base)|persona:\(persona)"
        guard session == nil || key != sessionContextKey else { return }

        var params = GenerateParameters(temperature: 0.6)
        params.maxTokens = 800
        let instr = instructions(includeMusic: includeMusic, songTitle: songTitle, lyrics: lyrics)
        // 此处 messages 里是本次发送前「已完成」的历史轮次（send 先重建、后追加新消息）。
        let history = conversationHistory()
        if history.isEmpty {
            session = ChatSession(container, instructions: instr, generateParameters: params)
        } else {
            session = ChatSession(container, instructions: instr, history: history, generateParameters: params)
        }
        sessionContextKey = key
    }

    /// 把 UI 里已完成的消息转成可回灌的对话历史（跳过空占位 / 未完成的助手消息；系统提示由 instructions 单独注入）。
    private func conversationHistory() -> [Chat.Message] {
        messages.compactMap { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user: return .user(text)
            case .assistant: return .assistant(text)
            }
        }
    }

    private func instructions(includeMusic: Bool, songTitle: String, lyrics: String) -> String {
        let persona = customPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        // 有自定义人设时用它作为身份，否则用默认助手设定。
        let personaLine = persona.isEmpty
            ? "你是 Meloha 音乐播放器内置的智能助手，请用简洁、友好的中文回答用户的问题。"
            : persona

        // 播放控制协议：让 AI 通过在回复里插入标记来操控播放器（标记会被隐藏、不展示给用户）。
        let controlLine = """
        你能控制本 App 的音乐播放。当且仅当用户想播放 / 暂停 / 切歌 / 快进快退时，在回复中原样插入对应标记：\
        <<PLAY>>=播放，<<PAUSE>>=暂停，<<TOGGLE>>=切换播放或暂停，<<NEXT>>=下一首，<<PREV>>=上一首，<<FORWARD>>=快进，<<BACK>>=快退。\
        例如用户说“暂停一下”，你就回复“好的～<<PAUSE>>”。与播放控制无关的对话里，绝对不要输出这些标记。
        """

        if includeMusic && !lyrics.isEmpty {
            return """
            \(personaLine)

            \(controlLine)

            当前用户正在听这首歌：《\(songTitle)》。它的歌词 / 字幕如下：
            \(lyrics)
            请结合上述歌曲信息回答用户的问题（翻译歌词、解释含义、背景、赏析等）；与歌曲无关的问题也照常回答。
            """
        }
        return "\(personaLine)\n\n\(controlLine)"
    }

    private func appendChunk(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += chunk
    }

    private func setAssistantText(_ text: String, id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    /// 去掉已闭合的控制标记，并隐藏结尾尚未闭合的半个标记（流式过程中避免露出 `<<PAU`）。
    private func strippedForDisplay(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var cleaned = Self.commandRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        if let open = cleaned.range(of: "<<", options: .backwards),
           cleaned[open.lowerBound...].range(of: ">>") == nil {
            cleaned = String(cleaned[..<open.lowerBound])
        }
        return cleaned
    }

    /// 解析并执行 AI 回复里的所有控制标记（按出现顺序）。
    private func executeCommands(in text: String) {
        guard let onPlaybackCommand else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        Self.commandRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let tokenRange = Range(match.range(at: 1), in: text) else { return }
            if let command = PlaybackCommand(rawValue: String(text[tokenRange]).uppercased()) {
                onPlaybackCommand(command)
            }
        }
    }

    private func finishResponding() {
        isResponding = false
        generateTask = nil
    }
}
