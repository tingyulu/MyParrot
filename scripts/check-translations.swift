#!/usr/bin/env swift
// Build-time guard for BUG-08: every 繁中 key passed to L("…") must have an entry
// in Localizer.table, otherwise non-繁中 users see the untranslated 繁中 string.
// Scans Sources/MyParrot for L(...) literal keys and diffs against the table.
// Dynamic calls like L(stateLabel) can't be checked statically and are skipped.
// Exit 1 (and list the gaps) if any literal key is missing a translation.
import Foundation

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/MyParrot"
let fm = FileManager.default

func hasHan(_ s: String) -> Bool {
    s.unicodeScalars.contains {
        (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value)
    }
}

// All string literals that are arguments to an L( … ) call, honoring quote state
// and paren depth (keys themselves contain ASCII parens, so we can't naively
// balance on every '(' / ')').
func usedKeys(in src: String) -> Set<String> {
    var keys = Set<String>()
    let c = Array(src)
    var i = 0
    while i < c.count {
        if c[i] == "L", i + 1 < c.count, c[i+1] == "(" {
            let prev: Character = i > 0 ? c[i-1] : " "
            if prev.isLetter || prev.isNumber || prev == "_" || prev == "." { i += 1; continue }
            var j = i + 2, depth = 1, inStr = false, esc = false, cur = ""
            while j < c.count, depth > 0 {
                let ch = c[j]
                if inStr {
                    if esc { cur.append(ch); esc = false }
                    else if ch == "\\" { cur.append(ch); esc = true }
                    else if ch == "\"" { if hasHan(cur) { keys.insert(cur) }; inStr = false }
                    else { cur.append(ch) }
                } else if ch == "\"" { inStr = true; cur = "" }
                else if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1 }
                j += 1
            }
            i = j; continue
        }
        i += 1
    }
    return keys
}

// Dict keys in Localizer.table: lines shaped like  "KEY": [   (first quoted string
// followed by a colon).
func tableKeys(in src: String) -> Set<String> {
    var keys = Set<String>()
    for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = Array(raw.drop(while: { $0 == " " }))
        guard line.first == "\"" else { continue }
        var k = "", idx = 1, esc = false, closed = false
        while idx < line.count {
            let ch = line[idx]
            if esc { k.append(ch); esc = false }
            else if ch == "\\" { esc = true }
            else if ch == "\"" { closed = true; idx += 1; break }
            else { k.append(ch) }
            idx += 1
        }
        guard closed else { continue }
        let rest = String(line[idx...]).drop(while: { $0 == " " })
        if rest.first == ":" { keys.insert(k) }
    }
    return keys
}

func swiftFiles(_ dir: String) -> [String] {
    guard let en = fm.enumerator(atPath: dir) else { return [] }
    return en.compactMap { ($0 as? String).map { "\(dir)/\($0)" } }.filter { $0.hasSuffix(".swift") }
}

var used = Set<String>()
for f in swiftFiles(root) {
    if let s = try? String(contentsOfFile: f, encoding: .utf8) { used.formUnion(usedKeys(in: s)) }
}
let locPath = "\(root)/Localization.swift"
let table = (try? String(contentsOfFile: locPath, encoding: .utf8)).map(tableKeys) ?? []

let missing = used.subtracting(table).sorted()
print("🌐 翻譯表完整性檢查")
print("   L() 使用的字面 key:\(used.count) · 翻譯表 key:\(table.count)")
if missing.isEmpty {
    print("✅ 所有 L() 字面 key 都有翻譯(英/日/韓/簡中)")
    exit(0)
} else {
    print("❌ 以下 key 缺翻譯(非繁中語系會顯示原繁中字串):")
    for k in missing { print("   · \(k)") }
    exit(1)
}
