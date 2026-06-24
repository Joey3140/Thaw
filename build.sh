#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Thaw"
BUNDLE_ID="com.stonerl.Thaw"
SIGN_ID="Developer ID Application: Joseph Drury (4MMDJ2N969)"
TEAM_ID="4MMDJ2N969"
DERIVED="build"

echo "Building $APP_NAME with Developer ID signing..."

# The shared SwiftPM manifest cache occasionally corrupts ("ManifestLoading …
# already exists"), breaking package resolution. Clear it defensively and keep
# this build's checkouts isolated so concurrent resolutions can't race it.
rm -rf ~/Library/Caches/org.swift.swiftpm/manifests 2>/dev/null || true
rm -rf "$DERIVED"

# Sign with a STABLE Developer ID (not the upstream "Apple Development" identity)
# so TCC consent — Accessibility especially, which this menu-bar manager needs —
# persists across rebuilds. ENABLE_HARDENED_RUNTIME=YES is already set per-target;
# --timestamp adds the secure Apple timestamp. This also re-signs the embedded
# MenuBarItemService.xpc and Sparkle.framework with the same identity.
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    clean build

APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "ERROR: $APP_PATH not produced" >&2; exit 1; }
echo "Built: $APP_PATH"

# Sparkle ships a prebuilt Updater.app/Autoupdate inside its framework that
# xcodebuild does not re-sign, so they keep Sparkle's own (team-less) signature.
# Re-sign them with our Developer ID, inside-out, then re-seal the outer app so
# the whole bundle is uniformly Dev ID signed (notarization-ready).
while IFS= read -r nested; do
    [ -e "$nested" ] || continue
    echo "Re-signing nested: ${nested#"$APP_PATH"/}"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$nested" 2>&1 | tail -1 || true
done < <(find "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
    \( -name "Updater.app" -o -name "Autoupdate" -o -name "*.xpc" \) 2>/dev/null)
# Re-seal the framework and the outer app over the new nested signatures.
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework" 2>&1 | tail -1 || true
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    --identifier "$BUNDLE_ID" "$APP_PATH" 2>&1 | tail -1 || true

codesign --verify --deep --strict "$APP_PATH" && echo "Signature: valid (deep/strict)"

# Quit a running instance (if any) so the new binary takes over, then install.
# Don't auto-launch a non-running instance — Thaw is a menu-bar MANAGER; starting
# it rearranges the menu bar and prompts for Accessibility. Leave that to the user.
WAS_RUNNING=0
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    WAS_RUNNING=1
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    for _ in $(seq 1 25); do
        pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null || break
        sleep 0.2
    done
    pkill -9 -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_PATH" "/Applications/$APP_NAME.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "/Applications/$APP_NAME.app" 2>/dev/null || true
echo "Installed: /Applications/$APP_NAME.app"

if [ "$WAS_RUNNING" = "1" ]; then
    open "/Applications/$APP_NAME.app"
    echo "Relaunched $APP_NAME (was running)"
else
    echo "Not launching — $APP_NAME is a menu-bar manager; start it yourself when ready."
fi
