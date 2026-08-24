#!/bin/zsh
set -euo pipefail

ROOT=/Users/jimdaley/GitHub/Rune-Scribe-Remediation-v1
TEMP=/tmp/runescribe-sourcebound-domain-terminal.C1mmD0
UDID=1563B47A-700D-4AEF-A8D5-89780C581F83
BUNDLE_ID=com.runescribe.app
REVISION=5642f169a72eccd8615e284816db63a75a0a18c1
TREE=c56eaa91d5ed78c7ba01129f21d974698a9aab8a
SOURCE_HASH=47a1aa1c98ab120164223b53b4430a5dbd7d07f77a49fb57a25fa475a01a362d
APP="$TEMP/DerivedData-ios-release/Build/Products/Release-iphonesimulator/RuneScrib.app"
STATUS="$TEMP/iphone-qualification-status.log"

print -r -- "source=$REVISION" >"$STATUS"

record() {
    print -r -- "$1" >>"$STATUS"
}

shutdown_and_verify() {
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    if pgrep -x Simulator >/dev/null 2>&1; then
        osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
    fi
    local state=""
    for _ in {1..40}; do
        state=$(xcrun simctl list devices | rg "$UDID" | head -1 || true)
        if [[ "$state" == *"(Shutdown)"* ]] && ! pgrep -x Simulator >/dev/null 2>&1; then
            record "cleanup_device_state=Shutdown"
            record "cleanup_simulator_app=NOT_RUNNING"
            return 0
        fi
        sleep 0.25
    done
    record "cleanup_device_state=${state:-UNKNOWN}"
    record "cleanup_simulator_app=FAILED"
    return 1
}

cleanup() {
    shutdown_and_verify || true
}
trap cleanup EXIT INT TERM

cd "$ROOT"
[[ "$(git rev-parse HEAD)" == "$REVISION" ]]
[[ "$(git rev-parse HEAD^{tree})" == "$TREE" ]]
[[ -z "$(git status --porcelain)" ]]
python3 scripts/generate-source-manifest.py --verify . \
    docs/verification/remediation-v1/SOURCE-MANIFEST.json \
    >"$TEMP/iphone-source-manifest-pre.log"
rg -q "$SOURCE_HASH" "$TEMP/iphone-source-manifest-pre.log"
shutdown_and_verify

record "phase=release-build"
xcodebuild \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-iOS \
    -configuration Release \
    -destination "platform=iOS Simulator,id=$UDID" \
    -destination-timeout 120 \
    -derivedDataPath "$TEMP/DerivedData-ios-release" \
    -resultBundlePath "$TEMP/ios-release.xcresult" \
    -disableAutomaticPackageResolution \
    clean build \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=9AQ2C2838M \
    PROVISIONING_PROFILE_SPECIFIER= \
    >"$TEMP/ios-release.log" 2>&1
record "release_build_exit=0"
shutdown_and_verify

record "phase=iphone-hosted"
xcrun simctl erase "$UDID" >/dev/null
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >"$TEMP/iphone-hosted-boot.log" 2>&1
xcodebuild test \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-iOS \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -destination-timeout 120 \
    -derivedDataPath "$TEMP/DerivedData-iphone-hosted" \
    -resultBundlePath "$TEMP/iphone-hosted.xcresult" \
    -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    >"$TEMP/iphone-hosted.log" 2>&1
record "iphone_hosted_exit=0"
shutdown_and_verify

record "phase=pre-ui-reset"
xcrun simctl erase "$UDID" >/dev/null
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >"$TEMP/iphone-ui-boot.log" 2>&1
if xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
    record "pre_ui_uninstall=removed"
else
    record "pre_ui_uninstall=absent"
fi
xcrun simctl keychain "$UDID" reset >/dev/null
record "pre_ui_keychain_reset_exit=0"

record "phase=iphone-ui"
xcodebuild test \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-iOS-Parity \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -destination-timeout 120 \
    -derivedDataPath "$TEMP/DerivedData-iphone-ui" \
    -resultBundlePath "$TEMP/iphone-ui.xcresult" \
    -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    >"$TEMP/iphone-ui.log" 2>&1
record "iphone_ui_exit=0"
shutdown_and_verify

record "phase=release-install-launch-terminate"
xcrun simctl erase "$UDID" >/dev/null
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >"$TEMP/iphone-release-boot.log" 2>&1
xcrun simctl install "$UDID" "$APP" >"$TEMP/iphone-release-install.log" 2>&1
record "release_install_exit=0"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
    >"$TEMP/iphone-release-launch.log" 2>&1
record "release_launch_exit=0"
sleep 2
xcrun simctl terminate "$UDID" "$BUNDLE_ID" \
    >"$TEMP/iphone-release-terminate.log" 2>&1
record "release_terminate_exit=0"
shutdown_and_verify

record "overall_exit=0"
[[ "$(git rev-parse HEAD)" == "$REVISION" ]]
[[ "$(git rev-parse HEAD^{tree})" == "$TREE" ]]
[[ -z "$(git status --porcelain)" ]]
python3 scripts/generate-source-manifest.py --verify . \
    docs/verification/remediation-v1/SOURCE-MANIFEST.json \
    >"$TEMP/iphone-source-manifest-post.log"
rg -q "$SOURCE_HASH" "$TEMP/iphone-source-manifest-post.log"
print -r -- "iPhone qualification PASS"
