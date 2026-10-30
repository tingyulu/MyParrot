import SwiftUI
import AppKit
import MyParrotCore

/// CAL-12:設定頁「會議提醒」區段。總開關**預設關**;關著時其他列全部隱藏,也不會請求任何權限。
/// 文案不帶業務詞(Eric 2026-10-17 14:55:MyParrot 要開源);外部通知只是一行使用者自填的指令。
struct CalendarReminderSettingsSection: View {
    @Bindable var reminders: MeetingReminderScheduler = .shared
    var notifications: AppNotifications = .shared
    @State private var keywordsText = ""
    @State private var commandText = ""

    var body: some View {
        Section {
            Toggle(L("會議前提醒錄音"), isOn: Binding(
                get: { reminders.settings.enabled },
                set: { reminders.setEnabled($0) }))
            Text(L("讀取你勾選的行事曆,會議開始前幾分鐘跳出通知,按一下就開錄。預設關閉;開啟時才會請求行事曆與通知權限。"))
                .font(MPFont.caption).foregroundStyle(.tertiary).lineSpacing(3)
            if reminders.settings.enabled {
                permissionRow(L("行事曆權限"), ok: reminders.source.isAuthorized,
                              pane: "com.apple.preference.security?Privacy_Calendars")
                permissionRow(L("通知權限"), ok: notifications.authorized ?? false,
                              pane: "com.apple.Notifications-Settings.extension")
                calendarRows
                TextField(L("關鍵字(逗號分隔)"), text: $keywordsText)
                    .onChange(of: keywordsText) { _, new in
                        reminders.update { $0.keywords = ReminderSettings.parseKeywords(new) }
                    }
                Text(L("標題含任一關鍵字的事件才提醒。")).font(MPFont.caption).foregroundStyle(.tertiary)
                Stepper(Lf("提前 %@ 分鐘提醒", ["\(reminders.settings.leadMinutes)"]),
                        value: Binding(get: { reminders.settings.leadMinutes },
                                       set: { v in reminders.update { $0.leadMinutes = v } }),
                        in: 1...30)
                if BuildFlavor.allowsExternalCommand {   // MAS-14:商店版沒有這欄(排程器那端也不會跑)
                    TextField(L("外部通知指令(選填)"), text: $commandText)
                        .font(MPFont.caption)
                        .onChange(of: commandText) { _, new in reminders.update { $0.externalCommand = new } }
                    Text(L("到點時用 /bin/sh 執行這一行;環境變數 MYPARROT_EVENT_TITLE、MYPARROT_START_ISO、MYPARROT_START_LOCAL、MYPARROT_START_TAIPEI 帶會議資料。"))
                        .font(MPFont.caption).foregroundStyle(.tertiary).lineSpacing(3)
                }
                LabeledContent(L("上次讀取")) {
                    Text(reminders.lastRefreshAt.map { ReminderWiring.dualTime($0, includeDate: true) } ?? L("尚未讀取"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L("24 小時內命中")) { Text("\(reminders.planned.count)").foregroundStyle(.secondary) }
                LabeledContent(L("下一場")) {
                    Text(reminders.next.map { "\($0.event.title) · \(ReminderWiring.dualTime($0.event.start, includeDate: true))" } ?? L("沒有"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let e = reminders.lastError {
                    Text(e).font(MPFont.caption).foregroundStyle(.orange)
                }
                Button(L("立即重新讀取")) {
                    Task { await reminders.refresh() }
                    notifications.refreshAuthorization()
                }
            }
        } header: { Text(L("會議提醒")) }
        .onAppear {
            keywordsText = ReminderSettings.joinKeywords(reminders.settings.keywords)
            commandText = reminders.settings.externalCommand
            notifications.refreshAuthorization()
        }
    }

    @ViewBuilder private var calendarRows: some View {
        if reminders.calendars.isEmpty {
            LabeledContent(L("要掃描的日曆")) { Text(L("讀不到任何日曆")).foregroundStyle(.secondary) }
        } else {
            Text(L("要掃描的日曆")).font(MPFont.label)
            ForEach(reminders.calendars) { cal in
                Toggle(isOn: Binding(
                    get: { reminders.settings.calendarIDs.contains(cal.id) },
                    set: { on in reminders.update { if on { $0.calendarIDs.insert(cal.id) } else { $0.calendarIDs.remove(cal.id) } } })) {
                    HStack(spacing: MP.spS) {
                        Text(cal.title)
                        Text(cal.source).font(MPFont.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func permissionRow(_ label: String, ok: Bool, pane: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: MP.spS) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(ok ? L("已授權") : L("未授權"))
                    .font(MPFont.caption).foregroundStyle(ok ? Color.secondary : Color.orange)
                if !ok {
                    Button(L("開啟系統設定")) {
                        if let u = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(u) }
                    }
                }
            }
        }
    }
}
