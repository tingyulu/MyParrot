import Foundation

/// MAS-06／07(#2646):沙盒版錄音夾的 security-scoped bookmark 狀態機。
/// `classify` 是純函式(SelfTest `masBookmarkStateMachine`):一次探測的原始事實 ⇒ 五態;
/// `probe`／`makeBookmark` 做真的 resolve／建書籤,只在 `BuildFlavor.usesSecurityScopedRecordingsDir` 下被
/// RecordingController 呼叫,SelfTest 不碰(真路徑在 MAS-06／07 真機驗)。
public enum RecordingsFolderAccess {

    /// 一次探測的原始事實(全部布林／URL,好測、好印)。
    public struct Probe: Sendable, Equatable {
        public var hasBookmark: Bool
        /// resolve 成功的 URL;nil＝沒有書籤或 resolve 丟錯(資料損壞／目標被刪)。
        public var resolvedURL: URL?
        /// 系統說書籤過期(資料夾搬過、要重存)。
        public var isStale: Bool
        public var directoryExists: Bool
        /// `startAccessingSecurityScopedResource()` 回 true。
        public var accessGranted: Bool
        /// 試寫一個暫存檔成功。
        public var writable: Bool
        public init(hasBookmark: Bool, resolvedURL: URL?, isStale: Bool, directoryExists: Bool, accessGranted: Bool, writable: Bool) {
            self.hasBookmark = hasBookmark; self.resolvedURL = resolvedURL; self.isStale = isStale
            self.directoryExists = directoryExists; self.accessGranted = accessGranted; self.writable = writable
        }
    }

    public enum State: Sendable, Equatable {
        /// 從未選過資料夾(首次啟動)⇒ 跳選擇器。
        case unset
        /// 可用。
        case valid(URL)
        /// 可用但書籤過期(資料夾搬過)⇒ 用這個 URL 重存書籤,不打擾使用者。
        case stale(URL)
        /// 書籤解不開或資料夾不在了 ⇒ 請重選。
        case missing(URL?)
        /// 解得開、資料夾在,但系統不給存取或寫不進(使用者在系統設定撤回「檔案與資料夾」)⇒ 請重選、錄音鍵前先擋。
        case denied(URL)

        /// 要不要跳選擇器／擋錄音鍵。
        public var needsUserAction: Bool {
            switch self {
            case .valid, .stale: return false
            case .unset, .missing, .denied: return true
            }
        }
        /// 可寫的 URL(valid／stale 才有)。
        public var usableURL: URL? {
            switch self {
            case .valid(let u), .stale(let u): return u
            case .unset, .missing, .denied: return nil
            }
        }
    }

    /// 純函式:探測結果 ⇒ 狀態。判定順序:沒書籤 → 解不開 → 資料夾不在 → 不給存取／寫不進 → 過期 → 可用。
    /// 🚫 不會把任何一態判成「靜默錄進容器」:要人介入的三態 `usableURL` 都是 nil。
    public static func classify(_ p: Probe) -> State {
        guard p.hasBookmark else { return .unset }
        guard let url = p.resolvedURL else { return .missing(nil) }
        guard p.directoryExists else { return .missing(url) }
        guard p.accessGranted, p.writable else { return .denied(url) }
        return p.isStale ? .stale(url) : .valid(url)
    }

    // MARK: - 真路徑(旗標下才被呼叫)

    /// 建 app-scoped security bookmark(使用者在 NSOpenPanel 選完,或 stale 時重存)。
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 解書籤並探測。回 (探測結果, 已 `startAccessing` 且可用的 URL——呼叫端負責不用時 `stopAccessing`)。
    /// 不可用的情況這裡已把 access 收回,呼叫端不必處理。
    public static func probe(bookmark: Data?) -> (probe: Probe, accessing: URL?) {
        guard let data = bookmark else {
            return (Probe(hasBookmark: false, resolvedURL: nil, isStale: false, directoryExists: false, accessGranted: false, writable: false), nil)
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return (Probe(hasBookmark: true, resolvedURL: nil, isStale: false, directoryExists: false, accessGranted: false, writable: false), nil)
        }
        let granted = url.startAccessingSecurityScopedResource()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        let writable = exists && canWrite(in: url)
        let usable = granted && exists && writable
        if granted && !usable { url.stopAccessingSecurityScopedResource() }
        return (Probe(hasBookmark: true, resolvedURL: url, isStale: stale, directoryExists: exists, accessGranted: granted, writable: writable),
                usable ? url : nil)
    }

    /// 試寫:在資料夾裡建一個 `.myparrot-write-test-<id>` 再刪。
    /// MAS-33:用解出來的同一個 URL 實例 `appendingPathComponent`,🚫 不以 `URL(fileURLWithPath: url.path)` 重建。
    static func canWrite(in dir: URL) -> Bool {
        let f = dir.appendingPathComponent(".myparrot-write-test-\(UUID().uuidString.prefix(8))")
        do {
            try Data().write(to: f, options: .atomic)
            try? FileManager.default.removeItem(at: f)
            return true
        } catch {
            return false
        }
    }
}
