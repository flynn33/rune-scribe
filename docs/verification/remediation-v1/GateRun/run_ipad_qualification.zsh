#!/bin/zsh
set -euo pipefail

ROOT=/Users/jimdaley/GitHub/Rune-Scribe-Remediation-v1
TEMP=/tmp/runescribe-sourcebound-domain-terminal.C1mmD0
UDID=77D54A1F-0818-4761-B946-D7723490F6B3
BUNDLE_ID=com.runescribe.app
REVISION=5642f169a72eccd8615e284816db63a75a0a18c1
TREE=c56eaa91d5ed78c7ba01129f21d974698a9aab8a
SOURCE_HASH=47a1aa1c98ab120164223b53b4430a5dbd7d07f77a49fb57a25fa475a01a362d
APP="$TEMP/DerivedData-ios-release/Build/Products/Release-iphonesimulator/RuneScrib.app"
STATUS="$TEMP/ipad-qualification-status.log"

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
    >"$TEMP/ipad-source-manifest-pre.log"
rg -q "$SOURCE_HASH" "$TEMP/ipad-source-manifest-pre.log"
[[ -d "$APP" ]]
shutdown_and_verify

record "phase=ipad-hosted"
xcrun simctl erase "$UDID" >/dev/null
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >"$TEMP/ipad-hosted-boot.log" 2>&1
xcodebuild test \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-iOS \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -destination-timeout 120 \
    -derivedDataPath "$TEMP/DerivedData-ipad-hosted" \
    -resultBundlePath "$TEMP/ipad-hosted.xcresult" \
    -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    >"$TEMP/ipad-hosted.log" 2>&1
record "ipad_hosted_exit=0"
shutdown_and_verify

record "phase=pre-ui-reset"
xcrun simctl erase "$UDID" >/dev/null
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >"$TEMP/ipad-ui-boot.log" 2>&1
if xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
    record "pre_ui_uninstall=removed"
else
    record "pre_ui_uninstall=absent"
fi
xcrun simctl keychain "$UDID" reset >/dev/null
record "pre_ui_keychain_reset_exit=0"

record "phase=ipad-ui-exact-four"
xcodebuild test \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-iOS-Parity \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -destination-timeout 120 \
    -derivedDataPath "$TEMP/DerivedData-ipad-ui" \
    -resultBundlePath "$TEMP/ipad-ui.xcresult" \
    -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO \
    -only-testing:RuneScribIOSUITests/RuneScribeParityUITests/testNorseVisualPresentationAndScreenshots \
    -only-testing:RuneScribIOSUITests/RuneScribeParityUITests/testShareBuilderControlsExposeStableAccessibilityState \
    -only-testing:RuneScribIOSUITests/RuneScribeParityUITests/testCipherLibraryShareActionsExposeUsableHitRegions \
    -only-testing:RuneScribIOSUITests/RuneScribeParityUITests/testFreshInstallExercisesPrimaryProductFlows \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    >"$TEMP/ipad-ui.log" 2>&1
record "ipad_ui_exit=0"
shutdown_and_verify

record "phase=release-install-launch-terminate"
xcrun simctl erase "$UDID" >/dev/null
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >"$TEMP/ipad-release-boot.log" 2>&1
xcrun simctl install "$UDID" "$APP" >"$TEMP/ipad-release-install.log" 2>&1
record "release_install_exit=0"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
    >"$TEMP/ipad-release-launch.log" 2>&1
record "release_launch_exit=0"
sleep 2
xcrun simctl terminate "$UDID" "$BUNDLE_ID" \
    >"$TEMP/ipad-release-terminate.log" 2>&1
record "release_terminate_exit=0"
shutdown_and_verify

record "overall_exit=0"
[[ "$(git rev-parse HEAD)" == "$REVISION" ]]
[[ "$(git rev-parse HEAD^{tree})" == "$TREE" ]]
[[ -z "$(git status --porcelain)" ]]
python3 scripts/generate-source-manifest.py --verify . \
    docs/verification/remediation-v1/SOURCE-MANIFEST.json \
    >"$TEMP/ipad-source-manifest-post.log"
rg -q "$SOURCE_HASH" "$TEMP/ipad-source-manifest-post.log"
print -r -- "iPad qualification PASS"
