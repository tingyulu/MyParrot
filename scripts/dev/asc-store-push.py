#!/usr/bin/env python3
"""把 docs/store/ 的商店資料寫進 App Store Connect（MAS-36；Eric 2026-10-31 C1；二審擋下後改版）。

用法：python3 -I scripts/dev/asc-store-push.py [--apply --manifest <sha>] [--only a,b,...] [--store docs/store]
  預設 dry-run：只 GET、列出每個欄位「現值 → 目標值」、印出 execution manifest（docs/store 內容＋本次 --only＋所有寫入常數＋腳本規則版本＋聯絡人檔摘要），不寫。
  --apply：真寫，必須帶同一組 dry-run 印出的 --manifest（內容、段、常數任一不同就擋）；每筆寫入前都先 GET 比對，相同就跳過（第二次 apply 應為 0 筆寫入）；同機同時只允許一個 apply（lock 檔）。
  --only：只處理這些段：app,categories,agerating,appinfo,version,versionloc,screenshots,review；price 不在預設，要 --only price 顯式跑。
寫的範圍（只有這些；🚫 不碰 builds、appStoreVersionSubmissions、availability、App Privacy）：
  apps.contentRightsDeclaration｜appInfos 主／次類別｜ageRatingDeclaration 全「無」｜appInfoLocalizations ×9（name／subtitle／privacyPolicyUrl）
  appStoreVersion（versionString 只允許從 ASC 預設 1.0 或上一個目標 0.5.3 改成 0.5.5／copyright／releaseType MANUAL）｜appStoreVersionLocalizations ×9（五欄）
  appScreenshotSets APP_DESKTOP：以 MD5 判斷每個語系缺哪張（同名不同內容或 FAILED／沒 commit 的先刪再傳；多餘的不刪、停下來要人清）、傳完排順序
  appStoreReviewDetail（聯絡人＋notes）｜appPriceSchedule（Free；既有價格若不是 0 就停下來不自動改）
安全：鎖 Apple ID 6828903849 ＋ bundle tw.uncle.MyParrot.mas，不符 exit 1；恰好一個可編輯 appInfo 與 macOS 版本；聯絡人欄位終端只印遮蔽值。
聯絡人資料不進 repo：讀 ~/.private_keys/asc-contact.env（CONTACT_FIRST／CONTACT_LAST／CONTACT_PHONE／CONTACT_EMAIL，嚴格逐行解析，600）。
JWT／ID／.p8 檢查沿用 asc-api.py（同目錄，importlib 載入）。exit 0＝完成且驗證一致；1＝用法／守門／要人工處理；2＝API 或網路；3＝apply 後驗證不一致。
"""
import argparse, atexit, hashlib, importlib.util, json, os, re, stat, sys, tempfile, time, urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("asc_api", os.path.join(HERE, "asc-api.py"))
asc = importlib.util.module_from_spec(spec); spec.loader.exec_module(asc)

API = "https://api.appstoreconnect.apple.com"
APP_ID = "6828903849"
BUNDLE = "tw.uncle.MyParrot.mas"
APP_NAME = "MyParrot"
LOCALES = ["zh-Hant", "en-US", "ja", "ko", "zh-Hans", "es-ES", "de-DE", "fr-FR", "pt-BR"]
VERSION_STRING = "0.5.5"             # 11/05 Eric A1:送審 build 改從公開倉 v0.5.5 (12) 建,ASC 版本字串跟著 build 的 CFBundleShortVersionString
PREVIOUS_VERSION = "0.5.3"           # 10/30 寫進 ASC 的上一個目標;只允許從它或 ASC 預設改成 VERSION_STRING
ASC_DEFAULT_VERSION = "1.0"          # ASC 建 App 時的預設版本字串；只允許從它改成 VERSION_STRING
COPYRIGHT = "2026 TING YU Lu"
PRIVACY_URL = "https://github.com/tingyulu/MyParrot/blob/main/docs/PRIVACY.md"
PRIMARY_CATEGORY, SECONDARY_CATEGORY = "PRODUCTIVITY", "BUSINESS"
DEFAULT_SECTIONS = ["app", "categories", "agerating", "appinfo", "version", "versionloc", "screenshots", "review"]
ALL_SECTIONS = DEFAULT_SECTIONS + ["price"]
LIMITS = {"subtitle": 30, "promotional_text": 170, "description": 4000}   # 字元；keywords ≤100 bytes；notes ≤4000 bytes
AGE_NONE = {k: "NONE" for k in [
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons", "horrorOrFearThemes",
    "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor", "sexualContentGraphicAndNudity",
    "sexualContentOrNudity", "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic"]}
AGE_FALSE = {k: False for k in ["advertising", "ageAssurance", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat",
                                 "parentalControls", "socialMedia", "socialMediaAgeRestricted", "unrestrictedWebAccess", "userGeneratedContent"]}
AGE_TARGET = {**AGE_NONE, **AGE_FALSE, "ageRatingOverrideV2": "NONE", "koreaAgeRatingOverride": "NONE"}
SENSITIVE = {"contactFirstName", "contactLastName", "contactPhone", "contactEmail"}
SCRUB = []        # 聯絡人原值（含 JSON 轉義與 URL 編碼形式），印任何錯誤訊息前先遮掉
SCHEMA_VERSION = "2026-11-05.1"   # 腳本寫入規則版本，進 manifest
AGE_OTHER_KNOWN = {"kidsAgeBand", "ageRatingOverride", "gracRatingClassificationNumber", "developerAgeRatingInfoUrl"}  # 不動也不算「漏答」的欄位

LOG = []
PLANNED = 0      # 計畫的資源寫入（dry-run 與 apply 同一套計數）
DONE = 0         # apply 成功的資源寫入
MUTATIONS = 0    # apply 成功的 HTTP 變更總數（含每個 PUT 分片、commit PATCH、DELETE、排序）
APPLY = False
MANIFEST = ""


def scrub(text):
    for v in SCRUB:
        if v: text = text.replace(v, "<redacted>")
    return text


def add_scrub(v):
    if not v: return
    SCRUB.extend({v, json.dumps(v, ensure_ascii=True)[1:-1], json.dumps(v, ensure_ascii=False)[1:-1], urllib.parse.quote(v), urllib.parse.quote_plus(v)})


def read_regular(p, what):
    """O_NOFOLLOW 開檔 → fstat 驗一般檔 → 由同一個 fd 讀，檢查與讀取之間沒有換檔的空窗。回 (bytes, stat)。"""
    try: fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError: die(1, f"缺 {what}：{p}")
    except OSError as e:
        if e.errno in (getattr(os, "ELOOP", 62), 20): die(1, f"{what} 必須是一般檔（不接受 symlink）：{p}")
        die(1, f"{what} 開不了：{p}（{e}）")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode): os.close(fd); die(1, f"{what} 必須是一般檔（不接受 symlink）：{p}")
        with os.fdopen(fd, "rb") as fh: return fh.read(), st
    except OSError as e:
        die(1, f"{what} 讀取失敗：{p}（{e}）")


def die(code, msg):
    print("❌ " + scrub(msg), file=sys.stderr); sys.exit(code)


class ApiError(Exception):
    """API／網路錯誤；retryable 只對網路、429、5xx、404（剛建資源的可見性延遲）為 True；401／403／其他 4xx 不重試。"""
    def __init__(self, msg, status=None, retryable=False):
        super().__init__(msg); self.status, self.retryable = status, retryable


LOGFH = None   # apply 時 --log 開著的檔，每筆變更成功就立刻 append


class Client:
    def __init__(self):
        self.key_id, self.issuer = asc.load_ids()
        self.p8 = os.path.expanduser(f"~/.private_keys/AuthKey_{self.key_id}.p8")
        asc.check_p8(self.p8)
        self._tok, self._tok_at = None, 0

    def token(self):
        if not self._tok or time.time() - self._tok_at > 480:
            self._tok, self._tok_at = asc.jwt(self.key_id, self.issuer, self.p8), time.time()
        return self._tok

    def call(self, method, path, body=None, ok404=False):
        url = path if path.startswith("https://") else API + path
        data = json.dumps(body).encode() if body is not None else None
        hdr = {"Authorization": "Bearer " + self.token()}
        if data is not None: hdr["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=hdr)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as e:
            txt = e.read().decode("utf-8", errors="replace")
            if e.code == 404 and ok404: return None
            raise ApiError(f"{method} {path} → HTTP {e.code}\n{txt[:1500]}", e.code, retryable=e.code in (404, 429) or e.code >= 500)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ApiError(f"{method} {path} 網路錯誤：{e}", None, retryable=True)
        if not raw.strip(): return {}
        try: doc = json.loads(raw)
        except json.JSONDecodeError: raise ApiError(f"{method} {path} 回應不是 JSON：{raw[:300]}", None, retryable=True)
        if isinstance(doc, dict) and doc.get("errors"): raise ApiError(f"{method} {path} API errors：{json.dumps(doc['errors'], ensure_ascii=False)[:1500]}", None, False)
        return doc

    def get(self, path, ok404=False): return self.call("GET", path, ok404=ok404)

    def write(self, method, path, body, what):
        """apply 才真寫；dry-run 只記計畫。回傳回應（dry-run 回 None）。"""
        global PLANNED, DONE
        PLANNED += 1
        if not APPLY:
            print(f"   ✎ 計畫 {method} {path}  （{what}）"); return None
        doc = self.call(method, path, body)
        DONE += 1
        self._record(what, method, path, body)
        print(f"   ✅ {method} {path}  （{what}）")
        return doc

    def _record(self, what, method, path, body=None, extra=None):
        global MUTATIONS
        MUTATIONS += 1
        e = {"what": what, "method": method, "path": path.split("?")[0][:120], "body_sha": hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:12] if body is not None else None}
        if extra: e.update(extra)
        LOG.append(e)
        if LOGFH:
            LOGFH.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "manifest": MANIFEST, **e}, ensure_ascii=False) + "\n"); LOGFH.flush()

    def put_raw(self, url, data, headers, what):
        req = urllib.request.Request(url, data=data, method="PUT", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=300) as r: r.read()
        except urllib.error.HTTPError as e:
            raise ApiError(f"PUT 上傳失敗 HTTP {e.code}: {e.read().decode('utf-8', errors='replace')[:500]}", e.code, retryable=e.code in (429,) or e.code >= 500)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ApiError(f"PUT 上傳網路錯誤：{e}", None, retryable=True)
        self._record(what, "PUT", urllib.parse.urlsplit(url).netloc, None, {"bytes": len(data), "chunk_sha": hashlib.sha256(data).hexdigest()[:12]})


# ---------- docs/store ----------
FIELDS = ("name", "subtitle", "promotional_text", "description", "keywords", "support_url", "marketing_url")


def parse_md(path, text):
    """前言只接受恰好一行 `# 標題` 與完整的 <!-- ... --> 註解（可多行）；其他任何內容（含 ### 或 #xx）都拒絕。"""
    fields, cur, buf = {}, None, []
    title_seen, in_comment = False, False
    for line in text.splitlines():
        m = re.match(r"^## ([A-Za-z_]+)\s*$", line)
        if cur is None and not m:
            t = line.strip()
            if in_comment:
                if "-->" in t: in_comment = False; t = t.split("-->", 1)[1].strip()
                else: continue
            while t.startswith("<!--"):
                if "-->" in t: t = t.split("-->", 1)[1].strip()
                else: in_comment = True; t = ""
            if not t: continue
            if re.match(r"^# \S", t) and not title_seen: title_seen = True; continue
            die(1, f"{path}: 第一個 ## 欄位之前有不該出現的內容：{t[:60]}")
        if m:
            if cur: fields[cur] = "\n".join(buf).strip()
            cur, buf = m.group(1), []
            if cur not in FIELDS: die(1, f"{path}: 不認得的欄位 ## {cur}")
            if cur in fields: die(1, f"{path}: 欄位 ## {cur} 重複")
        elif cur is not None: buf.append(line)
    if cur: fields[cur] = "\n".join(buf).strip()
    return fields


def load_store(root):
    meta = {}
    for loc in LOCALES:
        p = os.path.join(root, "metadata", f"{loc}.md")
        f = parse_md(p, read_regular(p, f"{loc} 文案")[0].decode("utf-8"))
        for k in FIELDS:
            if not f.get(k): die(1, f"{loc}: 欄位 {k} 缺或空")
        if f["name"] != APP_NAME: die(1, f"{loc}: name 不是 {APP_NAME}")
        for k, lim in LIMITS.items():
            if len(f[k]) > lim: die(1, f"{loc}: {k} {len(f[k])} 字元 > {lim}")
        if len(f["keywords"].encode()) > 100: die(1, f"{loc}: keywords {len(f['keywords'].encode())} bytes > 100")
        for k in ("support_url", "marketing_url"):
            u = urllib.parse.urlsplit(f[k])
            if u.scheme != "https" or not u.netloc or "\n" in f[k]: die(1, f"{loc}: {k} 要完整 https:// URL")
        meta[loc] = f
    rn = read_regular(os.path.join(root, "review-notes.md"), "review-notes")[0].decode("utf-8").split("```")
    if len(rn) != 3: die(1, f"review-notes.md 要恰好一個 ``` 區塊（現在 {len(rn) // 2} 個）")
    notes = rn[1].strip()
    if len(notes.encode()) > 4000: die(1, "review notes 超過 4000 bytes")
    shots_dir = os.path.join(root, "screenshots")
    names = sorted(x for x in os.listdir(shots_dir) if x.lower().endswith(".png"))
    if not (1 <= len(names) <= 10): die(1, f"screenshots 有 {len(names)} 張（要 1～10）")
    shots = []
    for n in names:
        data = read_regular(os.path.join(shots_dir, n), f"截圖 {n}")[0]
        shots.append({"name": n, "data": data, "md5": hashlib.md5(data).hexdigest()})
    # manifest：所有會送出的內容
    h = hashlib.sha256()
    for loc in LOCALES:
        for k in FIELDS: h.update(f"{loc}.{k}=".encode() + meta[loc][k].encode() + b"\0")
    h.update(b"notes=" + notes.encode() + b"\0")
    for s in shots: h.update(f"shot {s['name']} ".encode() + s["md5"].encode() + b"\0")
    return meta, notes, shots, h.hexdigest()[:16]


def load_contact():
    p = os.path.expanduser("~/.private_keys/asc-contact.env")
    raw, st = read_regular(p, "聯絡人檔（CONTACT_FIRST／CONTACT_LAST／CONTACT_PHONE／CONTACT_EMAIL 四行）")
    if stat.S_IMODE(st.st_mode) & 0o077: die(1, f"{p} 權限太寬，chmod 600")
    if st.st_uid != os.getuid(): die(1, f"{p} 不是自己的檔")
    c = {"_digest": hashlib.sha256(raw).hexdigest()}
    for line in raw.decode("utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"): continue
        k, _, v = line.partition("=")
        if k not in ("CONTACT_FIRST", "CONTACT_LAST", "CONTACT_PHONE", "CONTACT_EMAIL"): die(1, f"{p} 不認得的鍵 {k}")
        c[k] = v.strip().strip('"')
    for k in ("CONTACT_FIRST", "CONTACT_LAST", "CONTACT_PHONE", "CONTACT_EMAIL"):
        if not c.get(k): die(1, f"{p} 缺 {k}")
    if not re.fullmatch(r"\+\d{8,15}", c["CONTACT_PHONE"]): die(1, "CONTACT_PHONE 要 +國碼數字")
    for k, v in c.items():
        if k != "_digest": add_scrub(v)
    return c


# ---------- diff 工具 ----------
def short(v, n=60):
    s = "∅" if v in (None, "") else str(v).replace("\n", "⏎")
    return s if len(s) <= n else s[:n] + f"…({len(str(v))})"


def show(k, v):
    if k in SENSITIVE: return "∅" if v in (None, "") else f"<遮蔽 {len(str(v))} 字>"
    return short(v)


def diff_attrs(label, current, target):
    """回傳只含有差異的目標欄位；逐欄印出（敏感欄位只印長度）。"""
    changes = {}
    for k, want in target.items():
        have = current.get(k)
        same = (have == want) or (have in (None, "") and want in (None, ""))
        print(f"   {label:<34} {k:<32} {show(k, have):<64} {'＝' if same else '→'} {show(k, want) if not same else ''}")
        if not same: changes[k] = want
    return changes


# ---------- 各段 ----------
def sec_app(c, app):
    print("\n## app（contentRightsDeclaration）")
    ch = diff_attrs("apps", app["attributes"], {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"})
    if ch: c.write("PATCH", f"/v1/apps/{APP_ID}", {"data": {"type": "apps", "id": APP_ID, "attributes": ch}}, "內容版權：不含第三方內容")


def sec_categories(c, info):
    print("\n## categories（appInfos 主／次類別）")
    rel = info["relationships"]
    cur = {k: (rel.get(k, {}).get("data") or {}).get("id") for k in ("primaryCategory", "secondaryCategory")}
    ch = diff_attrs("appInfos", cur, {"primaryCategory": PRIMARY_CATEGORY, "secondaryCategory": SECONDARY_CATEGORY})
    if ch:
        body = {"data": {"type": "appInfos", "id": info["id"], "relationships": {k: {"data": {"type": "appCategories", "id": v}} for k, v in ch.items()}}}
        c.write("PATCH", f"/v1/appInfos/{info['id']}", body, "類別 Productivity／Business")


def sec_agerating(c, info):
    print("\n## agerating（全部「無／false」）")
    d = c.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    unknown = set(d["attributes"]) - set(AGE_TARGET) - AGE_OTHER_KNOWN
    if unknown: die(1, f"年齡分級出現腳本不認得的題目 {sorted(unknown)}（Apple 新增？）；先補 AGE_TARGET 再跑，不能默默留空")
    ch = diff_attrs("ageRatingDeclaration", d["attributes"], AGE_TARGET)
    if ch: c.write("PATCH", f"/v1/ageRatingDeclarations/{d['id']}", {"data": {"type": "ageRatingDeclarations", "id": d["id"], "attributes": ch}}, f"年齡分級 {len(ch)} 題")


def sec_appinfo(c, info, meta):
    print("\n## appinfo（appInfoLocalizations ×9：name／subtitle／privacyPolicyUrl）")
    cur = {x["attributes"]["locale"]: x for x in c.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50")["data"]}
    for loc in LOCALES:
        want = {"name": APP_NAME, "subtitle": meta[loc]["subtitle"], "privacyPolicyUrl": PRIVACY_URL}
        if loc in cur:
            ch = diff_attrs(f"appInfoLoc {loc}", cur[loc]["attributes"], want)
            if ch: c.write("PATCH", f"/v1/appInfoLocalizations/{cur[loc]['id']}", {"data": {"type": "appInfoLocalizations", "id": cur[loc]["id"], "attributes": ch}}, f"App 資訊 {loc}")
        else:
            diff_attrs(f"appInfoLoc {loc} (新建)", {}, want)
            c.write("POST", "/v1/appInfoLocalizations", {"data": {"type": "appInfoLocalizations", "attributes": {"locale": loc, **want},
                    "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}}}}, f"App 資訊 {loc} 新建")


def sec_version(c, ver):
    print("\n## version（versionString／copyright／releaseType）")
    cur_vs = ver["attributes"].get("versionString")
    if cur_vs not in (ASC_DEFAULT_VERSION, PREVIOUS_VERSION, VERSION_STRING):
        die(1, f"守門：版本字串 {cur_vs} 不是 ASC 預設 {ASC_DEFAULT_VERSION}、上一個目標 {PREVIOUS_VERSION} 或目標 {VERSION_STRING}，拒絕改寫")
    ch = diff_attrs("appStoreVersion", ver["attributes"], {"versionString": VERSION_STRING, "copyright": COPYRIGHT, "releaseType": "MANUAL"})
    if ch: c.write("PATCH", f"/v1/appStoreVersions/{ver['id']}", {"data": {"type": "appStoreVersions", "id": ver["id"], "attributes": ch}}, f"版本 {VERSION_STRING}／版權／手動發佈")


def version_locs(c, ver):
    return {x["attributes"]["locale"]: x for x in c.get(f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations?limit=50")["data"]}


def sec_versionloc(c, ver, meta):
    """回傳 {locale: id}（含本次 POST 新建的，apply 時供截圖段直接用，不靠列表 GET 的可見性）。"""
    print("\n## versionloc（appStoreVersionLocalizations ×9：五欄）")
    cur = version_locs(c, ver)
    ids = {loc: x["id"] for loc, x in cur.items()}
    for loc in LOCALES:
        f = meta[loc]
        want = {"promotionalText": f["promotional_text"], "description": f["description"], "keywords": f["keywords"], "supportUrl": f["support_url"], "marketingUrl": f["marketing_url"]}
        if loc in cur:
            ch = diff_attrs(f"versionLoc {loc}", cur[loc]["attributes"], want)
            if ch: c.write("PATCH", f"/v1/appStoreVersionLocalizations/{cur[loc]['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": cur[loc]["id"], "attributes": ch}}, f"版本頁 {loc}")
        else:
            diff_attrs(f"versionLoc {loc} (新建)", {}, want)
            res = c.write("POST", "/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations", "attributes": {"locale": loc, **want},
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}}}}, f"版本頁 {loc} 新建")
            ids[loc] = res["data"]["id"] if res else "<new>"
    return ids


def desktop_set(c, loc_id):
    """回傳 (set_id 或 None, [現有截圖 dict 依顯示順序])；多於一個 APP_DESKTOP 集合就停。"""
    sets = c.get(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets?include=appScreenshots&limit=50")
    desk = [s for s in sets["data"] if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP"]
    if len(desk) > 1: die(1, f"語系 {loc_id} 有 {len(desk)} 個 APP_DESKTOP 截圖集合，請在 ASC 清成一個再跑")
    if not desk: return None, []
    inc = {x["id"]: x for x in sets.get("included", [])}
    have = []
    for ref in desk[0]["relationships"].get("appScreenshots", {}).get("data", []) or []:
        x = inc.get(ref["id"])
        if not x:
            got = c.get(f"/v1/appScreenshots/{ref['id']}", ok404=True)   # included 不完整就逐張補抓；抓不到就停，不當成不存在
            if not got or not got.get("data"): die(2, f"截圖 {ref['id']} 在集合裡但抓不到內容，不敢判斷有沒有，停")
            x = got["data"]
        a = x["attributes"]
        have.append({"id": x["id"], "name": a.get("fileName"), "md5": a.get("sourceFileChecksum"), "state": (a.get("assetDeliveryState") or {}).get("state")})
    names = [h["name"] for h in have]
    if None in names or len(names) != len(set(names)): die(1, f"語系 {loc_id} 遠端截圖檔名缺失或重複：{names}，請先在 ASC 人工整理")
    return desk[0]["id"], have


def upload_screenshot(c, set_id, shot):
    res = c.write("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": shot["name"], "fileSize": len(shot["data"])},
                  "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}}, f"截圖預留＋上傳＋commit {shot['name']}")
    if res is None: return None
    sid = res["data"]["id"]
    ops = res["data"]["attributes"]["uploadOperations"]
    for i, op in enumerate(ops):
        hdr = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        c.put_raw(op["url"], shot["data"][op["offset"]:op["offset"] + op["length"]], hdr, f"{shot['name']} 分片 {i + 1}/{len(ops)}")
    c.call("PATCH", f"/v1/appScreenshots/{sid}", {"data": {"type": "appScreenshots", "id": sid, "attributes": {"uploaded": True, "sourceFileChecksum": shot["md5"]}}})
    c._record(f"{shot['name']} commit（md5 {shot['md5'][:8]}）", "PATCH", f"/v1/appScreenshots/{sid}", {"uploaded": True, "md5": shot["md5"]})
    return sid


def sec_screenshots(c, ver, shots, loc_ids, only):
    print("\n## screenshots（每個語系的 APP_DESKTOP 集合：MD5 比對，缺或壞的補，多餘的停）")
    missing = [loc for loc in LOCALES if loc_ids.get(loc) in (None, "<new>")]
    if missing and "versionloc" not in only:
        die(1, f"語系 {missing} 的版本頁還不存在，而本次沒選 versionloc 段；請用含 versionloc 的 --only（或預設全段）重跑 dry-run 再 apply")
    if missing and APPLY: die(2, f"{missing} 版本頁語系的 id 不明（versionloc 段沒回 id），不猜")
    pending = []   # (loc, name, sid)
    order_fix = []  # (set_id, [ids])
    for loc in LOCALES:
        lid = loc_ids.get(loc)
        if lid in (None, "<new>"):
            print(f"   {loc:<8} 語系尚未存在：apply 時由 versionloc 段新建後直接接手 → 計畫 1 個集合＋{len(shots)} 張")
            for _ in range(1 + len(shots)): c.write("POST", "/v1/appScreenshotSets|appScreenshots", None, f"{loc} 截圖（新語系）")
            continue
        set_id, have = None, []
        for attempt in range(6):   # 剛 POST 的語系，關聯可能慢幾秒才可見：只重試 retryable（網路／404／429／5xx）
            try:
                set_id, have = desktop_set(c, lid); break
            except ApiError as e:
                if not e.retryable or attempt == 5: raise
                time.sleep(2 * (attempt + 1))
        extras = [h for h in have if h["name"] not in {s["name"] for s in shots}]
        if extras: die(1, f"{loc} 有本地沒有的截圖 {[h['name'] for h in extras]}，不自動刪；請在 ASC 刪掉後重跑")
        by_name = {h["name"]: h for h in have}
        todo, bad = [], []
        for s in shots:
            h = by_name.get(s["name"])
            if h and h["md5"] == s["md5"] and h["state"] == "COMPLETE": continue
            if h: bad.append(h)
            todo.append(s)
        print(f"   {loc:<8} 現有 {len(have)} 張 {[(h['name'], h['state'], 'md5 同' if h['md5'] == next((s['md5'] for s in shots if s['name'] == h['name']), None) else 'md5 異') for h in have]}；要傳 {[s['name'] for s in todo]}")
        if not todo:
            want_ids = [by_name[s["name"]]["id"] for s in shots]
            if [h["id"] for h in have] != want_ids: order_fix.append((set_id, want_ids))
            continue
        for h in bad:
            c.write("DELETE", f"/v1/appScreenshots/{h['id']}", None, f"刪 {loc} {h['name']}（{h['state']}／md5 不符）")
        if set_id is None:
            res = c.write("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
                          "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}}}, f"截圖集合 {loc}")
            set_id = res["data"]["id"] if res else "<new>"
        new_ids = {}
        for s in todo:
            sid = upload_screenshot(c, set_id, s)
            if sid: new_ids[s["name"]] = sid; pending.append((loc, s["name"], sid))
        if APPLY:
            ids = [new_ids.get(s["name"]) or (by_name.get(s["name"]) or {}).get("id") for s in shots]
            order_fix.append((set_id, ids))
    if pending:
        print("   等 Apple 處理截圖…")
        states = {}
        for _ in range(60):
            states = {(loc, n): c.get(f"/v1/appScreenshots/{sid}")["data"]["attributes"]["assetDeliveryState"]["state"] for loc, n, sid in pending}
            if all(s in ("COMPLETE", "FAILED") for s in states.values()): break
            time.sleep(5)
        for k, s in sorted(states.items()): print(f"   {k[0]:<8} {k[1]:<20} {s}")
        if any(s != "COMPLETE" for s in states.values()): die(3, "有截圖沒到 COMPLETE（重跑會刪掉壞的重傳）")
    for set_id, ids in order_fix:
        if any(i is None for i in ids) or len(set(ids)) != len(ids) or len(ids) != len(shots):
            die(3, f"截圖排序的 id 清單不完整或重複：{ids}")
        c.write("PATCH", f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots", {"data": [{"type": "appScreenshots", "id": i} for i in ids]}, "截圖排序")


def sec_review(c, ver, notes, contact):
    print("\n## review（appStoreReviewDetail：聯絡人＋notes、不需帳號；聯絡人只印長度）")
    cur = c.get(f"/v1/appStoreVersions/{ver['id']}/appStoreReviewDetail")["data"]
    want = {"contactFirstName": contact["CONTACT_FIRST"], "contactLastName": contact["CONTACT_LAST"], "contactPhone": contact["CONTACT_PHONE"],
            "contactEmail": contact["CONTACT_EMAIL"], "demoAccountRequired": False, "notes": notes}
    if cur:
        ch = diff_attrs("reviewDetail", cur["attributes"], want)
        if ch: c.write("PATCH", f"/v1/appStoreReviewDetails/{cur['id']}", {"data": {"type": "appStoreReviewDetails", "id": cur["id"], "attributes": ch}}, "送審資訊")
    else:
        diff_attrs("reviewDetail (新建)", {}, want)
        c.write("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": want,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}}}}, "送審資訊 新建")


def current_prices(c):
    url = f"/v1/appPriceSchedules/{APP_ID}/manualPrices?include=appPricePoint&limit=50"
    out = []
    while url:
        m = c.get(url, ok404=True)
        if not m or not m.get("data"): break
        pts = {x["id"]: x for x in m.get("included", [])}
        for x in m["data"]:
            pid = (x["relationships"].get("appPricePoint", {}).get("data") or {}).get("id")
            pp = pts.get(pid)
            if pp is None:
                got = c.get(f"/v1/appPricePoints/{pid}", ok404=True) if pid else None
                if not got: die(2, f"價格 {x['id']} 的價位 {pid} 抓不到，不敢判斷")
                pp = got["data"]
            out.append({"price": pp.get("attributes", {}).get("customerPrice"), "start": x["attributes"].get("startDate"), "end": x["attributes"].get("endDate")})
        url = (m.get("links") or {}).get("next")
    return out


def sec_price(c):
    print("\n## price（Free；只在沒有任何價格時建；既有價格不是 0 就停）")
    base = c.get(f"/v1/appPriceSchedules/{APP_ID}/baseTerritory", ok404=True)
    base_id = ((base or {}).get("data") or {}).get("id") or "USA"
    cur = current_prices(c)
    if cur:
        print(f"   既有 manualPrices（基準 {base_id}）：{cur}")
        if any(p["price"] is None or float(p["price"]) != 0.0 for p in cur): die(1, "既有價格不是 0，不自動改；請人工在 ASC 處理")
        print("   已是 Free，略過"); return
    pps = c.get(f"/v1/apps/{APP_ID}/appPricePoints?filter[territory]={base_id}&limit=5")["data"]
    zero = [p for p in pps if float(p["attributes"]["customerPrice"]) == 0.0]
    if not zero: die(2, f"{base_id} 找不到 0 元價位")
    print(f"   {'appPriceSchedule':<34} {'manualPrices':<32} {'∅':<64} → Free（{base_id} 價位 customerPrice={zero[0]['attributes']['customerPrice']}）")
    body = {"data": {"type": "appPriceSchedules", "relationships": {
                "app": {"data": {"type": "apps", "id": APP_ID}},
                "baseTerritory": {"data": {"type": "territories", "id": base_id}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
            "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                          "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": zero[0]["id"]}}}}]}
    c.write("POST", "/v1/appPriceSchedules", body, "價格 Free")


# ---------- 驗證（apply 後 GET 全部回來比對 docs/store） ----------
def verify(c, info, ver, meta, notes, contact, shots, only):
    print("\n## 驗證（GET 回來逐欄比對）")
    bad = 0
    def chk(label, have, want):
        nonlocal bad
        ok = have == want
        bad += 0 if ok else 1
        k = label.split()[-1]
        print(f"   {'✅' if ok else '❌'} {label:<44} {show(k, have) if k in SENSITIVE else short(have, 50)}" + ("" if ok else f"  ≠ {show(k, want) if k in SENSITIVE else short(want, 50)}"))
    app = c.get(f"/v1/apps/{APP_ID}")["data"]["attributes"]
    if "app" in only: chk("contentRightsDeclaration", app.get("contentRightsDeclaration"), "DOES_NOT_USE_THIRD_PARTY_CONTENT")
    info = c.get(f"/v1/appInfos/{info['id']}?include=primaryCategory,secondaryCategory")["data"]   # 關聯要 include 才有 data（10/31 第一次 apply 驗證誤報的教訓）
    if "categories" in only:
        for k, w in (("primaryCategory", PRIMARY_CATEGORY), ("secondaryCategory", SECONDARY_CATEGORY)):
            chk(k, (info["relationships"].get(k, {}).get("data") or {}).get("id"), w)
    if "agerating" in only:
        a = c.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]["attributes"]
        for k, w in AGE_TARGET.items(): chk(f"age.{k}", a.get(k), w)
    if "appinfo" in only:
        cur = {x["attributes"]["locale"]: x["attributes"] for x in c.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50")["data"]}
        for loc in LOCALES:
            a = cur.get(loc, {})
            chk(f"appInfo {loc} name", a.get("name"), APP_NAME); chk(f"appInfo {loc} subtitle", a.get("subtitle"), meta[loc]["subtitle"]); chk(f"appInfo {loc} privacyPolicyUrl", a.get("privacyPolicyUrl"), PRIVACY_URL)
    v = c.get(f"/v1/appStoreVersions/{ver['id']}")["data"]["attributes"]
    if "version" in only:
        chk("versionString", v.get("versionString"), VERSION_STRING); chk("copyright", v.get("copyright"), COPYRIGHT); chk("releaseType", v.get("releaseType"), "MANUAL")
    vl = version_locs(c, ver)
    if "versionloc" in only:
        for loc in LOCALES:
            a = vl.get(loc, {}).get("attributes", {}); f = meta[loc]
            for k, w in (("promotionalText", f["promotional_text"]), ("description", f["description"]), ("keywords", f["keywords"]), ("supportUrl", f["support_url"]), ("marketingUrl", f["marketing_url"])):
                chk(f"version {loc} {k}", a.get(k), w)
    if "screenshots" in only:
        want = [(s["name"], s["md5"], "COMPLETE") for s in shots]
        for loc in LOCALES:
            if loc not in vl: chk(f"shots {loc} order+md5+state", None, want); continue
            _, have = desktop_set(c, vl[loc]["id"])
            chk(f"shots {loc} order+md5+state", [(h["name"], h["md5"], h["state"]) for h in have], want)
    if "review" in only:
        r = (c.get(f"/v1/appStoreVersions/{ver['id']}/appStoreReviewDetail")["data"] or {}).get("attributes", {})
        chk("review contactFirstName", r.get("contactFirstName"), contact["CONTACT_FIRST"]); chk("review contactLastName", r.get("contactLastName"), contact["CONTACT_LAST"])
        chk("review contactPhone", r.get("contactPhone"), contact["CONTACT_PHONE"]); chk("review contactEmail", r.get("contactEmail"), contact["CONTACT_EMAIL"])
        chk("review demoAccountRequired", r.get("demoAccountRequired"), False); chk("review notes", r.get("notes"), notes)
    if "price" in only:
        prices = [float(p["price"]) if p["price"] is not None else None for p in current_prices(c)]
        chk("price 非空且全部 0", bool(prices) and all(p == 0.0 for p in prices), True)
    return bad


def main():
    global APPLY
    ap = argparse.ArgumentParser(description="docs/store → App Store Connect（MAS-36）", allow_abbrev=False)
    ap.add_argument("--apply", action="store_true", help="真寫（預設 dry-run）")
    ap.add_argument("--manifest", help="dry-run 印出的 manifest sha；--apply 必帶且要相符")
    ap.add_argument("--only", help="逗號分隔的段：" + ",".join(ALL_SECTIONS))
    ap.add_argument("--store", default=os.path.normpath(os.path.join(HERE, "..", "..", "docs", "store")))
    a = ap.parse_args()
    APPLY = a.apply
    only = set(DEFAULT_SECTIONS)
    if a.only:
        only = set(a.only.split(","))
        if not only <= set(ALL_SECTIONS): ap.error(f"--only 只接受 {','.join(ALL_SECTIONS)}")
    store = os.path.realpath(a.store)
    meta, notes, shots, content_sha = load_store(store)
    contact = load_contact()
    # execution manifest：內容 ＋ 本次段 ＋ 所有寫入常數 ＋ 腳本規則版本 ＋ 聯絡人檔摘要（dry-run 與 apply 必須完全同一組）
    h = hashlib.sha256(content_sha.encode())
    for item in (sorted(only), APP_ID, BUNDLE, APP_NAME, VERSION_STRING, ASC_DEFAULT_VERSION, COPYRIGHT, PRIVACY_URL, PRIMARY_CATEGORY, SECONDARY_CATEGORY, AGE_TARGET, SCHEMA_VERSION, contact["_digest"]):
        h.update(json.dumps(item, sort_keys=True, ensure_ascii=False).encode() + b"\0")
    global MANIFEST
    manifest = MANIFEST = h.hexdigest()[:16]
    if APPLY and a.manifest != manifest: die(1, f"--apply 要帶 --manifest {manifest}（同一組 --only、同一份 docs/store、同一版腳本的 dry-run 印的那串）")
    if APPLY:
        lock = os.path.join(tempfile.gettempdir(), "myparrot-asc-store-push.lock")
        try: fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            try: pid = int(open(lock).read().strip() or 0)
            except (OSError, ValueError): pid = 0
            alive = False
            if pid > 0:
                try: os.kill(pid, 0); alive = True
                except ProcessLookupError: alive = False
                except PermissionError: alive = True
            if alive: die(1, f"另一個 apply 在跑（pid {pid}）：{lock}")
            print(f"   ⚠️ 清掉過期 lock（pid {pid} 已不在）"); os.remove(lock)
            fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, str(os.getpid()).encode()); os.close(fd)
        atexit.register(lambda: os.path.exists(lock) and os.remove(lock))
    global LOGFH
    logp = os.environ.get("MYPARROT_ASC_PUSH_LOG")
    if APPLY and logp:
        fd = os.open(logp, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
            os.close(fd); die(1, f"log 檔 {logp} 不是自己的 0600 一般檔，不寫")
        LOGFH = os.fdopen(fd, "a", encoding="utf-8")
        LOGFH.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "manifest": manifest, "event": "apply-start", "only": sorted(only)}) + "\n"); LOGFH.flush()
        atexit.register(lambda: (LOGFH.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "manifest": manifest, "event": "apply-end", "done": DONE, "mutations": MUTATIONS, "complete": DONE == PLANNED}) + "\n"), LOGFH.flush()))
    c = Client()
    print(f"模式：{'APPLY（真寫）' if APPLY else 'DRY-RUN（只讀，不寫）'}；store={store}；manifest={manifest}；段={','.join(s for s in ALL_SECTIONS if s in only)}")

    # 守門
    app = c.get(f"/v1/apps/{APP_ID}")["data"]
    if app["attributes"]["bundleId"] != BUNDLE or app["attributes"]["name"] != APP_NAME:
        die(1, f"守門：Apple ID {APP_ID} 是 {app['attributes']['name']}／{app['attributes']['bundleId']}，不是 {APP_NAME}／{BUNDLE}")
    infos = c.get(f"/v1/apps/{APP_ID}/appInfos")["data"]
    editable = [i for i in infos if i["attributes"].get("state") in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")]
    if len(editable) != 1: die(1, f"守門：可編輯的 appInfo 不是恰好一個：{[(i['id'], i['attributes'].get('state')) for i in infos]}")
    info = c.get(f"/v1/appInfos/{editable[0]['id']}?include=primaryCategory,secondaryCategory")["data"]
    vers = c.get(f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=MAC_OS&limit=20")["data"]
    editable_v = [v for v in vers if v["attributes"].get("appVersionState") in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")]
    if len(editable_v) != 1: die(1, f"守門：可編輯的 macOS 版本不是恰好一個：{[(v['attributes']['versionString'], v['attributes'].get('appVersionState')) for v in vers]}")
    ver = editable_v[0]
    if ver["attributes"].get("versionString") not in (ASC_DEFAULT_VERSION, PREVIOUS_VERSION, VERSION_STRING):
        die(1, f"守門：版本字串 {ver['attributes'].get('versionString')} 不是 {ASC_DEFAULT_VERSION}、{PREVIOUS_VERSION} 或 {VERSION_STRING}")
    print(f"守門通過：{APP_NAME}／{BUNDLE}；appInfo {info['id']}；版本 {ver['attributes']['versionString']}（{ver['attributes'].get('appVersionState')}，id {ver['id']}）")

    if "app" in only: sec_app(c, app)
    if "categories" in only: sec_categories(c, info)
    if "agerating" in only: sec_agerating(c, info)
    if "appinfo" in only: sec_appinfo(c, info, meta)
    if "version" in only: sec_version(c, ver)
    loc_ids = sec_versionloc(c, ver, meta) if "versionloc" in only else {loc: x["id"] for loc, x in version_locs(c, ver).items()}
    if "screenshots" in only: sec_screenshots(c, ver, shots, loc_ids, only)
    if "review" in only: sec_review(c, ver, notes, contact)
    if "price" in only: sec_price(c)

    print(f"\n{'資源寫入 ' + str(DONE) + '／計畫 ' + str(PLANNED) + '；HTTP 變更總數 ' + str(MUTATIONS) + '（含 PUT 分片、commit、刪除、排序）' if APPLY else '計畫資源寫入 ' + str(PLANNED) + ' 筆；manifest=' + manifest}")
    if APPLY:
        bad = verify(c, info, ver, meta, notes, contact, shots, only)
        if bad: die(3, f"驗證 {bad} 項不一致")
        print("✅ 驗證全部一致")


if __name__ == "__main__":
    try:
        main()
    except ApiError as e:
        die(2, str(e))
