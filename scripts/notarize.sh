#!/bin/bash
# Submits the already-built MyParrot.app (from scripts/build-app.sh) to Apple's
# notary service, staples the ticket, and verifies Gatekeeper acceptance.
# Separate from build-app.sh on purpose: notarization takes minutes and talks
# to Apple's servers, so it must never run as part of the everyday dev loop.
#
# Prerequisites:
#   1. A "Developer ID Application" certificate in the keychain (Xcode →
#      Settings → Accounts → Manage Certificates → + Developer ID Application).
#   2. Notary credentials stored once via:
#        xcrun notarytool store-credentials "MyParrot-notary" \
#          --apple-id <your Apple ID> --team-id <team ID>
#      (omit --password for a secure interactive prompt)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="MyParrot.app"
PROFILE="${NOTARY_PROFILE:-MyParrot-notary}"

[ -d "$APP" ] || { echo "❌ 找不到 $APP — 先跑 scripts/build-app.sh"; exit 1; }

# Notarization only accepts Developer ID Application signatures; Apple
# Development (the everyday local-testing cert) is rejected outright.
AUTHORITY="$(codesign -dvvv "$APP" 2>&1 | grep '^Authority=' | head -1 || true)"
case "$AUTHORITY" in
  *"Developer ID Application"*) ;;
  *)
    echo "❌ $APP 目前簽章身份是「${AUTHORITY:-無}」,不是 Developer ID Application — 公證一定會被拒。"
    echo "   用該身份重新 build 一次:"
    echo "   CODESIGN_IDENTITY=\"Developer ID Application: ...\" bash scripts/build-app.sh"
    exit 1
    ;;
esac

ZIP="/tmp/MyParrot-notarize.zip"
rm -f "$ZIP"
echo "▶ zipping $APP for submission..."
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▶ submitting to Apple notary service (--wait,可能要幾分鐘)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "▶ stapling ticket to $APP..."
xcrun stapler staple "$APP"

echo "▶ verifying Gatekeeper acceptance..."
spctl -a -vvv --type execute "$APP"

echo "✅ $APP 已公證 + staple,可直接發布給其他人(下載後不會跳 Gatekeeper 警告)"
