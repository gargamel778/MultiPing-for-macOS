#!/bin/bash
#
# Build, Developer ID-sign, notarize and install MultiPing for macOS.
#
# Replaces the ad-hoc signature (which Gatekeeper rejects outright) with a real
# Developer ID signature plus an Apple notarization ticket, so the app launches
# with no warning here and on any other Mac.
#
# ONE-TIME PREREQUISITES (both need your Apple account, so they are yours to do):
#
#   1. A "Developer ID Application" certificate. xcodebuild cannot create one —
#      -allowProvisioningUpdates only handles development/App Store certs.
#      Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ +
#           ▸ "Developer ID Application"
#
#   2. Notarization credentials stored in the keychain under the profile name
#      below. Create an app-specific password at appleid.apple.com (Sign-In and
#      Security ▸ App-Specific Passwords), then run:
#
#        xcrun notarytool store-credentials "MultiPing-Notary" \
#          --apple-id "$MULTIPING_APPLE_ID" --team-id "<your-team-id>"
#
#      It prompts for that password and stores it in your keychain. Nothing in
#      this script ever sees or handles the password.
#
set -euo pipefail

TEAM="<your-team-id>"
SCHEME="MultiPing for macOS"
APP_NAME="MultiPing for macOS.app"
KEYCHAIN_PROFILE="MultiPing-Notary"
INSTALL_DIR="/Applications"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ_DIR="$REPO/MultiPing for macOS"
BUILD_DIR="${TMPDIR:-/tmp}/multiping-signed-build"
APP="$BUILD_DIR/Build/Products/Release/$APP_NAME"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
say "Preflight"

# `|| true` matters: grep exits 1 when there is no match, and under
# `set -e -o pipefail` that would abort the script here — before the helpful
# message below ever prints, leaving a bare "exit 1".
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
           | grep "Developer ID Application" | grep "$TEAM" | head -1 \
           | sed -E 's/.*"(.*)".*/\1/' || true)
[ -n "$IDENTITY" ] || die "No 'Developer ID Application' certificate for team $TEAM.
       Create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + (see header)."
echo "  signing identity: $IDENTITY"

xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
  || die "No notarization credentials under profile '$KEYCHAIN_PROFILE'.
       Run the xcrun notarytool store-credentials command in this script's header."
echo "  notary profile:   $KEYCHAIN_PROFILE  (ok)"

# ------------------------------------------------------------------- build
say "Building Release with hardened runtime"
rm -rf "$BUILD_DIR"
xcodebuild -project "$PROJ_DIR/MultiPing.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -derivedDataPath "$BUILD_DIR" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  build | tail -3

[ -d "$APP" ] || die "build produced no app at $APP"

# ------------------------------------------------------------------- sign
# Inside-out: every nested executable must be signed before the outer bundle,
# or the outer signature seals a binary that later changes and breaks it.
say "Signing nested binaries, then the bundle"
while IFS= read -r bin; do
  echo "  nested: ${bin#$APP/}"
  codesign --force --sign "$IDENTITY" --timestamp --options runtime "$bin"
done < <(find "$APP/Contents/Resources" "$APP/Contents/Frameworks" \
              -type f -perm +111 2>/dev/null)

codesign --force --sign "$IDENTITY" --timestamp --options runtime \
         --entitlements "$PROJ_DIR/MultiPing/MultiPing.entitlements" "$APP"

say "Verifying signature before submission"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=|flags="

# --------------------------------------------------------------- notarize
say "Submitting to Apple for notarization (this usually takes 1-5 minutes)"
ZIP="$BUILD_DIR/MultiPing.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
  echo
  echo "Notarization failed. Apple's per-issue detail:"
  SUB=$(xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" -f json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["history"][0]["id"])')
  xcrun notarytool log "$SUB" --keychain-profile "$KEYCHAIN_PROFILE"
  die "notarization rejected (see log above)"
fi

say "Stapling the ticket so it validates offline"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

say "Gatekeeper assessment"
spctl -a -vvv "$APP" 2>&1 | head -5

# ---------------------------------------------------------------- install
# Keep the previous copy as a fallback until the new one is verified in place.
say "Installing to $INSTALL_DIR"
TARGET="$INSTALL_DIR/$APP_NAME"
BACKUP="$INSTALL_DIR/.$APP_NAME.previous"

if [ -d "$TARGET" ]; then
  echo "  backing up existing copy -> $BACKUP"
  rm -rf "$BACKUP"
  ditto "$TARGET" "$BACKUP"
  pkill -x "MultiPing for macOS" 2>/dev/null || true
  sleep 1
  rm -rf "$TARGET"
fi

ditto "$APP" "$TARGET"

SRC_SUM=$(find "$APP"    -type f -exec md5 -q {} \; | sort | md5 -q)
DST_SUM=$(find "$TARGET" -type f -exec md5 -q {} \; | sort | md5 -q)
echo "  source checksum:      $SRC_SUM"
echo "  destination checksum: $DST_SUM"
if [ "$SRC_SUM" != "$DST_SUM" ]; then
  echo "  checksum MISMATCH — rolling back"
  rm -rf "$TARGET"
  [ -d "$BACKUP" ] && ditto "$BACKUP" "$TARGET"
  die "install verification failed; previous version restored"
fi

if ! spctl -a -vvv "$TARGET" >/dev/null 2>&1; then
  echo "  installed copy fails Gatekeeper — rolling back"
  rm -rf "$TARGET"
  [ -d "$BACKUP" ] && ditto "$BACKUP" "$TARGET"
  die "installed app rejected by Gatekeeper; previous version restored"
fi

say "Done — signed, notarized, stapled and installed"
echo "  $TARGET"
echo "  rollback copy kept at $BACKUP (delete once you're happy)"
