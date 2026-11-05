#!/usr/bin/env python3
"""docs/store 機械檢查（MAS-30）：九語文案欄位上限、關鍵字黑名單、截圖尺寸／alpha、人名守門。

用法：python3 -I scripts/dev/store-metadata-check.py docs/store [--guard-tokens <檔>]
  --guard-tokens：一行一個 token（真錄音夾檔名切詞，由呼叫端產生、不留在 repo），ASCII 整字比對、CJK 子字串比對。
上限（Apple 官方 2026-10-30）：name 2～30、subtitle ≤30、promotional_text ≤170、description ≤4000（字元）、keywords ≤100 bytes、
  每個關鍵字 >2 字元、截圖 2880×1800 且無 alpha。
exit 0＝全過；1＝有錯（逐條列）。零 pip 依賴（截圖用 sips 讀尺寸與 alpha）。
"""
import os, re, subprocess, sys

LOCALES = ["zh-Hant", "en-US", "zh-Hans", "ja", "ko", "es-ES", "de-DE", "fr-FR", "pt-BR"]
FIELDS = ["name", "subtitle", "promotional_text", "description", "keywords", "support_url", "marketing_url"]
LIMITS = {"name": 30, "subtitle": 30, "promotional_text": 170, "description": 4000}
# 關鍵字黑名單：其他 app／公司名（官方：Names of other apps or companies aren't allowed）
KEYWORD_BLACKLIST = {"zoom", "teams", "google", "meet", "webex", "slack", "otter", "notion", "apple", "microsoft", "whisper", "chatgpt", "claude"}
# 描述裡商店版沒有的東西（研究 §9：不提 CLI／Claude／Codex／GitHub 下載／更新檢查）
DESCRIPTION_FORBIDDEN = [r"\bCLI\b", r"\bClaude\b", r"\bCodex\b", r"download[^.\n]{0,40}GitHub", r"GitHub[^.\n]{0,40}download", r"update check", r"更新檢查", r"完整版"]


def parse(path):
    text = open(path, encoding="utf-8").read()
    fields, cur, buf = {}, None, []
    for line in text.splitlines():
        m = re.match(r"^## (\w+)\s*$", line)
        if m:
            if cur: fields[cur] = "\n".join(buf).strip()
            cur, buf = m.group(1), []
        elif cur is not None:
            buf.append(line)
    if cur: fields[cur] = "\n".join(buf).strip()
    return fields


def check_locale(root, loc, errors):
    p = os.path.join(root, "metadata", f"{loc}.md")
    if not os.path.isfile(p):
        errors.append(f"{loc}: 缺檔 {p}"); return
    f = parse(p)
    for k in FIELDS:
        if not f.get(k): errors.append(f"{loc}: 欄位 {k} 缺或空")
    name = f.get("name", "")
    if not (2 <= len(name) <= 30): errors.append(f"{loc}: name 長度 {len(name)}（2～30）")
    for k, lim in LIMITS.items():
        v = f.get(k, "")
        if len(v) > lim: errors.append(f"{loc}: {k} {len(v)} 字元 > {lim}")
    kw = f.get("keywords", "")
    kb = len(kw.encode("utf-8"))
    if kb > 100: errors.append(f"{loc}: keywords {kb} bytes > 100")
    for w in [x.strip() for x in kw.split(",") if x.strip()]:
        if len(w) <= 2: errors.append(f"{loc}: 關鍵字「{w}」≤2 字元")
        if w.lower() in KEYWORD_BLACKLIST: errors.append(f"{loc}: 關鍵字「{w}」在黑名單（其他 app／公司名）")
    desc = f.get("description", "")
    if "<" in desc and ">" in desc: errors.append(f"{loc}: description 疑似含 HTML")
    for pat in DESCRIPTION_FORBIDDEN:
        if re.search(pat, desc, re.I): errors.append(f"{loc}: description 命中禁詞 /{pat}/")
    for k in ("support_url", "marketing_url"):
        if not f.get(k, "").startswith("https://"): errors.append(f"{loc}: {k} 要完整 https:// URL")
    return f


def check_screenshots(root, errors):
    d = os.path.join(root, "screenshots")
    if not os.path.isdir(d):
        errors.append("screenshots/ 不存在"); return 0
    pngs = sorted(x for x in os.listdir(d) if x.lower().endswith((".png", ".jpg", ".jpeg")))
    if not (1 <= len(pngs) <= 10): errors.append(f"screenshots/ 有 {len(pngs)} 張（要 1～10）")
    for n in pngs:
        p = os.path.join(d, n)
        out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", p], capture_output=True, text=True).stdout
        w = re.search(r"pixelWidth: (\d+)", out); h = re.search(r"pixelHeight: (\d+)", out); a = re.search(r"hasAlpha: (\w+)", out)
        if not (w and h): errors.append(f"{n}: sips 讀不到尺寸"); continue
        if (int(w.group(1)), int(h.group(1))) != (2880, 1800): errors.append(f"{n}: {w.group(1)}×{h.group(1)}，要 2880×1800")
        if a and a.group(1).lower() == "yes": errors.append(f"{n}: 有 alpha（商店不收）")
    return len(pngs)


# 守門白名單：真錄音夾檔名切出來、但其實是通用詞／產品名的 token（命中只列資訊、不算錯；新增前先看 context）
GUARD_GENERIC = {"meeting", "myparrot", "new", "only", "store", "test", "mini", "notes", "max", "mic", "hfp", "airpods",
                 "tokens", "corrections", "contract", "cheer", "lin", "問卷", "會議", "修復", "測試", "錄音"}


def check_guard(root, tokens_path, errors):
    toks = [t.strip() for t in open(tokens_path, encoding="utf-8") if t.strip()]
    toks = [t for t in toks if t.lower() not in GUARD_GENERIC]
    files = []
    for dp, _, fns in os.walk(root):
        files += [os.path.join(dp, x) for x in fns if x.endswith(".md")]
    hits = 0
    for p in files:
        text = open(p, encoding="utf-8").read()
        for t in toks:
            if re.fullmatch(r"[A-Za-z]+", t):
                if len(t) >= 3 and re.search(r"(?<![A-Za-z])" + re.escape(t) + r"(?![A-Za-z])", text, re.I):
                    hits += 1; errors.append(f"守門命中 [{t}] in {os.path.relpath(p, root)}")
            elif t in text:
                hits += 1; errors.append(f"守門命中 [{t}] in {os.path.relpath(p, root)}")
    return len(toks), hits


def main():
    if len(sys.argv) < 2: sys.exit(__doc__)
    root = sys.argv[1]; guard = None
    if "--guard-tokens" in sys.argv: guard = sys.argv[sys.argv.index("--guard-tokens") + 1]
    errors = []
    for loc in LOCALES: check_locale(root, loc, errors)
    n_shots = check_screenshots(root, errors)
    guard_line = "（未給 --guard-tokens，守門未跑）"
    if guard:
        nt, nh = check_guard(root, guard, errors); guard_line = f"守門 token {nt}（白名單已排除 {len(GUARD_GENERIC)} 個通用詞）、命中 {nh}"
    print(f"locales {len(LOCALES)}、screenshots {n_shots}、{guard_line}")
    if errors:
        print("❌ " + "\n❌ ".join(errors)); sys.exit(1)
    print("✅ docs/store 全過")


if __name__ == "__main__":
    main()
