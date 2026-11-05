import Foundation

/// PERM(#2673,TEST_PLAN Y 節):權限被拒引導的純決策——錄音前橫幅矩陣、麥克風被拒不怪裝置、對方軌無聲警告依輸出裝置分流。
/// 全部不碰 TCC、不碰 UI;正控突變(拿掉 denied 分支／拿掉分流)記錄在 TEST_REPORT「PERM」節。
extension SelfTest {

    /// PERM-02:`PermissionHints.decide` 4×4×2 矩陣。
    static func permissionHintDecision() -> Result {
        var fails: [String] = []
        for mic in PermissionState.allCases {
            for speech in PermissionState.allCases {
                for needed in [true, false] {
                    let hints = PermissionHints.decide(mic: mic, speech: speech, speechNeeded: needed)
                    let tag = "mic=\(mic.rawValue) speech=\(speech.rawValue) needed=\(needed)"
                    // 麥克風列
                    let m = hints.first { $0.kind == .microphone }
                    switch mic {
                    case .authorized:
                        if m != nil { fails.append("\(tag):已授權不該有麥克風橫幅") }
                    case .notDetermined:
                        if m?.action != .request { fails.append("\(tag):未問過應是 request") }
                        if m?.template != PermissionHints.micNotDetermined { fails.append("\(tag):麥克風未問過模板錯") }
                    case .denied, .restricted:
                        if m?.action != .openSystemSettings(pane: PermissionKind.microphone.settingsPane) {
                            fails.append("\(tag):被拒應開系統設定麥克風分頁")
                        }
                        if m?.template != PermissionHints.micBlocked { fails.append("\(tag):麥克風被拒模板錯") }
                    }
                    // 語音辨識列:只在 needed 時出現
                    let sp = hints.first { $0.kind == .speech }
                    if !needed || speech == .authorized {
                        if sp != nil { fails.append("\(tag):不需要／已授權不該有語音辨識橫幅") }
                    } else if speech == .notDetermined {
                        if sp?.action != .request { fails.append("\(tag):語音未問過應是 request") }
                    } else if sp?.action != .openSystemSettings(pane: PermissionKind.speech.settingsPane) {
                        fails.append("\(tag):語音被拒應開系統設定語音辨識分頁")
                    }
                    // 順序:麥克風在前;沒有系統音訊列(查不到就不假裝知道)
                    if hints.count == 2, hints[0].kind != .microphone { fails.append("\(tag):麥克風應排第一") }
                    if hints.contains(where: { $0.kind == .systemAudio }) { fails.append("\(tag):不該有系統音訊橫幅") }
                    for h in hints where L10nFormat.placeholderCount(h.template) != 0 { fails.append("\(tag):模板不該有佔位符") }
                }
            }
        }
        // 分頁字串與 URL 都要合法
        for k in PermissionKind.allCases where !k.settingsPane.hasPrefix("com.apple.preference.security?Privacy_") {
            fails.append("\(k) 分頁字串不對:\(k.settingsPane)")
        }
        if PermissionKind.microphone.settingsURL.scheme != "x-apple.systempreferences" { fails.append("settingsURL scheme 錯") }
        // isBlocked / recordGateBlocks(PERM-03):只有 denied／restricted 擋
        for st in PermissionState.allCases {
            let expect = st == .denied || st == .restricted
            if st.isBlocked != expect { fails.append("\(st.rawValue).isBlocked 應為 \(expect)") }
            if PermissionHints.recordGateBlocks(mic: st) != expect { fails.append("recordGateBlocks(\(st.rawValue)) 應為 \(expect)") }
        }
        // PERM-03 gate 動作(二審第三輪):未問過先請求、請求過仍未決放行、被拒擋、授權放行
        let g = PermissionHints.recordGateAction
        if g(.notDetermined, false) != .requestFirst { fails.append("notDetermined 應先請求") }
        if g(.notDetermined, true) != .pass { fails.append("請求過仍 notDetermined 應放行(防重入)") }
        if g(.denied, false) != .block || g(.restricted, true) != .block { fails.append("denied／restricted 應擋") }
        if g(.authorized, false) != .pass { fails.append("authorized 應放行") }
        return Result(name: "PERM-02 錄音前權限橫幅決策", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "4×4×2 矩陣 32 組全對;分頁字串 3 個合法;gate 只擋 denied／restricted、未問過先請求" : fails.joined(separator: ";"))
    }

    /// PERM-04:麥克風 8 秒無聲該跳哪條——被拒／受限 ⇒ 不跳;其他照 AUD-38(藍牙／一般)。
    static func micSilentWarningByAuthorization() -> Result {
        var fails: [String] = []
        let f = PermissionHints.micSilentWarning
        if f(.denied, false) != nil { fails.append("denied 不該跳") }
        if f(.denied, true) != nil { fails.append("denied+藍牙 不該跳") }
        if f(.restricted, false) != nil { fails.append("restricted 不該跳") }
        if f(.authorized, false) != .micSilent { fails.append("authorized 應跳 micSilent") }
        if f(.authorized, true) != .micSilentBluetooth { fails.append("authorized+藍牙 應跳 micSilentBluetooth") }
        if f(.notDetermined, false) != nil { fails.append("notDetermined(系統框還掛著)不該怪裝置") }
        return Result(name: "PERM-04 麥克風被拒時不怪裝置", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "6 案全對(denied／restricted／notDetermined 不跳,authorized 照 AUD-38)" : fails.joined(separator: ";"))
    }

    /// PERM-05:對方軌無聲警告依輸出裝置傳輸類型分流;新 case 的 action／自動收起／模板參數數一致。
    static func sysSilentBannerSplit() -> Result {
        var fails: [String] = []
        let w = SysTrackWatchdog.self
        if w.silentBanner(outputTransport: .bluetooth) != .sysSilent { fails.append("藍牙首跳應是 sysSilent(HFP 說法)") }
        if w.silentBanner(outputTransport: .unknown) != .sysSilent { fails.append("未知(tap 沒建好／切換中)首跳應走舊文案,不推論權限") }
        if w.silentBanner(outputTransport: .other) != .sysSilentCheckPermission { fails.append("非藍牙首跳應是 sysSilentCheckPermission") }
        if w.rebuildBanner(silentWarned: true, reason: .persistentSilence, inRewarnGrace: false, outputTransport: .bluetooth) != .sysRebuildMaybeStillSilent {
            fails.append("藍牙重建後應是 sysRebuildMaybeStillSilent")
        }
        if w.rebuildBanner(silentWarned: true, reason: .persistentSilence, inRewarnGrace: false, outputTransport: .unknown) != .sysRebuildMaybeStillSilent {
            fails.append("未知重建後應照舊 sysRebuildMaybeStillSilent")
        }
        if w.rebuildBanner(silentWarned: true, reason: .persistentSilence, inRewarnGrace: false, outputTransport: .other) != .sysSilentCheckPermission {
            fails.append("非藍牙重建後應是 sysSilentCheckPermission(不說已嘗試重建)")
        }
        for t in [OutputTransport.bluetooth, .other, .unknown] {
            if w.rebuildBanner(silentWarned: false, reason: .persistentSilence, inRewarnGrace: true, outputTransport: t) != nil {
                fails.append("再跳觀察期內持續無聲不該跳(\(t))")
            }
            if w.rebuildBanner(silentWarned: false, reason: .outputDeviceChanged, inRewarnGrace: false, outputTransport: t) != .sysRestarted(reason: .outputDeviceChanged) {
                fails.append("其他原因應照舊 sysRestarted(\(t))")
            }
        }
        // 預設參數＝未知(既有呼叫端行為不變)
        if w.rebuildBanner(silentWarned: true, reason: .signalLost, inRewarnGrace: false) != .sysRebuildMaybeStillSilent { fails.append("預設 outputTransport 應維持舊行為") }
        // 新 case 的屬性
        let c = RecordingWarning.sysSilentCheckPermission
        if c.action != .openSystemSettings(pane: PermissionKind.systemAudio.settingsPane) { fails.append("新 case 的 action 應開系統音訊錄製分頁") }
        if !c.clearsWhenSysSignalReturns { fails.append("新 case 對方有聲應自動收起") }
        if RecordingWarning.sysSilent.action != nil { fails.append("舊 sysSilent 不該有 action") }
        if c.zhTW.contains("HFP") || c.zhTW.contains("藍牙") { fails.append("非藍牙文案不該提 HFP／藍牙") }
        if !c.zhTW.contains("系統音訊錄製") { fails.append("非藍牙文案要提系統音訊錄製權限") }
        // 所有 case 模板佔位符數＝參數數(新 case 加進來後再掃一次)
        let samples: [RecordingWarning] = [.engineChangeDeferred, .whisperModelMissing, .cloudNotConfigured, .micSwitched(device: "A"),
                                           .micSwitchFailed(device: "A"), .micReconnected(reason: .signalLost, device: nil),
                                           .sysRebuildMaybeStillSilent, .sysRestarted(reason: .signalLost), .micSilentBluetooth,
                                           .micBluetoothUnstable(device: "A"), .micSilent, .sysSilent, .sysSilentCheckPermission, .deviceChanged]
        for s in samples where L10nFormat.placeholderCount(s.template) != s.arguments.count {
            fails.append("\(s) 模板佔位符 \(L10nFormat.placeholderCount(s.template)) ≠ 參數 \(s.arguments.count)")
        }
        return Result(name: "PERM-05 對方軌無聲警告分流", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "藍牙／非藍牙／未知 × 首跳／重建後 6 案;觀察期與其他原因不變;action／自動收起／14 個模板參數數一致" : fails.joined(separator: ";"))
    }
}
