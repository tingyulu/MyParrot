import Foundation
import MyParrotCore

let results = SelfTest.run()
print("🦜 MyParrot 自我測試")
print(String(repeating: "=", count: 40))
var failed = 0
for r in results {
    let mark = r.passed ? "✅ PASS" : "❌ FAIL"
    let detail = r.detail.isEmpty ? "" : "  — \(r.detail)"
    print("\(mark)  \(r.name)\(detail)")
    if !r.passed { failed += 1 }
}
print(String(repeating: "=", count: 40))
print("\(results.count - failed)/\(results.count) 通過")
exit(failed == 0 ? 0 : 1)
