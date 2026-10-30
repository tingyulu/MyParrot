import Foundation

/// #2646 MAS-08:商店版旗標下的純函式——建置旗標對帳、書籤狀態機、登錄表不列 CLI 後端、外部指令忽略。
/// 全部不碰偏好、不碰檔案系統、兩種建置(帶／不帶 `MYPARROT_MAS`)都要綠;每案帶正控(GitHub 版的對照)。
/// 真路徑(`RecordingsFolderAccess.probe`、沙盒內寫檔)在 MAS-06／07 真機驗。正控突變記錄在 TEST_REPORT「MAS」節。
extension SelfTest {

    /// MAS-01 對帳:`isMAS` 跟編譯條件一致,四個衍生開關全部由它推出。
    static func masBuildFlavor() -> Result {
        var fails: [String] = []
        let f = BuildFlavor.self
        #if MYPARROT_MAS
        if !f.isMAS { fails.append("定義了 MYPARROT_MAS 但 isMAS 為 false") }
        #else
        if f.isMAS { fails.append("沒定義 MYPARROT_MAS 但 isMAS 為 true") }
        #endif
        if f.allowsUpdateChecker != !f.isMAS { fails.append("allowsUpdateChecker 應＝!isMAS") }
        if f.allowsCLIBackends != !f.isMAS { fails.append("allowsCLIBackends 應＝!isMAS") }
        if f.allowsExternalCommand != !f.isMAS { fails.append("allowsExternalCommand 應＝!isMAS") }
        if f.usesSecurityScopedRecordingsDir != f.isMAS { fails.append("usesSecurityScopedRecordingsDir 應＝isMAS") }
        return Result(name: "MAS-01 建置旗標對帳", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "isMAS=\(f.isMAS),四個衍生開關一致" : fails.joined(separator: ";"))
    }

    /// MAS-07 書籤狀態機:探測事實 ⇒ 五態;要人介入的三態都沒有可用 URL(不會靜默錄進容器)。
    static func masBookmarkStateMachine() -> Result {
        var fails: [String] = []
        typealias A = RecordingsFolderAccess
        let u = URL(fileURLWithPath: "/tmp/mas-bookmark-fixture", isDirectory: true)   // 只當值用,不碰檔案系統
        func p(_ has: Bool, _ url: URL?, stale: Bool = false, exists: Bool = true,
               granted: Bool = true, writable: Bool = true) -> A.Probe {
            A.Probe(hasBookmark: has, resolvedURL: url, isStale: stale, directoryExists: exists, accessGranted: granted, writable: writable)
        }
        let table: [(String, A.Probe, A.State)] = [
            ("沒書籤", p(false, nil), .unset),
            ("沒書籤時其他欄位不算", p(false, u, stale: true), .unset),
            ("解不開", p(true, nil), .missing(nil)),
            ("解開但資料夾不在", p(true, u, exists: false), .missing(u)),
            ("資料夾不在且過期仍是 missing", p(true, u, stale: true, exists: false), .missing(u)),
            ("不給存取", p(true, u, granted: false), .denied(u)),
            ("給存取但寫不進", p(true, u, writable: false), .denied(u)),
            ("過期又不給存取 ⇒ denied 優先", p(true, u, stale: true, granted: false), .denied(u)),
            ("過期但可用", p(true, u, stale: true), .stale(u)),
            ("全部好", p(true, u), .valid(u)),
        ]
        for (name, probe, want) in table where A.classify(probe) != want {
            fails.append("\(name):得 \(A.classify(probe)),要 \(want)")
        }
        if !A.State.unset.needsUserAction || !A.State.missing(nil).needsUserAction || !A.State.missing(u).needsUserAction
            || !A.State.denied(u).needsUserAction { fails.append("unset/missing/denied 應要人介入") }
        if A.State.valid(u).needsUserAction || A.State.stale(u).needsUserAction { fails.append("valid/stale 不該要人介入") }
        if A.State.valid(u).usableURL != u || A.State.stale(u).usableURL != u { fails.append("valid/stale 應給出 URL") }
        if A.State.denied(u).usableURL != nil || A.State.missing(u).usableURL != nil || A.State.unset.usableURL != nil {
            fails.append("denied/missing/unset 不該給出 URL(否則會靜默錄進容器)")
        }
        return Result(name: "MAS-07 書籤狀態機", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "\(table.count) 列判定表＋介入／可用 URL 規則全對" : fails.joined(separator: ";"))
    }

    /// MAS-14 登錄表:商店版不列 Claude CLI／Codex CLI;舊偏好指到它們 ⇒ off 不崩;GitHub 版照舊(正控)。
    static func masRegistryWithoutCLI() -> Result {
        var fails: [String] = []
        let R = ModelBackendRegistry.self
        let ids = { (list: [ModelBackendInfo]) in list.map(\.id) }
        let mas = R.assemble(platformSupportsAFM: true, includeCLIBackends: false)
        let gh = R.assemble(platformSupportsAFM: true, includeCLIBackends: true)
        if ids(mas).contains("claudeCLI") || ids(mas).contains("codexCLI") { fails.append("商店版不應列 CLI 後端,得 \(ids(mas))") }
        for keep in ["off", "appleFM", "appleTranslation"] where !ids(mas).contains(keep) { fails.append("商店版應保留 \(keep),得 \(ids(mas))") }
        if ids(gh).firstIndex(of: "claudeCLI") != 1 || ids(gh).firstIndex(of: "codexCLI") != 2 { fails.append("GitHub 版順序應 off/claudeCLI/codexCLI/…(正控),得 \(ids(gh))") }
        if ids(gh).filter({ $0 != "claudeCLI" && $0 != "codexCLI" }) != ids(mas) { fails.append("兩版差異只應是兩個 CLI 後端") }
        if ids(R.assemble(platformSupportsAFM: true)) != ids(gh) { fails.append("assemble 預設應含 CLI 後端(既有測試沿用)") }
        for cap in ModelCapability.allCases {
            if R.resolve("claudeCLI", in: mas, for: cap, includeDebugOnly: false).id != "off" { fails.append("商店版 \(cap)=claudeCLI 應回 off") }
            if R.resolve("codexCLI", in: mas, for: cap, includeDebugOnly: false).id != "off" { fails.append("商店版 \(cap)=codexCLI 應回 off") }
            if R.resolve("claudeCLI", in: gh, for: cap, includeDebugOnly: false).id != "claudeCLI" { fails.append("GitHub 版 \(cap)=claudeCLI 應回 claudeCLI(正控)") }
        }
        if R.resolve(nil, in: mas, for: .minutes, includeDebugOnly: false).id != "off" { fails.append("鍵不存在應 off") }
        if R.resolve("appleFM", in: mas, for: .minutes, includeDebugOnly: false).id != "appleFM" { fails.append("商店版 appleFM 應可選") }
        if R.resolve("appleFM", in: mas, for: .translation, includeDebugOnly: false).id != "off" { fails.append("appleFM 不做翻譯應 off") }
        let hasCLI = ids(R.all).contains("claudeCLI") || ids(R.all).contains("codexCLI")
        if hasCLI != BuildFlavor.allowsCLIBackends { fails.append("本建置 all 含 CLI=\(hasCLI) 與 allowsCLIBackends=\(BuildFlavor.allowsCLIBackends) 不一致") }
        return Result(name: "MAS-14 登錄表不列 CLI 後端", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "商店版 \(ids(mas)) / GitHub 版 \(ids(gh));舊偏好 CLI ⇒ off" : fails.joined(separator: ";"))
    }

    /// MAS-14 外部指令:不允許 ⇒ nil(不跑);允許 ⇒ 去頭尾空白;空白 ⇒ nil。
    static func masExternalCommandIgnored() -> Result {
        var fails: [String] = []
        let E = ExternalNotifyCommand.self
        if E.effective("echo hi", allowed: false) != nil { fails.append("不允許時應回 nil") }
        if E.effective("echo hi", allowed: true) != "echo hi" { fails.append("允許時應原樣(正控)") }
        if E.effective("  echo hi \n", allowed: true) != "echo hi" { fails.append("允許時應去頭尾空白") }
        if E.effective("   ", allowed: true) != nil || E.effective("", allowed: true) != nil { fails.append("空白應回 nil") }
        if E.effective("", allowed: false) != nil { fails.append("空白且不允許應回 nil") }
        return Result(name: "MAS-14 外部指令在商店版忽略", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "allowed=false ⇒ nil;true ⇒ 原樣/去空白;空白 ⇒ nil" : fails.joined(separator: ";"))
    }
}
