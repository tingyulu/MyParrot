import AppKit
import MyParrotCore

/// #2407:把三個零件接起來——`RecordingController`(錄音與兩個告警)、`MeetingReminderScheduler`(排程)、
/// `AppNotifications`(macOS 通知與按鈕)。App 啟動時呼叫一次;總開關關著時排程器什麼都不做。
/// 通知文字只問「要開始錄音嗎?」加時間(Eric D1:MyParrot 要開源,不帶任何業務說明)。
@MainActor
enum ReminderWiring {
    private static var installed = false

    static func install(controller: RecordingController) {
        guard !installed else { return }
        installed = true
        let notes = AppNotifications.shared
        let sched = MeetingReminderScheduler.shared
        notes.install()

        // 開關打開且行事曆授權成功 → 順便請求通知權限(CAL-03/06:只在這一刻請求)。
        sched.onEnabled = { Task { await notes.requestAuthorization() } }

        // CAL-06:T−N 分鐘的提醒。
        sched.notify = { r in
            notes.post(id: r.key,
                       title: r.event.title,
                       body: L("要開始錄音嗎?") + " " + dualTime(r.event.start),
                       category: AppNotifications.categoryReminder,
                       userInfo: ["title": r.event.title, "key": r.key])
        }

        // 「開始錄音」鈕 → 既有開錄路徑;已在錄/CLI 在錄(#949)就不開、只告知。
        notes.onStartRecording = { [weak controller] title in
            guard let c = controller else { return }
            NSApp.activate(ignoringOtherApps: true)
            if c.state == .recording || c.state == .paused {
                notes.post(id: "info-\(UUID().uuidString.prefix(6))", title: L("已在錄音"),
                           body: L("MyParrot 已經在錄音中,沒有另外開錄。"), category: AppNotifications.categoryInfo)
                return
            }
            if CLIRecordingProbe.isCLIRecording() || c.externalRecording != nil {   // #949:新版 CLI 走租約
                notes.post(id: "info-\(UUID().uuidString.prefix(6))", title: L("CLI 正在錄音"),
                           body: L("myparrot 指令列正在錄音,沒有另外開錄。"), category: AppNotifications.categoryInfo)
                return
            }
            if !title.isEmpty { c.currentTitle = title }
            RecordingConsent.confirmThen { c.startRecording() }   // MAS-17:通知按鈕也是 GUI 入口
        }

        // 「停止錄音」鈕 → 既有 stop()(CAL-11 只提醒,按了才停)。
        notes.onStopRecording = { [weak controller] in
            guard let c = controller, c.state == .recording || c.state == .paused else { return }
            c.stop()
        }

        // CAL-08(G1):某軌從起錄到現在都沒訊號。
        controller.onDeadTrackAlarm = { [weak controller] track in
            let minutes = max(1, Int(((controller?.deadTrackAlarmAfter) ?? 180) / 60))
            let name = track == .mic ? L("你的麥克風(右軌)") : L("對方聲音(左軌)")
            notes.post(id: "deadtrack-\(track.rawValue)-\(UUID().uuidString.prefix(6))",
                       title: L("錄音沒有訊號"),
                       body: Lf("%@已 %@ 分鐘沒有訊號。", [name, "\(minutes)"]),
                       category: AppNotifications.categoryInfo)
        }

        // CAL-11(C2):兩軌連續沒人說話。
        controller.onSilenceStopSuggested = { [weak controller] in
            let minutes = max(1, Int(((controller?.silenceStopAfter) ?? 1800) / 60))
            notes.post(id: "silence-\(UUID().uuidString.prefix(6))",
                       title: L("好像沒有人在說話"),
                       body: Lf("已經 %@ 分鐘沒有聲音了,要停止錄音嗎?", ["\(minutes)"]),
                       category: AppNotifications.categorySilence)
        }

        sched.start()
    }

    /// CAL-02:通知、設定頁、日誌共用的時間字串。本機＝台北 → 一個時間;否則「14:30 台北 ／ 08:30 Berlin (UTC+2)」。
    static func dualTime(_ date: Date, includeDate: Bool = false) -> String {
        let p = DualTimeZoneFormat.parts(date, local: .current, includeDate: includeDate)
        return p.isSame ? p.reference : Lf("%@ 台北 ／ %@ %@", [p.reference, p.local, p.localZone])
    }
}
