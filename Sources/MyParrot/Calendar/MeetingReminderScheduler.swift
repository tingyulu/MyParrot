import AppKit
import MyParrotCore

/// CAL-04/05/07(#2407 第一階段,Eric E1):排程器住 App 本身。每 5 分鐘＋行事曆變動＋睡醒重讀,
/// 對每場命中的會議排 T−提前分鐘 的計時器;到點 → 查已發紀錄 → 寫已發 → 發通知 → 跑外部指令。
/// App 沒開就沒提醒(第一階段已知缺口,#2429 用 launchd 補,兩邊共用同一份已發紀錄)。
/// 日誌只記數字與鍵(CAL-13),不記標題與人名。
@MainActor
@Observable
final class MeetingReminderScheduler {
    static let shared = MeetingReminderScheduler()

    // MARK: 設定(UserDefaults 持久化;預設全關)
    private(set) var settings: ReminderSettings

    // MARK: 狀態(設定頁/狀態 JSON 用)
    private(set) var calendars: [CalendarInfo] = []
    /// 24 小時內命中、還沒開始、還沒發過的場次,依提醒時刻排序。
    private(set) var planned: [PlannedReminder] = []
    private(set) var lastRefreshAt: Date?
    private(set) var lastError: String?
    private(set) var authorizationDenied = false
    private(set) var firedThisSession: [String] = []
    private(set) var lastFiredAt: Date?
    private(set) var running = false
    var next: PlannedReminder? { planned.first }

    // MARK: 依賴
    let source: EventKitCalendarSource
    let fired: FiredReminderStore
    /// App 層接通知(CAL-06)。
    var notify: ((PlannedReminder) -> Void)?
    /// 總開關打開且行事曆授權成功後呼叫(App 層順便請求通知權限)。
    var onEnabled: (() -> Void)?

    private var refreshTimer: Timer?
    private var fireTimer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// DEBUG 通道注入的假事件(CAL-14):只進記憶體,不碰真日曆。
    private var injected: [CalendarEventInfo] = []

    static let refreshInterval: TimeInterval = 300
    static let horizon: TimeInterval = 24 * 3600

    init(source: EventKitCalendarSource = EventKitCalendarSource(),
         fired: FiredReminderStore = FiredReminderStore(),
         defaults: UserDefaults = .standard) {
        self.source = source
        self.fired = fired
        self.defaults = defaults
        self.settings = Self.loadSettings(defaults)
    }

    // MARK: - 設定持久化

    private let defaults: UserDefaults
    static let kEnabled = "calendarRemindersEnabled"
    static let kCalendars = "calendarReminderCalendarIDs"
    static let kKeywords = "calendarReminderKeywords"
    static let kLead = "calendarReminderLeadMinutes"
    static let kCommand = "calendarReminderExternalCommand"

    static func loadSettings(_ d: UserDefaults) -> ReminderSettings {
        var s = ReminderSettings()
        s.enabled = d.bool(forKey: kEnabled)
        s.calendarIDs = Set(d.stringArray(forKey: kCalendars) ?? [])
        if let kw = d.string(forKey: kKeywords) { s.keywords = ReminderSettings.parseKeywords(kw) }
        let lead = d.integer(forKey: kLead)
        if lead > 0 { s.leadMinutes = lead }
        s.externalCommand = d.string(forKey: kCommand) ?? ""
        return s
    }

    private func persist() {
        defaults.set(settings.enabled, forKey: Self.kEnabled)
        defaults.set(Array(settings.calendarIDs).sorted(), forKey: Self.kCalendars)
        defaults.set(ReminderSettings.joinKeywords(settings.keywords), forKey: Self.kKeywords)
        defaults.set(settings.leadMinutes, forKey: Self.kLead)
        defaults.set(settings.externalCommand, forKey: Self.kCommand)
    }

    /// 設定頁唯一的寫入口:改完存檔,再依開關決定啟停/重讀。
    func update(_ mutate: (inout ReminderSettings) -> Void) {
        var s = settings
        mutate(&s)
        guard s != settings else { return }
        let wasEnabled = settings.enabled
        settings = s
        persist()
        if !s.enabled {
            stop()
        } else if !wasEnabled || !running {
            start()
        } else {
            Task { await refresh() }
        }
    }

    func setEnabled(_ on: Bool) { update { $0.enabled = on } }

    // MARK: - 啟停

    /// App 啟動時呼叫一次:關著就什麼都不做(CAL-03:零權限請求)。
    func start() {
        guard settings.enabled else { return }
        Task { await enable() }
    }

    private func enable() async {
        let ok = await source.requestAccess()
        authorizationDenied = !ok
        guard ok else {
            lastError = L("行事曆未授權")
            log("auth denied")
            return
        }
        running = true
        installObservers()
        onEnabled?()
        await refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        refreshTimer?.tolerance = 15
    }

    func stop() {
        running = false
        refreshTimer?.invalidate(); refreshTimer = nil
        fireTimer?.invalidate(); fireTimer = nil
        if let o = changeObserver { NotificationCenter.default.removeObserver(o); changeObserver = nil }
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        planned = []
        log("stopped")
    }

    private func installObservers() {
        if changeObserver == nil {
            changeObserver = source.observeChanges { [weak self] in Task { @MainActor in await self?.refresh() } }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }   // CAL-04:睡醒補跑一次(錯過的提醒立刻發)
            }
        }
    }

    // MARK: - 重讀與排程

    func refresh() async {
        guard settings.enabled, source.isAuthorized else { return }
        let now = Date()
        do {
            calendars = try await source.calendars()
            let events = try await source.events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(Self.horizon))
                + injected
            let firedKeys = fired.load(now: now)
            planned = MeetingReminderRules.select(events: events, settings: settings, now: now, horizon: Self.horizon)
                .filter { firedKeys[$0.key] == nil }
            lastRefreshAt = now
            lastError = nil
            if fired.isCorrupt { log("fired-store corrupt, treated as empty") }
            log("refresh calendars=\(calendars.count) events=\(events.count) matches=\(planned.count) next=\(planned.first.map { Self.iso($0.event.start) } ?? "-")")
            scheduleNextFire()
        } catch {
            lastError = "\(error)"
            log("refresh failed: \(error)")
        }
    }

    private func scheduleNextFire() {
        fireTimer?.invalidate(); fireTimer = nil
        guard let n = planned.first else { return }
        let delay = max(0, n.fireAt.timeIntervalSinceNow)
        fireTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireDue() }
        }
        fireTimer?.tolerance = 2
    }

    /// 到點:把所有該發的(提醒時刻 ≤ 現在、會議還沒開始)都發掉;已開始的丟掉不發。
    private func fireDue() {
        let now = Date()
        var rest: [PlannedReminder] = []
        for r in planned {
            if r.event.start <= now { log("dropped started \(r.key)"); continue }
            if r.fireAt <= now.addingTimeInterval(1) { fire(r) } else { rest.append(r) }
        }
        planned = rest
        scheduleNextFire()
    }

    /// CAL-05:發前先查、發後即寫;通知與外部指令走同一把鍵。
    func fire(_ r: PlannedReminder) {
        if fired.contains(r.key) { log("skip duplicate \(r.key)"); return }
        do { try fired.markFired(r.key) } catch { log("fired-store write failed: \(error)") }
        firedThisSession.append(r.key)
        lastFiredAt = Date()
        notify?(r)
        runExternalCommand(for: r)
        log("fired \(r.key)")
    }

    private func runExternalCommand(for r: PlannedReminder) {
        // MAS-14:商店版忽略外部指令(設定頁也不出現這欄);判斷在 ExternalNotifyCommand.effective(純函式,SelfTest 守)。
        guard let cmd = ExternalNotifyCommand.effective(settings.externalCommand, allowed: BuildFlavor.allowsExternalCommand) else { return }
        let env = ExternalNotifyCommand.environment(title: r.event.title, start: r.event.start, local: .current)
        Task.detached(priority: .utility) {
            let out = ExternalNotifyCommand.run(cmd, environment: env)
            await MainActor.run { Self.shared.log("external exit=\(out.exitCode) timedOut=\(out.timedOut)") }
        }
    }

    // MARK: - DEBUG 通道(CAL-14):假事件只進記憶體

    func inject(title: String, start: Date, end: Date) {
        injected.append(CalendarEventInfo(id: "debug-\(UUID().uuidString.prefix(8))",
                                          calendarID: settings.calendarIDs.first ?? "debug",
                                          title: title, start: start, end: end))
    }

    /// 等同「時間到了」:不管提醒時刻,直接走 fire(仍過去重)。找不到鍵回 false。
    @discardableResult
    func fireNow(key: String) -> Bool {
        guard let r = planned.first(where: { $0.key == key }) else { return false }
        fire(r)
        planned.removeAll { $0.key == key }
        scheduleNextFire()
        return true
    }

    func clearInjected() { injected = [] }

    // MARK: - 日誌(CAL-13:只有數字與鍵)

    static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MyParrot/calendar.log")
    }

    func log(_ line: String) {
        let url = Self.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = "\(Self.iso(Date())) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
