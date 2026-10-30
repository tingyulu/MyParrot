#!/bin/bash
# Assembles a runnable MyParrot.app from the SwiftPM build product, signs it, and
# installs it to ~/Applications (OUTSIDE iCloud Drive) so macOS TCC remembers the
# mic / speech / audio-capture grants instead of re-prompting every launch.
set -euo pipefail

cd "$(dirname "$0")/.."
MODE="${1:-debug}"   # debug | release | mas-dev | mas-dist | verify-mas <app>
# #2646 Mac App Store 免費版(TEST_PLAN X 節 MAS-04／24／25／34):
#   mas-dev  ＝ MYPARROT_MAS=1 build(預設 debug,MYPARROT_MAS_CONFIG=release 可改)→ bundle id tw.uncle.MyParrot.mas
#              → 沙盒 entitlements → Apple Development 簽 → 裝到 ~/Applications/MyParrot-mas.app(🚫 永遠不碰現用的 MyParrot.app)。
#              功能測試用;debug 才有 DebugControl(myparrotctl)通道,沙盒下結果檔要寫在已選的錄音夾裡。
#   mas-dist ＝ 同上但 Apple Distribution 簽,不安裝;productbuild 出 .pkg(Mac Installer Distribution 簽)→ 可 altool validate。
#   verify-mas <app> ＝ 只跑 MAS-34 的簽章一致性檢查(Team ID／bundle id／六條 entitlements／六條用途字串),正控用。
#   debug／release ＝ GitHub 版,行為一行不變。MAS 兩種模式的 swift build 走獨立 scratch path .build-mas(兩套快取互不洗)。
FLAVOR=github; MAS_SIGN=""
case "$MODE" in
  debug|release) CONFIG="$MODE" ;;
  mas-dev)  CONFIG="${MYPARROT_MAS_CONFIG:-debug}"; FLAVOR=mas; MAS_SIGN=dev ;;   # 預設 debug:才有 DebugControl 通道可驗(MAS-24 偏差,見 TEST_REPORT);MYPARROT_MAS_CONFIG=release 可改
  mas-dist) CONFIG=release; FLAVOR=mas; MAS_SIGN=dist ;;
  verify-mas) ;;
  *) echo "用法: scripts/build-app.sh [debug|release|mas-dev|mas-dist|verify-mas <app>]"; exit 1 ;;
esac

# --- MAS-34:簽章一致性檢查(mas-dev／mas-dist 簽完必跑;任一不符 exit 1、mas-dist 不產 pkg) ---------------
# 期望值:bundle id＝tw.uncle.MyParrot.mas(Info.plist 與簽章 Identifier 都是)、Team ID＝簽章憑證的 OU、
# entitlements 恰好六條且全 true、六條 TCC 用途字串非空、ITSAppUsesNonExemptEncryption=false、PrivacyInfo.xcprivacy 在。
MAS_BUNDLE_ID="tw.uncle.MyParrot.mas"
MAS_ENTITLEMENT_KEYS="com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.device.audio-input com.apple.security.personal-information.calendars com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope"
MAS_USAGE_KEYS="NSMicrophoneUsageDescription NSAudioCaptureUsageDescription NSCalendarsFullAccessUsageDescription NSCalendarsUsageDescription NSSpeechRecognitionUsageDescription NSUserNotificationsUsageDescription"
verify_mas_signature() {
  local app="$1" fail=0 plist="$1/Contents/Info.plist" ent
  ent="$(mktemp -t myparrot-ent).plist"
  echo "▶ MAS-34 簽章一致性檢查:$app"
  # 1. 簽章本體:Identifier／TeamIdentifier
  local dvv; dvv="$(codesign -dvv "$app" 2>&1 || true)"
  local sig_id team; sig_id="$(printf '%s\n' "$dvv" | sed -n 's/^Identifier=//p' | head -1)"; team="$(printf '%s\n' "$dvv" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  [ "$sig_id" = "$MAS_BUNDLE_ID" ] || { echo "  ❌ 簽章 Identifier=$sig_id,應為 $MAS_BUNDLE_ID"; fail=1; }
  if [ -z "$team" ] || [ "$team" = "not set" ]; then echo "  ❌ 簽章沒有 TeamIdentifier(ad-hoc／自簽?)"; fail=1; fi
  # Team ID 要等於簽章憑證的 OU(Apple Development／Apple Distribution／Developer ID 同一個團隊都是同一個 OU)
  local authority cert_ou
  authority="$(printf '%s\n' "$dvv" | sed -n 's/^Authority=//p' | head -1)"
  cert_ou="$(security find-certificate -c "$authority" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')"
  if [ -n "$cert_ou" ] && [ "$cert_ou" != "$team" ]; then echo "  ❌ 簽章 TeamIdentifier=$team 與憑證 OU=$cert_ou 不符"; fail=1; fi
  # 2. Info.plist
  local plist_id; plist_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  [ "$plist_id" = "$MAS_BUNDLE_ID" ] || { echo "  ❌ Info.plist CFBundleIdentifier=$plist_id,應為 $MAS_BUNDLE_ID"; fail=1; }
  local enc; enc="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$plist" 2>/dev/null || echo missing)"
  [ "$enc" = "false" ] || { echo "  ❌ ITSAppUsesNonExemptEncryption=$enc,應為 false"; fail=1; }
  for k in $MAS_USAGE_KEYS; do
    local v; v="$(/usr/libexec/PlistBuddy -c "Print :$k" "$plist" 2>/dev/null || true)"
    [ -n "$v" ] || { echo "  ❌ 用途字串 $k 缺或為空"; fail=1; }
  done
  [ -f "$app/Contents/Resources/PrivacyInfo.xcprivacy" ] || { echo "  ❌ 缺 Resources/PrivacyInfo.xcprivacy"; fail=1; }
  # MAS-26 偏差(10/30):ITMS-90546 ⇒ 商店版要有 Assets.car 且 CFBundleIconName=AppIcon
  [ -f "$app/Contents/Resources/Assets.car" ] || { echo "  ❌ 缺 Resources/Assets.car(ITMS-90546 Missing asset catalog)"; fail=1; }
  local iconname; iconname="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$plist" 2>/dev/null || echo missing)"
  [ "$iconname" = "AppIcon" ] || { echo "  ❌ CFBundleIconName=$iconname,應為 AppIcon"; fail=1; }
  # 3. entitlements:從最終簽章讀回(不是讀來源檔),恰好六條、全 true
  if ! codesign -d --entitlements "$ent" --xml "$app" 2>/dev/null; then echo "  ❌ 讀不到簽章 entitlements"; fail=1; fi
  if [ -s "$ent" ]; then
    local n; n="$(/usr/libexec/PlistBuddy -c 'Print' "$ent" 2>/dev/null | grep -c ' = ' || true)"
    [ "$n" = "6" ] || { echo "  ❌ 簽章 entitlements 有 $n 條,應恰好 6 條"; fail=1; }
    for k in $MAS_ENTITLEMENT_KEYS; do
      local v; v="$(/usr/libexec/PlistBuddy -c "Print :$k" "$ent" 2>/dev/null || echo missing)"
      [ "$v" = "true" ] || { echo "  ❌ entitlement $k=$v,應為 true"; fail=1; }
    done
  fi
  rm -f "$ent"
  if [ "$fail" = 0 ]; then
    echo "  ✅ Identifier=$sig_id TeamIdentifier=$team(憑證 OU 相符)、六條 entitlements、六條用途字串、加密宣告、privacy manifest、Assets.car 全部一致"
  else
    echo "  ❌ MAS-34 檢查不通過"
  fi
  return $fail
}
if [ "$MODE" = verify-mas ]; then
  [ -d "${2:-}" ] || { echo "用法: scripts/build-app.sh verify-mas <MyParrot-mas.app 路徑>"; exit 1; }
  verify_mas_signature "$2"; exit $?
fi

if [ "$FLAVOR" = mas ]; then
  export MYPARROT_MAS=1
  SCRATCH=(--scratch-path .build-mas)
  echo "▶ MYPARROT_MAS=1 swift build -c $CONFIG --scratch-path .build-mas(商店版)"
else
  SCRATCH=()
  echo "▶ swift build -c $CONFIG"
fi
swift build -c "$CONFIG" ${SCRATCH[@]+"${SCRATCH[@]}"}

# Guard: every L("…") key must have a translation (non-fatal, but surfaced).
echo "▶ check translations"
if ! swift scripts/check-translations.swift Sources/MyParrot; then
  # 二審:商店版缺字串／缺 lproj 一律擋(MAS-28「缺一即紅」);GitHub 版維持只警告。
  if [ "${FLAVOR:-github}" = mas ]; then echo "❌ 商店版翻譯檢查不過,不打包"; exit 1; fi
  echo "⚠️ 有 key 缺翻譯(見上),不阻擋打包"
fi

if [ "$FLAVOR" = mas ]; then
  BIN=".build-mas/$CONFIG/MyParrot"
  # mas-dev 在 repo 根暫存成 MyParrot-mas.app(跟 GitHub 版的暫存 MyParrot.app 分開);
  # mas-dist 暫存在 dist/mas/MyParrot.app(商店安裝到 /Applications 時就叫 MyParrot.app,.pkg 的 component 要用這個名字)。
  if [ "$MAS_SIGN" = dist ]; then mkdir -p dist/mas; APP="dist/mas/MyParrot.app"; else APP="MyParrot-mas.app"; fi
  ENTITLEMENTS="Resources/MyParrot-mas.entitlements"
else
  APP="MyParrot.app"
  BIN=".build/$CONFIG/MyParrot"
  ENTITLEMENTS="Resources/MyParrot.entitlements"
fi

# Regenerate the app icon if missing.
if [ ! -f Resources/AppIcon.icns ]; then
  echo "▶ generating AppIcon.icns"
  swift scripts/make-icon.swift /tmp/MyParrot.iconset >/dev/null
  iconutil -c icns /tmp/MyParrot.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MyParrot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# MAS-27:privacy manifest 兩版都嵌(內容＝docs/PRIVACY.md;不追蹤、不收集)。
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [ "$FLAVOR" = mas ]; then
  # MAS-04:商店版 bundle id(Eric 2026-10-29 B1)、顯示名維持 MyParrot、加密宣告(不含非豁免加密 ⇒ 免出口文件)。
  # 來源 Resources/Info.plist 不動(GitHub 版零回歸),只改這份複本。
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $MAS_BUNDLE_ID" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" "$APP/Contents/Info.plist"
  echo "▶ MAS Info.plist 補丁:CFBundleIdentifier=$MAS_BUNDLE_ID、ITSAppUsesNonExemptEncryption=false"
  # MAS-26 偏差(10/30):ASC processing 回 ITMS-90546「Missing asset catalog」——商店版 bundle 必須帶 Assets.car(含 AppIcon)。
  # 從既有 AppIcon.icns 反推 iconset → 組 .xcassets → actool 編成 Assets.car;Info.plist 的 CFBundleIconName=AppIcon 本來就有。
  # 只在商店版做(GitHub 版零回歸);actool 是 Xcode 的,商店版本來就要 Xcode。
  ACT_TMP="$(mktemp -d -t myparrot-assets)"
  iconutil -c iconset Resources/AppIcon.icns -o "$ACT_TMP/AppIcon.iconset"
  ICONSET_DIR="$ACT_TMP/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$ICONSET_DIR"
  printf '{"info":{"author":"xcode","version":1}}\n' > "$ACT_TMP/Assets.xcassets/Contents.json"
  {
    printf '{"images":['
    first=1
    for sz in 16 32 128 256 512; do
      for scale in 1 2; do
        if [ "$scale" = 1 ]; then f="icon_${sz}x${sz}.png"; else f="icon_${sz}x${sz}@2x.png"; fi
        [ -f "$ACT_TMP/AppIcon.iconset/$f" ] || { echo "❌ iconset 缺 $f(AppIcon.icns 不完整)"; exit 1; }
        cp "$ACT_TMP/AppIcon.iconset/$f" "$ICONSET_DIR/$f"
        [ "$first" = 1 ] || printf ','; first=0
        printf '{"idiom":"mac","size":"%sx%s","scale":"%sx","filename":"%s"}' "$sz" "$sz" "$scale" "$f"
      done
    done
    printf '],"info":{"author":"xcode","version":1}}\n'
  } > "$ICONSET_DIR/Contents.json"
  MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
  if ! xcrun actool "$ACT_TMP/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
       --minimum-deployment-target "$MIN_OS" --app-icon AppIcon \
       --output-partial-info-plist "$ACT_TMP/partial.plist" --output-format human-readable-text \
       --errors --warnings > "$ACT_TMP/actool.log" 2>&1; then
    echo "❌ actool 失敗:"; cat "$ACT_TMP/actool.log"; exit 1
  fi
  [ -f "$APP/Contents/Resources/Assets.car" ] || { echo "❌ actool 沒產出 Assets.car"; cat "$ACT_TMP/actool.log"; exit 1; }
  ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$ACT_TMP/partial.plist" 2>/dev/null || true)"
  [ "$ICON_NAME" = "AppIcon" ] || { echo "❌ actool partial plist CFBundleIconName=$ICON_NAME,應為 AppIcon"; exit 1; }
  echo "▶ embedded Assets.car(actool,AppIcon 10 張,min macOS $MIN_OS;$(stat -f %z "$APP/Contents/Resources/Assets.car") bytes)"
  rm -rf "$ACT_TMP"
fi

# UI-32:吉祥物 PNG 幀(idle=閉嘴/sing=張嘴);缺任一檔=用向量 fallback,不阻擋打包。
# 二審:白名單複製(cp -R 整個目錄會把備份檔/metadata 一起封進正式 bundle)。
# png_ok <f> = 檔存在且可解碼(二審 both:-f 只驗存在,零位元組/損壞檔會被打包
# 還印 embedded,執行期才靜默降級——建置期就驗,壞檔明講)。
png_ok() { [ -f "$1" ] && sips -g pixelWidth "$1" >/dev/null 2>&1; }
if png_ok Resources/mascot/idle.png && png_ok Resources/mascot/sing.png; then
  mkdir -p "$APP/Contents/Resources/mascot"
  cp Resources/mascot/idle.png Resources/mascot/sing.png "$APP/Contents/Resources/mascot/"
  echo "▶ embedded mascot frames"
else
  echo "⚠️ Resources/mascot/{idle,sing}.png 缺或不可解碼 — 吉祥物走向量 fallback"
fi
# UI-33b footer 大頭圖:與動畫幀用途獨立,單獨打包(二審:巢在上面 if 裡會在幀缺時
# 連帶無聲丟掉 head)。缺檔明講,不假裝完整成功。
# #2438 UI v2:鸚鵡新姿勢幀(缺檔不擋,app 用 idle 幀變形模擬)與計時字型(R1 Share Tech Mono,OFL 1.1)
for f in pant sleep; do
  if png_ok "Resources/mascot/$f.png"; then
    mkdir -p "$APP/Contents/Resources/mascot"
    cp "Resources/mascot/$f.png" "$APP/Contents/Resources/mascot/"
    echo "▶ embedded mascot frame $f"
  fi
done
if ls Resources/Fonts/*.ttf >/dev/null 2>&1; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
  [ -f Resources/Fonts/OFL.txt ] && cp Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"
  echo "▶ embedded fonts: $(ls Resources/Fonts/*.ttf | xargs -n1 basename | tr '\n' ' ')"
fi
# MAS-32(#2646):九語 InfoPlist.strings(TCC 用途字串)打進 Contents/Resources/<lang>.lproj/;缺任一語擋打包。
LPROJ_COUNT=0
for d in Resources/lproj/*.lproj; do
  [ -f "$d/InfoPlist.strings" ] || { echo "❌ $d 缺 InfoPlist.strings"; exit 1; }
  mkdir -p "$APP/Contents/Resources/$(basename "$d")"
  cp "$d/InfoPlist.strings" "$APP/Contents/Resources/$(basename "$d")/InfoPlist.strings"
  LPROJ_COUNT=$((LPROJ_COUNT + 1))
done
[ "$LPROJ_COUNT" = 9 ] || { echo "❌ lproj 應有 9 個,得 $LPROJ_COUNT"; exit 1; }
echo "▶ embedded InfoPlist.strings: $LPROJ_COUNT lproj"
# MAS-16(#2646):第三方授權全文(whisper.cpp MIT／SwiftyOpenCC MIT／OpenCC Apache-2.0／Share Tech Mono OFL)打進 bundle,
# 設定頁「第三方授權」展開讀這裡;缺檔擋打包(商店版沒有這些會違反各授權的附帶義務)。
if ls Resources/Licenses/*.txt >/dev/null 2>&1; then
  mkdir -p "$APP/Contents/Resources/Licenses"
  cp Resources/Licenses/*.txt "$APP/Contents/Resources/Licenses/"
  echo "▶ embedded licenses: $(ls Resources/Licenses/*.txt | wc -l | tr -d ' ') files"
else
  echo "❌ Resources/Licenses/*.txt 缺(第三方授權全文)"; exit 1
fi
if png_ok Resources/mascot/head.png; then
  mkdir -p "$APP/Contents/Resources/mascot"
  cp Resources/mascot/head.png "$APP/Contents/Resources/mascot/"
  echo "▶ embedded footer head icon"
else
  echo "⚠️ Resources/mascot/head.png 缺或不可解碼 — footer 小圖走 fallback(idle 幀→🦜)"
fi

# --- Build stamp (UI-16) ------------------------------------------------------
# 蓋進 Info.plist(簽章前),UI 左下顯示「build MMdd-HHmm <git短hash>[*]」;
# `*` = working tree 有未 commit 改動。讓測試一眼確認跑的是哪一版。
GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
DIRTY=""
[ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY="*"
STAMP="$(date +%m%d-%H%M) ${GIT_HASH}${DIRTY}"
/usr/libexec/PlistBuddy -c "Add :MPBuildStamp string $STAMP" "$APP/Contents/Info.plist"
echo "▶ build stamp: $STAMP"

# --- Whisper 引擎(TR-14/16/17):嵌入動態框架 + OpenCC 字典 bundle -----------
# whisper.framework 由 scripts/fetch-whisper.sh 產出(不進 git);缺了就跳過
# (app 仍可跑,Whisper 引擎會回退 Apple 原生並提示)。
if [ -d "Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MyParrot" 2>/dev/null || true
  echo "▶ embedded whisper.framework"
else
  echo "⚠️ Frameworks/whisper.xcframework 不存在 — 先跑 scripts/fetch-whisper.sh,否則 Whisper 引擎不可用"
fi
OPENCC_BUNDLE="$(dirname "$BIN")/SwiftyOpenCC_OpenCC.bundle"
if [ -d "$OPENCC_BUNDLE" ]; then
  cp -R "$OPENCC_BUNDLE" "$APP/Contents/Resources/"
  chmod -R u+w "$APP/Contents/Resources/SwiftyOpenCC_OpenCC.bundle"  # SPM checkout 唯讀,不加會卡 xattr/簽章
  echo "▶ embedded OpenCC dictionaries"
fi

# --- Pick a signing identity -------------------------------------------------
# TCC (permission memory) anchors grants to the signing identity. A real
# Apple-issued cert has a Team ID, so its Designated Requirement is stable across
# rebuilds → permissions asked ONCE. A self-signed cert (no Team ID) degrades to
# a per-build cdhash match → re-prompts every rebuild. Preference order:
#   1) $CODESIGN_IDENTITY override
#   2) Developer ID Application (works for local TCC same as Apple Development,
#      AND is the only cert type Apple's notary service accepts — so the default
#      dev-loop build is already release/notarize-ready with no separate mode)
#   3) Apple Development
#   4) the self-signed "MyParrot Dev" (works, but TCC won't persist across builds)
#   5) ad-hoc
HARDENED=0
if [ "$FLAVOR" = mas ]; then
  # MAS-24／25:功能測試用 Apple Development(同 Team ID、本機開得起來);發行用 Apple Distribution(本機不能直接開,只驗)。
  # 兩種都要同一個團隊的憑證(OU 相同),MAS-34 會對帳。CODESIGN_IDENTITY 可覆寫。
  HARDENED=1
  # 用 SHA-1 指紋而不是名字選憑證:同名的 Apple Development 憑證可能有兩張(Xcode 兩台機器各發一張),
  # codesign --sign "<名字>" 會回 ambiguous 整個簽不下去(2026-10-29 mas-dev 第一次就撞到)。
  pick_identity() {   # $1 = CN 前綴的 regex;印出「<40 碼指紋> <名字>」,取第一張
    security find-identity -v -p codesigning 2>/dev/null \
      | grep -E "\"($1)[^\"]*\"" | head -1 \
      | sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}) "(.*)"$/\1 \2/' || true
  }
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGN_ID="$CODESIGN_IDENTITY"; echo "▶ codesign with override identity: $SIGN_ID"
  elif [ "$MAS_SIGN" = dev ]; then
    HIT="$(pick_identity 'Apple Development')"
    [ -n "$HIT" ] || { echo "❌ 找不到 Apple Development 憑證(mas-dev 需要)。Xcode → Settings → Accounts → Manage Certificates → + Apple Development"; exit 1; }
    SIGN_ID="${HIT%% *}"; echo "▶ codesign(商店版·功能測試)with: ${HIT#* }(指紋 ${SIGN_ID:0:8}…)"
  else
    HIT="$(pick_identity 'Apple Distribution|3rd Party Mac Developer Application')"
    [ -n "$HIT" ] || { echo "❌ 找不到 Apple Distribution 憑證(mas-dist 需要)。developer.apple.com → Certificates → + → Apple Distribution,下載雙擊裝進登入鑰匙圈"; exit 1; }
    SIGN_ID="${HIT%% *}"; echo "▶ codesign(商店版·發行)with: ${HIT#* }(指紋 ${SIGN_ID:0:8}…)"
  fi
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
  SIGN_ID="$CODESIGN_IDENTITY"
  echo "▶ codesign with override identity: $SIGN_ID"
  HARDENED=1
else
  REAL_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
  [ -z "$REAL_ID" ] && REAL_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)"
  if [ -n "$REAL_ID" ]; then
    SIGN_ID="$REAL_ID"
    HARDENED=1
    echo "▶ codesign with Apple identity (TCC 跨版本保留): $SIGN_ID"
  elif security find-identity 2>/dev/null | grep -q "MyParrot Dev"; then
    SIGN_ID="MyParrot Dev"
    echo "▶ codesign with self-signed: MyParrot Dev"
    echo "  ⚠️ 自簽無 Team ID — 每次重新 build 後 macOS 會重問權限。"
    echo "     根治:Xcode → Settings → Accounts → Manage Certificates → + Apple Development,"
    echo "     腳本下次會自動改用該憑證。"
  else
    SIGN_ID="-"
    echo "▶ 找不到任何憑證 — 用 ad-hoc 簽章(每次都會重問權限)"
  fi
fi

# Hardened Runtime + a secure timestamp are required for notarization (scripts/
# notarize.sh) and harmless for plain local testing, so apply them whenever
# signing with any real Apple identity — one build works for both purposes.
CODESIGN_OPTS=()
[ "$HARDENED" = 1 ] && CODESIGN_OPTS=(--options runtime --timestamp)

# The project lives in iCloud Drive, whose fileprovider keeps re-adding the
# com.apple.FinderInfo xattr that blocks codesign. Retry a few times to catch a
# clean window (strip → sign immediately).
signed=0
for attempt in 1 2 3 4 5; do
  xattr -cr "$APP" 2>/dev/null || true   # best-effort;set -e 下不可讓它殺腳本
  # 內層先簽:嵌入的 framework 必須在外層 app 簽章前完成(nested code rule)。
  # (if 寫法防 set -e:框架簽失敗只警告,交由外層簽章的重試機制處理)
  if [ -d "$APP/Contents/Frameworks/whisper.framework" ]; then
    codesign --force --sign "$SIGN_ID" "${CODESIGN_OPTS[@]}" "$APP/Contents/Frameworks/whisper.framework" \
      || echo "⚠️ whisper.framework 簽章失敗(attempt $attempt)"
  fi
  if codesign --force --sign "$SIGN_ID" "${CODESIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP" 2>/dev/null; then
    signed=1; break
  fi
  sleep 1
done
[ "$signed" = 1 ] && echo "▶ codesign OK (attempt $attempt)" || echo "⚠️ codesign 仍失敗(iCloud 競態)— app 仍可跑但簽章可能是舊的"

if [ "$FLAVOR" = mas ]; then
  [ "$signed" = 1 ] || { echo "❌ 商店版簽章失敗,不繼續"; exit 1; }
  verify_mas_signature "$APP" || exit 1
fi

# --- mas-dist:不安裝,出 .pkg(MAS-25) ------------------------------------------
if [ "$FLAVOR" = mas ] && [ "$MAS_SIGN" = dist ]; then
  INSTALLER_ID="$(security find-identity -v -p basic 2>/dev/null | grep -oE '"(Mac Installer Distribution|3rd Party Mac Developer Installer)[^"]*"' | head -1 | tr -d '"' || true)"
  [ -n "$INSTALLER_ID" ] || { echo "❌ 找不到 Mac Installer Distribution 憑證(.pkg 簽章需要)。developer.apple.com → Certificates → + → Mac Installer Distribution"; exit 1; }
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  PKG="dist/mas/MyParrot-$VERSION-$BUILD_NO-mas.pkg"
  rm -f "$PKG"
  echo "▶ productbuild → $PKG(installer 簽:$INSTALLER_ID)"
  productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"
  pkgutil --check-signature "$PKG" | sed 's/^/   /'
  # 10/30（二審後）：Key ID／Issuer ID 任一沒在 env 時讀 ~/.private_keys/asc-ids.env —— 只認兩個 KEY=VALUE、🚫 不 source
  # （非秘密;.p8 另放同夾）。validate 是 mas-dist 的一部分(MAS-25):跑不了就 exit 2、altool 失敗就 exit 1,不再靜默回 0。
  IDS_FILE="${MYPARROT_ASC_IDS_FILE:-$HOME/.private_keys/asc-ids.env}"   # 測試用覆寫;平常不設
  if { [ -z "${MYPARROT_ASC_API_KEY_ID:-}" ] || [ -z "${MYPARROT_ASC_API_ISSUER_ID:-}" ]; } && [ -f "$IDS_FILE" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        ''|'#'*) continue ;;
        MYPARROT_ASC_API_KEY_ID)    [ -z "${MYPARROT_ASC_API_KEY_ID:-}" ]    && MYPARROT_ASC_API_KEY_ID="$v" ;;
        MYPARROT_ASC_API_ISSUER_ID) [ -z "${MYPARROT_ASC_API_ISSUER_ID:-}" ] && MYPARROT_ASC_API_ISSUER_ID="$v" ;;
        *) echo "❌ $IDS_FILE 有未知的 key「$k」(只認 MYPARROT_ASC_API_KEY_ID／MYPARROT_ASC_API_ISSUER_ID)"; exit 1 ;;
      esac
    done < "$IDS_FILE"
  fi
  if [ -n "${MYPARROT_ASC_API_KEY_ID:-}" ] && [ -n "${MYPARROT_ASC_API_ISSUER_ID:-}" ]; then
    case "$MYPARROT_ASC_API_KEY_ID" in
      *[!A-Z0-9]*|'') echo "❌ MYPARROT_ASC_API_KEY_ID 格式不對(預期 10 個大寫英數)"; exit 1 ;;
    esac
    [ -f "$HOME/.private_keys/AuthKey_$MYPARROT_ASC_API_KEY_ID.p8" ] || { echo "❌ 找不到 ~/.private_keys/AuthKey_$MYPARROT_ASC_API_KEY_ID.p8"; exit 1; }
    echo "▶ xcrun altool --validate-app(App Store Connect API key $MYPARROT_ASC_API_KEY_ID;.p8 放 ~/.private_keys/)"
    if ! xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$MYPARROT_ASC_API_KEY_ID" --apiIssuer "$MYPARROT_ASC_API_ISSUER_ID"; then
      echo "❌ altool validate 失敗:$PKG 不可送件"; exit 1
    fi
    echo "✅ 商店版 .pkg 已產出並通過 altool validate:$PKG(本機不會安裝;Apple Distribution 簽的 app 本機直接開會被 Gatekeeper 擋,是預期的)"
    exit 0
  fi
  echo "⚠️ 商店版 .pkg 已產出但**未經 altool 驗證**(缺 MYPARROT_ASC_API_KEY_ID／MYPARROT_ASC_API_ISSUER_ID,env 與 $IDS_FILE 都沒有):$PKG"
  echo "   驗證:xcrun altool --validate-app -f \"$PKG\" -t macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
  echo "   上傳:xcrun altool --upload-package … 或把 .pkg 拖進 Transporter.app"
  exit 2
fi

# --- Install to ~/Applications (non-iCloud) so the signature stays valid ------
# Running from the iCloud project dir lets iCloud re-break the signature; copying
# to ~/Applications (not synced) keeps it clean and the TCC grant stable.
DEST_DIR="${MYPARROT_DEST_DIR:-$HOME/Applications}"   # CLT-06:驗證時可指到別處,不碰現用 app
case "$DEST_DIR" in
  /*) ;;                                   # 只收絕對路徑
  *) echo "MYPARROT_DEST_DIR 必須是絕對路徑:$DEST_DIR"; exit 1 ;;
esac
DEST_DIR="${DEST_DIR%/}"
if [ -z "$DEST_DIR" ] || [ "$DEST_DIR" = "$(pwd)" ] || [ "$DEST_DIR" = "/" ] || [ "$DEST_DIR" = "$HOME" ]; then
  echo "MYPARROT_DEST_DIR 不可指到 /、家目錄或 repo 根:$DEST_DIR"; exit 1
fi
DEST="$DEST_DIR/$(basename "$APP")"
if [ "$FLAVOR" = mas ]; then
  # MAS-24 鐵則:商店版測試 build 只能叫 MyParrot-mas.app,🚫 絕不覆蓋 Eric 現用的 MyParrot.app。
  [ "$(basename "$DEST")" = "MyParrot-mas.app" ] || { echo "❌ 商店版安裝名必須是 MyParrot-mas.app,得 $DEST"; exit 1; }
fi
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null   # strip once; outside iCloud it won't come back
if codesign --verify --strict "$DEST" 2>/dev/null; then
  echo "▶ 已安裝到 $DEST(簽章 strict 驗證通過)"
else
  echo "▶ 已安裝到 $DEST(strict 驗證未過,但可執行)"
fi

echo "✅ Built & installed $(basename "$APP")"
echo "   執行(建議從這裡開,權限才記得住):  open \"$DEST\""
echo "   ⚠️ 換新版前先 Cmd+Q 完全關掉舊的,否則 open 只會把舊實例叫到前面。"
echo "   首次啟動只會要 麥克風 + 語音辨識 + 系統音訊擷取(不要螢幕錄影)。"
