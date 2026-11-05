import Foundation

/// #2412 DEBUG 控制通道的**純決策**部分(DBG-01):指令字串怎麼切、結果檔可以寫去哪。
/// 放 Core 是為了讓 SelfTest 驗得到;真正收指令、動 UI 的 `DebugControl` 在 app target
/// 且整檔 `#if DEBUG`,release 不含。這裡沒有任何副作用。
public enum DebugCommand {
    /// 參數分隔字元(ASCII Unit Separator),指令本身不可能含它。
    public static let separator: Character = "\u{1F}"

    /// 切參數:空參數保留(`a\u{1F}\u{1F}b` → ["a","","b"]),整串空字串 → []。
    public static func parse(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    }

    /// 結果檔只准寫到暫存區或家目錄底下(DBG-01/06):絕對路徑、不含 `..`、
    /// 前綴是 /tmp、/private/tmp、$TMPDIR(含 /private/var/folders)或家目錄。
    /// `extraRoots`(PERM-11,#2673):沙盒 build 的「家目錄」是容器、外面的驗證腳本讀不到(TCC 擋 ~/Library/Containers),
    /// 而 /tmp 沙盒又寫不進 ⇒ 兩邊唯一共同可寫的是**目前錄音夾**(app 本來就在那裡寫錄音);DebugControl 把它當額外根傳進來。
    /// 二審(PERM-11):路徑與根都先解 symlink 再比前綴(檢查當下指到外面的 symlink 會被擋;檢查到寫入之間被換掉的 TOCTOU 不在防護內,
    /// DEBUG 建置限定);根至少兩層(`/`、`/Users` 這種過寬的根丟掉)。
    public static func isAllowedResultPath(_ path: String,
                                           home: String = NSHomeDirectory(),
                                           tmp: String = NSTemporaryDirectory(),
                                           extraRoots: [String] = []) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        // resolvingSymlinksInPath 只對「存在的」前綴去 /private(目錄 /private/tmp/ → /tmp,不存在的 /private/tmp/a.json 不動),
        // 兩邊會不對稱 ⇒ 解完 symlink 再明確把 /private/{tmp,var,etc} 前綴去掉,路徑與根同一套規則。
        func canon(_ p: String) -> String {
            var r = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
            for base in ["/private/tmp", "/private/var", "/private/etc"] where r == base || r.hasPrefix(base + "/") {
                r = String(r.dropFirst("/private".count))
            }
            return r
        }
        var roots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        for r in [tmp, home] + extraRoots where r.hasPrefix("/") && r.split(separator: "/").count >= 2 {
            roots.append(r.hasSuffix("/") ? r : r + "/")
        }
        let target = canon(path)
        return roots.contains { root in
            let c = canon(root)
            return target.hasPrefix(c.hasSuffix("/") ? c : c + "/")
        }
    }
}
