#!/usr/bin/env python3
"""App Store Connect API 唯讀小客戶端（MAS-26 查 build processing 用；零 pip 依賴，ES256 JWT 用 openssl 簽）。

用法：python3 -I scripts/dev/asc-api.py [--require-nonempty] <path> [query]
  例：scripts/dev/asc-api.py /v1/apps 'filter[bundleId]=tw.uncle.MyParrot.mas'
      scripts/dev/asc-api.py --require-nonempty /v1/builds 'filter[app]=<appleId>&sort=-uploadedDate&limit=5&fields[builds]=version,processingState'
憑證：Key ID／Issuer ID 讀 env MYPARROT_ASC_API_KEY_ID／MYPARROT_ASC_API_ISSUER_ID，
      沒設就讀 ~/.private_keys/asc-ids.env（只認這兩個 KEY=VALUE，🚫 不 source）；
      .p8 固定在 ~/.private_keys/AuthKey_<KEY_ID>.p8（秘密，🚫 進 repo、🚫 貼對話；要是一般檔、非 symlink、mode 600）。
只做 GET、path 必須以 /v1/ 開頭；回應必須是 JSON 物件，--require-nonempty 時 data 為空就 exit 3。
exit：0 成功｜1 用法／設定／憑證檔問題｜2 HTTP／網路／非 JSON｜3 查到 0 筆（--require-nonempty）。
2026-10-30 建（#2654）；二審（GPT）後：DER parser 顯式 bounds check、不落盤未簽 JWT、嚴格 env 解析。
"""
import base64, json, os, re, stat, subprocess, sys, time, urllib.error, urllib.request

API = "https://api.appstoreconnect.apple.com"
KEY_RE = re.compile(r"^[A-Z0-9]{10}$")
ISSUER_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
ENV_KEYS = ("MYPARROT_ASC_API_KEY_ID", "MYPARROT_ASC_API_ISSUER_ID")


def die(code, msg):
    print(msg, file=sys.stderr)
    sys.exit(code)


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _der_int(der, i):
    """讀 der[i:] 的一個 INTEGER，回 (value_bytes_32, next_index)。顯式檢查，不用 assert。"""
    if i + 2 > len(der) or der[i] != 0x02:
        raise ValueError(f"DER: expected INTEGER at {i}")
    ln = der[i + 1]
    if ln >= 0x80 or ln == 0 or i + 2 + ln > len(der):
        raise ValueError("DER: bad INTEGER length")
    v = der[i + 2:i + 2 + ln]
    if v[0] & 0x80:
        raise ValueError("DER: negative INTEGER")
    if len(v) > 1 and v[0] == 0x00 and not (v[1] & 0x80):
        raise ValueError("DER: non-minimal INTEGER")
    if v[0] == 0x00:
        v = v[1:]  # 至多一個 sign-padding 00
    if not (1 <= len(v) <= 32):
        raise ValueError("DER: INTEGER out of P-256 range")
    return v.rjust(32, b"\x00"), i + 2 + ln


def der_to_raw(der):
    """ECDSA DER SEQUENCE{r,s} → JOSE raw r‖s（恰 64 bytes）。"""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("DER: not a SEQUENCE")
    ln = der[1]
    if ln >= 0x80:  # P-256 簽章 ≤ 72 bytes，不會用長格式
        raise ValueError("DER: unexpected long-form length")
    if 2 + ln != len(der):
        raise ValueError("DER: SEQUENCE length mismatch / trailing data")
    r, i = _der_int(der, 2)
    s, i = _der_int(der, i)
    if i != len(der):
        raise ValueError("DER: trailing bytes inside SEQUENCE")
    out = r + s
    if len(out) != 64:
        raise ValueError("DER: raw signature not 64 bytes")
    return out


def jwt(key_id, issuer, p8):
    hdr = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    pl = {"iss": issuer, "iat": now - 30, "exp": now + 600, "aud": "appstoreconnect-v1"}
    msg = b64url(json.dumps(hdr, separators=(",", ":")).encode()) + "." + b64url(json.dumps(pl, separators=(",", ":")).encode())
    # 未簽部分走 stdin，不落盤
    r = subprocess.run(["openssl", "dgst", "-sha256", "-sign", p8], input=msg.encode(), capture_output=True)
    if r.returncode != 0:
        die(1, "openssl 簽章失敗：" + r.stderr.decode(errors="replace").strip())
    return msg + "." + b64url(der_to_raw(r.stdout))


def load_ids():
    env = {k: os.environ.get(k) for k in ENV_KEYS}
    if not all(env.values()):
        idfile = os.path.expanduser("~/.private_keys/asc-ids.env")
        if os.path.isfile(idfile):
            seen = set()
            with open(idfile, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" not in line:
                        die(1, f"{idfile}:{n} 不是 KEY=VALUE")
                    k, v = line.split("=", 1)
                    if k not in ENV_KEYS:
                        die(1, f"{idfile}:{n} 未知的 key {k!r}（只認 {ENV_KEYS}）")
                    if k in seen:
                        die(1, f"{idfile}:{n} 重複的 key {k}")
                    if not v or v != v.strip() or v[0] in "\"'" or "$" in v:
                        die(1, f"{idfile}:{n} {k} 的值不可為空、不可帶引號／空白／$")
                    seen.add(k)
                    if not env.get(k):
                        env[k] = v
    key_id, issuer = env[ENV_KEYS[0]], env[ENV_KEYS[1]]
    if not key_id or not issuer:
        die(1, f"需要 {ENV_KEYS[0]} 與 {ENV_KEYS[1]}（env 或 ~/.private_keys/asc-ids.env）")
    if not KEY_RE.match(key_id):
        die(1, "Key ID 格式不對（預期 10 個大寫英數）")
    if not ISSUER_RE.match(issuer):
        die(1, "Issuer ID 格式不對（預期 UUID 小寫）")
    return key_id, issuer


def check_p8(p8):
    try:
        st = os.lstat(p8)
    except FileNotFoundError:
        die(1, f"找不到 {p8}")
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        die(1, f"{p8} 必須是一般檔案（非 symlink）")
    if st.st_uid != os.getuid():
        die(1, f"{p8} 擁有者不是目前使用者")
    if st.st_mode & 0o077:
        die(1, f"{p8} 權限過寬（{oct(st.st_mode & 0o777)}），請 chmod 600")


def main():
    args = sys.argv[1:]
    require_nonempty = False
    if args and args[0] == "--require-nonempty":
        require_nonempty = True
        args = args[1:]
    if len(args) not in (1, 2):
        die(1, "用法：asc-api.py [--require-nonempty] <path> [query]")
    path, query = args[0], (args[1] if len(args) == 2 else "")
    if not path.startswith("/v1/") or re.search(r"[\s?#]", path) or not path.isascii():
        die(1, "path 必須以 /v1/ 開頭，不可含空白、?、#（query 用第二個參數）")
    key_id, issuer = load_ids()
    p8 = os.path.expanduser(f"~/.private_keys/AuthKey_{key_id}.p8")
    check_p8(p8)
    url = API + path + ("?" + query if query else "")
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + jwt(key_id, issuer, p8)})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        die(2, f"HTTP {e.code} {e.read().decode('utf-8', errors='replace')[:2000]}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        die(2, f"網路錯誤：{e}")
    try:
        doc = json.loads(body)
    except json.JSONDecodeError:
        die(2, "回應不是 JSON：" + body[:300])
    if not isinstance(doc, dict):
        die(2, "回應不是 JSON 物件")
    if doc.get("errors"):
        die(2, "API errors：" + json.dumps(doc["errors"], ensure_ascii=False)[:2000])
    if require_nonempty and not doc.get("data"):
        print(body)
        die(3, "查到 0 筆（--require-nonempty）")
    print(body)


if __name__ == "__main__":
    main()
