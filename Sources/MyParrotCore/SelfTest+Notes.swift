import Foundation

/// #2438 UI v2 Phase 1 M2 的 SelfTest 案例(筆記 sidecar／自動存檔／Markdown 編輯・高亮・區塊、sidecar 改名／垃圾桶)。
/// 登錄在 `SelfTest.run()`,`@Test` 在 `SelfTestCases.swift`。
/// 真檔案例一律在 `FileManager.default.temporaryDirectory` 下自建目錄,測完整個刪掉;🚫 碰 `~/Documents/MyParrot`。
extension SelfTest {

    // MARK: - 共用小工具

    /// 收集失敗訊息;`detail` 列前幾條。
    private struct Checks {
        var fails: [String] = []
        var count = 0
        mutating func expect(_ ok: Bool, _ msg: @autoclosure () -> String) {
            count += 1
            if !ok { fails.append(msg()) }
        }
        mutating func edit(_ got: MarkdownEdit?, _ text: String, _ sel: Range<Int>, _ label: String) {
            count += 1
            guard let got else { fails.append("\(label):得 nil"); return }
            if got.text != text || got.selection != sel {
                fails.append("\(label):得 \(got.text.debugDescription) \(got.selection),應 \(text.debugDescription) \(sel)")
            }
        }
        mutating func merge(_ t: Tally) {
            count += t.count
            fails += t.fails
        }
        func result(_ name: String) -> Result {
            Result(name: name, passed: fails.isEmpty,
                   detail: fails.isEmpty ? "\(count) 項全過" : "\(fails.count)/\(count) 項失敗:" + fails.prefix(6).joined(separator: "；"))
        }
    }

    /// @MainActor 區段回傳的檢查結果(跨 isolation 要 Sendable)。
    private struct Tally: Sendable {
        var count = 0
        var fails: [String] = []
        mutating func ok(_ b: Bool, _ m: @autoclosure () -> String) {
            count += 1
            if !b { fails.append(m()) }
        }
    }

    /// 自建暫存目錄(案例結束 defer 刪)。
    private static func scratchDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_m2_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ s: String, _ url: URL) throws { try Data(s.utf8).write(to: url) }
    private static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private static func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// NotesStore 是 @MainActor;SelfTest.run() 不是。執行檔在主執行緒呼叫 ⇒ 直接 assumeIsolated;
    /// 從背景執行緒呼叫(Swift Testing 未標 @MainActor 時)⇒ 同步丟到 main queue。
    private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    // MARK: - NOTE-01 sidecar 命名與草稿流轉

    static func notesSidecarAndDraft() -> Result {
        let name = "NOTE-01 筆記 sidecar 與草稿流轉"
        var c = Checks()
        // 純函式
        let stem = URL(fileURLWithPath: "/tmp/x/2026-10-19 1930 週會")
        c.expect(NotesDocument(stem: stem).url.lastPathComponent == "2026-10-19 1930 週會.notes.md", "notes 檔名")
        c.expect(NotesDocument(recordingURL: URL(fileURLWithPath: "/tmp/x/a b.m4a")).url.path == "/tmp/x/a b.notes.md", "由錄音檔推 notes")
        c.expect(NotesDocument(recordingURL: URL(fileURLWithPath: "/tmp/x/v1.2 demo.caf")).url.lastPathComponent == "v1.2 demo.notes.md", "stem 含點")
        c.expect(NotesDocument.draftURL(in: URL(fileURLWithPath: "/tmp/x")).path == "/tmp/x/.draft.notes.md", "草稿路徑")
        c.expect(NotesDocument.initialText(title: "Weekly") == "# Weekly\n", "initialText")
        c.expect(NotesDocument.marker(at: 754) == "⚑ 00:12:34 ", "marker 754s,得 \(NotesDocument.marker(at: 754))")
        c.expect(NotesDocument.marker(at: 0) == "⚑ 00:00:00 ", "marker 0")
        c.expect(NotesDocument.marker(at: 36005.9) == "⚑ 10:00:05 ", "marker 捨去小數")
        c.expect(NotesDocument.marker(at: -3) == "⚑ 00:00:00 " && NotesDocument.marker(at: .nan) == "⚑ 00:00:00 ", "負數/NaN 當 0")
        c.expect(NotesDocument.marker(at: 360000) == "⚑ 100:00:00 ", "百小時不截")
        c.expect(NotesDocument.quote(speakerLabel: "Them", elapsed: 782, text: "hello") == "> Them 00:13:02：hello\n", "quote 單行")
        c.expect(NotesDocument.quote(speakerLabel: "對方", elapsed: 1, text: "a\r\nb\n\nc\n") == "> 對方 00:00:01：a\n> b\n>\n> c\n",
                 "quote 多行每行帶 >,得 \(NotesDocument.quote(speakerLabel: "對方", elapsed: 1, text: "a\r\nb\n\nc\n").debugDescription)")
        c.expect(NotesDocument.quote(speakerLabel: "You", elapsed: 5, text: "  hi  ", separator: ": ") == "> You 00:00:05: hi\n", "quote 自訂分隔")
        // 引用整段要被解析成一個 quote 區塊
        c.expect(MarkdownBlocks.parse(NotesDocument.quote(speakerLabel: "L", elapsed: 1, text: "a\nb")) == [.quote("L 00:00:01：a\nb")], "quote 解析回同一區塊")

        // 檔案系統(暫存夾)
        let fm = FileManager.default
        guard let dir = try? scratchDir("note01") else { return Result(name: name, passed: false, detail: "建不出暫存夾") }
        defer { try? fm.removeItem(at: dir) }
        let tally: Tally = onMain {
            var tl = Tally()
            func ok(_ b: Bool, _ m: @autoclosure () -> String) { tl.ok(b, m()) }
            let fm = FileManager.default   // FileManager 不是 Sendable,不從外面帶進 MainActor 區段
            let draft = NotesDocument.draftURL(in: dir)
            // A:草稿存在、目標不存在 ⇒ 改名
            let sA = dir.appendingPathComponent("2026-10-19 1930 A")
            do {
                try write("# A\n- draft\n", draft)
                let st = NotesStore(scheduler: ManualNotesScheduler())
                ok(st.attachDraft(to: sA), "A attach 失敗 \(st.lastError ?? "")")
                ok(!fm.fileExists(atPath: draft.path), "A 草稿應已改名走")
                ok(read(NotesDocument(stem: sA).url) == "# A\n- draft\n", "A 目標內容")
                ok(st.url == NotesDocument(stem: sA).url && st.text == "# A\n- draft\n" && !st.isDirty, "A store 狀態")
            } catch { ok(false, "A \(error)") }
            // B:草稿不存在、目標不存在 ⇒ 標題當內容,不立刻建檔;打字後才寫
            let sB = dir.appendingPathComponent("2026-10-19 1945 Client kickoff")
            let sched = ManualNotesScheduler()
            let st = NotesStore(scheduler: sched)
            ok(st.attachDraft(to: sB), "B attach 失敗")
            ok(st.text == "# Client kickoff\n", "B 預設內容應為 stem 標題部分,得 \(st.text.debugDescription)")
            ok(!fm.fileExists(atPath: NotesDocument(stem: sB).url.path), "B 沒打字不該建檔")
            st.setText(st.text + "first note\n")
            sched.advance(by: 1.0)
            ok(read(NotesDocument(stem: sB).url) == "# Client kickoff\nfirst note\n", "B 打字後應寫檔")
            let st2 = NotesStore(scheduler: ManualNotesScheduler())
            ok(st2.attachDraft(to: dir.appendingPathComponent("2026-10-19 2000 X"), title: "Custom") && st2.text == "# Custom\n", "B 指定標題")
            // C:草稿與目標都存在 ⇒ 不覆蓋,草稿接在後面
            let sC = dir.appendingPathComponent("2026-10-19 2015 C")
            do {
                try write("# C\nold\n\n", NotesDocument(stem: sC).url)
                try write("draft line\n", draft)
                let st3 = NotesStore(scheduler: ManualNotesScheduler())
                ok(st3.attachDraft(to: sC), "C attach 失敗")
                ok(read(NotesDocument(stem: sC).url) == "# C\nold\n\ndraft line\n", "C 應接在後面,得 \(String(describing: read(NotesDocument(stem: sC).url)).debugDescription)")
                ok(!fm.fileExists(atPath: draft.path), "C 草稿併入後應刪")
                ok(st3.text == "# C\nold\n\ndraft line\n", "C store 內容")
            } catch { ok(false, "C \(error)") }
            // D:草稿不存在、目標存在 ⇒ 照讀
            let st4 = NotesStore(scheduler: ManualNotesScheduler())
            ok(st4.attachDraft(to: sC) && st4.text == "# C\nold\n\ndraft line\n", "D 照讀既有")
            // load:不存在＝空字串不是錯;placeholder;讀不懂的檔不接管也不覆蓋
            let st5 = NotesStore(scheduler: ManualNotesScheduler())
            ok(st5.load(url: dir.appendingPathComponent("none.notes.md")) && st5.text == "" && st5.lastError == nil, "load 不存在＝空")
            ok(st5.load(url: dir.appendingPathComponent("none2.notes.md"), placeholder: "# P\n") && st5.text == "# P\n" && !st5.isDirty, "load placeholder")
            let bad = dir.appendingPathComponent("bad.notes.md")
            let badBytes = Data([0x23, 0x20, 0xFF, 0xFE, 0x0A])
            try? badBytes.write(to: bad)
            ok(!st5.load(url: bad) && st5.url == nil && st5.lastError != nil, "load 非 UTF-8 應失敗且不接管")
            st5.setText("oops")
            ok(st5.flush() && (try? Data(contentsOf: bad)) == badBytes, "讀失敗的檔不可被覆蓋")
            // 換場前先存:A 打字未到 debounce 就切到 sB ⇒ A 的字已落地;兩場各讀各的
            let sched6 = ManualNotesScheduler()
            let st6 = NotesStore(scheduler: sched6)
            _ = st6.load(url: NotesDocument(stem: sA).url)
            st6.setText("# A\n- draft\n- more\n")
            _ = st6.load(url: NotesDocument(stem: sB).url)
            ok(read(NotesDocument(stem: sA).url) == "# A\n- draft\n- more\n", "切換前應 flush")
            ok(st6.text == "# Client kickoff\nfirst note\n", "切到 B 讀 B 自己的")
            sched6.advance(by: 5)
            ok(st6.writeCount == 1, "切換後舊 debounce 不應再寫,writeCount=\(st6.writeCount)")
            // 改名後 retarget:未存的字寫到新路徑;丟垃圾桶後 detach:排程中的存檔不在原路徑長出孤兒檔
            let sched7 = ManualNotesScheduler()
            let st7 = NotesStore(scheduler: sched7)
            let oldN = dir.appendingPathComponent("2026-10-19 2200 Old.notes.md")
            let newN = dir.appendingPathComponent("2026-10-19 2200 New.notes.md")
            _ = st7.load(url: oldN)
            st7.setText("x")
            _ = st7.flush()
            try? fm.moveItem(at: oldN, to: newN)          // 模擬 performRename
            st7.retarget(to: newN)
            st7.setText("xy")
            sched7.advance(by: 1)
            ok(read(newN) == "xy" && !fm.fileExists(atPath: oldN.path), "retarget 後寫新路徑、舊路徑不長回來")
            st7.setText("xyz")                            // 排程中
            try? fm.removeItem(at: newN)                  // 模擬檔已進垃圾桶(暫存夾自建檔)
            st7.detach()
            sched7.advance(by: 5)
            ok(!fm.fileExists(atPath: newN.path) && st7.url == nil && !st7.isDirty && sched7.pendingCount == 0, "detach 後不寫孤兒檔")
            ok(!names(dir).contains { $0.contains(".tmp-") }, "不應殘留 tmp:\(names(dir))")
            return tl
        }
        c.merge(tally)
        return c.result(name)
    }

    // MARK: - NOTE-02 自動存檔(debounce＋原子寫)

    static func notesAtomicAutosave() -> Result {
        let name = "NOTE-02 自動存檔 debounce＋原子寫"
        let fm = FileManager.default
        guard let dir = try? scratchDir("note02") else { return Result(name: name, passed: false, detail: "建不出暫存夾") }
        defer { try? fm.removeItem(at: dir) }
        let tally: Tally = onMain {
            var tl = Tally()
            func ok(_ b: Bool, _ m: @autoclosure () -> String) { tl.ok(b, m()) }
            let fm = FileManager.default   // FileManager 不是 Sendable,不從外面帶進 MainActor 區段
            let url = dir.appendingPathComponent("2026-10-19 1930 S.notes.md")
            let sched = ManualNotesScheduler()
            let st = NotesStore(debounce: 1.0, maxWait: 3.0, scheduler: sched)
            ok(st.load(url: url), "load")
            // (a) 一次改動:0.9 秒內不寫,滿 1 秒寫一次
            st.setText("a")
            ok(st.isDirty, "改動後應 dirty")
            sched.advance(by: 0.9)
            ok(st.writeCount == 0 && !fm.fileExists(atPath: url.path), "未滿 debounce 不該寫")
            sched.advance(by: 0.1)
            ok(st.writeCount == 1 && read(url) == "a" && !st.isDirty, "滿 1 秒應寫一次,writeCount=\(st.writeCount)")
            ok(st.lastSavedAt.map { abs($0.timeIntervalSince(sched.now)) < 1e-6 } == true, "lastSavedAt 用注入時鐘")
            // (b) 連打 50 次(每 0.05 秒)⇒ ≤3 次寫入(預期 1),最後內容正確
            var w0 = st.writeCount
            var t = "a"
            for k in 0..<50 { t += "\(k % 10)"; st.setText(t); sched.advance(by: 0.05) }
            sched.advance(by: 2)
            ok(st.writeCount - w0 <= 3 && st.writeCount - w0 >= 1, "連打 50 次寫 \(st.writeCount - w0) 次(應 1…3)")
            ok(read(url) == t, "連打後內容應為最後版本")
            // (c) 持續打字 5 秒(每 0.1 秒)⇒ maxWait 讓中途也存,總寫入 ≤3
            w0 = st.writeCount
            var midWrites = 0
            for k in 0..<50 {
                t += "\(k % 7)"; st.setText(t); sched.advance(by: 0.1)
                if k == 45 { midWrites = st.writeCount - w0 }
            }
            sched.advance(by: 2)
            ok(midWrites >= 1, "持續打字 4.6 秒內應至少存一次(maxWait),得 \(midWrites)")
            ok(st.writeCount - w0 <= 3, "持續打字 50 次寫 \(st.writeCount - w0) 次(應 ≤3)")
            ok(read(url) == t, "持續打字後內容正確")
            // (d) 內容沒變不寫;改回原樣不排程
            w0 = st.writeCount
            ok(st.flush() && st.writeCount == w0, "沒變的 flush 不該寫")
            st.setText(t)
            ok(sched.pendingCount == 0, "同內容 setText 不該排程")
            st.setText(t + "x"); st.setText(t)
            ok(!st.isDirty && sched.pendingCount == 0, "改回已存內容 ⇒ 不 dirty、不排程")
            sched.advance(by: 5)
            ok(st.writeCount == w0, "改回原樣不該寫")
            // (e) 立即 flush 取消 debounce;檔已存在時走 tmp＋replace ⇒ 目標換成新 inode(不是原地改寫)
            let inodeBefore = (try? fm.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber
            st.setText(t + "!")
            ok(st.flush() && read(url) == t + "!" && sched.pendingCount == 0, "flush 立即寫並取消排程")
            let inodeAfter = (try? fm.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber
            ok(inodeBefore != nil && inodeAfter != nil && inodeBefore != inodeAfter,
               "原子寫應換上新檔(inode \(String(describing: inodeBefore)) → \(String(describing: inodeAfter)))")
            // (f) 原子寫:目錄裡沒有 tmp 殘留,只有目標檔
            ok(names(dir) == ["2026-10-19 1930 S.notes.md"], "目錄應只剩目標檔,得 \(names(dir))")
            // (g) 寫失敗(上層目錄不存在):不拋、lastError、保持 dirty、不留 tmp
            let st2 = NotesStore(scheduler: ManualNotesScheduler())
            let ghost = dir.appendingPathComponent("no-such-dir/x.notes.md")
            ok(st2.load(url: ghost), "load 不存在路徑＝空")
            st2.setText("lost?")
            ok(!st2.flush() && st2.lastError != nil && st2.isDirty, "寫失敗應回 false、lastError、仍 dirty")
            ok(names(dir) == ["2026-10-19 1930 S.notes.md"], "寫失敗不留 tmp,得 \(names(dir))")
            // (h) 外部改檔後 load 讀到新內容(崩潰後重開＝從檔案恢復)
            try? write("from disk\n", url)
            let st3 = NotesStore(scheduler: ManualNotesScheduler())
            ok(st3.load(url: url) && st3.text == "from disk\n", "重開從檔案恢復")
            // (i) url 沒設定時 flush 是 no-op
            let st4 = NotesStore(scheduler: ManualNotesScheduler())
            st4.setText("x")
            ok(st4.flush() && st4.writeCount == 0, "沒 url 的 flush 應 no-op")
            return tl
        }
        var c = Checks()
        c.merge(tally)
        return c.result(name)
    }

    // MARK: - NOTE-03 工具列插入規則

    static func markdownToolbarInsert() -> Result {
        var c = Checks()
        let E = MarkdownEditing.self
        // 粗體/斜體/刪除線/程式碼:包住、解除、游標置中
        c.edit(E.wrap("hello world", selection: 6..<11, with: "**"), "hello **world**", 8..<13, "粗體包住")
        c.edit(E.wrap("hello **world**", selection: 8..<13, with: "**"), "hello world", 6..<11, "粗體再按解除")
        c.edit(E.wrap("**bold**", selection: 0..<8, with: "**"), "bold", 0..<4, "選取含符號 ⇒ 解除")
        c.edit(E.wrap("ab", selection: 1..<1, with: "**"), "a****b", 3..<3, "無選取插一對游標置中")
        c.edit(E.wrap("a****b", selection: 3..<3, with: "**"), "ab", 1..<1, "空對再按拿掉")
        c.edit(E.wrap("**x**", selection: 2..<3, with: "*"), "***x***", 3..<4, "粗體上加斜體")
        c.edit(E.wrap("***x***", selection: 3..<4, with: "*"), "**x**", 2..<3, "斜體解除不拆粗體")
        c.edit(E.wrap("***x***", selection: 3..<4, with: "**"), "*x*", 1..<2, "粗斜體解粗體")
        c.edit(E.wrap("x", selection: 0..<1, with: "~~"), "~~x~~", 2..<3, "刪除線")
        c.edit(E.wrap("~~x~~", selection: 2..<3, with: "~~"), "x", 0..<1, "刪除線解除")
        c.edit(E.wrap("a b", selection: 2..<3, with: "`"), "a `b`", 3..<4, "行內程式碼")
        c.edit(E.wrap("x", selection: 0..<0, with: "`"), "``x", 1..<1, "程式碼無選取")
        c.edit(E.wrap("會議😀重點", selection: 4..<6, with: "**"), "會議😀**重點**", 6..<8, "中文＋emoji 以 UTF-16 計")
        c.edit(E.wrap("x", selection: 5..<9, with: "**"), "x****", 3..<3, "越界選取夾回")
        // 程式碼:多行 ⇒ 圍欄,再按拿掉
        c.edit(E.toggleCode("a\nb", selection: 0..<3), "```\na\nb\n```", 4..<7, "多行圍欄")
        c.edit(E.toggleCode("```\na\nb\n```", selection: 4..<7), "a\nb", 0..<3, "圍欄再按拿掉")
        c.edit(E.toggleCode("ab", selection: 0..<2), "`ab`", 1..<3, "單行走行內")
        // 行首前綴:每行加、再按移除、互相取代、編號遞增
        c.edit(E.prefixLines("a\nb\nc", selection: 0..<5, with: "- "), "- a\n- b\n- c", 0..<11, "項目清單三行")
        c.edit(E.prefixLines("- a\n- b\n- c", selection: 0..<11, with: "- "), "a\nb\nc", 0..<5, "項目清單再按移除")
        c.edit(E.prefixLines("a\nb\nc", selection: 0..<5, with: "1. "), "1. a\n2. b\n3. c", 0..<14, "編號遞增")
        c.edit(E.prefixLines("- a\n- b", selection: 0..<7, with: "1. "), "1. a\n2. b", 0..<9, "項目換編號")
        c.edit(E.prefixLines("1. a\n2. b", selection: 0..<9, with: "1. "), "a\nb", 0..<3, "編號再按移除")
        c.edit(E.prefixLines("## T", selection: 4..<4, with: "# "), "# T", 3..<3, "H2 換 H1")
        c.edit(E.prefixLines("## T", selection: 4..<4, with: "## "), "T", 1..<1, "H2 再按移除")
        c.edit(E.prefixLines("abc", selection: 1..<1, with: "### "), "### abc", 5..<5, "H3 游標跟著移")
        c.edit(E.prefixLines("x", selection: 0..<0, with: "- [ ] "), "- [ ] x", 6..<6, "勾選框")
        c.edit(E.prefixLines("- [x] x", selection: 0..<0, with: "- [ ] "), "x", 0..<0, "勾選框再按移除(含已勾)")
        c.edit(E.prefixLines("a\nb", selection: 0..<3, with: "> "), "> a\n> b", 0..<7, "引用")
        c.edit(E.prefixLines("> a\n> b", selection: 0..<7, with: "> "), "a\nb", 0..<3, "引用再按移除")
        c.edit(E.prefixLines("> a", selection: 3..<3, with: "- "), "> - a", 5..<5, "引用內加清單")
        c.edit(E.prefixLines("", selection: 0..<0, with: "- "), "- ", 2..<2, "空行插語法")
        c.edit(E.prefixLines("a\n\nb", selection: 0..<4, with: "- "), "- a\n\n- b", 0..<8, "多行略過空行")
        c.edit(E.prefixLines("  - a", selection: 5..<5, with: "1. "), "  1. a", 6..<6, "保留縮排")
        // 連結
        c.edit(E.insertLink("go site", selection: 3..<7, url: "https://x.com", clipboardIsURL: true),
               "go [site](https://x.com)", 24..<24, "連結:剪貼簿網址＋選取")
        c.edit(E.insertLink("", selection: 0..<0, url: "https://x.com", clipboardIsURL: true), "[](https://x.com)", 1..<1, "連結:剪貼簿網址無選取")
        c.edit(E.insertLink("a", selection: 0..<1, url: "hello", clipboardIsURL: false), "[a](url)", 4..<7, "連結:非網址選中 url")
        c.edit(E.insertLink("x ", selection: 2..<2, url: "", clipboardIsURL: false), "x [](url)", 3..<3, "連結:非網址無選取")
        // 表格 2×2
        let table = "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |\n|  |  |\n"
        c.edit(E.insertTable2x2("", selection: 0..<0), table, 2..<10, "表格空文件")
        let t2 = E.insertTable2x2("intro", selection: 5..<5, headers: ("名稱", "數量"))
        c.edit(t2, "intro\n\n| 名稱 | 數量 |\n| --- | --- |\n|  |  |\n|  |  |\n", 9..<11, "表格接在段落後空一行")
        c.expect(MarkdownBlocks.parse(t2.text) == [.paragraph("intro"), .table(header: ["名稱", "數量"], rows: [["", ""], ["", ""]])],
                 "插入的表格要被解析成 2×2 表格")
        let t3 = E.insertTable2x2("a\nb", selection: 2..<2)
        c.expect(MarkdownBlocks.parse(t3.text).count == 3, "表格插在兩段中間不吃掉下一段:\(t3.text.debugDescription)")
        // 分隔線
        c.edit(E.insertHR("text", selection: 4..<4), "text\n\n---\n", 10..<10, "分隔線在段落後空一行(不變 H2)")
        c.expect(MarkdownBlocks.parse("text\n\n---\n") == [.paragraph("text"), .hr], "分隔線解析為 hr")
        c.edit(E.insertHR("", selection: 0..<0), "---\n", 4..<4, "分隔線空文件")
        c.edit(E.insertHR("a\nb", selection: 2..<2), "a\n\n---\n\nb", 7..<7, "分隔線插在兩段中間")
        // ⚑ 標記插入
        c.edit(E.insert("ab", selection: 1..<1, snippet: NotesDocument.marker(at: 61)), "a⚑ 00:01:01 b", 12..<12, "標記插在游標處")
        return c.result("NOTE-03 工具列插入規則")
    }

    // MARK: - NOTE-04 編輯行為

    static func markdownEditingBehaviors() -> Result {
        var c = Checks()
        let E = MarkdownEditing.self
        // Enter 接續清單
        c.edit(E.enterContinuesList("- a", selection: 3..<3), "- a\n- ", 6..<6, "Enter 接項目")
        c.edit(E.enterContinuesList("* a", selection: 3..<3), "* a\n* ", 6..<6, "Enter 保留 * 標記")
        c.edit(E.enterContinuesList("1. a", selection: 4..<4), "1. a\n2. ", 8..<8, "Enter 編號遞增")
        c.edit(E.enterContinuesList("9) x", selection: 4..<4), "9) x\n10) ", 9..<9, "Enter 9) → 10)")
        c.edit(E.enterContinuesList("- [x] done", selection: 10..<10), "- [x] done\n- [ ] ", 17..<17, "Enter 接未勾的勾選框")
        c.edit(E.enterContinuesList("1. [ ] a", selection: 8..<8), "1. [ ] a\n2. [ ] ", 16..<16, "Enter 編號勾選框")
        c.edit(E.enterContinuesList("  - nested", selection: 10..<10), "  - nested\n  - ", 15..<15, "Enter 保留縮排")
        c.edit(E.enterContinuesList("> - q", selection: 5..<5), "> - q\n> - ", 10..<10, "Enter 引用內清單")
        c.edit(E.enterContinuesList("- ab", selection: 3..<3), "- a\n- b", 6..<6, "Enter 在項目中間拆兩項")
        c.edit(E.enterContinuesList("- ", selection: 2..<2), "", 0..<0, "空項再 Enter 刪前綴")
        c.edit(E.enterContinuesList("a\n- ", selection: 4..<4), "a\n", 2..<2, "空項(第二行)刪前綴")
        c.edit(E.enterContinuesList("- [ ] ", selection: 6..<6), "", 0..<0, "空勾選框項刪前綴")
        c.expect(E.enterContinuesList("plain", selection: 5..<5) == nil, "非清單 ⇒ nil")
        c.expect(E.enterContinuesList("- a", selection: 1..<1) == nil, "游標在前綴裡 ⇒ nil")
        c.expect(E.enterContinuesList("- abc", selection: 2..<4) == nil, "有選取 ⇒ nil")
        c.expect(E.enterContinuesList("# h", selection: 3..<3) == nil, "標題不接續")
        // Tab／⇧Tab
        c.edit(E.indent("- a", selection: 3..<3), "  - a", 5..<5, "Tab 縮排")
        c.edit(E.outdent("  - a", selection: 5..<5), "- a", 3..<3, "⇧Tab 退縮")
        c.edit(E.indent("a\nb", selection: 0..<3), "  a\n  b", 0..<7, "多行縮排")
        c.edit(E.outdent("   x", selection: 0..<0), " x", 0..<0, "退縮最多兩格")
        c.edit(E.outdent("\tx", selection: 2..<2), "x", 1..<1, "退縮 tab")
        c.edit(E.outdent("x", selection: 1..<1), "x", 1..<1, "沒縮排不動")
        // ⌘⏎／預覽點勾選框
        c.edit(E.toggleCheckbox("- [ ] a", atLine: 0), "- [x] a", 0..<0, "勾")
        c.edit(E.toggleCheckbox("- [x] a", atLine: 0), "- [ ] a", 0..<0, "取消勾")
        c.edit(E.toggleCheckbox("- [X] a", atLine: 0), "- [ ] a", 0..<0, "大寫 X 也算勾")
        c.edit(E.toggleCheckbox("x\n- [ ] b", atLine: 1, selection: 1..<1), "x\n- [x] b", 1..<1, "指定行、選取不動")
        c.edit(E.toggleCheckbox("1. [ ] n", atLine: 0), "1. [x] n", 0..<0, "編號勾選框")
        c.edit(E.toggleCheckbox("  - [ ] sub", atLine: 0), "  - [x] sub", 0..<0, "巢狀勾選框")
        c.edit(E.toggleCheckbox("- a", selection: 3..<3), "- [ ] a", 7..<7, "⌘⏎ 清單項補勾選框")
        c.edit(E.toggleCheckbox("plain", selection: 0..<0), "- [ ] plain", 6..<6, "⌘⏎ 一般文字變勾選框")
        c.edit(E.toggleCheckbox("x", atLine: 3), "x", 0..<0, "行號越界原樣")
        // 預覽點勾選框寫回:用解析出的行號
        let doc = "# T\n- [ ] a\n  - [ ] b\n"
        if case .list(_, let items)? = MarkdownBlocks.parse(doc).last, items.count == 2 {
            c.edit(E.toggleCheckbox(doc, atLine: items[1].line), "# T\n- [ ] a\n  - [x] b\n", 0..<0, "預覽點巢狀勾選框寫回")
        } else { c.expect(false, "預覽解析清單失敗") }
        // 自動成對
        c.edit(E.autoPair("", selection: 0..<0, typed: "["), "[]", 1..<1, "[ 成對")
        c.edit(E.autoPair("ab", selection: 0..<2, typed: "["), "[ab]", 1..<3, "[ 包住選取")
        c.edit(E.autoPair("", selection: 0..<0, typed: "`"), "``", 1..<1, "` 成對")
        c.edit(E.autoPair("``", selection: 1..<1, typed: "`"), "``", 2..<2, "` 跳過收尾")
        c.edit(E.autoPair("a]", selection: 1..<1, typed: "]"), "a]", 2..<2, "] 跳過收尾")
        c.edit(E.autoPair("*", selection: 1..<1, typed: "*"), "****", 2..<2, "** 補收尾")
        c.edit(E.autoPair("**", selection: 1..<1, typed: "*"), "**", 2..<2, "* 跳過收尾")
        c.expect(E.autoPair("**", selection: 2..<2, typed: "*") == nil, "*** 不再補")
        c.expect(E.autoPair("x", selection: 1..<1, typed: "a") == nil, "一般字 ⇒ nil")
        c.expect(E.autoPair("x", selection: 1..<1, typed: "*") == nil, "單一 * ⇒ nil")
        // 貼上網址自動成連結
        c.edit(E.linkifyPastedURL("see ", selection: 4..<4, pasted: "https://a.com\n"), "see <https://a.com>", 19..<19, "貼網址無選取 ⇒ <網址>")
        c.edit(E.linkifyPastedURL("click here", selection: 6..<10, pasted: "https://a.com"), "click [here](https://a.com)", 27..<27, "貼網址有選取 ⇒ [選取](網址)")
        c.expect(E.linkifyPastedURL("x", selection: 1..<1, pasted: "not a url") == nil, "非網址 ⇒ nil")
        c.expect(E.linkifyPastedURL("[a](", selection: 4..<4, pasted: "https://a.com") == nil, "手打連結中 ⇒ nil")
        c.expect(E.linkifyPastedURL("https://old.com", selection: 0..<15, pasted: "https://a.com") == nil, "選取本身是網址 ⇒ nil")
        c.expect(E.isLikelyURL("https://a.com/x?y=1") && E.isLikelyURL("http://localhost:8080"), "網址判定(正)")
        c.expect(!E.isLikelyURL("ftp://a.com") && !E.isLikelyURL("http://") && !E.isLikelyURL("a b") && !E.isLikelyURL(""), "網址判定(負)")
        return c.result("NOTE-04 Markdown 編輯行為")
    }

    // MARK: - NOTE-05 高亮範圍

    static func markdownHighlightRanges() -> Result {
        var c = Checks()
        typealias S = MarkdownHighlight.Span
        func hl(_ text: String, _ want: [S], _ label: String) {
            let got = MarkdownHighlight.spans(in: text)
            c.expect(got == want, "\(label):得 \(got.map { "\($0.kind)\($0.range)" })")
            c.expect(invariant(text, got), "\(label):越界或重疊")
        }
        func invariant(_ text: String, _ s: [S]) -> Bool {
            let n = (text as NSString).length
            guard s.allSatisfy({ $0.range.lowerBound >= 0 && $0.range.upperBound <= n && !$0.range.isEmpty }) else { return false }
            return zip(s, s.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound }
        }
        hl("# Title", [S(0..<7, .heading)], "1 標題整行")
        hl("## **Bold** in heading", [S(0..<22, .heading)], "2 標題內粗體以外層為準")
        hl("- item", [S(0..<1, .listMarker)], "3 項目符號")
        hl("- [ ] task", [S(0..<1, .listMarker), S(2..<5, .checkbox)], "4 勾選框")
        hl("  1. [x] nested", [S(2..<4, .listMarker), S(5..<8, .checkbox)], "5 巢狀編號勾選框")
        hl("> quote **b**", [S(0..<2, .quote), S(8..<13, .bold)], "6 引用內粗體")
        hl("```swift\nlet **x** = 1\n```\nafter **y**", [S(0..<26, .code), S(33..<38, .bold)], "7 圍欄整塊,塊內不切")
        hl("a `**x**` b", [S(2..<9, .code)], "8 程式碼內粗體以外層為準")
        hl("**[link](u)** and [**b**](v)", [S(0..<13, .bold), S(18..<28, .link)], "9 粗體包連結／連結包粗體")
        hl("⚑ 00:12:34 討論預算", [S(0..<10, .timestamp)], "10 時間戳")
        hl("會議😀 **重點** see <https://x.io>", [S(5..<11, .bold), S(16..<30, .link)], "11 中英混排＋emoji(UTF-16)")
        hl("---\n* * *", [], "12 分隔線不是清單符號")
        hl("```\ncode **x**", [S(0..<14, .code)], "13 未關圍欄延伸到文末")
        hl("**a [b** c](u)", [S(0..<8, .bold)], "14 交叉時先開始的贏")
        hl("# A\r\n- b", [S(0..<3, .heading), S(5..<6, .listMarker)], "15 CRLF")
        hl("> # H", [S(0..<2, .quote), S(2..<5, .heading)], "16 引用內標題")
        hl("- [ ]x", [S(0..<1, .listMarker)], "17 [ ] 後沒空白不是勾選框")
        hl("> - [x] 完成 ⚑ 00:01:02", [S(0..<2, .quote), S(2..<3, .listMarker), S(4..<7, .checkbox), S(11..<21, .timestamp)], "18 引用＋清單＋勾選＋行中時間戳")
        // 大雜燴:只驗不越界、不重疊、有排序
        let big = "# 週會\n\n- [ ] **寄合約** 給 [ABC](https://a.b)\n  1. `code` ⚑ 00:00:05\n> 對方 00:13:02：報價 **低**\n```\n| a | b |\n```\n| x | y |\n|---|---|\n😀**混**English`c`"
        let s = MarkdownHighlight.spans(in: big)
        c.expect(invariant(big, s) && s.count >= 10, "19 大雜燴 invariant(\(s.count) 段)")
        c.expect(MarkdownHighlight.ranges(in: "# x").first.map { $0.range == 0..<3 && $0.kind == .heading } == true, "ranges 簽章轉接")
        c.expect(MarkdownHighlight.spans(in: "").isEmpty, "空字串")
        return c.result("NOTE-05 語法高亮範圍")
    }

    // MARK: - NOTE-06 區塊解析

    static func markdownBlocksParse() -> Result {
        var c = Checks()
        typealias B = MarkdownBlocks.Block
        typealias I = MarkdownBlocks.ListItem
        func p(_ text: String, _ want: [B], _ label: String) {
            let got = MarkdownBlocks.parse(text)
            c.expect(got == want, "\(label):得 \(got)")
        }
        p("# H1\n## H2\n###### H6", [.heading(level: 1, text: "H1"), .heading(level: 2, text: "H2"), .heading(level: 6, text: "H6")], "1 ATX 標題")
        p("## T ##\n#", [.heading(level: 2, text: "T"), .heading(level: 1, text: "")], "2 收尾井號與空標題")
        p("Title\n===\nSub\n---", [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub")], "3 setext 標題")
        p("line 1\nline 2\n\nnext", [.paragraph("line 1\nline 2"), .paragraph("next")], "4 段落")
        p("- a\n  - b\n    - c\n- d", [.list(ordered: false, items: [
            I(indent: 0, checked: nil, text: "a", line: 0), I(indent: 1, checked: nil, text: "b", line: 1),
            I(indent: 2, checked: nil, text: "c", line: 2), I(indent: 0, checked: nil, text: "d", line: 3)])], "5 巢狀清單")
        p("1. x\n2) y", [.list(ordered: true, items: [
            I(indent: 0, checked: nil, text: "x", ordered: true, number: 1, line: 0),
            I(indent: 0, checked: nil, text: "y", ordered: true, number: 2, line: 1)])], "6 編號清單")
        p("- [ ] t\n- [x] u\n- [X] v\n- [ ]", [.list(ordered: false, items: [
            I(indent: 0, checked: false, text: "t", line: 0), I(indent: 0, checked: true, text: "u", line: 1),
            I(indent: 0, checked: true, text: "v", line: 2), I(indent: 0, checked: false, text: "", line: 3)])], "7 勾選框")
        p("> a\n> b\n\nc", [.quote("a\nb"), .paragraph("c")], "8 引用")
        p("```swift\nlet a = 1\n\nlet b\n```\nafter", [.code(lang: "swift", lines: ["let a = 1", "", "let b"]), .paragraph("after")], "9 圍欄程式碼")
        p("~~~\nx\n", [.code(lang: nil, lines: ["x", ""])], "10 未關圍欄到文末")
        p("| A | B |\n|---|:-:|\n| 1 | 2 |\n| 3 |\n| 4 | 5 | 6 |", [.table(header: ["A", "B"], rows: [["1", "2"], ["3", ""], ["4", "5"]])], "11 表格(補齊/截斷)")
        p("| a \\| b | c |\n| - | - |", [.table(header: ["a | b", "c"], rows: [])], "12 表格跳脫直線")
        p("a | b\nc | d", [.paragraph("a | b\nc | d")], "13 沒分隔列不是表格")
        p("***\n\n- - -\n\n___", [.hr, .hr, .hr], "14 分隔線三種")
        p("⚑ 00:12:34 討論\n⚑ 1:02:03\n⚑ 00:00:01text", [.timestamp(h: 0, m: 12, s: 34, rest: "討論"), .timestamp(h: 1, m: 2, s: 3, rest: ""),
                                                         .paragraph("⚑ 00:00:01text")], "15 時間戳列")
        p("see [a](https://x) **b**", [.paragraph("see [a](https://x) **b**")], "16 行內留給 App")
        p("- a\n1. b", [.list(ordered: false, items: [I(indent: 0, checked: nil, text: "a", line: 0)]),
                       .list(ordered: true, items: [I(indent: 0, checked: nil, text: "b", ordered: true, number: 1, line: 1)])], "17 換種類另起清單")
        p("- a\n\n- b", [.list(ordered: false, items: [I(indent: 0, checked: nil, text: "a", line: 0), I(indent: 0, checked: nil, text: "b", line: 2)])], "18 鬆散清單")
        p("- a\n  more\nnext", [.list(ordered: false, items: [I(indent: 0, checked: nil, text: "a\nmore", line: 0)]), .paragraph("next")], "19 縮排續行")
        p("# 週會\n⚑ 00:00:05 開始\n> 對方 00:13:02：報價\n- [ ] 寄合約", [
            .heading(level: 1, text: "週會"), .timestamp(h: 0, m: 0, s: 5, rest: "開始"), .quote("對方 00:13:02：報價"),
            .list(ordered: false, items: [I(indent: 0, checked: false, text: "寄合約", line: 3)])], "20 筆記典型內容")
        p("para\n# H\n- x", [.paragraph("para"), .heading(level: 1, text: "H"),
                            .list(ordered: false, items: [I(indent: 0, checked: nil, text: "x", line: 2)])], "21 標題/清單打斷段落")
        p("\tx\n- a\n\t- b", [.paragraph("x"), .list(ordered: false, items: [
            I(indent: 0, checked: nil, text: "a", line: 1), I(indent: 2, checked: nil, text: "b", line: 2)])], "22 tab 算 4 格")
        p("", [], "23 空文件")
        p("a\r\n\r\nb", [.paragraph("a"), .paragraph("b")], "24 CRLF")
        return c.result("NOTE-06 Markdown 區塊解析")
    }

    // MARK: - UI-53 sidecar 改名

    static func sidecarRenamePlan() -> Result {
        let name = "UI-53 sidecar 改名計畫＋真改名＋回滾"
        var c = Checks()
        let fm = FileManager.default
        c.expect(SidecarSet.extensions == ["caf", "m4a", "txt", "srt", "json", "notes.md", "minutes.md", "minutes.json", "zh-Hant.srt", "corrections.json", "live.srt", "en.srt", "ja.srt", "ko.srt", "zh-Hans.srt", "es.srt", "de.srt", "fr.srt", "pt-BR.srt", "tokens.json"], "extensions 清單")   // MAS-28 D2 四語譯文檔
        c.expect(Recording.derivedExtensions == SidecarSet.extensions, "derivedExtensions 轉呼叫")
        c.expect(SidecarSet.url(stem: URL(fileURLWithPath: "/t/a.b"), ext: "zh-Hant.srt").path == "/t/a.b.zh-Hant.srt", "url(stem:ext:) 含點")
        let sp = SidecarSet.splitName("2026-10-19 1930 Weekly sync")
        c.expect(sp.prefix == "2026-10-19 1930 " && sp.title == "Weekly sync", "splitName 前綴")
        c.expect(SidecarSet.splitName("legacy").prefix == nil && SidecarSet.splitName("legacy").title == "legacy", "splitName 無前綴")
        guard let dir = try? scratchDir("ui53") else { return Result(name: name, passed: false, detail: "建不出暫存夾") }
        defer { try? fm.removeItem(at: dir) }
        do {
            let stem = dir.appendingPathComponent("2026-10-19 1930 Weekly sync")
            let contents = ["m4a": "AUDIO", "txt": "你: hi", "srt": "1\n00:00:00,000 --> 00:00:01,000\nhi\n", "notes.md": "# Weekly sync\n"]
            for (ext, body) in contents { try write(body, SidecarSet.url(stem: stem, ext: ext)) }
            c.expect(SidecarSet.existing(stem: stem).map(\.lastPathComponent) == ["m4a", "txt", "srt", "notes.md"].map { "2026-10-19 1930 Weekly sync.\($0)" }, "existing 依 extensions 順序")
            func fail(_ r: Swift.Result<[SidecarSet.Move], SidecarError>) -> SidecarError? { if case .failure(let e) = r { return e }; return nil }
            c.expect(fail(SidecarSet.renamePlan(stem: stem, newTitle: "")) == .invalidTitle, "空標題拒絕")
            c.expect(fail(SidecarSet.renamePlan(stem: stem, newTitle: "  ..  ")) == .invalidTitle, "清理後空拒絕")
            c.expect(fail(SidecarSet.renamePlan(stem: stem, newTitle: "\u{0}\t")) == .invalidTitle, "控制字元清完空拒絕")
            c.expect(fail(SidecarSet.renamePlan(stem: stem, newTitle: "Weekly sync")) == .unchanged, "同名 ⇒ unchanged")
            c.expect(fail(SidecarSet.renamePlan(stem: stem, newTitle: " Weekly sync. ")) == .unchanged, "清理後同名 ⇒ unchanged")
            c.expect(fail(SidecarSet.renamePlan(stem: dir.appendingPathComponent("nothing"), newTitle: "x")) == .notFound, "沒檔 ⇒ notFound")
            // 衝突:目標 stem 只有 minutes.md(本場沒有這種檔)也算
            try write("other", dir.appendingPathComponent("2026-10-19 1930 Taken.minutes.md"))
            c.expect(fail(SidecarSet.renamePlan(stem: stem, newTitle: "Taken")) == .conflict(["2026-10-19 1930 Taken.minutes.md"]), "任一衍生檔已存在 ⇒ conflict")
            // 正常:前綴不動、標題清理、四檔一起
            guard case .success(let plan) = SidecarSet.renamePlan(stem: stem, newTitle: "Client/ABC: kickoff") else {
                c.expect(false, "正常改名應成功"); return c.result(name)
            }
            let want = ["m4a", "txt", "srt", "notes.md"].map { "2026-10-19 1930 Client-ABC- kickoff.\($0)" }
            c.expect(plan.map(\.to.lastPathComponent) == want, "改名目標 \(plan.map(\.to.lastPathComponent))")
            c.expect(plan.map(\.from) == SidecarSet.existing(stem: stem), "改名來源＝existing")
            try SidecarSet.performRename(plan)
            for (ext, body) in contents {
                let newURL = SidecarSet.url(stem: dir.appendingPathComponent("2026-10-19 1930 Client-ABC- kickoff"), ext: ext)
                c.expect(read(newURL) == body, "真改名後 \(ext) 內容")
                c.expect(!fm.fileExists(atPath: SidecarSet.url(stem: stem, ext: ext).path), "舊 \(ext) 應不在")
            }
            c.expect(read(dir.appendingPathComponent("2026-10-19 1930 Taken.minutes.md")) == "other", "無關檔不受影響")
            // 無前綴的舊檔:整個名字換掉
            try write("L", dir.appendingPathComponent("legacy.m4a"))
            if case .success(let lp) = SidecarSet.renamePlan(stem: dir.appendingPathComponent("legacy"), newTitle: "New name") {
                c.expect(lp.map(\.to.lastPathComponent) == ["New name.m4a"], "無前綴 ⇒ 整個換")
            } else { c.expect(false, "無前綴改名應成功") }
            // 只差大小寫:不算衝突,真改得動
            let lower = dir.appendingPathComponent("2026-10-19 2000 abc")
            try write("A", SidecarSet.url(stem: lower, ext: "m4a"))
            try write("T", SidecarSet.url(stem: lower, ext: "txt"))
            if case .success(let cp) = SidecarSet.renamePlan(stem: lower, newTitle: "ABC") {
                try SidecarSet.performRename(cp)
                c.expect(names(dir).contains("2026-10-19 2000 ABC.m4a") && names(dir).contains("2026-10-19 2000 ABC.txt")
                         && !names(dir).contains("2026-10-19 2000 abc.m4a"), "大小寫改名 \(names(dir))")
            } else { c.expect(false, "只差大小寫不應被當衝突") }
            // 回滾:計畫做好後,第二個檔的目標被別人占住 ⇒ 第一個檔要移回來、占位檔不被蓋
            let s2 = dir.appendingPathComponent("2026-10-19 2100 Roll")
            for ext in ["m4a", "txt", "srt"] { try write("R-\(ext)", SidecarSet.url(stem: s2, ext: ext)) }
            guard case .success(let rp) = SidecarSet.renamePlan(stem: s2, newTitle: "Rolled") else {
                c.expect(false, "回滾案計畫應成功"); return c.result(name)
            }
            let s2new = dir.appendingPathComponent("2026-10-19 2100 Rolled")
            try write("occupant", SidecarSet.url(stem: s2new, ext: "txt"))
            var threw: SidecarError?
            do { try SidecarSet.performRename(rp) } catch let e as SidecarError { threw = e } catch { threw = .ioFailed("\(error)") }
            if case .ioFailed(let msg)? = threw { c.expect(msg.contains("rollback ok"), "回滾訊息應說 rollback ok:\(msg)") }
            else { c.expect(false, "占位後 performRename 應丟 ioFailed,得 \(String(describing: threw))") }
            c.expect(read(SidecarSet.url(stem: s2, ext: "m4a")) == "R-m4a", "第一個檔應已移回原名")
            c.expect(!fm.fileExists(atPath: SidecarSet.url(stem: s2new, ext: "m4a").path), "第一個檔不應留在新名")
            c.expect(read(SidecarSet.url(stem: s2new, ext: "txt")) == "occupant", "占位檔不可被覆蓋")
            c.expect(read(SidecarSet.url(stem: s2, ext: "txt")) == "R-txt" && read(SidecarSet.url(stem: s2, ext: "srt")) == "R-srt", "其他檔原地不動")
            // uniqueFileName 也探 notes.md(只剩筆記也算佔用)
            var dc = DateComponents(); dc.year = 2026; dc.month = 8; dc.day = 23; dc.hour = 16; dc.minute = 55
            let date = Calendar.current.date(from: dc)!
            let base = Recording.fileName(date: date, title: "X")
            try write("n", dir.appendingPathComponent(String(base.dropLast(4)) + ".notes.md"))
            c.expect(Recording.uniqueFileName(date: date, title: "X", in: dir) == String(base.dropLast(4)) + " 2.caf", "只有 notes.md 也算佔用")
            c.expect(!names(dir).contains { $0.contains(".tmp-") }, "不應有 tmp 殘留")
        } catch {
            c.expect(false, "例外:\(error)")
        }
        return c.result(name)
    }

    // MARK: - UI-54 垃圾桶＋鎖

    static func sidecarTrashAndLock() -> Result {
        let name = "UI-54 移到垃圾桶＋錄音中/轉稿中鎖"
        var c = Checks()
        let fm = FileManager.default
        // 鎖(純函式)
        let a = URL(fileURLWithPath: "/r/2026-10-19 1930 A"), b = URL(fileURLWithPath: "/r/2026-10-19 1931 B")
        c.expect(SidecarSet.isLocked(stem: a, recordingStem: a, transcribingStem: nil, queuedStems: []), "錄音中那場鎖")
        c.expect(SidecarSet.isLocked(stem: a, recordingStem: nil, transcribingStem: a, queuedStems: []), "轉稿中鎖")
        c.expect(SidecarSet.isLocked(stem: a, recordingStem: nil, transcribingStem: b, queuedStems: [b, a]), "排隊中鎖")
        c.expect(SidecarSet.isLocked(stem: a, recordingStem: nil, transcribingStem: nil, queuedStems: [], convertingStems: [a]), "轉檔中鎖")
        c.expect(!SidecarSet.isLocked(stem: a, recordingStem: b, transcribingStem: b, queuedStems: [b], convertingStems: [b]), "別場忙不影響")
        c.expect(!SidecarSet.isLocked(stem: a, recordingStem: nil, transcribingStem: nil, queuedStems: []), "全閒不鎖")
        c.expect(SidecarSet.isLocked(stem: URL(fileURLWithPath: "/r/./x/../2026-10-19 1930 A"), recordingStem: a, transcribingStem: nil, queuedStems: []), "路徑正規化後比對")
        // 垃圾桶:只動自建暫存夾裡、名字帶本次 UUID 的檔;驗完只刪垃圾桶裡那幾個副本
        guard let dir = try? scratchDir("ui54") else { return Result(name: name, passed: false, detail: "建不出暫存夾") }
        defer { try? fm.removeItem(at: dir) }
        let tag = "mp-selftest-trash-\(UUID().uuidString)"
        let stem = dir.appendingPathComponent(tag)
        do {
            for ext in ["m4a", "txt", "notes.md"] { try write("T-\(ext)", SidecarSet.url(stem: stem, ext: ext)) }
            try write("keep", dir.appendingPathComponent("\(tag)-other.m4a"))   // 名字相近但不同 stem
            let plan = SidecarSet.trashPlan(stem: stem)
            c.expect(plan.map(\.lastPathComponent) == ["m4a", "txt", "notes.md"].map { "\(tag).\($0)" }, "trashPlan 清單 \(plan.map(\.lastPathComponent))")
            let trashed = try SidecarSet.performTrash(plan)
            c.expect(trashed.count == 3, "回傳 3 個垃圾桶 URL")
            for (orig, t) in zip(plan, trashed) {
                c.expect(fm.fileExists(atPath: t.path), "垃圾桶裡應有 \(t.lastPathComponent)")
                c.expect(!fm.fileExists(atPath: orig.path), "原位應已不在 \(orig.lastPathComponent)")
                c.expect(t.path.contains("/.Trash") || t.path.contains("/.Trashes"), "應在垃圾桶:\(t.path)")
            }
            c.expect(read(dir.appendingPathComponent("\(tag)-other.m4a")) == "keep", "相近名字的別場不受影響")
            // 只清掉自己剛丟進去的副本(名字必含本次 UUID)
            for t in trashed where t.lastPathComponent.hasPrefix(tag) { try? fm.removeItem(at: t) }
            c.expect(trashed.allSatisfy { !fm.fileExists(atPath: $0.path) }, "測試副本已從垃圾桶清掉")
            // 回滾:清單第二個不存在 ⇒ 第一個從垃圾桶移回原位
            let r1 = dir.appendingPathComponent("\(tag)-r.m4a")
            try write("R", r1)
            var threw = false
            do { try SidecarSet.performTrash([r1, dir.appendingPathComponent("\(tag)-missing.txt")]) } catch { threw = true }
            c.expect(threw, "第二個失敗應丟錯")
            c.expect(read(r1) == "R", "第一個應從垃圾桶移回原位")
            c.expect(SidecarSet.trashPlan(stem: dir.appendingPathComponent("nothing")).isEmpty, "沒檔 ⇒ 空清單")
        } catch {
            c.expect(false, "例外:\(error)")
        }
        return c.result(name)
    }
}

/// 手動時鐘排程器(SelfTest 用):`advance(by:)` 推進虛擬時間並依序觸發到期的動作。
@MainActor
final class ManualNotesScheduler: NotesSaveScheduling {
    private(set) var now: Date
    private var queue: [(id: Int, at: Date, action: @MainActor () -> Void, token: Token)] = []
    private var nextID = 0

    final class Token: NotesScheduledTask {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    init(start: Date = Date(timeIntervalSinceReferenceDate: 0)) { now = start }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any NotesScheduledTask {
        let t = Token()
        queue.append((nextID, now.addingTimeInterval(max(0, delay)), action, t))
        nextID += 1
        return t
    }

    var pendingCount: Int { queue.filter { !$0.token.cancelled }.count }

    func advance(by dt: TimeInterval) {
        let end = now.addingTimeInterval(dt)
        let due = end.addingTimeInterval(1e-9)   // 浮點誤差:剛好到期的要算到
        while let next = queue.filter({ !$0.token.cancelled && $0.at <= due })
            .min(by: { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }) {
            now = max(now, next.at)
            queue.removeAll { $0.id == next.id }
            next.action()
        }
        queue.removeAll { $0.token.cancelled }
        now = max(now, end)
    }
}
