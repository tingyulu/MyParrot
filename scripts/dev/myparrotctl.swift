// #2412 驗證用:送指令給 DEBUG 建置的 MyParrot(見 Sources/MyParrot/Debug/DebugControl.swift)。
// 編譯:swiftc -O scripts/dev/myparrotctl.swift -o /tmp/myparrotctl
// 用法:myparrotctl <指令> [參數…] <結果檔>        結果檔必須是絕對路徑、在 /tmp 或家目錄底下
//   myparrotctl state /tmp/s.json                 讀狀態 JSON
//   myparrotctl record /tmp/r.json ; myparrotctl pause … ; resume … ; stop … ; new …
//   myparrotctl title 週會 /tmp/r.json
//   myparrotctl transcribe latest /tmp/r.json     轉最新一筆(或給索引 0..n)
//   myparrotctl load-transcript 0 /tmp/r.json     把第 0 筆的 .srt 讀回畫面
//   myparrotctl check-transcript /tmp/r.json      跑校正(結果含建議 id)
//   myparrotctl correction accept <id> /tmp/r.json   accept|ignore|revert
//   myparrotctl corrections ignore-all /tmp/r.json
//   myparrotctl correction focus <id> /tmp/r.json    UI-60:選中該則(列內展開原句、逐字稿捲到該段並高亮;state 帶 focusedSuggestion/fullTranscript)
//   myparrotctl backend localFake /tmp/r.json     off|claudeCLI|localFake(舊指令,只管校正;同 model set correction)
//   #2438 M6 模型(MDL-05;state 也帶 "model":{correction,minutes,translation}、"modelPending"、"minutesEnabled"):
//   myparrotctl model list /tmp/r.json              每個能力:可選後端 id、出機後端、目前選的；privacyAccepted
//   myparrotctl model get minutes /tmp/r.json       correction|minutes|translation
//   myparrotctl model set minutes localFake /tmp/r.json   直接寫(ModelBackendRegistry.select),不跳隱私框;use 同義
//   myparrotctl model request correction claudeCLI /tmp/r.json   走設定頁 picker 同一條路:出機後端沒同意過 ⇒ 掛起等確認框
//   myparrotctl model privacy accept|cancel /tmp/r.json   回答掛起中的確認框(同設定頁「開啟」／「取消」)
//   myparrotctl appearance light|dark|system /tmp/r.json  App 內覆寫外觀(UI-55 截圖;不寫偏好),system＝還原
//   myparrotctl appearance set light|dark|system /tmp/r.json ; appearance get /tmp/r.json   UI-56:寫偏好 appearanceMode 並套用／讀回
//   myparrotctl model-hint status|reset|show|open|later /tmp/r.json   UI-57 首次模型提示(reset＝下次啟動再跳;open/later＝按兩顆鈕)
//   #2646 商店版(沙盒;結果檔要放在 app 寫得到的地方,例如已選的錄音夾底下):
//   myparrotctl folder-prompt status|show|later|revalidate <錄音夾>/_ctl/r.json   MAS-06/07 選錄音夾提示與書籤重探(state 也帶 recordingsFolder、sandbox)
//   myparrotctl sandbox-probe /Users/<你>/Documents/x <錄音夾>/_ctl/r.json      MAS-03 試寫真路徑(沙盒 wrote=false;GitHub 版正控 true)
//   myparrotctl whisper list|download <id>|delete <id>|verify <id> <結果檔>   MAS-11/12/13 模型進容器＋SHA-256(download 結束才寫結果,1 GB 要等)
//   myparrotctl engine get|set appleNative|whisperKit <結果檔>              切逐字稿引擎(同設定頁)
//   myparrotctl prefs <結果檔>                                            印自己網域的偏好鍵(Data 只印長度)
//   myparrotctl consent status|reset|show|accept|cancel <結果檔>         MAS-17 一次性錄音提示(show＝走真提示;state 也帶 consent、indicator)
//   myparrotctl legal <結果檔>                                            MAS-16 連結與第三方授權全文是否在 bundle
//   myparrotctl onboarding status|reset|show|download|later <結果檔>     MAS-31 首啟模型下載卡片(download＝按「下載建議模型」)
//   myparrotctl scope-probe <結果檔>                                      MAS-33 書籤 URL vs 重建 URL 的 startAccessing(沙盒 true/false)
//   myparrotctl transcribe-policy get|set <immediately|whenIdle|never> /tmp/r.json ; transcribe-idle status|force /tmp/r.json   #2483 E:重轉時機、待閒置重轉(force＝忽略閒置條件立刻重轉一筆)
//   myparrotctl afm status|force <deviceNotEligible|appleIntelligenceNotEnabled|modelNotReady|unknown|unsupported>|clear /tmp/r.json   #2438 Phase 3a:Apple 本機模型可用性(force＝DEBUG 覆寫,校正與會議記錄都看得到;state 也回 afm)
//   myparrotctl settings open /tmp/r.json ; window mini /tmp/r.json ; dismiss-warning /tmp/r.json
//   myparrotctl mic list /tmp/r.json ; mic select <index|名稱片段> /tmp/r.json   AUD-38 切麥(錄音中＝熱切換;state 也帶 isSwitchingMic、mic)
//   myparrotctl snapshot /tmp/shot.png [light|dark] [main|settings|mini]   圖＝結果;另有 shot.png.json
//   myparrotctl window-shot /tmp/win.png [main|sheet|alert]   真視窗截圖(自截,不需螢幕錄製權限;#2438);另有 win.png.json
//                                                  sheet＝設定頁(snapshot settings 畫不出 Form)、alert＝設定頁上的確認框
//   myparrotctl settings scroll 0.5 /tmp/r.json     設定頁捲到 0～1 的位置(先 settings open)
//   #2438 M5 筆記／檔案／會議記錄:
//   myparrotctl notes get|path|flush /tmp/r.json ; notes set "# 標題\n- 一" /tmp/r.json ; notes append "..." /tmp/r.json
//   myparrotctl notes mark /tmp/r.json(錄音中:插 ⚑ h:mm:ss)   ; notes quote 0 /tmp/r.json(引用第 0 行逐字稿)
//   myparrotctl files search 週會 /tmp/r.json ; files select 0 /tmp/r.json ; files locked 0 /tmp/r.json
//   myparrotctl files rename 0 新標題 /tmp/r.json ; files trash 0 /tmp/r.json(真丟垃圾桶,只對示範夾用)
//   myparrotctl minutes status|update /tmp/r.json ; minutes cadence 2 /tmp/r.json ; minutes auto on|off /tmp/r.json
//   #2623 每場模型用量(TOK-06;state 也帶 "tokens"):
//   myparrotctl tokens status /tmp/r.json ; tokens inject correction|minutes|translation <backend> <in> <out> /tmp/r.json(要先 files select 一場)
//   #2612 翻譯(TRL-13;state 也帶 "translation"):
//   myparrotctl translation status|update|whole|retry /tmp/r.json ; translation target zh-Hant|en|ja|ko|zh-Hans /tmp/r.json
//   myparrotctl translation live on|off /tmp/r.json      把畫面上的稿當錄音中來源起/停自動翻譯 loop(驗節奏與排隊,不必真錄音)
//   myparrotctl translation cadence 30|60|120|300 /tmp/r.json ; translation show on|off /tmp/r.json
//   myparrotctl translation availability force installed|supported|unsupported /tmp/r.json ; translation availability clear /tmp/r.json
//   #2438 M4 面板工作區(UI-45～48;結果含 panes JSON、visibleColumns、windowFrame、screenVisibleFrame):
//   myparrotctl panes /tmp/r.json                   讀面板狀態(state 也帶 "panes"／"windowFrame")
//   myparrotctl pane notes on /tmp/r.json           transcript|notes|minutes|files  on|off(files＝檔案列表展開)
//   myparrotctl pane order notes,transcript,minutes /tmp/r.json   設內容欄順序
//   myparrotctl pane width notes 1500 /tmp/r.json   設欄寬(同欄間把手放開;下限 320),寬螢幕上逼出壓縮路徑
//   myparrotctl dock right /tmp/r.json              控制欄靠左|右(K1)
//   myparrotctl quit /tmp/r.json
//   #2407 會議提醒(CAL-14):
//   myparrotctl calendar status|reload /tmp/r.json ; calendar enable|disable /tmp/r.json(enable 第一次會跳權限詢問)
//   myparrotctl calendar calendars all /tmp/r.json ; calendar keywords "面談,測試" /tmp/r.json ; calendar lead 2 /tmp/r.json
//   myparrotctl calendar inject "測試面談" 2026-10-17T08:00:00Z 2026-10-17T09:00:00Z /tmp/r.json   假事件只進記憶體
//   myparrotctl calendar fire <key> /tmp/r.json      等同時間到了(仍過去重)
//   myparrotctl notify status|request /tmp/r.json ; notify action start [標題] /tmp/r.json ; notify action stop /tmp/r.json
//   myparrotctl alarms dead 10 /tmp/r.json ; alarms silence 20 /tmp/r.json   把 3 分鐘/30 分鐘改短驗證
//   #949 第一段(唯一 writer;state 也帶 "lease"、"externalRecording"、"windowVisible"、"recordingsDetail"):
//   myparrotctl lease status /tmp/r.json            租約檔內容＋locked(alive=true/dead=false)＋inspection＋holdsLease
//   myparrotctl lease break /tmp/r.json             測試用:刪租約檔(只准示範夾＋MYPARROT_CONFIG_DIR 覆寫時)
//   myparrotctl external status /tmp/r.json         CLI(別的進程)在錄的那一場:owner/name/elapsed/paused/unresponsive;沒有＝null
//   myparrotctl external stop|pause|resume /tmp/r.json   ＝橫幅的鈕(requestExternal*:新版寫 commands/、舊版 CLI 只能 SIGINT 停)
//   🔴 通知是廣播:機上有別的 DEBUG 建置在跑(~/Applications 版預設也是 debug 組態)時,沒設頻道的 quit/state 會打到它。
//   驗證實例與 myparrotctl 都帶 MYPARROT_DEBUG_CHANNEL=<名字>(2026-10-20 #949 實踩:quit 把 Eric 的 app 一起關了)。
//   GUI 驗證啟動(🚫 真錄音資料夾):MYPARROT_DEBUG_CHANNEL=x MYPARROT_CONFIG_DIR=<scratch>/cfg .build/debug/MyParrot -recordingsDir <scratch>/rec \
//       -debugSkipPermissionRequest YES -modelHintShown YES [-backgroundStart]   (探針實測:-backgroundStart 不帶值也不會把下一個
//       -recordingsDir 吃掉;argument domain 遇到下一個 -key 不配對。-modelHintShown YES 免得首次說明框擋住 quit)
//       再加 CFFIXED_USER_HOME=<scratch>/home:Documents 預設值也落在 scratch(雙保險;偏好仍走真的偏好域)
// 加 --wait 會等結果檔出現(最多 60 秒)並把內容印出來:myparrotctl --wait state /tmp/s.json
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var wait = false
if args.first == "--wait" { wait = true; args.removeFirst() }
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("用法:myparrotctl [--wait] <指令> [參數…] <結果檔>\n".utf8)); exit(1)
}
// snapshot 的結果檔是圖本身;等的是 .json
var resultPath = args.last!
if args.first == "snapshot" { resultPath = args[1] + ".json"; }
// window-shot 也是圖在前、可接選項(main|sheet|alert);等 .json(成功失敗都會寫)。
if args.first == "window-shot" { resultPath = args[1] + ".json" }
if wait { try? FileManager.default.removeItem(atPath: resultPath) }

// #949:MYPARROT_DEBUG_CHANNEL 有值 ⇒ 只送到同頻道的驗證實例(通知是廣播;沒設頻道時機上每個 DEBUG 建置都會收到,
// 包括 Eric 平常用的那個——`quit` 會把它一起關掉)。
let channel = ProcessInfo.processInfo.environment["MYPARROT_DEBUG_CHANNEL"].flatMap { $0.isEmpty ? nil : $0 }
let notificationName = "tw.uncle.MyParrot.debug" + (channel.map { ".\($0)" } ?? "")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(notificationName), object: args.joined(separator: "\u{1F}"),
    userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))

if wait {
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        if let data = FileManager.default.contents(atPath: resultPath), !data.isEmpty {
            print(String(decoding: data, as: UTF8.self)); exit(0)
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    FileHandle.standardError.write(Data("逾時:60 秒內沒有結果檔 \(resultPath)(App 不是 DEBUG 建置?沒在跑?)\n".utf8)); exit(2)
}
