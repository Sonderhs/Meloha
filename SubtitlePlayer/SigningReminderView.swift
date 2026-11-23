import SwiftUI
import UserNotifications

struct SigningReminderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("signingManualExpiry") private var manualExpiry = 0.0
    @AppStorage("signingRemindTomorrow") private var remindTomorrow = true
    @AppStorage("signingRemindSixHours") private var remindSixHours = true
    @State private var detectedExpiry: Date?
    @State private var showSettings = false
    @State private var editingDate = Date()
    @State private var status = ""
    @State private var reminderTask: Task<Void, Never>?
    private let notificationPrefix = "meloha.signing-expiry."
    private var expiry: Date? { detectedExpiry ?? (manualExpiry > 0 ? Date(timeIntervalSince1970: manualExpiry) : nil) }

    var body: some View {
        Button { editingDate = expiry ?? Date().addingTimeInterval(7 * 86_400); showSettings = true } label: {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Label(countdown(at: context.date), systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(expiry.map { $0.timeIntervalSince(context.date) <= 86_400 } == true ? Color.orange : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 5)
        .sheet(isPresented: $showSettings) { settings }
        .task { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onChange(of: manualExpiry) { _, _ in schedule() }
        .onChange(of: remindTomorrow) { _, _ in schedule() }
        .onChange(of: remindSixHours) { _, _ in schedule() }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                if let detectedExpiry {
                    Section("签名描述文件") { Text(detectedExpiry.formatted(date: .abbreviated, time: .shortened)) }
                } else {
                    Section("手动设置到期时间") {
                        DatePicker("到期时间", selection: $editingDate)
                        Button("保存到期时间") { manualExpiry = editingDate.timeIntervalSince1970 }
                        Button("刚重新签名，按 7 天计时") {
                            editingDate = Date().addingTimeInterval(7 * 86_400)
                            manualExpiry = editingDate.timeIntervalSince1970
                        }
                        if manualExpiry > 0 { Button("清除倒计时", role: .destructive) { manualExpiry = 0 } }
                    }
                }
                Section("到期提醒") {
                    Toggle("提前 24 小时", isOn: $remindTomorrow)
                    Toggle("提前 6 小时", isOn: $remindSixHours)
                    Button("启用通知") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                            schedule()
                        }
                    }
                    if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("签名到期提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }
    }

    private func countdown(at now: Date) -> String {
        guard let expiry else { return "设置签名倒计时" }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 0 else { return "签名已到期" }
        let hours = Int(seconds / 3600)
        let prefix = detectedExpiry == nil ? "签名预计剩余" : "签名剩余"
        if hours >= 24 { return "\(prefix) \(hours / 24) 天 \(hours % 24) 小时" }
        if hours > 0 { return "\(prefix) \(hours) 小时" }
        return "\(prefix) \(max(1, Int(seconds / 60))) 分钟"
    }

    private func refresh() {
        detectedExpiry = ProvisioningExpiry.installedProfile()
        schedule()
    }

    private func schedule() {
        let previousTask = reminderTask
        previousTask?.cancel()
        let date = expiry
        let enabled = [(24, remindTomorrow), (6, remindSixHours)]
        reminderTask = Task {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            let center = UNUserNotificationCenter.current()
            let authorization = await center.notificationSettings().authorizationStatus
            guard !Task.isCancelled else { return }
            let ids = enabled.map { notificationPrefix + String($0.0) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            guard authorization == .authorized || authorization == .provisional else {
                status = authorization == .denied ? "通知已关闭，可在 iPhone 的设置中启用。" : "允许通知后，iOS 会在到期前提醒你。"
                return
            }
            guard let date else { status = "设置到期时间后安排提醒。"; return }
            var count = 0
            for (hours, isEnabled) in enabled where isEnabled {
                let leadTime = date.timeIntervalSinceNow - Double(hours * 3600)
                guard leadTime > 0, !Task.isCancelled else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Meloha 签名即将到期"
                content.body = "约 \(hours) 小时后到期，请重新签名并覆盖安装。"
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, leadTime), repeats: false)
                do {
                    try await center.add(UNNotificationRequest(identifier: notificationPrefix + String(hours), content: content, trigger: trigger))
                    count += 1
                } catch {
                    guard !Task.isCancelled else { return }
                    status = "无法安排提醒，请检查通知设置后重试。"
                    return
                }
            }
            guard !Task.isCancelled else { return }
            status = count > 0 ? "已安排 \(count) 条到期提醒。" : "没有待发送的到期提醒。"
        }
    }
}
