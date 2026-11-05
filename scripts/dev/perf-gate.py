#!/usr/bin/env python3
"""GATE-04(TEST_PLAN AA 節,2026-11-05):每個 build 必跑的 UX 效能閘。

一鍵:build 隔離的 Debug 測試 app(bundle id 後綴 perfgate、裝到 ~/Library/Caches/MyParrot-perfgate/app)→ 用回放檔當音源
(MYPARROT_REPLAY,不碰麥克風／系統音訊、不需 TCC)開錄 → 量待錄音／錄音中／打字中的 CPU、主執行緒 render 樣本、卡頓偵測器
stall → 停錄後驗兩軌 RMS、即時稿行數、sidecar → 對門檻判紅綠、印表、寫 reports/<時間>.md。exit 0＝全綠。

用法:scripts/dev/perf-gate.py [--engine apple|whisper] [--audio <m4a>] [--skip-build] [--record-seconds 60]
                               [--type-seconds 30] [--cps 8] [--no-positive-control] [--keep-app]
門檻(Debug 組態;數字來自 11/04 最終版再放兩三成餘裕,見 TEST_PLAN AA 節 GATE-04):
  apple  :待錄音 CPU ≤20%、render ≤250;錄音不打字 CPU ≤30%、render ≤300、stall＝0、p95 ≤20 ms;打字 stall ≤2、max ≤150 ms
  whisper:錄音不打字 CPU ≤60%、stall ≤2,其餘同 apple(需本機已有 large-v3 模型)
  產物   :兩軌 RMS 各 ≥ −40 dBFS 且與來源同段差 ≤3 dB、錄音長度差 ≤1 s、.txt ≥ 1 行／10 s、.srt 與 .notes.md 在、lastError 空
量不到的(明列,見 GATE-09):IME 組字、藍牙／裝置切換、TCC 拒絕、真會議長時負載。
🔒 隔離:只動 ~/Library/Caches/MyParrot-perfgate/ 底下的東西;跑前跑後比對 tw.uncle.MyParrot 偏好域與 ~/Documents/MyParrot 檔名清單,變了就紅。
"""
import argparse, datetime, fcntl, json, os, pathlib, re, shutil, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = pathlib.Path.home() / "Library/Caches/MyParrot-perfgate"
APP_DIR, CTL_DIR, REC_DIR, REPORTS = GATE / "app", GATE / "ctl", GATE / "recordings", GATE / "reports"
APP = APP_DIR / "MyParrot.app"
BIN = APP / "Contents/MacOS/MyParrot"
CTL = GATE / "myparrotctl"
CHANNEL = "perfgate"
BUNDLE_ID = "tw.uncle.MyParrot.perfgate"
REAL_DOCS = pathlib.Path.home() / "Documents/MyParrot"

THRESH = {
    "apple":   dict(idle_cpu=20, idle_render=250, rec_cpu=30, rec_render=300, rec_stalls=0, rec_p95=20, type_stalls=2, type_max=150, stop_max=400),
    "whisper": dict(idle_cpu=20, idle_render=250, rec_cpu=60, rec_render=300, rec_stalls=2, rec_p95=20, type_stalls=2, type_max=150, stop_max=400),
}
# 已知問題(二審第三輪:不放寬門檻、不改通過語義;紅還是紅、exit 仍非 0,只在表上標出卡號,讓看表的人知道這條是已知):
# (issue_key, 引擎, 判斷式(metrics dict), 卡號)——只在「這列失敗的唯一原因就是該已知問題」時命中(二審第四輪:別從表格字串 regex 猜)。
KNOWN_ISSUES = [
    ("stop_stall", "whisper", lambda m: m.get("stalls", 99) <= 2 and 400 < m.get("max_ms", 0) <= 800, "#2737 Whisper 停錄收尾在主執行緒 619 ms"),
]
RMS_FLOOR_DB, RMS_DELTA_DB, DURATION_DELTA_S = -40.0, 3.0, 1.0

ENV = dict(os.environ, MYPARROT_DEBUG_CHANNEL=CHANNEL)
_ctl_n = 0


class GateAbort(Exception):
    """閘自己的預期失敗(build 失敗、app 沒起來、fail-closed 判定…):有報告、exit 2,不帶 traceback。"""


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ctl(*args, wait=15.0):
    """送一個 DebugControl 指令(只到 perfgate 頻道),自己輪詢結果檔(myparrotctl --wait 固定等 60 秒,太慢)。"""
    global _ctl_n
    _ctl_n += 1
    out = CTL_DIR / f"{_ctl_n:03d}-{args[0]}.json"
    if out.exists():
        out.unlink()
    r = subprocess.run([str(CTL), *map(str, args), str(out)], env=ENV, check=False, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"myparrotctl {' '.join(map(str, args))} 回 {r.returncode}:{r.stderr.strip()[:200]}")
    deadline = time.time() + wait
    while time.time() < deadline:
        if out.exists() and out.stat().st_size > 0:
            try:
                return json.loads(out.read_text())
            except json.JSONDecodeError:
                time.sleep(0.1)
                continue
        time.sleep(0.1)
    raise TimeoutError(f"myparrotctl {' '.join(map(str, args))}:{wait:.0f} 秒沒結果檔")


def require_ok(name, result, fields=()):
    """二審:控制與量測回應一律 fail closed——不是 ok:true 就炸;要的數字欄位缺了或不是數字也炸,🚫 不准 `.get(...) or 0`。"""
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise RuntimeError(f"{name} 失敗:{result!r}")
    missing = [f for f in fields if not isinstance(result.get(f), (int, float)) or isinstance(result.get(f), bool)]
    if missing:
        raise RuntimeError(f"{name} 缺量測欄位 {missing}:{result!r}")
    return result


STALL_FIELDS = ("stalls", "maxMs", "p95Ms", "pings")


def stalls(name):
    """perf stalls 讀數,四個欄位都要在;pings 為 0 代表偵測器根本沒在量,也算失敗。"""
    r = require_ok(name, ctl("perf", "stalls"), STALL_FIELDS)
    if r["pings"] <= 0:
        raise RuntimeError(f"{name}:watchdog pings=0,偵測器沒在量")
    return r


def gate_pids():
    r = sh(["pgrep", "-f", str(BIN)])
    if r.returncode == 0:
        return [int(x) for x in r.stdout.split()]
    if r.returncode == 1:
        return []   # 沒有符合的行程
    raise RuntimeError(f"pgrep 失敗 rc={r.returncode}:{r.stderr.strip()[:120]}")   # 工具失效 ≠ 沒有 pid(二審第四輪)


def fmt_cpu(c):
    return "量不到" if c != c else f"{c:.1f}"   # NaN ⇒ 量測工具失效,跟「超標」分開看(二審第三輪)


def cpu_percent(pid, samples=3):
    """top 連取 samples+1 筆(第一筆不準丟掉),回(平均, 最大)。"""
    r = sh(["top", "-l", str(samples + 1), "-s", "1", "-pid", str(pid), "-stats", "cpu"])
    vals = [float(m.group(1)) for m in re.finditer(r"^\s*(\d+(?:\.\d+)?)\s*$", r.stdout, re.M)]
    vals = vals[1:] if len(vals) > 1 else vals
    if not vals:
        return (float("nan"), float("nan"))
    return (sum(vals) / len(vals), max(vals))


def sample_render(pid, seconds=5):
    """`sample` 主執行緒 5 秒,回 ViewGraphRootValueUpdater.render 的最大樣本數(頂層那一筆就是整窗 pass 的總數)。"""
    f = CTL_DIR / f"sample-{time.time_ns()}.txt"
    r = sh(["sample", str(pid), str(seconds), "-file", str(f)])
    if r.returncode != 0 or not f.exists() or f.stat().st_size == 0:
        return None   # 二審:量不到就是量不到,不准當 0
    txt = f.read_text(errors="ignore")
    if "Call graph" not in txt and "Thread_" not in txt:
        return None
    hits = [int(m.group(1)) for m in re.finditer(r"(\d+)\s+\S*ViewGraphRootValueUpdater\.render", txt)]
    # 符號改名／SwiftUI 換版會讓命中為空 ⇒ 一律 None(量不到),不猜 0(二審第二輪)。GUI app 待機 5 s 內一定有 render。
    return max(hits) if hits else None


def ffprobe_duration(path):
    r = sh(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)])
    return float(r.stdout.strip() or "nan")


def rms_db(path, seconds=None):
    """每聲道 RMS dBFS(ffmpeg astats);seconds 給了只量前 N 秒(跟錄音同段比)。"""
    cmd = ["ffmpeg", "-nostats", "-hide_banner"]
    if seconds:
        cmd += ["-t", f"{seconds:.3f}"]
    cmd += ["-i", str(path), "-af", "astats=metadata=1:reset=0", "-f", "null", "-"]
    r = sh(cmd)
    out = []
    for block in re.split(r"Channel: ", r.stderr)[1:]:
        m = re.search(r"RMS level dB: (-?[\d.]+|-inf)", block)
        if m:
            out.append(float("-inf") if m.group(1) == "-inf" else float(m.group(1)))
    return out[:2]


def defaults_snapshot(domain):
    """(ok, 內容或錯誤)。二審第六輪:讀不到要讓比對列判紅,不能前後都 "<rc N>" 就當 same。"""
    r = sh(["defaults", "export", domain, "-"])
    return (r.returncode == 0, r.stdout if r.returncode == 0 else f"<rc {r.returncode}> {r.stderr.strip()[:80]}")


def docs_snapshot():
    try:
        return sorted(p.name for p in REAL_DOCS.iterdir())
    except FileNotFoundError:
        return []


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engine", choices=["apple", "whisper"], default="apple")
    ap.add_argument("--audio", type=pathlib.Path, default=GATE / "demo-dialogue.m4a")
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--record-seconds", type=int, default=60)
    ap.add_argument("--type-seconds", type=int, default=30)
    ap.add_argument("--cps", type=float, default=8)
    ap.add_argument("--no-positive-control", action="store_true")
    ap.add_argument("--keep-app", action="store_true", help="跑完不 quit 測試 app(要看畫面時)")
    ap.add_argument("--allow-external-audio", action="store_true",
                    help="允許閘的快取夾以外的音檔(例如 Eric 指定的真錄音;逐字稿會留在閘的錄音夾與報告,B3 的 release 前一次用)")
    a = ap.parse_args()
    T = THRESH[a.engine]
    # fail fast:參數範圍(二審第四輪:cps 0 ⇒ n_chars 0 空工作量也會「過」)
    if not 20 <= a.record_seconds <= 300:
        ap.error("--record-seconds 要 20～300")
    if not 1 <= a.type_seconds <= 120:
        ap.error("--type-seconds 要 1～120")
    if not 0.5 <= a.cps <= 50:
        ap.error("--cps 要 0.5～50(app 端同樣夾在這個範圍)")

    rows, red = [], []

    def esc(v):
        t = str(v).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
        if a.allow_external_audio:
            t = t.replace(str(a.audio), "<外部音檔>")   # 二審第五輪:宣稱不印就全表都不印
            if a.audio.name:
                t = t.replace(a.audio.name, "<外部音檔>")
        return t

    def row(name, value, ok, note="", issue_key=None, metrics=None):
        rows.append((esc(name), esc(value), "✅" if ok else "❌", esc(note), issue_key, metrics or {}))
        if not ok:
            red.append(name)

    # 單例鎖:同一台同時跑兩個閘會互刪目錄、互收 app(固定頻道／固定 id)。flock 持有到程序結束:
    # 沒有 TOCTOU、沒有 PID 重用問題、程序死掉鎖自動放(二審第四輪)。🔴 鎖要在任何 GATE 內的清理之前拿——
    # 後來者拿不到鎖也不准先把先行者的錄音夾／控制回應刪掉(二審第五輪);鎖之前只建 GATE 本身與 lock 檔。
    aborted = None
    prefs_before = docs_before = None
    lock_fd = None
    have_lock = False   # 🔴 沒拿到鎖(BUSY)就什麼都不准碰:11/05 實測 BUSY 實例的 finally 把正在跑的那支測試 app quit 掉了
    kept_marker = GATE / "keep-app.pid"
    try:
        # 鎖初始化也在報告結構內:權限錯、lock 是目錄、被占用都出報告(BUSY／ABORTED)再 exit 2(二審第六輪)。
        GATE.mkdir(parents=True, exist_ok=True)
        lock_path = GATE / "lock"
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_WRONLY | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise GateAbort(f"❌ BUSY:另一個 perf-gate 還在跑(持有 {lock_path});等它結束")
        have_lock = True
        os.ftruncate(lock_fd, 0)
        os.lseek(lock_fd, 0, os.SEEK_SET)
        os.write(lock_fd, str(os.getpid()).encode())
        # 上一輪 --keep-app 留下的 app 還活著 ⇒ 共用夾、頻道、id 都還被它用,這輪不准動(二審第六輪)。
        if kept_marker.exists():
            try:
                kept = int(kept_marker.read_text().strip() or "0")
            except ValueError:
                kept = 0
            if kept and kept in gate_pids():
                raise GateAbort(f"❌ BUSY:上一輪 --keep-app 保留的測試 app(pid {kept})還開著;先 quit 它(或 kill {kept})再跑")
            kept_marker.unlink()
        # 持鎖後才清上一輪的錄音夾與控制回應(這段也在報告保證結構內:失敗照樣出 ABORTED 報告)
        for d in (APP_DIR, CTL_DIR, REPORTS):
            d.mkdir(parents=True, exist_ok=True)
        if REC_DIR.exists():
            shutil.rmtree(REC_DIR)
        REC_DIR.mkdir(parents=True)
        for f in CTL_DIR.glob("*"):
            shutil.rmtree(f) if f.is_dir() else f.unlink()
        # 隔離基線在任何會動到 app 的動作之前抓;不管 _run 在哪一步失敗,finally 都比(二審第四輪)。
        prefs_before = defaults_snapshot("tw.uncle.MyParrot")
        docs_before = docs_snapshot()
        _run(a, T, rows, red, row)
    except GateAbort as e:
        aborted = f"{e}\n"
        row("閘自己中斷(預期失敗)", str(e)[:200], False, "fail closed")
    except Exception as e:   # noqa: BLE001 — 其他例外也要收 app、寫報告(KeyboardInterrupt／SystemExit 照常往外丟)
        import traceback
        aborted = traceback.format_exc()
        row("閘自己中斷", f"{type(e).__name__}: {e}", False, "見報告末 traceback")
    finally:
        # 三段各自捕例外:收 app 壞了不得跳過兩項隔離比對(二審第五輪)。沒拿到鎖 ⇒ 整段跳過(app、夾、鎖都是別人的)。
        if not have_lock:
            row("未持鎖,不收 app、不比隔離", "BUSY 或鎖初始化失敗", False, "共用夾／app 屬於正在跑的那一輪")
        elif not a.keep_app:
            try:
                try:
                    ctl("quit", wait=5)
                except Exception:   # noqa: BLE001 — app 退出前不一定來得及寫結果檔;下面以 pid 消失為準
                    pass
                for _ in range(20):
                    if not gate_pids():
                        break
                    time.sleep(0.5)
                for p in gate_pids():
                    sh(["kill", "-TERM", str(p)])
                time.sleep(1)
                left = gate_pids()
                row("測試 app 已收", "是" if not left else f"殘留 pid {left}", not left)
                if not left and kept_marker.exists():
                    kept_marker.unlink()
            except Exception as e:   # noqa: BLE001
                row("收 app 失敗", f"{type(e).__name__}: {e}"[:200], False)
        else:
            # --keep-app:app 還開著,偏好沒寫回,「quit 後比」不成立 ⇒ 這輪不得當全綠(二審第五輪);
            # 留標記讓下一輪知道共用夾還被它用著、不准動(第六輪)。
            try:
                kept_marker.write_text(" ".join(str(p) for p in gate_pids()))
            except OSError:
                pass
            row("隔離驗證(--keep-app)", "app 未退出,未驗;下一輪會被擋到它退出", False, "keep-app 模式結果標 UNVERIFIED")
        # 隔離比對放在 quit 之後:偏好是 app 退出時才寫回網域,早比會漏(二審第三輪);不管 _run 走到哪都比(第四輪)。
        if have_lock and prefs_before is not None:
            try:
                prefs_after = defaults_snapshot("tw.uncle.MyParrot")
                both_ok = prefs_before[0] and prefs_after[0]
                same = both_ok and prefs_after[1] == prefs_before[1]
                row("隔離:偏好域 tw.uncle.MyParrot 未變(quit 後比)",
                    ("same" if same else "CHANGED") if both_ok else f"讀不到:前 {prefs_before[1][:40]!r} 後 {prefs_after[1][:40]!r}",
                    same, "只比 GitHub 版網域;.mas 容器從 shell 讀不到(會跳授權框)不比;讀不到＝紅")
            except Exception as e:   # noqa: BLE001
                row("隔離:偏好域比對失敗", f"{type(e).__name__}: {e}"[:200], False)
            try:
                docs_after = docs_snapshot()
                row("隔離:~/Documents/MyParrot 第一層檔名未變", "same" if docs_after == docs_before else "CHANGED", docs_after == docs_before,
                    "只比第一層檔名,不比內容／mtime")
            except Exception as e:   # noqa: BLE001
                row("隔離:Documents 比對失敗", f"{type(e).__name__}: {e}"[:200], False)
        elif have_lock:
            row("隔離基線沒抓到", "鎖後初始化失敗(見中斷列)", False)
        if lock_fd is not None:
            try:
                if have_lock:
                    fcntl.flock(lock_fd, fcntl.LOCK_UN)
                os.close(lock_fd)   # 沒持鎖也要關 fd(不 unlock,鎖是別人的)
            except OSError:
                pass
    _report(a, rows, red, aborted)


def _report(a, rows, red, aborted):
    """永遠產報告:寫檔失敗就把全文印到 stderr、exit 2(二審第三輪);檔名帶毫秒＋pid 不互蓋;先寫暫存再 rename。"""
    try:
        stamp = sh(["git", "-C", str(ROOT), "log", "-1", "--format=%h"]).stdout.strip() or "?"
    except Exception:   # noqa: BLE001
        stamp = "?"
    now = datetime.datetime.now()
    # 已知問題只改「判」欄的標示(⚠️ 已知 #卡),紅還是紅、exit 仍非 0——不放寬門檻、不改通過語義。
    known_hit = []
    marked = []
    for n, v, o, t, key, metrics in rows:
        tag = o
        if o == "❌" and key:
            for issue_key, eng, pred, card in KNOWN_ISSUES:
                if key == issue_key and eng == a.engine and pred(metrics):
                    tag = f"❌ 已知({card})"
                    known_hit.append(card)
        marked.append((n, v, tag, t))
    unverified = a.no_positive_control or a.keep_app
    if aborted:
        verdict = "ABORTED"
    elif unverified:
        verdict = "UNVERIFIED(跳過正控或 keep-app,不算全綠)"
    elif not red:
        verdict = "全綠"
    else:
        verdict = f"紅 {len(red)}" + (f"(其中已知 {len(known_hit)})" if known_hit else "")
    audio_label = "(外部音檔,不印檔名)" if a.allow_external_audio else a.audio.name
    head = f"## perf-gate {now:%Y-%m-%d %H:%M} · {stamp} · engine={a.engine} · audio={audio_label} · {verdict}\n\n"
    table = "| 項 | 值 | 判 | 門檻 |\n|---|---|---|---|\n" + "\n".join(f"| {n} | {v} | {o} | {t} |" for n, v, o, t in marked) + "\n"
    if aborted and a.allow_external_audio:
        aborted = aborted.replace(str(a.audio), "<外部音檔>")
        if a.audio.name:
            aborted = aborted.replace(a.audio.name, "<外部音檔>")
    out = head + table + (f"\n```\n{aborted}```\n" if aborted else "")
    rp = REPORTS / f"{now:%Y%m%d-%H%M%S}-{now.microsecond // 1000:03d}-{os.getpid()}-{a.engine}.md"
    try:
        REPORTS.mkdir(parents=True, exist_ok=True)
        tmp = rp.with_suffix(".md.tmp")
        tmp.write_text(out)
        os.replace(tmp, rp)
        where = str(rp)
    except OSError as e:
        sys.stderr.write(f"❌ 報告寫不出來({e}),全文如下:\n{out}\n")
        where = "(未落檔)"
        aborted = aborted or f"report write failed: {e}"
    print(out)
    if aborted:
        print(f"❌ 閘中斷  → {where}")
        sys.exit(2)
    if unverified:
        print(f"⚠️ 未驗證(--no-positive-control／--keep-app):結果不得當全綠  → {where}")
        sys.exit(2)
    print(("✅ 全綠" if not red else "❌ 紅:" + "、".join(red) + ("  (已知:" + "、".join(known_hit) + ")" if known_hit else "")) + f"  → {where}")
    sys.exit(0 if not red else 1)


def _run(a, T, rows, red, row):
    """主流程;回測試 app 的 pid 給 finally 收尾。"""

    # 1. build(隔離 id)+ctl
    if not a.skip_build:
        env = dict(os.environ, MYPARROT_BUNDLE_SUFFIX="perfgate", MYPARROT_DEST_DIR=str(APP_DIR))
        r = subprocess.run(["bash", "scripts/build-app.sh", "debug"], cwd=ROOT, env=env, capture_output=True, text=True)
        (GATE / "build.log").write_text(r.stdout + r.stderr)
        if r.returncode != 0:
            print(r.stdout[-2000:], r.stderr[-2000:])
            raise GateAbort("❌ build 失敗,見 " + str(GATE / "build.log"))
    plist = APP / "Contents/Info.plist"
    bid = sh(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(plist)]).stdout.strip()
    if bid != BUNDLE_ID:
        raise GateAbort(f"❌ 測試 app 的 bundle id 是 {bid!r},應為 {BUNDLE_ID}(fail closed:不准拿正式 id 跑閘)")
    src = ROOT / "scripts/dev/myparrotctl.swift"
    if not CTL.exists() or CTL.stat().st_mtime < src.stat().st_mtime:
        r = sh(["swiftc", "-O", str(src), "-o", str(CTL)])
        if r.returncode != 0:
            raise GateAbort("❌ myparrotctl 編不過:" + r.stderr[-800:])
    # 二審第二輪:先判路徑授權,再決定要不要生成——否則外部路徑會先被 make-demo-audio.sh 寫出檔案才被拒。
    a.audio = a.audio.expanduser().resolve()
    if GATE.resolve() not in a.audio.parents and not a.allow_external_audio:
        raise GateAbort(f"❌ 音檔 {a.audio} 不在 {GATE} 底下;真錄音要明講 --allow-external-audio(逐字稿會留在閘的夾)")
    if a.audio.exists() and not a.audio.is_file():
        raise GateAbort("❌ 音檔不是一般檔案(目錄／裝置／空檔名)")
    if not a.audio.exists():
        if a.allow_external_audio:
            raise GateAbort(f"❌ 外部音檔不存在:{a.audio}(閘只會在自己的快取夾生成合成對話)")
        r = subprocess.run(["bash", str(ROOT / "scripts/dev/make-demo-audio.sh"), str(a.audio)], capture_output=True, text=True)
        if r.returncode != 0 or not a.audio.exists():
            raise GateAbort("❌ 合成音檔失敗:" + r.stdout[-800:] + r.stderr[-800:])
    audio_dur = ffprobe_duration(a.audio)
    need = a.record_seconds + a.type_seconds + 10
    if audio_dur < need:
        raise GateAbort(f"❌ 回放檔只有 {audio_dur:.0f} s,閘要 {need} s(make-demo-audio.sh --rounds 加長)")

    # 2. 隔離基線在 main 抓(進 _run 之前)。

    # 3. 收掉上一次沒收乾淨的測試 app(只殺這個路徑的 pid,是閘自己開的)
    for pid in gate_pids():
        sh(["kill", "-TERM", str(pid)])
    time.sleep(1)

    # 4. 啟動(回放檔＋獨立頻道＋錄音夾指到閘的夾;argument domain 寫回偏好也只寫到 perfgate 自己的域)
    launch = ["open", "-n", "-a", str(APP), "--env", f"MYPARROT_REPLAY={a.audio}", "--env", f"MYPARROT_DEBUG_CHANNEL={CHANNEL}",
              "--args", "-recordingsDir", str(REC_DIR), "-debugSkipPermissionRequest", "YES", "-modelHintShown", "YES"]
    r = sh(launch)
    if r.returncode != 0:
        raise GateAbort("❌ open 失敗:" + r.stderr)
    pid = None
    for _ in range(40):
        p = gate_pids()
        if p:
            pid = p[0]
            break
        time.sleep(0.5)
    if pid is None:
        raise GateAbort("❌ 測試 app 20 秒內沒起來")
    st = None
    for _ in range(30):
        try:
            st = ctl("state", wait=2)
            if st.get("ok"):
                break
        except TimeoutError:
            pass
    if not st or not st.get("ok"):
        raise GateAbort("❌ DebugControl 30 秒內沒回 state")
    row("錄音夾＝閘的夾", str(st.get("recordingsDir")), str(st.get("recordingsDir")) == str(REC_DIR), "fail closed")
    rs = require_ok("replay status", ctl("replay", "status"))
    row("回放檔已設定(下一場用)", "configured=yes" if rs.get("configuredReplay") == str(a.audio) else f"configured≠音檔({rs.get('configuredReplay', '')})",
        rs.get("configuredReplay") == str(a.audio), f"{audio_dur:.0f} s")

    # 5. 引擎
    eng = "appleNative" if a.engine == "apple" else "whisperKit"
    require_ok("engine set", ctl("engine", "set", eng))
    eg = require_ok("engine get", ctl("engine", "get"))
    row("引擎", str(eg.get("engine", eg)), str(eg.get("engine", "")) == eng)

    # 6. 待錄音
    time.sleep(8)
    idle_cpu = cpu_percent(pid)
    idle_render = sample_render(pid)
    row("待錄音 CPU 平均／最大 %", f"{fmt_cpu(idle_cpu[0])}／{fmt_cpu(idle_cpu[1])}", idle_cpu[0] <= T["idle_cpu"], f"≤{T['idle_cpu']}")
    row("待錄音 render 樣本／5 s", str(idle_render), idle_render is not None and idle_render <= T["idle_render"], f"≤{T['idle_render']}(None＝量不到)")

    # 7. 錄音不打字
    require_ok("perf reset", ctl("perf", "reset"))
    rec = require_ok("record", ctl("record"))
    t_rec = time.time()
    if "state" in rec and str(rec["state"]) not in ("recording", "idle", "finished"):
        raise GateAbort(f"❌ record 回應狀態異常:{rec}")
    st = require_ok("state", ctl("state"))
    row("開錄後狀態", str(st.get("state")), str(st.get("state")) == "recording")
    ra = require_ok("replay status", ctl("replay", "status"))
    row("這一場正在播的回放檔", "active=yes" if ra.get("activeReplay") == str(a.audio) and ra.get("active") is True else f"active≠音檔({ra.get('activeReplay', '')})",
        ra.get("activeReplay") == str(a.audio) and ra.get("active") is True)
    # 錄音夾要是閘的夾:inprogress 要長在 REC_DIR 底下(fail closed:絕不能寫進 ~/Documents/MyParrot)
    time.sleep(3)
    inprog = list(REC_DIR.rglob("*inprogress*")) + list(REC_DIR.glob(".myparrot/**/*"))
    row("錄音落在閘的夾", f"{len(inprog)} 個項目", len(inprog) > 0, str(REC_DIR))
    # 開錄瞬間(開檔、起引擎、寫 state)是一次性的主執行緒工作,跟「錄音中穩態」分開量:前 3 s 允許 ≤2 次、≤400 ms,之後歸零重算。
    p0 = stalls("開錄瞬間 perf stalls")
    row("開錄瞬間 stall(前 3 s)", f"{p0['stalls']}(max {p0['maxMs']:.0f} ms)", p0["stalls"] <= 2 and p0["maxMs"] <= 400, "≤2、max ≤400 ms")
    require_ok("perf reset", ctl("perf", "reset"))
    time.sleep(max(0, 17 - (time.time() - t_rec)))
    rec_cpu = cpu_percent(pid)
    rec_render = sample_render(pid)
    remain = a.record_seconds - (time.time() - t_rec)
    if remain > 0:
        time.sleep(remain)
    pf = stalls("錄音穩態 perf stalls")
    row("錄音 CPU 平均／最大 %", f"{fmt_cpu(rec_cpu[0])}／{fmt_cpu(rec_cpu[1])}", rec_cpu[0] <= T["rec_cpu"], f"≤{T['rec_cpu']}")
    row("錄音 render 樣本／5 s", str(rec_render), rec_render is not None and rec_render <= T["rec_render"], f"≤{T['rec_render']}(None＝量不到)")
    row(f"錄音穩態 {a.record_seconds - 3} s stall(>100 ms)", f"{pf['stalls']}(max {pf['maxMs']:.0f} ms,pings {pf['pings']})",
        pf["stalls"] <= T["rec_stalls"], f"≤{T['rec_stalls']}")
    row("錄音 p95 ms", f"{pf['p95Ms']:.1f}", pf["p95Ms"] <= T["rec_p95"], f"≤{T['rec_p95']}")

    # 8. 正控:故意卡 300 ms 一定要被記到(閘的尺自己要能量到)
    if not a.no_positive_control:
        require_ok("perf reset", ctl("perf", "reset"))
        require_ok("perf block", ctl("perf", "block", "300"))
        pc = stalls("正控 perf stalls")
        # 偵測器每 100 ms 探一次,300 ms 的卡最壞只量到 ≈200 ms(ping 剛好在卡之前送出)⇒ 下限 180,不是 300。
        row("正控 perf block 300", f"stalls {pc['stalls']}、max {pc['maxMs']:.0f} ms",
            pc["stalls"] >= 1 and pc["maxMs"] >= 180, "≥1、≥180 ms(300 − ping 100)")

    # 9. 打字
    require_ok("perf reset", ctl("perf", "reset"))
    base = "今天先對三個議題,上線時間、量測結果與客戶回饋。後端完成八成,剩錯誤處理;介面改版下個版本一起出。風險是外部服務回應不穩,備案切本機快取。"
    n_chars = int(a.type_seconds * a.cps)
    text = (base * (n_chars // len(base) + 1))[:n_chars]
    ty = require_ok("notes type", ctl("notes", "type", text, str(a.cps)), ("etaSeconds", "chars"))
    eta = float(ty["etaSeconds"])
    time.sleep(eta + 2)
    pt = stalls("打字 perf stalls")
    row(f"打字 {a.type_seconds} s×{a.cps:g} 字元/s stall", f"{pt['stalls']}(max {pt['maxMs']:.0f} ms)",
        pt["stalls"] <= T["type_stalls"] and pt["maxMs"] <= T["type_max"], f"≤{T['type_stalls']}、max ≤{T['type_max']} ms")
    notes = require_ok("notes get", ctl("notes", "get"))
    row("筆記字數", str(len(notes.get("text", ""))), len(notes.get("text", "")) >= n_chars * 0.9, f"≥{int(n_chars * 0.9)}")

    # 9b. 正控二:storm——裝飾時鐘催到 120 Hz(修前「高頻狀態變動 ⇒ 每幀整窗 pass」同一機制),render 或 CPU 必須爆門檻,否則尺有問題
    if not a.no_positive_control:
        require_ok("perf storm on", ctl("perf", "storm", "120"))
        time.sleep(3)
        s_cpu = cpu_percent(pid)
        s_render = sample_render(pid)
        require_ok("perf storm off", ctl("perf", "storm", "off"))
        time.sleep(2)
        # render 尺要「量得到」且「量到爆」;CPU 只當參考,不准拿 CPU 爆門檻掩護 render parser 失效(二審)。
        row("正控 storm 120 Hz:render／CPU", f"{s_render}／{s_cpu[0]:.1f}%",
            s_render is not None and s_render > T["rec_render"], f"render >{T['rec_render']}(CPU 參考 >{T['rec_cpu']})")

    # 10. 停錄、產物(停錄瞬間的發布／sidecar 寫入也是一次性主執行緒工作,單獨量)
    rec_len = time.time() - t_rec
    rp = require_ok("replay status", ctl("replay", "status"), ("sentChunks", "totalChunks", "maxLateMs"))
    expected = int(rec_len / 0.1)   # 閘不暫停 ⇒ 送出的塊數應接近經過秒數×10(二審第二輪:timer 沒跑時 0/N 也不能綠)
    row("回放源狀態(停錄前)",
        f"送 {rp['sentChunks']}/{rp['totalChunks']} 塊(預期≈{expected})、最大落後 {rp['maxLateMs']:.0f} ms、error={rp.get('error') or '無'}",
        rp.get("active") is True and rp.get("finished") is False and not rp.get("error")
        and rp["totalChunks"] > 0 and max(1, expected - 10) <= rp["sentChunks"] <= min(rp["totalChunks"], expected + 10) and rp["maxLateMs"] <= 250,
        "仍在播、無錯、進度 ≈ 經過秒數×10(±10 塊)、落後 ≤250 ms")
    require_ok("perf reset", ctl("perf", "reset"))
    require_ok("stop", ctl("stop"))
    time.sleep(6)
    ps_ = stalls("停錄瞬間 perf stalls")
    row("停錄瞬間 stall", f"{ps_['stalls']}(max {ps_['maxMs']:.0f} ms)", ps_["stalls"] <= 2 and ps_["maxMs"] <= T["stop_max"],
        f"≤2、max ≤{T['stop_max']} ms", issue_key="stop_stall", metrics={"stalls": ps_["stalls"], "max_ms": ps_["maxMs"]})
    st = require_ok("state", ctl("state"))
    row("停錄 lastError", str(st.get("lastError") or "null"), not st.get("lastError"))
    m4as = sorted(REC_DIR.glob("*.m4a"), key=lambda p: p.stat().st_mtime)
    cafs = sorted(REC_DIR.glob("*.caf"), key=lambda p: p.stat().st_mtime)
    rec_file = (m4as or cafs or [None])[-1]
    if rec_file is None:
        row("錄音檔", "沒有", False)
    else:
        d = ffprobe_duration(rec_file)
        row("錄音長度 s", f"{d:.1f}(錄了 {rec_len:.1f})", abs(d - rec_len) <= DURATION_DELTA_S, f"差 ≤{DURATION_DELTA_S}")
        got = rms_db(rec_file)
        ref = rms_db(a.audio, seconds=d)
        # 二審:整段 RMS 相近證明不了聲道沒互換——合成對話開頭 3 s 只有對方(L)在講,錄音與來源都要「L 比 R 大 ≥10 dB」。
        g3, r3 = rms_db(rec_file, seconds=2.5), rms_db(a.audio, seconds=2.5)
        if len(g3) == 2 and len(r3) == 2:
            row("聲道識別(前 2.5 s L−R dB)", f"錄音 {g3[0] - g3[1]:.1f}、來源 {r3[0] - r3[1]:.1f}",
                (g3[0] - g3[1]) >= 10 and (r3[0] - r3[1]) >= 10, "兩邊都 ≥10(合成對話第一句是對方;來源自己也要過)")
        else:
            row("聲道識別(前 2.5 s)", f"{g3}/{r3}", False)
        if len(got) == 2 and len(ref) == 2:
            for i, name in enumerate(("對方(L)", "你(R)")):
                ok = got[i] >= RMS_FLOOR_DB and abs(got[i] - ref[i]) <= RMS_DELTA_DB
                row(f"{name} RMS dBFS", f"{got[i]:.1f}(來源同段 {ref[i]:.1f})", ok, f"≥{RMS_FLOOR_DB:.0f} 且差 ≤{RMS_DELTA_DB:.0f}")
        else:
            row("兩軌 RMS", f"{got}/{ref}", False)
        stem = rec_file.with_suffix("")
        txt = pathlib.Path(str(stem) + ".txt")
        lines = len([l for l in txt.read_text(errors="ignore").splitlines() if l.strip()]) if txt.exists() else 0
        row("即時稿 .txt 行數", str(lines), lines >= a.record_seconds // 10, f"≥{a.record_seconds // 10}")
        row(".srt 在", str(pathlib.Path(str(stem) + ".srt").exists()), pathlib.Path(str(stem) + ".srt").exists())
        row(".notes.md 在", str(pathlib.Path(str(stem) + ".notes.md").exists()), pathlib.Path(str(stem) + ".notes.md").exists())

    # 11. 收 app 與隔離比對都在 main 的 finally(quit 之後才比,偏好退出時才寫回)。


if __name__ == "__main__":
    main()
