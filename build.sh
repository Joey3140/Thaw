#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Thaw"
BUNDLE_ID="com.stonerl.Thaw"
SIGN_ID="Developer ID Application: Joseph Drury (4MMDJ2N969)"
TEAM_ID="4MMDJ2N969"
DERIVED="build"
# notarytool keychain profile (team 4MMDJ2N969). Created once with
# `xcrun notarytool store-credentials`; shared with the user's other apps.
NOTARY_PROFILE="claudequota-notary"

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
# xcodebuild does not re-sign, so they keep Sparkle's own (ad-hoc, team-less)
# signature. Re-sign them with our Developer ID, inside-out, then re-seal the
# outer app so the whole bundle is uniformly Dev ID signed (notarization-ready).
# NOTE: Sparkle's PREBUILT Downloader.xpc/Installer.xpc ship with *empty*
# entitlements in their code signature (the App Sandbox entitlements in Sparkle's
# source `.entitlements` only apply when building Sparkle from source, which we
# don't). So there is no sandbox here to preserve; a plain re-sign is correct.
# We deliberately do NOT inject app-sandbox onto these prebuilt binaries — doing
# so on a binary not built for containerization would risk runtime failures.
while IFS= read -r nested; do
    [ -e "$nested" ] || continue
    echo "Re-signing nested: ${nested#"$APP_PATH"/}"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$nested" 2>&1 | tail -1 || true
done < <(find "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
    \( -name "Updater.app" -o -name "Autoupdate" -o -name "*.xpc" \) 2>/dev/null)

# Strip the debug `get-task-allow` entitlement that xcodebuild injects into the
# embedded XPC services (the targets have an empty CODE_SIGN_ENTITLEMENTS, so
# base-entitlement injection stamps it). MenuBarItemService holds Accessibility
# privilege and MenuBarCaptureService (added in 2.x) holds Screen Recording; a
# debuggable helper lets any same-user process task_for_pid() and inject code
# into a TCC-trusted process. Neither service needs entitlements (upstream's
# notarized 2.1.0 ships both with an empty set), so re-sign with NONE (no
# --entitlements, no --preserve-metadata) before the outer re-seal folds them
# into the bundle signature.
XPC_SERVICES=()
for xpc in "$APP_PATH"/Contents/XPCServices/*.xpc; do
    [ -d "$xpc" ] || continue
    XPC_SERVICES+=("$xpc")
    echo "Re-signing (stripping get-task-allow): ${xpc#"$APP_PATH"/}"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$xpc" 2>&1 | tail -1 || true
done
[ "${#XPC_SERVICES[@]}" -gt 0 ] || { echo "ERROR: no XPC services found in $APP_PATH" >&2; exit 1; }

# The outer app keeps whatever entitlements the project declares (2.1.0 has
# com.apple.security.files.user-selected.read-only) minus get-task-allow, so a
# re-seal can't silently drop an entitlement upstream adds later.
APP_ENTITLEMENTS="$DERIVED/$APP_NAME.resign.entitlements"
codesign -d --entitlements - --xml "$APP_PATH" > "$APP_ENTITLEMENTS" 2>/dev/null || true
APP_ENTITLEMENT_ARGS=()
if [ -s "$APP_ENTITLEMENTS" ]; then
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$APP_ENTITLEMENTS" >/dev/null 2>&1 || true
    APP_ENTITLEMENT_ARGS=(--entitlements "$APP_ENTITLEMENTS")
fi

# Re-seal the framework and the outer app over the new nested signatures.
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework" 2>&1 | tail -1 || true
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    ${APP_ENTITLEMENT_ARGS[@]+"${APP_ENTITLEMENT_ARGS[@]}"} \
    --identifier "$BUNDLE_ID" "$APP_PATH" 2>&1 | tail -1 || true

codesign --verify --deep --strict "$APP_PATH" && echo "Signature: valid (deep/strict)"

# Assert neither the app nor its privileged helpers are debuggable. codesign
# prints the entitlements plist to stdout; grep for the dangerous key and fail
# the build if it survived (regression guard for the injection above).
for signed in "$APP_PATH" "${XPC_SERVICES[@]}"; do
    if codesign -d --entitlements - "$signed" 2>/dev/null | grep -q "get-task-allow"; then
        echo "ERROR: ${signed#"$DERIVED"/} still carries com.apple.security.get-task-allow" >&2
        exit 1
    fi
done
echo "Verified: app and XPC helpers have no get-task-allow"

# Notarize + staple. Beyond clearing the Gatekeeper "unidentified developer"
# block on other Macs, a notarized + stapled build is what keeps TCC grants
# (Accessibility / Screen Recording) attached across rebuilds — an un-notarized
# rebuild changes the code identity enough that macOS treats the grant as stale
# (shows ON in Settings but captures return transparent). Stapling writes the
# ticket into the bundle without re-signing, so the install below carries it.
# Set SKIP_NOTARIZE=1 for a fast local-iteration build you won't rely on TCC for.
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "SKIP_NOTARIZE=1 — skipping notarization (TCC grants may go stale on this build)."
else
    echo "Notarizing with Apple (uploads + waits for verdict, ~1-5 min)..."
    NOTARIZE_ZIP="$DERIVED/$APP_NAME-notarize.zip"
    rm -f "$NOTARIZE_ZIP"
    # notarytool needs an archive; ditto preserves the bundle + xattrs.
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
    if ! xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "ERROR: notarization failed, so nothing was installed. A 401 means the app-specific" >&2
        echo "password in keychain profile '$NOTARY_PROFILE' is no longer valid: make a new one at" >&2
        echo "appleid.apple.com, then run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID" >&2
        exit 1
    fi
    xcrun stapler staple "$APP_PATH"
    rm -f "$NOTARIZE_ZIP"
    spctl -a -vv "$APP_PATH" 2>&1 | grep -E "accepted|source=" || true
    echo "Notarized + stapled."
fi

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
