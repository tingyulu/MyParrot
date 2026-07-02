import SwiftUI

/// App UI display language (separate from the speech-recognition language).
/// Default follows the system; unsupported system languages fall back to English.
/// User-overridable in Settings, switches live.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, en, zhTW, ja, ko, zhCN
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟隨系統 / System"
        case .en:     return "English"
        case .zhTW:   return "繁體中文"
        case .ja:     return "日本語"
        case .ko:     return "한국어"
        case .zhCN:   return "简体中文"
        }
    }
}

@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()
    var language: AppLanguage = .system {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "uiLanguage") }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "uiLanguage"),
           let l = AppLanguage(rawValue: raw) { language = l }
    }

    /// Resolve to a concrete language, following the OS when `.system`.
    private var resolved: AppLanguage {
        if language != .system { return language }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.language.region?.identifier
        switch code {
        case "zh": return (region == "CN" || region == "SG") ? .zhCN : .zhTW
        case "ja": return .ja
        case "ko": return .ko
        case "en": return .en
        default:   return .en
        }
    }

    /// Keys are the 繁中 strings already in the views, so `.zhTW` returns the key.
    func t(_ key: String) -> String {
        let lang = resolved
        if lang == .zhTW { return key }
        return Self.table[key]?[lang] ?? Self.table[key]?[.en] ?? key
    }

    private static let table: [String: [AppLanguage: String]] = [
        "迷你模式": [.en: "Mini Mode", .ja: "ミニモード", .ko: "미니 모드", .zhCN: "迷你模式"],
        "設定": [.en: "Settings", .ja: "設定", .ko: "설정", .zhCN: "设置"],
        "完成": [.en: "Done", .ja: "完了", .ko: "완료", .zhCN: "完成"],
        "待錄音": [.en: "Ready", .ja: "待機中", .ko: "대기 중", .zhCN: "待录音"],
        "錄音中": [.en: "Recording", .ja: "録音中", .ko: "녹음 중", .zhCN: "录音中"],
        "已暫停": [.en: "Paused", .ja: "一時停止", .ko: "일시정지", .zhCN: "已暂停"],
        "結束後": [.en: "Finished", .ja: "終了", .ko: "완료", .zhCN: "结束后"],
        "對方": [.en: "Them", .ja: "相手", .ko: "상대방", .zhCN: "对方"],
        "你": [.en: "You", .ja: "あなた", .ko: "나", .zhCN: "你"],
        "會議名稱": [.en: "Meeting name", .ja: "会議名", .ko: "회의 이름", .zhCN: "会议名称"],
        "開始錄音": [.en: "Record", .ja: "録音開始", .ko: "녹음 시작", .zhCN: "开始录音"],
        "暫停": [.en: "Pause", .ja: "一時停止", .ko: "일시정지", .zhCN: "暂停"],
        "繼續": [.en: "Resume", .ja: "再開", .ko: "계속", .zhCN: "继续"],
        "結束": [.en: "Stop", .ja: "終了", .ko: "종료", .zhCN: "结束"],
        "新錄音": [.en: "New", .ja: "新規録音", .ko: "새 녹음", .zhCN: "新录音"],
        "最近錄音": [.en: "Recent", .ja: "最近の録音", .ko: "최근 녹음", .zhCN: "最近录音"],
        "在 Finder 打開": [.en: "Show in Finder", .ja: "Finderで表示", .ko: "Finder에서 열기", .zhCN: "在访达中打开"],
        "尚無錄音": [.en: "No recordings yet", .ja: "録音はまだありません", .ko: "녹음 없음", .zhCN: "尚无录音"],
        "雙聲道": [.en: "Stereo", .ja: "ステレオ", .ko: "스테레오", .zhCN: "双声道"],
        "雙聲道 · 已轉稿": [.en: "Stereo · Transcribed", .ja: "ステレオ・文字起こし済み", .ko: "스테레오 · 변환됨", .zhCN: "双声道 · 已转写"],
        "處理中…": [.en: "Processing…", .ja: "処理中…", .ko: "처리 중…", .zhCN: "处理中…"],
        "收音中": [.en: "Live", .ja: "受信中", .ko: "수신 중", .zhCN: "收音中"],
        "錄音中收音": [.en: "Capturing (recording)", .ja: "録音中・受信中", .ko: "녹음 중 수신", .zhCN: "录音中收音"],
        "等待訊號": [.en: "No signal", .ja: "信号なし", .ko: "신호 없음", .zhCN: "等待信号"],
        "轉逐字稿": [.en: "Transcribe", .ja: "文字起こし", .ko: "받아쓰기", .zhCN: "转写"],
        "存 Drive": [.en: "Save to Drive", .ja: "Driveに保存", .ko: "Drive에 저장", .zhCN: "存到 Drive"],
        "存 Google Drive": [.en: "Save to Google Drive", .ja: "Google Driveに保存", .ko: "Google Drive에 저장", .zhCN: "存到 Google Drive"],
        "即時逐字稿": [.en: "Live Transcript", .ja: "リアルタイム文字起こし", .ko: "실시간 받아쓰기", .zhCN: "实时字幕"],
        "最近 3 分鐘": [.en: "Last 3 min", .ja: "直近3分", .ko: "최근 3분", .zhCN: "最近 3 分钟"],
        "完整": [.en: "Full", .ja: "全文", .ko: "전체", .zhCN: "完整"],
        "轉逐字稿中…": [.en: "Transcribing…", .ja: "文字起こし中…", .ko: "변환 중…", .zhCN: "转写中…"],
        "開始錄音後,逐字稿會即時顯示在這裡;或對任一錄音檔按「轉逐字稿」。": [
            .en: "Transcript appears here while recording — or press Transcribe on any recording.",
            .ja: "録音中はここに文字起こしが表示されます。録音を選んで「文字起こし」も可能。",
            .ko: "녹음 중 여기에 받아쓰기가 표시됩니다. 녹음에서 '받아쓰기'를 눌러도 됩니다.",
            .zhCN: "开始录音后,字幕会实时显示在这里;或对任一录音按「转写」。"],
        "分軌讓「誰說的」自動標好(對方左／你右)": [
            .en: "Split channels auto-label the speaker (Them = L / You = R)",
            .ja: "チャンネル分離で話者を自動判別(相手=左／あなた=右)",
            .ko: "채널 분리로 화자 자동 구분 (상대방=왼쪽 / 나=오른쪽)",
            .zhCN: "分轨让「谁说的」自动标好(对方左／你右)"],
        "廣告": [.en: "Ad", .ja: "広告", .ko: "광고", .zhCN: "广告"],
        "免費版顯示一行小廣告": [.en: "Free version shows a small ad", .ja: "無料版では小さな広告が表示されます", .ko: "무료 버전은 작은 광고를 표시합니다", .zhCN: "免费版显示一行小广告"],
        "升級移除": [.en: "Remove", .ja: "削除", .ko: "제거", .zhCN: "升级移除"],
        "需要麥克風 / 語音辨識 / 系統音訊權限": [
            .en: "Needs Microphone / Speech / System Audio permission",
            .ja: "マイク／音声認識／システム音声の権限が必要",
            .ko: "마이크 / 음성 인식 / 시스템 오디오 권한 필요",
            .zhCN: "需要麦克风 / 语音识别 / 系统音频权限"],
        "授權": [.en: "Grant", .ja: "許可", .ko: "허용", .zhCN: "授权"],
        // Settings
        "輸入來源(分兩軌)": [.en: "Input (two channels)", .ja: "入力ソース(2チャンネル)", .ko: "입력 소스(2채널)", .zhCN: "输入来源(分两轨)"],
        "對方聲音(左軌)": [.en: "Their voice (Left)", .ja: "相手の声(左)", .ko: "상대방 음성(왼쪽)", .zhCN: "对方声音(左轨)"],
        "系統音訊 · 全部": [.en: "System audio · All", .ja: "システム音声・全体", .ko: "시스템 오디오 · 전체", .zhCN: "系统音频 · 全部"],
        "你的麥克風(右軌)": [.en: "Your mic (Right)", .ja: "あなたのマイク(右)", .ko: "내 마이크(오른쪽)", .zhCN: "你的麦克风(右轨)"],
        "(藍牙)": [.en: " (Bluetooth)", .ja: "(Bluetooth)", .ko: " (블루투스)", .zhCN: "(蓝牙)"],
        "(iPhone)": [.en: " (iPhone)", .ja: "(iPhone)", .ko: " (iPhone)", .zhCN: "(iPhone)"],
        "聆聽輸出": [.en: "Listening output", .ja: "再生出力", .ko: "듣기 출력", .zhCN: "聆听输出"],
        "跟隨系統 · 不影響錄音": [.en: "Follow system · Doesn't affect recording", .ja: "システムに従う・録音に影響なし", .ko: "시스템 따름 · 녹음에 영향 없음", .zhCN: "跟随系统 · 不影响录音"],
        "提醒:麥克風別選藍牙耳機,否則整條藍牙掉 HFP,對方聲音也會變糊。": [
            .en: "Tip: don't use a Bluetooth mic — it drops the link to HFP and muddies their voice too.",
            .ja: "ヒント:マイクにBluetoothを使わないで。HFPに切替わり相手の声も劣化します。",
            .ko: "팁: 마이크로 블루투스를 쓰지 마세요. HFP로 전환되어 상대방 음성도 흐려집니다.",
            .zhCN: "提醒:麦克风别选蓝牙耳机,否则整条蓝牙掉 HFP,对方声音也会变糊。"],
        "錄音": [.en: "Recording", .ja: "録音", .ko: "녹음", .zhCN: "录音"],
        "麥克風靈敏度": [.en: "Mic sensitivity", .ja: "マイク感度", .ko: "마이크 감도", .zhCN: "麦克风灵敏度"],
        "對著麥克風講話測試": [.en: "Speak to test", .ja: "話してテスト", .ko: "말해서 테스트", .zhCN: "对着麦克风讲话测试"],
        "錄音時即時逐字稿": [.en: "Live transcript while recording", .ja: "録音中にリアルタイム文字起こし", .ko: "녹음 중 실시간 받아쓰기", .zhCN: "录音时实时字幕"],
        "回音消除(喇叭外放·停止後處理)": [.en: "Echo cleanup (speakers · after stop)", .ja: "エコー除去(スピーカー・停止後)", .ko: "에코 제거(스피커 · 정지 후)", .zhCN: "回音消除(扬声器外放·停止后处理)"],
        "用喇叭(非耳機)開會時,停止後自動消掉對方聲音被麥克風收進去的回音;純後製、不影響開會當下的聲音。": [
            .en: "When meeting on speakers (not headphones), removes the other party's voice that bled into your mic, after you stop. Post-processing only — doesn't affect live meeting audio.",
            .ja: "スピーカー(イヤホン以外)で会議する際、停止後に相手の声がマイクに入った反響を除去。後処理のみで会議中の音には影響しません。",
            .ko: "스피커(이어폰 아님)로 회의할 때 정지 후 상대방 소리가 마이크에 들어간 반향을 제거; 후처리만 하며 회의 중 소리에는 영향 없음.",
            .zhCN: "用扬声器(非耳机)开会时,停止后自动消掉对方声音被麦克风收进去的回音;纯后期、不影响开会当下的声音。"],
        "錄音格式": [.en: "Recording format", .ja: "録音フォーマット", .ko: "녹음 형식", .zhCN: "录音格式"],
        "錄製 PCM → 存檔 m4a(雙聲道)": [.en: "Capture PCM → Save m4a (stereo)", .ja: "録音PCM → 保存m4a(ステレオ)", .ko: "녹음 PCM → 저장 m4a(스테레오)", .zhCN: "录制 PCM → 存档 m4a(双声道)"],
        "逐字稿": [.en: "Transcript", .ja: "文字起こし", .ko: "받아쓰기", .zhCN: "字幕"],
        "辨識語言": [.en: "Recognition language", .ja: "認識言語", .ko: "인식 언어", .zhCN: "识别语言"],
        "介面語言": [.en: "Display language", .ja: "表示言語", .ko: "표시 언어", .zhCN: "界面语言"],
        "預設跟隨系統語言;不支援的語言會用英文。支援:英/繁中/日/韓/簡中。": [
            .en: "Defaults to the system language; unsupported ones use English. Supported: EN / 繁中 / JA / KO / 简中.",
            .ja: "既定はシステム言語。非対応は英語。対応:英/繁中/日/韓/簡中。",
            .ko: "기본은 시스템 언어. 미지원은 영어. 지원: 영/번체/일/한/간체.",
            .zhCN: "默认跟随系统语言;不支持的语言用英文。支持:英/繁中/日/韩/简中。"],
        "引擎": [.en: "Engine", .ja: "エンジン", .ko: "엔진", .zhCN: "引擎"],
        "存檔": [.en: "Storage", .ja: "保存先", .ko: "저장", .zhCN: "存档"],
        "存檔目錄": [.en: "Save folder", .ja: "保存フォルダ", .ko: "저장 폴더", .zhCN: "存档目录"],
        "選擇…": [.en: "Choose…", .ja: "選択…", .ko: "선택…", .zhCN: "选择…"],
        "可指向 Google Drive 同步資料夾。": [.en: "Can point to a Google Drive synced folder.", .ja: "Google Drive同期フォルダを指定できます。", .ko: "Google Drive 동기화 폴더를 지정할 수 있습니다.", .zhCN: "可指向 Google Drive 同步文件夹。"],
        "檔名範本": [.en: "Filename", .ja: "ファイル名", .ko: "파일 이름", .zhCN: "文件名"],
        "日期+時間+會議名稱": [.en: "Date + Time + Meeting name", .ja: "日付+時刻+会議名", .ko: "날짜+시간+회의 이름", .zhCN: "日期+时间+会议名称"],
        "權限": [.en: "Permissions", .ja: "権限", .ko: "권한", .zhCN: "权限"],
        "麥克風": [.en: "Microphone", .ja: "マイク", .ko: "마이크", .zhCN: "麦克风"],
        "語音辨識": [.en: "Speech recognition", .ja: "音声認識", .ko: "음성 인식", .zhCN: "语音识别"],
        "已授權": [.en: "Granted", .ja: "許可済み", .ko: "허용됨", .zhCN: "已授权"],
        "未授權": [.en: "Not granted", .ja: "未許可", .ko: "미허용", .zhCN: "未授权"],
        "重新請求權限": [.en: "Request again", .ja: "再リクエスト", .ko: "다시 요청", .zhCN: "重新请求权限"],
        // Quit guard (recording in progress)
        "錄音還在進行中": [.en: "A recording is still in progress", .ja: "録音がまだ進行中です", .ko: "녹음이 아직 진행 중입니다", .zhCN: "录音还在进行中"],
        "要先結束並儲存這段錄音,還是繼續錄音?": [
            .en: "Stop and save this recording first, or keep recording?",
            .ja: "この録音を終了して保存しますか?それとも録音を続けますか?",
            .ko: "이 녹음을 끝내고 저장할까요, 아니면 계속 녹음할까요?",
            .zhCN: "要先结束并保存这段录音,还是继续录音?"],
        "繼續錄音": [.en: "Keep Recording", .ja: "録音を続ける", .ko: "계속 녹음", .zhCN: "继续录音"],
        "結束錄音並離開": [.en: "Stop & Quit", .ja: "終了して保存・終了", .ko: "끝내고 종료", .zhCN: "结束录音并退出"],
    ]
}

/// Localize a 繁中 key to the current UI language. Call inside SwiftUI bodies.
@MainActor func L(_ key: String) -> String { Localizer.shared.t(key) }
