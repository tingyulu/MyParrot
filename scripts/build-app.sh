#!/bin/bash
# Assembles a runnable MyParrot.app from the SwiftPM build product, signs it, and
# installs it to ~/Applications (OUTSIDE iCloud Drive) so macOS TCC remembers the
# mic / speech / audio-capture grants instead of re-prompting every launch.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"   # 預設 debug(快);交付才用 release

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"

# Guard: every L("…") key must have a translation (non-fatal, but surfaced).
echo "▶ check translations"
swift scripts/check-translations.swift Sources/MyParrot || echo "⚠️ 有 key 缺翻譯(見上),不阻擋打包"

APP="MyParrot.app"
BIN=".build/$CONFIG/MyParrot"

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
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
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
  if codesign --force --sign "$SIGN_ID" "${CODESIGN_OPTS[@]}" --entitlements Resources/MyParrot.entitlements "$APP" 2>/dev/null; then
    signed=1; break
  fi
  sleep 1
done
[ "$signed" = 1 ] && echo "▶ codesign OK (attempt $attempt)" || echo "⚠️ codesign 仍失敗(iCloud 競態)— app 仍可跑但簽章可能是舊的"

# --- Install to ~/Applications (non-iCloud) so the signature stays valid ------
# Running from the iCloud project dir lets iCloud re-break the signature; copying
# to ~/Applications (not synced) keeps it clean and the TCC grant stable.
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null   # strip once; outside iCloud it won't come back
if codesign --verify --strict "$DEST" 2>/dev/null; then
  echo "▶ 已安裝到 $DEST(簽章 strict 驗證通過)"
else
  echo "▶ 已安裝到 $DEST(strict 驗證未過,但可執行)"
fi

echo "✅ Built & installed MyParrot.app"
echo "   執行(建議從這裡開,權限才記得住):  open \"$DEST\""
echo "   ⚠️ 換新版前先 Cmd+Q 完全關掉舊的,否則 open 只會把舊實例叫到前面。"
echo "   首次啟動只會要 麥克風 + 語音辨識 + 系統音訊擷取(不要螢幕錄影)。"
