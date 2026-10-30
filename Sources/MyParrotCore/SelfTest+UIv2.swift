import Foundation

/// #2438 UI v2 Phase 1 M1 的 SelfTest 案例(多模型骨架、會議記錄 Markdown、面板狀態、視窗加寬)。
/// 拆檔是為了跟其他里程碑同時加案例時少撞;登錄在 `SelfTest.run()`,`@Test` 在 `SelfTestCases.swift`。
extension SelfTest {

    // MARK: MDL-01 登錄表解析

    static func modelRegistryResolution() -> Result {
        var fails: [String] = []
        let R = ModelBackendRegistry.self
        let ids = { (list: [ModelBackendInfo]) in list.map(\.id) }

        // 後端宣告的能力集合
        if R.claudeCLI.capabilities != [.correction, .minutes, .translation] { fails.append("claudeCLI 能力應＝校正＋會議記錄＋翻譯(#2612),得 \(R.claudeCLI.capabilities)") }
        if R.claudeCLI.isLocal || R.claudeCLI.debugOnly { fails.append("claudeCLI 應 isLocal=false、debugOnly=false") }
        if R.off.capabilities != Set(ModelCapability.allCases) || !R.off.isLocal { fails.append("off 應支援全部能力且不出機") }
        if R.claudeCLI.id != CorrectionBackend.claudeCLI.rawValue || R.off.id != CorrectionBackend.off.rawValue { fails.append("登錄表 id 應等於 CorrectionBackend.rawValue") }
        if Set(ids(R.all)).count != R.all.count { fails.append("id 重複") }
        // MAS-14:商店版建置的登錄表沒有兩個 CLI 後端,下面的期望值依旗標組(商店版本身的對照在 masRegistryWithoutCLI)。
        let cli = BuildFlavor.allowsCLIBackends ? ["claudeCLI", "codexCLI"] : []
        // #2612:翻譯選單＝off／claudeCLI／codexCLI／appleTranslation(＋DEBUG localFake)
        #if DEBUG
        let trExpected = ["off"] + cli + ["appleTranslation", "localFake"]
        #else
        let trExpected = ["off"] + cli + ["appleTranslation"]
        #endif
        if ids(R.backends(for: .translation)) != trExpected { fails.append("翻譯應列 \(trExpected),得 \(ids(R.backends(for: .translation)))") }

        // 純過濾(兩種建置都跑):debugOnly 依旗標進出、能力不符不列
        let fixture = [R.off,
                       ModelBackendInfo(id: "fixtureDebug", label: "x", capabilities: [.minutes], isLocal: true, debugOnly: true),
                       ModelBackendInfo(id: "fixtureTr", label: "x", capabilities: [.translation], isLocal: true)]
        if ids(R.filter(fixture, for: .minutes, includeDebugOnly: false)) != ["off"] { fails.append("filter 不含 debugOnly 時應只剩 off") }
        if ids(R.filter(fixture, for: .minutes, includeDebugOnly: true)) != ["off", "fixtureDebug"] { fails.append("filter 含 debugOnly 時應列出") }
        if ids(R.filter(fixture, for: .correction, includeDebugOnly: true)) != ["off"] { fails.append("能力不符不應列") }

        // 建置分支:debugOnly 後端只在 DEBUG 列
        let branch: String
        #if DEBUG
        branch = "DEBUG"
        if !R.includesDebugOnly { fails.append("DEBUG 建置 includesDebugOnly 應為 true") }
        let expectedAll = ["off"] + cli + (AFMAvailability.isPlatformSupported ? ["appleFM"] : []) + ["appleTranslation", "localFake"]
        if ids(R.all) != expectedAll { fails.append("DEBUG all 應為 \(expectedAll),得 \(ids(R.all))") }
        let expectedCap = expectedAll.filter { $0 != "appleTranslation" }   // 校正／會議記錄不列只做翻譯的後端
        for cap in [ModelCapability.correction, .minutes] where ids(R.backends(for: cap)) != expectedCap {
            fails.append("DEBUG \(cap) 應列 \(expectedCap),得 \(ids(R.backends(for: cap)))")
        }
        if R.localFake.capabilities != [.correction, .minutes, .translation] || !R.localFake.debugOnly || !R.localFake.isLocal { fails.append("localFake 宣告不對") }
        if R.localFake.id != CorrectionBackend.localFake.rawValue { fails.append("localFake id 應等於 CorrectionBackend.localFake.rawValue") }
        #else
        branch = "release"
        if R.includesDebugOnly { fails.append("release 建置 includesDebugOnly 應為 false") }
        let expectedAll = ["off"] + cli + (AFMAvailability.isPlatformSupported ? ["appleFM"] : []) + ["appleTranslation"]
        if ids(R.all) != expectedAll { fails.append("release all 應為 \(expectedAll),得 \(ids(R.all))") }
        let expectedCap = expectedAll.filter { $0 != "appleTranslation" }
        for cap in ModelCapability.allCases where R.backends(for: cap).contains(where: \.debugOnly) {
            fails.append("release \(cap) 不應列 debugOnly 後端")
        }
        for cap in [ModelCapability.correction, .minutes] where ids(R.backends(for: cap)) != expectedCap {
            fails.append("release \(cap) 應列 \(expectedCap),得 \(ids(R.backends(for: cap)))")
        }
        #endif

        // selected/select:獨立 suite,不碰真偏好
        // 固定 suite 名(不帶 UUID):cfprefsd 會留一個空 plist,固定名＝最多一檔、不隨次數累積。開頭先清。
        let suite = "MyParrotSelfTest.mdl01"
        guard let d = UserDefaults(suiteName: suite) else { return Result(name: "MDL-01 登錄表解析", passed: false, detail: "建不出測試 suite") }
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        for cap in ModelCapability.allCases where R.selected(for: cap, defaults: d).id != "off" || R.isEnabled(cap, defaults: d) {
            fails.append("\(cap) 鍵不存在應為 off")
        }
        d.set("gpt9", forKey: "model.correction")
        if R.selected(for: .correction, defaults: d).id != "off" { fails.append("值不在表內應為 off") }
        d.set("appleTranslation", forKey: "model.minutes")   // #2612:只做翻譯的後端拿去當會議記錄 ⇒ off
        if R.selected(for: .minutes, defaults: d).id != "off" { fails.append("後端不支援該能力應為 off") }
        R.select("claudeCLI", for: .minutes, defaults: d)
        if BuildFlavor.allowsCLIBackends {
            if d.string(forKey: "model.minutes") != "claudeCLI" || R.selected(for: .minutes, defaults: d).id != "claudeCLI" || !R.isEnabled(.minutes, defaults: d) {
                fails.append("select claudeCLI → model.minutes 應生效")
            }
        } else if d.string(forKey: "model.minutes") != "off" || R.isEnabled(.minutes, defaults: d) {
            fails.append("MAS-14:商店版 select claudeCLI 應 fail closed 寫 off")   // 本建置不提供 ⇒ 跟不認得的 id 同路
        }
        R.select("bogus", for: .minutes, defaults: d)
        if d.string(forKey: "model.minutes") != "off" || R.isEnabled(.minutes, defaults: d) { fails.append("select 不認得的 id 應寫 off") }
        R.select("appleTranslation", for: .correction, defaults: d)
        if d.string(forKey: "model.correction") != "off" { fails.append("select 不支援的能力應寫 off") }
        #if DEBUG
        R.select("localFake", for: .correction, defaults: d)
        if R.selected(for: .correction, defaults: d).id != "localFake" { fails.append("DEBUG select localFake 應生效") }
        #else
        // release:不認得的值(含 DEBUG 建置寫進同一網域的假供應商 id)一律 off;上面 gpt9 已覆蓋,這裡再驗 select 擋下。
        R.select("fixtureDebug", for: .correction, defaults: d)
        if R.selected(for: .correction, defaults: d).id != "off" { fails.append("release select 非表內 id 應為 off") }
        #endif

        return Result(name: "MDL-01 模型登錄表解析(預設全關/不認得＝off/debugOnly 只在 DEBUG)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "\(branch) 分支;能力宣告、過濾、鍵不存在/值不在表/能力不符/select 擋無效值 全過" : fails.joined(separator: ";"))
    }

    // MARK: MDL-02 偏好遷移

    static func modelLegacyKeyMigration() -> Result {
        var fails: [String] = []
        let R = ModelBackendRegistry.self
        // 固定 suite 名(不帶 UUID):cfprefsd 會留一個空 plist,固定名＝最多一檔、不隨次數累積。開頭先清。
        let suite = "MyParrotSelfTest.mdl02"
        guard let d = UserDefaults(suiteName: suite) else { return Result(name: "MDL-02 偏好遷移", passed: false, detail: "建不出測試 suite") }
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        func reset() { for k in ["correctionBackend", "model.correction", "model.minutes", "model.translation"] { d.removeObject(forKey: k) } }

        // 1. 舊鍵 claudeCLI、新鍵沒有 ⇒ 遷移,舊鍵保留。
        //    MAS-14:商店版表裡沒有 claudeCLI ⇒ 鍵照樣搬(原樣複製)、但解析成 off(舊偏好指到 CLI 後端不崩、功能不出現)。
        let wantCLI: CorrectionBackend = BuildFlavor.allowsCLIBackends ? .claudeCLI : .off
        reset()
        d.set("claudeCLI", forKey: "correctionBackend")
        let b1 = RecordingController.loadCorrectionBackend(defaults: d)
        if b1 != wantCLI { fails.append("遷移後校正應為 \(wantCLI),得 \(b1)") }
        if d.string(forKey: "model.correction") != "claudeCLI" { fails.append("model.correction 應被寫成 claudeCLI(原樣複製,解析另算)") }
        if d.string(forKey: "correctionBackend") != "claudeCLI" { fails.append("舊鍵應保留") }
        if d.object(forKey: "model.minutes") != nil { fails.append("遷移不應碰其他能力的鍵") }
        // 2. 重跑無副作用
        R.migrateLegacyKeys(defaults: d)
        if d.string(forKey: "model.correction") != "claudeCLI" || RecordingController.loadCorrectionBackend(defaults: d) != wantCLI { fails.append("重跑遷移應不變") }

        // 3. 新鍵已有值 ⇒ 不覆蓋
        reset()
        d.set("claudeCLI", forKey: "correctionBackend")
        d.set("off", forKey: "model.correction")
        if RecordingController.loadCorrectionBackend(defaults: d) != .off || d.string(forKey: "model.correction") != "off" { fails.append("新鍵已有值不應被舊鍵覆蓋") }

        // 4. 都沒有 ⇒ off,且不平白寫出新鍵
        reset()
        if RecordingController.loadCorrectionBackend(defaults: d) != .off { fails.append("都沒有應為 off") }
        if d.object(forKey: "model.correction") != nil { fails.append("都沒有時不應寫出 model.correction") }

        // 5. 舊鍵是垃圾值 ⇒ 照抄(值合不合法交給解析),解析成 off
        reset()
        d.set("gpt9", forKey: "correctionBackend")
        if RecordingController.loadCorrectionBackend(defaults: d) != .off { fails.append("舊鍵垃圾值應解析成 off") }

        // 6. 寫入走新鍵,舊鍵不再寫也不刪。MAS-14:商店版 save claudeCLI ⇒ select fail closed 寫 off(本建置不提供)。
        reset()
        d.set("off", forKey: "correctionBackend")
        RecordingController.saveCorrectionBackend(.claudeCLI, defaults: d)
        if d.string(forKey: "model.correction") != wantCLI.rawValue { fails.append("save 應寫 model.correction=\(wantCLI.rawValue)") }
        if d.string(forKey: "correctionBackend") != "off" { fails.append("save 不應動舊鍵") }
        if RecordingController.loadCorrectionBackend(defaults: d) != wantCLI { fails.append("寫完讀回應為 \(wantCLI)") }
        RecordingController.saveCorrectionBackend(.off, defaults: d)
        if RecordingController.loadCorrectionBackend(defaults: d) != .off { fails.append("改回 off 讀回應為 off") }
        reset()
        RecordingController.saveCorrectionBackend(.claudeCLI, defaults: d)
        if d.object(forKey: "correctionBackend") != nil { fails.append("舊鍵不存在時 save 不應建出舊鍵") }

        return Result(name: "MDL-02 偏好遷移(舊 correctionBackend → model.correction,舊鍵保留)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "遷移/重跑/不覆蓋/都沒有/垃圾值/寫新鍵不動舊鍵 6 組" : fails.joined(separator: ";"))
    }

    // MARK: MDL-03(純函式部分)隱私確認判定

    /// 設定頁「模型」區段的確認框閘:出機後端第一次才問、以後端為單位(各能力共用)、本機後端與 off 不問、
    /// 不認得的 id 不問(交給 select 寫 off)。UI 與 DebugControl `model request` 都走這兩個函式。
    static func modelPrivacyConfirmation() -> Result {
        var fails: [String] = []
        let R = ModelBackendRegistry.self
        let suite = "MyParrotSelfTest.mdl03"
        guard let d = UserDefaults(suiteName: suite) else { return Result(name: "MDL-03 隱私確認判定", passed: false, detail: "建不出測試 suite") }
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }

        if R.privacyAcceptedKey(for: "claudeCLI") != "privacyAccepted.claudeCLI" { fails.append("偏好鍵應為 privacyAccepted.<後端 id>") }
        // MAS-14:商店版登錄表沒有任何出機後端 ⇒ claudeCLI 等同不認得的 id,不問;GitHub 版照舊要問。
        let cliAsks = BuildFlavor.allowsCLIBackends
        if R.needsPrivacyConfirmation("claudeCLI", defaults: d) != cliAsks { fails.append("出機後端沒同意過應要問(商店版:表裡沒有 ⇒ 不問),allowsCLI=\(cliAsks)") }
        if R.needsPrivacyConfirmation("off", defaults: d) { fails.append("off 不應問") }
        if R.needsPrivacyConfirmation("gpt9", defaults: d) { fails.append("不認得的 id 不應問") }
        #if DEBUG
        if R.needsPrivacyConfirmation(R.localFake.id, defaults: d) { fails.append("本機後端(localFake)不應問") }
        #endif
        if !cliAsks, R.all.contains(where: { !$0.isLocal }) { fails.append("商店版登錄表不應有任何出機後端,得 \(R.all.filter { !$0.isLocal }.map(\.id))") }
        // 正控:有一個出機後端被問到,才算尺量得到;同意後同一後端不再問(任何能力)
        R.acceptPrivacy("claudeCLI", defaults: d)
        if d.object(forKey: "privacyAccepted.claudeCLI") as? Bool != true { fails.append("acceptPrivacy 應寫 privacyAccepted.claudeCLI=true") }
        if R.needsPrivacyConfirmation("claudeCLI", defaults: d) { fails.append("同意過的後端不應再問") }
        // 同意不碰任何能力的選擇(選擇仍由 select 決定)
        for cap in ModelCapability.allCases where d.object(forKey: R.defaultsKey(for: cap)) != nil { fails.append("acceptPrivacy 不應寫 \(R.defaultsKey(for: cap))") }
        // 撤銷同意(刪鍵)⇒ 又要問(商店版:仍不問)
        d.removeObject(forKey: "privacyAccepted.claudeCLI")
        if R.needsPrivacyConfirmation("claudeCLI", defaults: d) != cliAsks { fails.append("刪掉同意鍵後應再問(商店版仍不問)") }

        return Result(name: "MDL-03 隱私確認判定(出機後端只問一次、以後端為單位、本機/off/不認得不問)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "鍵名/出機要問/off 不問/不認得不問/同意後不問/不碰能力選擇/刪鍵重問 全過" : fails.joined(separator: ";"))
    }

    // MARK: UI-47 補(Eric 2026-10-19 23:40～23:42):視窗最小寬度、把手在視窗內互換

    static func workspaceMinWidthAndRedistribute() -> Result {
        var fails: [String] = []
        if WorkspaceLayout.minimumWidth(columns: 0) != 380 { fails.append("0 欄應 380") }
        if WorkspaceLayout.minimumWidth(columns: 2) != 1040 { fails.append("2 欄應 380+2×330=1040,得 \(WorkspaceLayout.minimumWidth(columns: 2))") }
        if WorkspaceLayout.minimumWidth(columns: 3) != 1370 || WorkspaceLayout.minimumWidth(columns: -1) != 380 { fails.append("3 欄／負數") }
        // 互換:總和不變、都不低於 320、夾住
        let a = WorkspaceLayout.redistribute(left: 380, right: 380, dx: 40)
        if a != (420, 340) { fails.append("+40 應 (420,340),得 \(a)") }
        let b = WorkspaceLayout.redistribute(left: 380, right: 380, dx: -200)
        if b != (320, 440) { fails.append("左夾在 320,得 \(b)") }
        let c = WorkspaceLayout.redistribute(left: 380, right: 380, dx: 500)
        if c != (440, 320) { fails.append("右夾在 320,得 \(c)") }
        let d = WorkspaceLayout.redistribute(left: 500, right: 820, dx: 100.4)
        if d.left + d.right != 1320 || d.left != 600 { fails.append("總和不變且取整,得 \(d)") }
        let e = WorkspaceLayout.redistribute(left: 320, right: 300, dx: 10)
        if e != (320, 300) { fails.append("本來就放不下兩個下限:不動,得 \(e)") }
        // 壓縮(視窗變窄):兩欄 380/380 壓到 700 ⇒ 350/350;壓到 600 ⇒ 全釘 320(放不下也回下限)
        if WorkspaceLayout.compress([380, 380], toFit: 700, floor: 320) != [350, 350] { fails.append("等比壓縮錯") }
        if WorkspaceLayout.compress([380, 380], toFit: 600, floor: 320) != [320, 320] { fails.append("放不下應全釘下限") }
        let wf = WorkspaceLayout.compress([600, 380], toFit: 760, floor: 320)   // 380 先釘 320,600 吃剩下 440(取整可少 1)
        if wf.count != 2 || wf[1] != 320 || wf[0] < 439 || wf[0] > 440 || wf[0] + wf[1] > 760 { fails.append("水位填平錯,得 \(wf)") }
        return Result(name: "UI-47b 視窗最小寬度＋把手視窗內互換＋變窄壓縮", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "最小寬 0/2/3 欄;互換 5 案;壓縮 3 案" : fails.joined(separator: ";"))
    }

    // MARK: MIN-00(純函式部分)會議記錄 Markdown

    private final class MinutesBox: @unchecked Sendable { var docs: [MinutesDocument] = []; var error: Error? }

    static func minutesMarkdownRender() -> Result {
        var fails: [String] = []
        let when = Date(timeIntervalSince1970: 1_760_870_000)
        let full = MinutesDocument(summary: "  Budget frozen until Q1.\n", decisions: ["Use plan B", "Freeze budget"],
                                   actions: ["Draft security chapter\n  by Friday", "   "], questions: ["Annual or Q1?"],
                                   timeline: ["00:03 budget", "00:10 plan B"], updatedAt: when, inputTokens: 4200, outputTokens: 900)
        let expected = """
        ## Summary

        Budget frozen until Q1.

        ## Decisions

        - Use plan B
        - Freeze budget

        ## Action items

        - Draft security chapter by Friday

        ## Open questions

        - Annual or Q1?

        ## Timeline

        - 00:03 budget
        - 00:10 plan B

        """
        let out = MinutesMarkdown.render(full)
        if out != expected { fails.append("完整記錄 render 不符:\(out.debugDescription)") }

        // 空記錄:五段都在,放佔位
        let empty = MinutesMarkdown.render(MinutesDocument(updatedAt: when))
        let heads = empty.split(separator: "\n").filter { $0.hasPrefix("## ") }
        if heads != ["## Summary", "## Decisions", "## Action items", "## Open questions", "## Timeline"] { fails.append("空記錄應有五段標題,得 \(heads)") }
        if empty.components(separatedBy: "\n\n—").count != 6 { fails.append("空記錄每段應放佔位 —") }
        if !empty.hasSuffix("—\n") || empty.hasSuffix("\n\n") { fails.append("結尾應恰一個換行") }

        // 自訂標題(App 傳 L(...) 進來);Core 預設英文
        let labels = MinutesLabels(summary: "S", decisions: "D", actions: "A", questions: "Q", timeline: "T", empty: "n/a")
        let custom = MinutesMarkdown.render(MinutesDocument(decisions: ["x"], updatedAt: when), labels: labels)
        if !custom.hasPrefix("## S\n\nn/a\n\n## D\n\n- x\n\n## A\n\nn/a") || !custom.hasSuffix("## T\n\nn/a\n") { fails.append("自訂標題沒套上:\(custom.debugDescription)") }

        // .minutes.json 來回
        if let data = try? JSONEncoder().encode(full), let back = try? JSONDecoder().decode(MinutesDocument.self, from: data) {
            if back != full { fails.append("JSON 來回不等") }
        } else { fails.append("JSON 編解碼失敗") }

        let fakeNote: String
        #if DEBUG
        // 假供應商:時間軸每呼叫一次多一筆、帶上一版、時鐘可注入
        let fake = LocalFakeMinutesProvider(now: { when })
        let box = MinutesBox()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let first = try await fake.update(MinutesInput(transcriptDelta: ["a", "b"], notes: "n"))
                let second = try await fake.update(MinutesInput(previous: first, transcriptDelta: ["c"], notes: "n", language: .en))
                box.docs = [first, second]
            } catch { box.error = error }
            sem.signal()
        }
        sem.wait()
        if let e = box.error { fails.append("假供應商丟錯:\(e)") }
        else if box.docs.count == 2 {
            let (a, b) = (box.docs[0], box.docs[1])
            if a.timeline.count != 1 || b.timeline.count != 2 || b.timeline.first != a.timeline.first { fails.append("假供應商時間軸應累加,得 \(a.timeline) → \(b.timeline)") }
            if b.updatedAt != when || a.decisions.isEmpty || a.actions.isEmpty || a.questions.isEmpty || a.summary.isEmpty { fails.append("假供應商四段應都有內容、時鐘可注入") }
            if MinutesMarkdown.render(b).split(separator: "\n").filter({ $0.hasPrefix("## ") }).count != 5 { fails.append("假供應商輸出 render 應有五段") }
        } else { fails.append("假供應商沒回兩版") }
        fakeNote = "DEBUG 假供應商兩次更新時間軸 1→2"
        #else
        fakeNote = "release 無假供應商"
        #endif

        return Result(name: "MIN-00 會議記錄 Markdown render(四段＋時間軸,純函式)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "完整/空/自訂標題/換行壓平/JSON 來回;\(fakeNote)" : fails.joined(separator: ";"))
    }

    // MARK: UI-46 面板狀態 toggle／move／dock(窮舉)

    static func paneStateMoveDock() -> Result {
        var fails: [String] = []
        let all = PaneKind.allCases
        let (t, n, m) = (PaneKind.transcript, PaneKind.notes, PaneKind.minutes)

        // 預設值
        let std = PaneState.standard, cmp = PaneState.compact
        if std.open != [t, n] || std.order != [t, n, m] || std.remoteSide != .left || !std.widths.isEmpty || !std.filesExpanded { fails.append("標準預設不對:\(std)") }
        if !cmp.open.isEmpty || cmp.order != [t, n, m] || cmp.remoteSide != .left { fails.append("窄版預設不對:\(cmp)") }
        if std.width(of: n) != 380 { fails.append("未拉過的欄寬應為 380") }

        // toggle:每種 × 開/關
        var toggles = 0
        for k in all {
            for startOpen in [true, false] {
                var s = PaneState(open: startOpen ? Set(all) : [])
                s.toggle(k)
                let expect: Set<PaneKind> = startOpen ? Set(all).subtracting([k]) : [k]
                if s.open != expect { fails.append("toggle \(k) 從 \(startOpen ? "開" : "關") 得 \(s.open)") }
                s.toggle(k)
                if s.open != (startOpen ? Set(all) : []) { fails.append("toggle 兩次應還原 \(k)") }
                toggles += 1
            }
        }

        // move 窮舉:6 種順序 × 3 種欄 × delta −4…4,全開時＝標準陣列移動(夾兩端)
        let perms: [[PaneKind]] = [[t, n, m], [t, m, n], [n, t, m], [n, m, t], [m, t, n], [m, n, t]]
        var moves = 0
        for p in perms {
            for k in all {
                for delta in -4...4 {
                    var s = PaneState(open: Set(all), order: p)
                    s.move(k, by: delta)
                    var ref = p
                    let i = ref.firstIndex(of: k)!
                    ref.remove(at: i)
                    ref.insert(k, at: min(max(i + delta, 0), p.count - 1))
                    if s.order != ref { fails.append("move \(k) by \(delta) 於 \(p) 得 \(s.order) 應 \(ref)") }
                    moves += 1
                }
            }
        }
        // 兩端與越界具名案例
        var e1 = PaneState.standard; e1.open = Set(all); e1.move(t, by: -1)
        if e1.order != [t, n, m] { fails.append("最左再左移應不動") }
        var e2 = PaneState.standard; e2.open = Set(all); e2.move(m, by: 1)
        if e2.order != [t, n, m] { fails.append("最右再右移應不動") }
        var e3 = PaneState.standard; e3.open = Set(all); e3.move(t, by: 99)
        if e3.order != [n, m, t] { fails.append("越界右移應夾到最右") }
        var e4 = PaneState.standard; e4.open = Set(all); e4.move(m, by: -99)
        if e4.order != [m, t, n] { fails.append("越界左移應夾到最左") }

        // 以看得到的欄為準:筆記關著時,逐字稿 ▶ 換到會議記錄後面(不是換到看不見的筆記後面)
        var v1 = PaneState(open: [t, m]); v1.move(t, by: 1)
        if v1.order != [n, m, t] || v1.visibleColumns(minutesEnabled: true) != [m, t] { fails.append("關著的欄不佔格,得 \(v1.order)") }
        var v2 = PaneState(open: [t, m]); v2.move(m, by: -1)
        if v2.order != [m, t, n] { fails.append("會議記錄 ◀ 應換到逐字稿前,得 \(v2.order)") }
        // 關著的欄自己移:在完整順序裡移
        var v3 = PaneState(open: [t]); v3.move(m, by: -1)
        if v3.order != [t, m, n] { fails.append("關著的欄在完整順序移,得 \(v3.order)") }
        // B2:會議記錄後端 off ⇒ 視同關,不佔格、不顯示
        var b2 = PaneState(open: Set(all))
        if b2.visibleColumns(minutesEnabled: false) != [t, n] { fails.append("B2 後端 off 應不顯示會議記錄欄") }
        if b2.openWidths(minutesEnabled: false).count != 2 { fails.append("B2 後端 off 欄寬應只算兩欄") }
        b2.move(n, by: 1, minutesEnabled: false)
        if b2.order != [t, n, m] { fails.append("B2 後端 off 時筆記已在最右,應不動,得 \(b2.order)") }
        if !b2.open.contains(m) { fails.append("B2 偏好應保留 open.minutes") }
        var zero = PaneState.standard; zero.move(n, by: 0)
        if zero != .standard { fails.append("delta 0 應不動") }

        // dock:左右 × 起點,中線判定
        var docks = 0
        for start in RemoteSide.allCases {
            for side in RemoteSide.allCases {
                var s = PaneState(open: [], remoteSide: start); s.dock(side)
                if s.remoteSide != side { fails.append("dock \(side) 從 \(start)") }
                docks += 1
            }
            for (x, expect) in [(0.0, RemoteSide.left), (579.0, .left), (580.0, start), (581.0, .right), (1160.0, .right)] {
                var s = PaneState(open: [], remoteSide: start); s.dock(dropX: CGFloat(x), windowWidth: 1160)
                if s.remoteSide != expect { fails.append("dropX \(x) 從 \(start) 應 \(expect) 得 \(s.remoteSide)") }
                docks += 1
            }
        }

        // 欄寬
        var w = PaneState.standard
        w.setWidth(450, for: n); w.setWidth(200, for: t)
        if w.width(of: n) != 450 || w.width(of: t) != 320 { fails.append("setWidth 應保留自訂寬、不低於 320") }
        if w.openWidths(minutesEnabled: true) != [320, 450] { fails.append("openWidths 應依畫面順序,得 \(w.openWidths(minutesEnabled: true))") }

        // JSON 來回(標準/窄版/自訂)
        var custom = PaneState(open: [n, m], order: [m, t, n], remoteSide: .right, widths: [n: 450], filesExpanded: false)
        custom.setWidth(512, for: m)
        for s in [PaneState.standard, .compact, custom] {
            guard let data = try? JSONEncoder().encode(s), let back = try? JSONDecoder().decode(PaneState.self, from: data) else { fails.append("JSON 編解碼失敗 \(s)"); continue }
            if back != s { fails.append("JSON 來回不等:\(s) → \(back)") }
        }
        // 讀入容錯:不認得的種類/重複/缺欄位;型別錯才丟
        let tolerant = #"{"open":["notes","translation"],"order":["minutes","translation","minutes"],"widths":{"notes":400,"translation":300}}"#
        if let s = try? JSONDecoder().decode(PaneState.self, from: Data(tolerant.utf8)) {
            if s.open != [n] || s.order != [m, t, n] || s.remoteSide != .left || s.widths != [n: 400] || !s.filesExpanded { fails.append("容錯解碼不對:\(s)") }
        } else { fails.append("容錯 JSON 不應丟錯") }
        if (try? JSONDecoder().decode(PaneState.self, from: Data(#"{"open":5}"#.utf8))) != nil { fails.append("型別錯應丟錯(App 回預設)") }
        if (try? JSONDecoder().decode(PaneState.self, from: Data("{}".utf8))) != .standard { fails.append("空物件應回標準預設") }

        return Result(name: "UI-46 面板狀態 toggle/move/dock 窮舉＋JSON 來回", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "toggle \(toggles) 案、move 窮舉 \(moves) 案＋兩端/越界/關欄不佔格/B2、dock \(docks) 案、JSON 3 來回＋容錯 3 案" : fails.prefix(8).joined(separator: ";"))
    }

    // MARK: UI-47 視窗自動加寬／縮窄(A1)

    static func workspaceLayoutResolve() -> Result {
        var fails: [String] = []
        let mac = CGRect(x: 0, y: 0, width: 1512, height: 949)           // MacBook 可見區
        let ext = CGRect(x: 1512, y: -98, width: 1920, height: 1050)     // 右側外接螢幕(原點非 0)
        let leftExt = CGRect(x: -1280, y: 0, width: 1280, height: 775)   // 左側小螢幕(負原點)
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        func inside(_ f: CGRect, _ v: CGRect) -> Bool { f.minX >= v.minX && f.maxX <= v.maxX && f.minY >= v.minY && f.maxY <= v.maxY }
        var cases = 0
        func check(_ name: String, _ got: (frame: CGRect, columnWidths: [CGFloat]), frame: CGRect, cols: [CGFloat], visible: CGRect) {
            cases += 1
            if got.frame != frame || got.columnWidths != cols { fails.append("\(name):得 \(got.frame) \(got.columnWidths),應 \(frame) \(cols)") }
            if !inside(got.frame, visible) { fails.append("\(name):視窗超出可見區 \(got.frame)") }
        }

        // 1. 開一欄 +390(380＋間距 10)
        check("開一欄", WorkspaceLayout.resolve(current: r(100, 200, 380, 620), openWidths: [380], visible: mac),
              frame: r(100, 200, 770, 620), cols: [380], visible: mac)
        // 2. 右緣碰邊先整體左挪(不壓縮)
        check("先左挪", WorkspaceLayout.resolve(current: r(800, 200, 380, 620), openWidths: [380, 380], visible: mac),
              frame: r(352, 200, 1160, 620), cols: [380, 380], visible: mac)
        // 3. 三欄全開:無間距目標 1520 對 1512 寬 ⇒ 壓縮(TEST_PLAN 的 1520 口徑)
        check("三欄 1520 壓縮", WorkspaceLayout.resolve(current: r(0, 100, 380, 620), gap: 0, openWidths: [380, 380, 380], visible: mac),
              frame: r(0, 100, 1511, 620), cols: [377, 377, 377], visible: mac)
        // 4. 三欄全開含間距(目標 1550),起點在中間 ⇒ 先左挪再壓縮(取整後寬 1511,右緣貼 1512)
        check("先左挪再壓縮", WorkspaceLayout.resolve(current: r(600, 100, 1160, 620), openWidths: [380, 380, 380], visible: mac),
              frame: r(1, 100, 1511, 620), cols: [367, 367, 367], visible: mac)
        // 5. 關欄縮回:左緣不動
        check("關欄縮回", WorkspaceLayout.resolve(current: r(352, 200, 1160, 620), openWidths: [380], visible: mac),
              frame: r(352, 200, 770, 620), cols: [380], visible: mac)
        // 6. 空欄位 ⇒ 只剩左欄
        check("空欄位", WorkspaceLayout.resolve(current: r(352, 200, 770, 620), openWidths: [], visible: mac),
              frame: r(352, 200, 380, 620), cols: [], visible: mac)
        // 7. 使用者自訂欄寬保留(放得下就原樣)
        check("自訂欄寬保留", WorkspaceLayout.resolve(current: r(50, 0, 380, 620), openWidths: [450, 400], visible: mac),
              frame: r(50, 0, 1250, 620), cols: [450, 400], visible: mac)
        // 8. 多螢幕:右側外接(原點 1512,-98),右緣超出先左挪
        check("外接螢幕左挪", WorkspaceLayout.resolve(current: r(3000, 0, 380, 620), openWidths: [380, 380], visible: ext),
              frame: r(2272, 0, 1160, 620), cols: [380, 380], visible: ext)
        // 9. 多螢幕:左緣貼 minX(1512)不越界、壓縮
        check("外接螢幕貼左緣壓縮", WorkspaceLayout.resolve(current: r(1512, 0, 380, 620), openWidths: [600, 600, 600], visible: ext),
              frame: r(1512, 0, 1919, 620), cols: [503, 503, 503], visible: ext)
        // 10. 負原點小螢幕:壓到 320 仍放不下 ⇒ 各欄 320、視窗＝可見區寬;高度夾進可見區
        check("小螢幕壓到底", WorkspaceLayout.resolve(current: r(-1200, 100, 380, 900), openWidths: [380, 380, 380], visible: leftExt),
              frame: r(-1280, 0, 1280, 775), cols: [320, 320, 320], visible: leftExt)
        // 11. 不等寬等比壓縮(water-filling):兩欄釘在 320、寬欄分剩下的
        check("不等寬等比", WorkspaceLayout.resolve(current: r(0, 0, 380, 620), openWidths: [700, 340, 340], visible: r(0, 0, 1400, 900)),
              frame: r(0, 0, 1400, 620), cols: [350, 320, 320], visible: r(0, 0, 1400, 900))
        // 12. 視窗原本左緣在可見區外 ⇒ 拉回;y 超出上緣 ⇒ 夾回
        check("左緣越界拉回", WorkspaceLayout.resolve(current: r(-40, 500, 380, 620), openWidths: [380], visible: mac),
              frame: r(0, 329, 770, 620), cols: [380], visible: mac)
        // 13. 壓縮不會把本來就窄的欄變寬、各欄 ≥ 320
        let narrow = WorkspaceLayout.resolve(current: r(0, 0, 380, 620), openWidths: [300, 900, 900], visible: r(0, 0, 1500, 900))
        cases += 1
        if narrow.columnWidths.first != 300 || narrow.columnWidths.dropFirst().contains(where: { $0 < 320 }) || !inside(narrow.frame, r(0, 0, 1500, 900)) {
            fails.append("窄欄不應被放大、其餘 ≥320,得 \(narrow.columnWidths)")
        }

        return Result(name: "UI-47 視窗自動加寬/縮窄 WorkspaceLayout.resolve(A1)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "\(cases) 案:+390/先左挪/1520 壓縮/先左挪再壓縮/關欄縮回/空欄/自訂寬/外接左挪/外接貼左緣/負原點壓到底/不等寬/越界拉回/窄欄不放大" : fails.joined(separator: ";"))
    }
}
