#!/usr/bin/env python3
"""App Store Connect API 唯讀小客戶端（MAS-26 查 build processing 用；零 pip 依賴，ES256 JWT 用 openssl 簽）。

用法：python3 -I scripts/dev/asc-api.py <path> [query]
  例：scripts/dev/asc-api.py /v1/apps 'filter[bundleId]=tw.uncle.MyParrot.mas'
      scripts/dev/asc-api.py /v1/builds 'filter[app]=<appleId>&sort=-uploadedDate&limit=5&fields[builds]=version,processingState'
憑證：Key ID／Issuer ID 讀 env MYPARROT_ASC_API_KEY_ID／MYPARROT_ASC_API_ISSUER_ID，
      沒設就讀 ~/.private_keys/asc-ids.env（兩行 KEY=VALUE；非秘密）；.p8 固定在 ~/.private_keys/AuthKey_<KEY_ID>.p8（秘密，🚫 進 repo）。
只做 GET；寫入類操作不在這支。2026-10-30 建（#2654）。
"""
import base64, json, os, subprocess, sys, time, tempfile, urllib.request, urllib.parse

def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def der_to_raw(der):
    # DER SEQUENCE { INTEGER r, INTEGER s } -> r||s, 32 bytes each
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)
    assert der[i] == 0x02; l = der[i+1]; r = der[i+2:i+2+l]; i = i+2+l
    assert der[i] == 0x02; l = der[i+1]; s = der[i+2:i+2+l]
    r = r.lstrip(b"\x00").rjust(32, b"\x00"); s = s.lstrip(b"\x00").rjust(32, b"\x00")
    return r + s

def jwt(key_id, issuer, p8):
    hdr = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    pl = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    msg = b64url(json.dumps(hdr, separators=(",", ":")).encode()) + "." + b64url(json.dumps(pl, separators=(",", ":")).encode())
    with tempfile.NamedTemporaryFile(delete=False) as f: f.write(msg.encode()); mp = f.name
    try:
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", p8, mp], capture_output=True, check=True).stdout
    finally:
        os.unlink(mp)
    return msg + "." + b64url(der_to_raw(der))

def main():
    env = dict(os.environ)
    idfile = os.path.expanduser("~/.private_keys/asc-ids.env")
    if os.path.exists(idfile):
        for line in open(idfile, encoding="utf-8"):
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1); env.setdefault(k, v)
    key_id = env.get("MYPARROT_ASC_API_KEY_ID"); issuer = env.get("MYPARROT_ASC_API_ISSUER_ID")
    if not key_id or not issuer or len(sys.argv) < 2:
        sys.exit("用法：asc-api.py <path> [query]；需要 MYPARROT_ASC_API_KEY_ID／MYPARROT_ASC_API_ISSUER_ID（env 或 ~/.private_keys/asc-ids.env）")
    p8 = os.path.expanduser(f"~/.private_keys/AuthKey_{key_id}.p8")
    if not os.path.exists(p8): sys.exit(f"找不到 {p8}")
    path = sys.argv[1]; query = sys.argv[2] if len(sys.argv) > 2 else ""
    url = "https://api.appstoreconnect.apple.com" + path + ("?" + query if query else "")
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + jwt(key_id, issuer, p8)})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: body = r.read().decode()
        print(body)
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode()[:2000]); sys.exit(1)

if __name__ == "__main__": main()
