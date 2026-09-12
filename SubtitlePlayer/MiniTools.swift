//
//  MiniTools.swift
//  SubtitlePlayer
//
//  小工具页的独立子页面：掷骰子 / 抽纸牌 / 抽签。
//  三者都在本地计算（系统随机源），无网络、无统计。
//
//  动画统一用「先快速跳变、再逐步减速停住」的节奏：用 async 循环手动控制每一跳的间隔，
//  而不是交给一条长时间的隐式动画——这样中途离开页面可以直接取消，也不会出现动画被打断
//  后停在半路的怪异状态。各页面的「上次结果」用 @AppStorage 存，小工具列表的行尾会读它。
//

import SwiftUI

// MARK: - 从播放页打开的小游戏

/// 播放页控制栏的小游戏入口。三个游戏共用一个 `.sheet(item:)`，各自带导航栏与「完成」。
enum MiniGame: String, Identifiable {
    case dice
    case cards
    case lottery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dice: return "掷骰子"
        case .cards: return "抽纸牌"
        case .lottery: return "抽签"
        }
    }
}

/// 把小游戏包成可从 sheet 呈现的形式（带标题栏和关闭按钮）。
struct MiniGameSheet: View {
    let game: MiniGame

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch game {
                case .dice: DiceRollerView()
                case .cards: CardDrawView()
                case .lottery: LotteryView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 掷骰子

struct DiceRollerView: View {
    /// 骰子个数，记住上次选择。
    @AppStorage("diceCount") private var diceCount: Int = 1
    @AppStorage("lastDiceResult") private var lastDiceResult: String = ""

    /// 每颗骰子当前显示的点数（1...6）。
    @State private var values: [Int] = [1]
    /// 翻滚时的随机倾角，停下时归零。
    @State private var tilts: [Double] = [0]
    /// 仍在翻滚的骰子下标。
    @State private var rolling: Set<Int> = []
    /// 正在跑的翻滚任务，离开页面时取消。
    @State private var tasks: [Task<Void, Never>] = []
    /// 每次有骰子停下时自增，用来触发触感反馈。
    @State private var settleTick = 0

    private var isRolling: Bool { !rolling.isEmpty }
    private var total: Int { values.reduce(0, +) }

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 16)]

    var body: some View {
        VStack(spacing: 28) {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(values.indices, id: \.self) { index in
                    Image(systemName: "die.face.\(values[index])")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .foregroundStyle(.tint)
                        .rotationEffect(.degrees(tilts[index]))
                        .scaleEffect(rolling.contains(index) ? 1.08 : 1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            VStack(spacing: 2) {
                Text("\(total)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(values.count > 1 ? "点数合计" : "点数")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Stepper("骰子数量 \(diceCount)", value: $diceCount, in: 1...6)
                .disabled(isRolling)

            Button {
                roll()
            } label: {
                Label(isRolling ? "翻滚中…" : "掷骰子", systemImage: "dice.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRolling)

            Text("完全本地计算的真随机，不联网、不记录。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(24)
        .navigationTitle("掷骰子")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.impact(flexibility: .solid), trigger: settleTick)
        .onAppear { syncDiceCount() }
        .onChange(of: diceCount) { _, _ in syncDiceCount() }
        .onDisappear { cancelAll() }
    }

    /// 让 values/tilts 的长度跟随 diceCount。新增的骰子默认 1 点。
    @MainActor
    private func syncDiceCount() {
        guard values.count != diceCount else { return }
        cancelAll()
        if diceCount > values.count {
            values.append(contentsOf: Array(repeating: 1, count: diceCount - values.count))
            tilts.append(contentsOf: Array(repeating: 0, count: diceCount - tilts.count))
        } else {
            values = Array(values.prefix(diceCount))
            tilts = Array(tilts.prefix(diceCount))
        }
    }

    @MainActor
    private func roll() {
        guard !isRolling else { return }
        cancelAll()
        rolling = Set(values.indices)
        // 每颗骰子各滚各的、依次停下，比一起停更有实物感。
        tasks = values.indices.map { index in
            Task { @MainActor in
                await tumble(index: index, duration: 0.65 + Double(index) * 0.16)
            }
        }
    }

    /// 单颗骰子的翻滚：间隔从 45ms 逐步拉长到 180ms，最后弹一下停住。
    @MainActor
    private func tumble(index: Int, duration: Double) async {
        var elapsed = 0.0
        var interval = 0.045

        while elapsed < duration, !Task.isCancelled, values.indices.contains(index) {
            withAnimation(.easeOut(duration: interval)) {
                values[index] = Int.random(in: 1...6)
                tilts[index] = Double.random(in: -20...20)
            }
            try? await Task.sleep(for: .seconds(interval))
            elapsed += interval
            interval = min(interval * 1.25, 0.18)
        }

        guard !Task.isCancelled, values.indices.contains(index) else { return }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) {
            values[index] = Int.random(in: 1...6)
            tilts[index] = 0
        }
        rolling.remove(index)
        settleTick += 1

        // 全部停下后才记结果，避免中途的点数被当成最终值。
        if rolling.isEmpty {
            lastDiceResult = values.count > 1
                ? "\(values.map(String.init).joined(separator: "+")) = \(total)"
                : "\(total)"
        }
    }

    @MainActor
    private func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
        rolling = []
        tilts = tilts.map { _ in 0 }
    }
}

// MARK: - 抽纸牌

/// 一张扑克牌。牌堆按真实牌组语义走：抽掉的不会再出现，抽完需重新洗牌。
struct PlayingCard: Identifiable, Equatable {
    let suit: String
    let rank: String

    var id: String { suit + rank }
    var isRed: Bool { suit == "♥" || suit == "♦" }
    var display: String { "\(suit) \(rank)" }

    static func freshDeck() -> [PlayingCard] {
        let suits = ["♠", "♥", "♣", "♦"]
        let ranks = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
        return suits.flatMap { suit in ranks.map { PlayingCard(suit: suit, rank: $0) } }
    }
}

struct CardDrawView: View {
    @AppStorage("lastCardResult") private var lastCardResult: String = ""

    /// 剩余牌堆（已洗好，从末尾取牌）。
    @State private var deck: [PlayingCard] = PlayingCard.freshDeck().shuffled()
    /// 当前翻开的牌。
    @State private var current: PlayingCard?
    /// 本轮已抽出的牌，按顺序显示在下方。
    @State private var drawn: [PlayingCard] = []
    /// 翻牌角度：<90 显示牌背，>=90 显示牌面。
    @State private var flipAngle: Double = 0
    @State private var drawTask: Task<Void, Never>?
    @State private var isDrawing = false

    private var isFaceUp: Bool { flipAngle >= 90 }

    var body: some View {
        VStack(spacing: 24) {
            cardStack
                .frame(height: 210)
                .padding(.top, 8)

            Text("剩余 \(deck.count) 张")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            HStack(spacing: 12) {
                Button {
                    draw()
                } label: {
                    Label(deck.isEmpty ? "已抽完" : "抽一张",
                          systemImage: "rectangle.portrait.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(deck.isEmpty || isDrawing)

                Button {
                    reshuffle()
                } label: {
                    Label("洗牌", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isDrawing || drawn.isEmpty)
            }

            if !drawn.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本轮已抽 \(drawn.count) 张")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(drawn) { card in
                                Text(card.display)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.gray.opacity(0.15), in: Capsule())
                                    .foregroundStyle(card.isRed ? .red : .primary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("抽纸牌")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: drawn.count)
        .onDisappear {
            drawTask?.cancel()
            drawTask = nil
        }
    }

    /// 牌堆 + 当前牌。牌堆用几层错位的圆角矩形示意厚度，剩得越少层数越少。
    private var cardStack: some View {
        ZStack {
            ForEach(0..<stackLayers, id: \.self) { layer in
                cardBack
                    .offset(x: CGFloat(layer) * 3, y: CGFloat(layer) * -3)
                    .opacity(0.35)
            }

            Group {
                if isFaceUp, let current {
                    cardFace(current)
                        // 容器已经转了 180°，牌面要再转回来才不是镜像的。
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                } else {
                    cardBack
                }
            }
            .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
    }

    private var stackLayers: Int {
        guard deck.count > 1 else { return 0 }
        return min(3, deck.count / 8 + 1)
    }

    private var cardBack: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.gradient)
            .frame(width: 140, height: 200)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 2)
                    .padding(6)
            }
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.85))
            }
    }

    private func cardFace(_ card: PlayingCard) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(width: 140, height: 200)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.gray.opacity(0.3), lineWidth: 1)
            }
            .overlay {
                VStack {
                    HStack {
                        Text("\(card.rank)\n\(card.suit)")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    Spacer()
                    Text(card.suit)
                        .font(.system(size: 64))
                    Spacer()
                    HStack {
                        Spacer()
                        Text("\(card.rank)\n\(card.suit)")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .rotationEffect(.degrees(180))
                    }
                }
                .padding(12)
                .foregroundStyle(card.isRed ? .red : .primary)
            }
    }

    @MainActor
    private func draw() {
        guard !deck.isEmpty, !isDrawing else { return }
        drawTask?.cancel()
        isDrawing = true
        drawTask = Task { @MainActor in
            let card = deck.removeLast()

            // 连抽时先把牌无动画地转回背面，否则会看到牌"倒着转回去"。
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { flipAngle = 0 }

            current = card
            withAnimation(.easeInOut(duration: 0.5)) { flipAngle = 180 }
            try? await Task.sleep(for: .seconds(0.5))

            guard !Task.isCancelled else { return }
            drawn.append(card)
            lastCardResult = card.display
            isDrawing = false
        }
    }

    @MainActor
    private func reshuffle() {
        drawTask?.cancel()
        isDrawing = false
        withAnimation(.easeInOut(duration: 0.3)) {
            flipAngle = 0
        }
        deck = PlayingCard.freshDeck().shuffled()
        drawn = []
        current = nil
    }
}

// MARK: - 抽签

/// 抽签 / 随机决定：自己维护一组选项，抽一个出来（"今晚吃什么"）。
/// 选项持久化在 UserDefaults，按行存——输入框是单行的，所以选项里不会有换行。
struct LotteryView: View {
    @AppStorage("lotteryOptions") private var storedOptions: String = ""
    @AppStorage("lastLotteryResult") private var lastLotteryResult: String = ""

    @State private var options: [String] = []
    @State private var newOption = ""
    /// 转动时高亮的选项下标。
    @State private var highlighted: Int?
    @State private var result: String?
    @State private var spinTask: Task<Void, Never>?
    @State private var isSpinning = false

    var body: some View {
        List {
            resultSection
            optionsSection
        }
        .navigationTitle("抽签")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: highlighted)
        .sensoryFeedback(.success, trigger: result)
        .onAppear { load() }
        .onDisappear {
            spinTask?.cancel()
            spinTask = nil
            isSpinning = false
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        Section {
            VStack(spacing: 8) {
                resultText
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .listRowBackground(Color.clear)

            Button {
                spin()
            } label: {
                Label(isSpinning ? "抽取中…" : "抽一个", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(options.count < 2 || isSpinning)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var resultText: some View {
        if isSpinning {
            Text(spinningLabel)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if let result {
            Text(result)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .transition(.scale.combined(with: .opacity))
        } else {
            Text(options.count < 2 ? "先添加至少 2 个选项" : "点下面的按钮开始")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 转动过程中显示的当前选项。下标可能因删除而越界，所以要边界检查。
    private var spinningLabel: String {
        guard let highlighted, options.indices.contains(highlighted) else { return "…" }
        return options[highlighted]
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            ForEach(options.indices, id: \.self) { index in
                HStack {
                    Text(options[index])
                    Spacer()
                    if highlighted == index {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.tint)
                    }
                }
                .listRowBackground(rowBackground(for: index))
            }
            .onDelete { offsets in
                guard !isSpinning else { return }
                options.remove(atOffsets: offsets)
                highlighted = nil
                save()
            }

            HStack {
                TextField("添加选项", text: $newOption)
                    .onSubmit { add() }
                Button {
                    add()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("选项")
        } footer: {
            Text("左滑删除。选项会记住，下次进来还在。")
        }
    }

    private func rowBackground(for index: Int) -> Color {
        highlighted == index
            ? Color.accentColor.opacity(0.18)
            : Color(.secondarySystemGroupedBackground)
    }

    private func load() {
        options = storedOptions
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func save() {
        storedOptions = options.joined(separator: "\n")
    }

    @MainActor
    private func add() {
        let trimmed = newOption.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        options.append(trimmed)
        newOption = ""
        save()
    }

    @MainActor
    private func spin() {
        guard options.count >= 2, !isSpinning else { return }
        spinTask?.cancel()
        isSpinning = true
        result = nil

        spinTask = Task { @MainActor in
            let count = options.count
            let target = Int.random(in: 0..<count)
            let start = highlighted ?? 0
            // 至少绕两圈再停在目标上，视觉上才像真的在转。
            let minimum = count * 2
            let extra = ((target - start - minimum) % count + count) % count
            let steps = minimum + extra

            for step in 1...steps {
                guard !Task.isCancelled else { return }
                highlighted = (start + step) % count
                // 间隔按进度平方增长：开头飞快，末尾一格一格挪。
                let progress = Double(step) / Double(steps)
                let interval = 0.05 + 0.24 * pow(progress, 2.2)
                try? await Task.sleep(for: .seconds(interval))
            }

            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                result = options[target]
                isSpinning = false
            }
            lastLotteryResult = options[target]
        }
    }
}
