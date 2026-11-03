#!/bin/zsh
# Builds Lavalier.app into ./build and code-signs it.
# Usage: ./build.sh [release|debug]   (default release)
#
# Signing identity, first match wins:
#   1. LAVALIER_SIGN_IDENTITY, if set: a name or SHA-1 hash from `security find-identity -v -p codesigning`,
#      or "-" for ad hoc.
#   2. The first "Apple Development" identity in your keychain (Xcode creates one for any Apple ID).
#   3. Ad hoc. The app works, but macOS treats every rebuild as a new app: you grant Microphone,
#      Accessibility and Input Monitoring again after each rebuild, and the Keychain asks once before the
#      new build may read the keys you saved.
# Signing with the same Apple Development identity every time keeps those grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
BIN=".build/$CONFIG/Lavalier"

IDENTITY="${LAVALIER_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ {print $2; exit}' || true)
fi
ADHOC=0
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
    IDENTITY="-"
    ADHOC=1
fi

rm -f "$BIN"
if ! swift build -c "$CONFIG" --product Lavalier 2>&1 | grep -v '^\['; then
    echo "build failed"; exit 1
fi
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing"; exit 1; }
APP="build/Lavalier.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lavalier"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || true
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign "$IDENTITY" --identifier com.davidfinnegan.lavalier --timestamp=none "$APP"
if [[ "$ADHOC" -eq 1 ]]; then
    echo "signed ad hoc: no Apple Development identity found. After each rebuild, grant the permissions again"
    echo "and allow the Keychain prompt once. See docs/SETUP.md, 'Signing'."
else
    codesign -dv "$APP" 2>&1 | grep -E '^Identifier=|^Authority=Apple Development|^TeamIdentifier=' || true
fi
echo "built $APP"
