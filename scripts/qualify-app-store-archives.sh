#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/qualify-app-store-archives.sh [--output-root PATH]

Builds fresh iOS and macOS Release archives, exports both for App Store Connect,
and verifies the exported products, signatures, production entitlements, and Store
provisioning profiles. The command does not validate, upload, submit, or release.

The source tree must be clean and committed. Evidence is retained outside the
repository. Xcode must have access to the Apple Developer account for the configured
team; automatic signing may create or download managed distribution assets.
USAGE
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
output_root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-root)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      output_root=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for tool in awk cmp codesign ditto file find git lipo mkdir mktemp pkgutil plutil \
  rg ruby security shasum tee xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool is unavailable: $tool" >&2
    exit 2
  fi
done

if [ -z "$output_root" ]; then
  output_root=$(mktemp -d "${TMPDIR:-/tmp}/RuneScribe-app-store-archives.XXXXXX")
else
  case "$output_root" in
    /*) ;;
    *) output_root="$PWD/$output_root" ;;
  esac
  case "$output_root/" in
    "$repository_root/"*)
      echo "ERROR: --output-root must be outside the repository" >&2
      exit 2
      ;;
  esac
  if [ -e "$output_root" ]; then
    echo "ERROR: output root already exists: $output_root" >&2
    exit 2
  fi
  mkdir -p "$output_root"
fi

project_file="$repository_root/RuneScrib.xcodeproj"
project_source="$repository_root/project.yml"
export_options="$repository_root/Config/AppStoreExportOptions.plist"

for required_path in "$project_file" "$project_source" "$export_options"; do
  if [ ! -e "$required_path" ]; then
    echo "ERROR: required repository input is missing: $required_path" >&2
    exit 2
  fi
done

plutil -lint "$export_options" >/dev/null

project_value() {
  local key=$1
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      value=$0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      gsub(/["[:space:]]/, "", value)
      print value
      exit
    }
  ' "$project_source"
}

development_team=$(awk '
  /^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*/ {
    value=$0
    sub(/^[^:]+:[[:space:]]*/, "", value)
    gsub(/["[:space:]]/, "", value)
    if (length(value) == 10 && value ~ /^[A-Z0-9]+$/) {
      print value
      exit
    }
  }
' "$project_source")
marketing_version=$(project_value MARKETING_VERSION)
build_number=$(project_value CURRENT_PROJECT_VERSION)
bundle_identifier=$(project_value RUNESCRIBE_APP_BUNDLE_IDENTIFIER)

if [ "${#development_team}" -ne 10 ] || \
    ! printf '%s\n' "$development_team" | rg -q '^[A-Z0-9]{10}$'; then
  echo "ERROR: project.yml has no valid 10-character DEVELOPMENT_TEAM" >&2
  exit 2
fi
if [ -z "$marketing_version" ] || [ -z "$build_number" ] || \
    [ -z "$bundle_identifier" ]; then
  echo "ERROR: project.yml is missing release identity values" >&2
  exit 2
fi

source_revision=$(git -C "$repository_root" rev-parse HEAD)
git -C "$repository_root" status --porcelain=v1 >"$output_root/source-status.txt"
if [ -s "$output_root/source-status.txt" ]; then
  echo "ERROR: App Store archive qualification requires a clean committed source tree" >&2
  cat "$output_root/source-status.txt" >&2
  exit 2
fi

printf '%s\n' "$source_revision" >"$output_root/source-revision.txt"
printf '%s\n' "$marketing_version" >"$output_root/marketing-version.txt"
printf '%s\n' "$build_number" >"$output_root/build-number.txt"
xcodebuild -version >"$output_root/xcode-version.txt"

ios_archive="$output_root/RuneScrib-iOS.xcarchive"
macos_archive="$output_root/RuneScrib-macOS.xcarchive"
ios_export="$output_root/ios-app-store-export"
macos_export="$output_root/macos-app-store-export"

echo "Qualifying Rune Scribe source revision $source_revision"
echo "Candidate: $marketing_version ($build_number)"
echo "Evidence root: $output_root"

xcodebuild archive \
  -project "$project_file" \
  -scheme RuneScrib-iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ios_archive" \
  -allowProvisioningUpdates 2>&1 | tee "$output_root/ios-archive.log"

xcodebuild archive \
  -project "$project_file" \
  -scheme RuneScrib-macOS \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$macos_archive" \
  -allowProvisioningUpdates 2>&1 | tee "$output_root/macos-archive.log"

mkdir -p "$ios_export" "$macos_export"

xcodebuild -exportArchive \
  -archivePath "$ios_archive" \
  -exportPath "$ios_export" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates 2>&1 | tee "$output_root/ios-export.log"

xcodebuild -exportArchive \
  -archivePath "$macos_archive" \
  -exportPath "$macos_export" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates 2>&1 | tee "$output_root/macos-export.log"

ios_ipa=$(find "$ios_export" -maxdepth 1 -type f -name '*.ipa' -print -quit)
macos_pkg=$(find "$macos_export" -maxdepth 1 -type f -name '*.pkg' -print -quit)
if [ -z "$ios_ipa" ] || [ -z "$macos_pkg" ]; then
  echo "ERROR: App Store export did not produce exactly the expected package types" >&2
  exit 1
fi

ios_expanded="$output_root/ios-expanded"
macos_expanded="$output_root/macos-expanded"
mkdir -p "$ios_expanded"
ditto -x -k "$ios_ipa" "$ios_expanded"
pkgutil --expand-full "$macos_pkg" "$macos_expanded"

ios_app=$(find "$ios_expanded/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)
macos_app=$(find "$macos_expanded" -type d -name '*.app' -print -quit)
if [ -z "$ios_app" ] || [ -z "$macos_app" ]; then
  echo "ERROR: exported packages do not contain both application bundles" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$ios_app" \
  2>&1 | tee "$output_root/ios-signature-verification.log"
codesign --verify --deep --strict --verbose=2 "$macos_app" \
  2>&1 | tee "$output_root/macos-signature-verification.log"
pkgutil --check-signature "$macos_pkg" \
  2>&1 | tee "$output_root/macos-package-signature.log"

codesign -dv --verbose=4 "$ios_app" \
  2>"$output_root/ios-signature-details.txt"
codesign -dv --verbose=4 "$macos_app" \
  2>"$output_root/macos-signature-details.txt"
codesign -d --entitlements :- "$ios_app" \
  >"$output_root/ios-exported-entitlements.plist" \
  2>"$output_root/ios-entitlements-extraction.log"
codesign -d --entitlements :- "$macos_app" \
  >"$output_root/macos-exported-entitlements.plist" \
  2>"$output_root/macos-entitlements-extraction.log"

ios_info="$ios_app/Info.plist"
macos_info="$macos_app/Contents/Info.plist"
ios_profile="$ios_app/embedded.mobileprovision"
macos_profile="$macos_app/Contents/embedded.provisionprofile"
security cms -D -i "$ios_profile" >"$output_root/ios-store-profile.plist"
security cms -D -i "$macos_profile" >"$output_root/macos-store-profile.plist"

assert_plist_value() {
  local plist=$1
  local key=$2
  local expected=$3
  local actual
  local key_path=${key//./\\.}
  actual=$(plutil -extract "$key_path" raw -o - "$plist" 2>/dev/null || true)
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: $plist has $key=$actual; expected $expected" >&2
    exit 1
  fi
}

assert_plist_single_value_array() {
  local plist=$1
  local key=$2
  local expected=$3
  local key_path=${key//./\\.}
  local count
  local actual
  count=$(plutil -extract "$key_path" raw -o - "$plist" 2>/dev/null || true)
  actual=$(plutil -extract "$key_path.0" raw -o - "$plist" 2>/dev/null || true)
  if [ "$count" != "1" ] || [ "$actual" != "$expected" ]; then
    echo "ERROR: $plist key $key is not exactly [$expected]" >&2
    exit 1
  fi
}

for info in "$ios_info" "$macos_info"; do
  assert_plist_value "$info" CFBundleIdentifier "$bundle_identifier"
  assert_plist_value "$info" CFBundleShortVersionString "$marketing_version"
  assert_plist_value "$info" CFBundleVersion "$build_number"
done

ios_architectures=$(lipo -archs "$ios_app/RuneScrib" 2>/dev/null || true)
macos_architectures=$(lipo -archs "$macos_app/Contents/MacOS/RuneScrib" 2>/dev/null || true)
if [ "$ios_architectures" != "arm64" ]; then
  echo "ERROR: iOS Store export architecture set is $ios_architectures; expected arm64" >&2
  exit 1
fi
if ! printf '%s\n' "$macos_architectures" | \
    rg -q '^(arm64|x86_64 arm64|arm64 x86_64)$'; then
  echo "ERROR: macOS Store export architecture set is invalid: $macos_architectures" >&2
  exit 1
fi

if find "$ios_app" "$macos_app" -type f \
    \( -name '*.debug.dylib' -o -name '*Tests*' -o -name '*TestSupport*' \) \
    -print -quit | rg -q .; then
  echo "ERROR: a Store export contains a test or debug artifact" >&2
  exit 1
fi

ios_privacy="$ios_app/PrivacyInfo.xcprivacy"
macos_privacy="$macos_app/Contents/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$ios_privacy" "$macos_privacy" >/dev/null
if ! cmp -s "$ios_privacy" "$macos_privacy"; then
  echo "ERROR: exported platform privacy manifests differ" >&2
  exit 1
fi

ios_entitlements="$output_root/ios-exported-entitlements.plist"
macos_entitlements="$output_root/macos-exported-entitlements.plist"
assert_plist_value "$ios_entitlements" application-identifier \
  "$development_team.$bundle_identifier"
assert_plist_value "$ios_entitlements" com.apple.developer.team-identifier \
  "$development_team"
assert_plist_value "$ios_entitlements" com.apple.developer.game-center true
assert_plist_value "$ios_entitlements" com.apple.developer.icloud-container-environment \
  Production
assert_plist_single_value_array "$ios_entitlements" \
  com.apple.developer.icloud-container-identifiers iCloud.com.runescribe.app
assert_plist_single_value_array "$ios_entitlements" keychain-access-groups \
  "$development_team.$bundle_identifier"
assert_plist_value "$ios_entitlements" get-task-allow false

assert_plist_value "$macos_entitlements" com.apple.application-identifier \
  "$development_team.$bundle_identifier"
assert_plist_value "$macos_entitlements" com.apple.developer.team-identifier \
  "$development_team"
assert_plist_value "$macos_entitlements" com.apple.developer.game-center true
assert_plist_value "$macos_entitlements" com.apple.developer.icloud-container-environment \
  Production
assert_plist_single_value_array "$macos_entitlements" \
  com.apple.developer.icloud-container-identifiers iCloud.com.runescribe.app
assert_plist_value "$macos_entitlements" com.apple.security.app-sandbox true
assert_plist_value "$macos_entitlements" \
  com.apple.security.files.user-selected.read-write true
assert_plist_value "$macos_entitlements" \
  com.apple.security.personal-information.addressbook true

plutil -convert json -o "$output_root/ios-exported-entitlements.json" \
  "$ios_entitlements"
plutil -convert json -o "$output_root/macos-exported-entitlements.json" \
  "$macos_entitlements"
ruby -rjson - \
  "$output_root/ios-exported-entitlements.json" \
  "$output_root/macos-exported-entitlements.json" <<'RUBY'
ios = JSON.parse(File.read(ARGV.fetch(0)))
macos = JSON.parse(File.read(ARGV.fetch(1)))
ios_allowed = %w[
  application-identifier
  beta-reports-active
  com.apple.developer.game-center
  com.apple.developer.icloud-container-environment
  com.apple.developer.icloud-container-identifiers
  com.apple.developer.icloud-services
  com.apple.developer.team-identifier
  com.apple.developer.ubiquity-kvstore-identifier
  get-task-allow
  keychain-access-groups
]
macos_allowed = %w[
  com.apple.application-identifier
  com.apple.developer.game-center
  com.apple.developer.icloud-container-environment
  com.apple.developer.icloud-container-identifiers
  com.apple.developer.icloud-services
  com.apple.developer.team-identifier
  com.apple.developer.ubiquity-kvstore-identifier
  com.apple.security.app-sandbox
  com.apple.security.files.user-selected.read-write
  com.apple.security.personal-information.addressbook
]
unexpected_ios = ios.keys - ios_allowed
unexpected_macos = macos.keys - macos_allowed
abort "unexpected iOS Store entitlements: #{unexpected_ios.sort.join(', ')}" \
  unless unexpected_ios.empty?
abort "unexpected macOS Store entitlements: #{unexpected_macos.sort.join(', ')}" \
  unless unexpected_macos.empty?
abort "iOS Store export lacks beta reporting" unless ios["beta-reports-active"] == true
RUBY

assert_plist_value "$output_root/ios-store-profile.plist" Name \
  "iOS Team Store Provisioning Profile: $bundle_identifier"
assert_plist_value "$output_root/macos-store-profile.plist" Name \
  "Mac Team Store Provisioning Profile: $bundle_identifier"

if ! rg -q '^Authority=Apple Distribution:' \
    "$output_root/ios-signature-details.txt"; then
  echo "ERROR: iOS export is not Apple Distribution signed" >&2
  exit 1
fi
if ! rg -q '^Authority=Apple Distribution:' \
    "$output_root/macos-signature-details.txt"; then
  echo "ERROR: macOS export is not Apple Distribution signed" >&2
  exit 1
fi
if ! rg -q 'flags=.*\(runtime\)' "$output_root/macos-signature-details.txt"; then
  echo "ERROR: macOS export does not have Hardened Runtime enabled" >&2
  exit 1
fi
if ! rg -q '3rd Party Mac Developer Installer:' \
    "$output_root/macos-package-signature.log"; then
  echo "ERROR: macOS package is not signed for Mac App Store installation" >&2
  exit 1
fi

shasum -a 256 "$ios_ipa" "$macos_pkg" >"$output_root/export-sha256.txt"

cat <<RESULT
App Store archive qualification passed.
Source revision: $source_revision
Candidate: $marketing_version ($build_number)
iOS package: $ios_ipa
macOS package: $macos_pkg
Evidence root: $output_root
Both packages were exported for App Store Connect and inspected locally.
No validation, upload, submission, release, or shipment was performed.
RESULT
