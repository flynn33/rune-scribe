#!/bin/zsh
set -euo pipefail

ROOT=/Users/jimdaley/GitHub/Rune-Scribe-Remediation-v1
OUTPUT_ROOT=/tmp/runescribe-sourcebound-domain-terminal.C1mmD0
EXPECTED_HEAD=5642f169a72eccd8615e284816db63a75a0a18c1
EXPECTED_TREE=c56eaa91d5ed78c7ba01129f21d974698a9aab8a
EXPECTED_SOURCE=47a1aa1c98ab120164223b53b4430a5dbd7d07f77a49fb57a25fa475a01a362d
APP="$OUTPUT_ROOT/DerivedData-macos-release/Build/Products/Release/RuneScrib.app"
LOCAL_ROOT="$OUTPUT_ROOT/macos-local-launch"
LOCAL_APP="$LOCAL_ROOT/RuneScrib.app"
LOCAL_ENTITLEMENTS="$LOCAL_ROOT/local-launch.entitlements"
LOCAL_PATTERN='macos-local-launch/RuneScrib\.app/Contents/MacOS/RuneScrib$'

for candidate_path in \
    "$OUTPUT_ROOT/DerivedData-macos-release" \
    "$OUTPUT_ROOT/DerivedData-macos-hosted" \
    "$OUTPUT_ROOT/DerivedData-macos-parity" \
    "$OUTPUT_ROOT/DerivedData-macos-release-devsigned" \
    "$OUTPUT_ROOT/macos-release.xcresult" \
    "$OUTPUT_ROOT/macos-hosted.xcresult" \
    "$OUTPUT_ROOT/macos-parity.xcresult" \
    "$OUTPUT_ROOT/macos-release-devsigned.xcresult" \
    "$OUTPUT_ROOT/macos-attachments-final" \
    "$LOCAL_ROOT"
do
    [[ ! -e "$candidate_path" ]]
done

cleanup() {
    local pid
    pid=$(pgrep -f "$LOCAL_PATTERN" | head -1 || true)
    if [[ -n "$pid" ]]; then
        kill "$pid" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

cd "$ROOT"
[[ "$(git rev-parse HEAD)" == "$EXPECTED_HEAD" ]]
[[ "$(git rev-parse HEAD^{tree})" == "$EXPECTED_TREE" ]]
[[ -z "$(git status --porcelain)" ]]
! pgrep -x RuneScrib >/dev/null 2>&1
! pgrep -x Simulator >/dev/null 2>&1
! pgrep -x xcodebuild >/dev/null 2>&1
xcrun simctl list devices | rg -q \
    'iPhone 17 Pro \(1563B47A-700D-4AEF-A8D5-89780C581F83\) \(Shutdown\)'
xcrun simctl list devices | rg -q \
    'iPad Pro 13-inch \(M5\) \(77D54A1F-0818-4761-B946-D7723490F6B3\) \(Shutdown\)'
python3 scripts/generate-source-manifest.py --verify "$ROOT" \
    docs/verification/remediation-v1/SOURCE-MANIFEST.json \
    >"$OUTPUT_ROOT/source-manifest-verify.log" 2>&1
rg -q "$EXPECTED_SOURCE" "$OUTPUT_ROOT/source-manifest-verify.log"

xcodebuild \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-macOS \
    -configuration Release \
    -destination platform=macOS,arch=arm64 \
    -derivedDataPath "$OUTPUT_ROOT/DerivedData-macos-release" \
    -resultBundlePath "$OUTPUT_ROOT/macos-release.xcresult" \
    -disableAutomaticPackageResolution \
    clean build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    >"$OUTPUT_ROOT/macos-release.log" 2>&1

{
    print -r -- "COMMAND: codesign --force --deep --sign - --options runtime --timestamp=none --entitlements Config/RuneScrib-macOS.entitlements $APP"
    codesign --force --deep --sign - --options runtime --timestamp=none \
        --entitlements Config/RuneScrib-macOS.entitlements "$APP"
    codesign --verify --deep --strict --verbose=4 "$APP"
    codesign -d --verbose=4 "$APP"
    codesign -d --entitlements :- "$APP"
} >"$OUTPUT_ROOT/macos-release-signing.log" 2>&1

{
    print -r -- "sourceRevision=$EXPECTED_HEAD"
    print -r -- "sourceTree=$EXPECTED_TREE"
    print -r -- "sourceAggregate=$EXPECTED_SOURCE"
    shasum -a 256 "$APP/Contents/MacOS/RuneScrib" \
        "$APP/Contents/_CodeSignature/CodeResources"
    file "$APP/Contents/MacOS/RuneScrib"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$APP/Contents/Info.plist"
    codesign --verify --deep --strict --verbose=4 "$APP"
    codesign -d --verbose=4 "$APP"
    codesign -d --entitlements :- "$APP"
} >"$OUTPUT_ROOT/macos-shipping-product-integrity-before.log" 2>&1
rg -q '^1\.0\.39$' "$OUTPUT_ROOT/macos-shipping-product-integrity-before.log"
rg -q '^39$' "$OUTPUT_ROOT/macos-shipping-product-integrity-before.log"
find "$APP" -type f -print0 | sort -z | xargs -0 shasum -a 256 \
    >"$OUTPUT_ROOT/macos-shipping-product-tree-before.sha256"

xcodebuild test \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-macOS \
    -configuration Debug \
    -destination platform=macOS,arch=arm64 \
    -derivedDataPath "$OUTPUT_ROOT/DerivedData-macos-hosted" \
    -resultBundlePath "$OUTPUT_ROOT/macos-hosted.xcresult" \
    -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO \
    -only-testing:RuneScribTests/CompatibilityBaselineTests \
    -only-testing:RuneScribTests/RuntimeCompositionTests \
    -only-testing:RuneScribArchitectureTests/ArchitectureGuardrailTests \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    CODE_SIGN_ENTITLEMENTS= \
    >"$OUTPUT_ROOT/macos-hosted.log" 2>&1

xcodebuild test \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-macOS-Parity \
    -configuration Debug \
    -destination platform=macOS,arch=arm64 \
    -derivedDataPath "$OUTPUT_ROOT/DerivedData-macos-parity" \
    -resultBundlePath "$OUTPUT_ROOT/macos-parity.xcresult" \
    -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    CODE_SIGN_ENTITLEMENTS= \
    >"$OUTPUT_ROOT/macos-parity.log" 2>&1

xcrun xcresulttool get test-results summary \
    --path "$OUTPUT_ROOT/macos-hosted.xcresult" --compact \
    >"$OUTPUT_ROOT/macos-hosted-summary.json"
xcrun xcresulttool get test-results summary \
    --path "$OUTPUT_ROOT/macos-parity.xcresult" --compact \
    >"$OUTPUT_ROOT/macos-parity-summary.json"
rg -q '"passedTests":23' "$OUTPUT_ROOT/macos-hosted-summary.json"
rg -q '"failedTests":0' "$OUTPUT_ROOT/macos-hosted-summary.json"
rg -q '"skippedTests":0' "$OUTPUT_ROOT/macos-hosted-summary.json"
rg -q '"passedTests":9' "$OUTPUT_ROOT/macos-parity-summary.json"
rg -q '"failedTests":0' "$OUTPUT_ROOT/macos-parity-summary.json"
rg -q '"skippedTests":0' "$OUTPUT_ROOT/macos-parity-summary.json"

xcrun xcresulttool export attachments \
    --path "$OUTPUT_ROOT/macos-parity.xcresult" \
    --output-path "$OUTPUT_ROOT/macos-attachments-final" \
    >"$OUTPUT_ROOT/macos-attachments-export.log" 2>&1
find "$OUTPUT_ROOT/macos-attachments-final" -maxdepth 1 -type f \
    -name '*.png' -print0 | sort -z | xargs -0 shasum -a 256 \
    >"$OUTPUT_ROOT/macos-attachments-final.sha256"
attachment_count=$(find "$OUTPUT_ROOT/macos-attachments-final" -maxdepth 1 \
    -type f -name '*.png' | wc -l | tr -d ' ')
[[ "$attachment_count" == 26 ]]
rg -q 'macos-share-builder-moonleaf' \
    "$OUTPUT_ROOT/macos-attachments-final/manifest.json"

set +e
{
    print -r -- "sourceRevision=$EXPECTED_HEAD"
    print -r -- "command=open -n $APP"
    open -n "$APP"
} >"$OUTPUT_ROOT/macos-release-launch.log" 2>&1
full_launch_status=$?
set -e
print -r -- "exitStatus=$full_launch_status" \
    >>"$OUTPUT_ROOT/macos-release-launch.log"
[[ "$full_launch_status" -ne 0 ]]
{
    /usr/bin/log show --last 2m --style compact --info --debug \
        --predicate 'process == "launchd" OR process == "kernel" OR process == "amfid" OR process == "runningboardd" OR process == "CoreServicesUIAgent"' \
        | rg -i "RuneScrib|com\\.runescribe\\.app|restricted entitlements|adhoc signed|error = 163|error=163|Security policy issue|spawn failed|AMFI" || true
} >"$OUTPUT_ROOT/macos-release-launch-amfi.log"
rg -q 'restricted entitlements' "$OUTPUT_ROOT/macos-release-launch-amfi.log"

security find-identity -v -p codesigning \
    >"$OUTPUT_ROOT/macos-signing-identities.log" 2>&1
set +e
xcodebuild \
    -project RuneScrib.xcodeproj \
    -scheme RuneScrib-macOS \
    -configuration Release \
    -destination platform=macOS,arch=arm64 \
    -derivedDataPath "$OUTPUT_ROOT/DerivedData-macos-release-devsigned" \
    -resultBundlePath "$OUTPUT_ROOT/macos-release-devsigned.xcresult" \
    -disableAutomaticPackageResolution \
    -allowProvisioningUpdates \
    clean build \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY='Apple Development' \
    DEVELOPMENT_TEAM=9AQ2C2838M \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    >"$OUTPUT_ROOT/macos-release-devsigned.log" 2>&1
development_signing_status=$?
set -e
print -r -- "exitStatus=$development_signing_status" \
    >>"$OUTPUT_ROOT/macos-release-devsigned.log"
if [[ "$development_signing_status" -ne 0 ]]; then
    rg -q 'No Accounts|isn.t registered|No profiles for' \
        "$OUTPUT_ROOT/macos-release-devsigned.log"
fi

mkdir "$LOCAL_ROOT"
cp Config/RuneScrib-macOS.entitlements "$LOCAL_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.game-center' \
    "$LOCAL_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.icloud-container-identifiers' \
    "$LOCAL_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.icloud-services' \
    "$LOCAL_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.ubiquity-kvstore-identifier' \
    "$LOCAL_ENTITLEMENTS"
plutil -lint "$LOCAL_ENTITLEMENTS"
ditto "$APP" "$LOCAL_APP"
{
    print -r -- "COMMAND: codesign --force --deep --sign - --options runtime --timestamp=none --entitlements $LOCAL_ENTITLEMENTS $LOCAL_APP"
    print -r -- 'removedOnly=com.apple.developer.game-center,com.apple.developer.icloud-container-identifiers,com.apple.developer.icloud-services,com.apple.developer.ubiquity-kvstore-identifier'
    codesign --force --deep --sign - --options runtime --timestamp=none \
        --entitlements "$LOCAL_ENTITLEMENTS" "$LOCAL_APP"
    codesign --verify --deep --strict --verbose=4 "$LOCAL_APP"
    codesign -d --verbose=4 "$LOCAL_APP"
    codesign -d --entitlements :- "$LOCAL_APP"
} >"$LOCAL_ROOT/signing.log" 2>&1

local_pid=''
{
    print -r -- "sourceRevision=$EXPECTED_HEAD"
    print -r -- "sourceTree=$EXPECTED_TREE"
    print -r -- "sourceAggregate=$EXPECTED_SOURCE"
    print -r -- "qualificationCopy=$LOCAL_APP"
    print -r -- 'entitlementMode=local ad-hoc; restricted iCloud and Game Center entitlements omitted only from this copy'
    print -r -- "command=open -n $LOCAL_APP"
    open -n "$LOCAL_APP"
    for _ in {1..80}; do
        local_pid=$(pgrep -f "$LOCAL_PATTERN" | head -1 || true)
        [[ -n "$local_pid" ]] && break
        sleep 0.25
    done
    [[ -n "$local_pid" ]]
    print -r -- "pid=$local_pid"
    ps -p "$local_pid" -o pid=,comm=,etime=
    sleep 5
    kill -0 "$local_pid"
    print -r -- 'launch=PASS aliveAfterSeconds=5'
    kill "$local_pid"
    terminated=false
    for _ in {1..80}; do
        if ! kill -0 "$local_pid" >/dev/null 2>&1; then
            terminated=true
            break
        fi
        sleep 0.25
    done
    [[ "$terminated" == true ]]
    print -r -- 'termination=PASS'
    print -r -- 'postflight=PASS process absent'
} >"$LOCAL_ROOT/launch.log" 2>&1

{
    print -r -- "sourceRevision=$EXPECTED_HEAD"
    print -r -- "sourceTree=$EXPECTED_TREE"
    print -r -- "sourceAggregate=$EXPECTED_SOURCE"
    shasum -a 256 "$APP/Contents/MacOS/RuneScrib" \
        "$APP/Contents/_CodeSignature/CodeResources"
    file "$APP/Contents/MacOS/RuneScrib"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$APP/Contents/Info.plist"
    codesign --verify --deep --strict --verbose=4 "$APP"
    codesign -d --verbose=4 "$APP"
    codesign -d --entitlements :- "$APP"
} >"$OUTPUT_ROOT/macos-shipping-product-integrity-after.log" 2>&1
find "$APP" -type f -print0 | sort -z | xargs -0 shasum -a 256 \
    >"$OUTPUT_ROOT/macos-shipping-product-tree-after.sha256"

before_hashes=$(rg '^[0-9a-f]{64}  ' \
    "$OUTPUT_ROOT/macos-shipping-product-integrity-before.log")
after_hashes=$(rg '^[0-9a-f]{64}  ' \
    "$OUTPUT_ROOT/macos-shipping-product-integrity-after.log")
[[ "$before_hashes" == "$after_hashes" ]]
cmp -s "$OUTPUT_ROOT/macos-shipping-product-tree-before.sha256" \
    "$OUTPUT_ROOT/macos-shipping-product-tree-after.sha256"
[[ "$(git rev-parse HEAD)" == "$EXPECTED_HEAD" ]]
[[ "$(git rev-parse HEAD^{tree})" == "$EXPECTED_TREE" ]]
[[ -z "$(git status --porcelain)" ]]
python3 scripts/generate-source-manifest.py --verify "$ROOT" \
    docs/verification/remediation-v1/SOURCE-MANIFEST.json \
    >"$OUTPUT_ROOT/source-manifest-final-verify.log" 2>&1
rg -q "$EXPECTED_SOURCE" "$OUTPUT_ROOT/source-manifest-final-verify.log"
cleanup
if pgrep -f '/RuneScrib\.app/Contents/MacOS/RuneScrib$' >/dev/null 2>&1; then
    pgrep -fal '/RuneScrib\.app/Contents/MacOS/RuneScrib$'
    exit 1
fi
! pgrep -x Simulator >/dev/null 2>&1
xcrun simctl list devices | rg -q \
    'iPhone 17 Pro \(1563B47A-700D-4AEF-A8D5-89780C581F83\) \(Shutdown\)'
xcrun simctl list devices | rg -q \
    'iPad Pro 13-inch \(M5\) \(77D54A1F-0818-4761-B946-D7723490F6B3\) \(Shutdown\)'

{
    print -r -- "head=$EXPECTED_HEAD"
    print -r -- "tree=$EXPECTED_TREE"
    print -r -- "sourceAggregate=$EXPECTED_SOURCE"
    print -r -- 'trackedTree=UNCHANGED'
    print -r -- 'shippingProductHashes=UNCHANGED'
    print -r -- 'shippingProductTree=HASH_IDENTICAL'
    print -r -- "$after_hashes"
    print -r -- "shippingProduct=$APP"
    print -r -- 'shippingEntitlements=FULL'
    print -r -- 'developerID=NOT_CLAIMED'
    print -r -- 'notarization=NOT_CLAIMED'
    print -r -- 'hostedTests=23 passed, 0 failed, 0 skipped'
    print -r -- 'parityTests=9 passed, 0 failed, 0 skipped'
    print -r -- 'parityPNGAttachments=26'
    print -r -- 'moonleafShareBuilderAttachment=PRESENT'
    print -r -- 'RuneScribProcess=NOT_RUNNING'
    print -r -- 'simulatorUse=NONE'
} >"$OUTPUT_ROOT/macos-final-boundary-audit.log"

trap - EXIT INT TERM
print -r -- "macOS qualification complete: $OUTPUT_ROOT"
