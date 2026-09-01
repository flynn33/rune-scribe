#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/qualify-release-products.sh [--output-root PATH]

Builds and inspects local Release products without launching Simulator or requiring a
distribution identity. The macOS product is copied and signed ad hoc with Hardened
Runtime enabled; the iOS Simulator product is signed ad hoc with the project's configured
development team so its entitlement prefixes match the shipping contract.

The output directory is retained and contains both build logs plus the qualified app
bundles. When --output-root is omitted, a unique directory is created under TMPDIR. A
custom output directory must be outside the repository so the clean-source check remains
meaningful.
Distribution identity, provisioning, archive, export, notarization, and upload are not
assessed by this local qualification.
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

for tool in awk cat codesign ditto git mkdir mktemp plutil tee xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool is unavailable: $tool" >&2
    exit 2
  fi
done

if [ -z "$output_root" ]; then
  output_root=$(mktemp -d "${TMPDIR:-/tmp}/RuneScribe-release-products.XXXXXX")
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
macos_entitlements_source="$repository_root/Config/RuneScrib-macOS.entitlements"
checker="$repository_root/scripts/check-shipping-products.sh"

for required_path in "$project_file" "$project_source" "$macos_entitlements_source" "$checker"; do
  if [ ! -e "$required_path" ]; then
    echo "ERROR: required repository input is missing: $required_path" >&2
    exit 2
  fi
done

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

case "$development_team" in
  [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
  *)
    echo "ERROR: project.yml has no valid 10-character DEVELOPMENT_TEAM" >&2
    exit 2
    ;;
esac

source_revision=$(git -C "$repository_root" rev-parse HEAD)
git -C "$repository_root" status --porcelain=v1 >"$output_root/source-status.txt"
if [ -s "$output_root/source-status.txt" ]; then
  echo "ERROR: release-product qualification requires a clean committed source tree" >&2
  cat "$output_root/source-status.txt" >&2
  exit 2
fi
printf '%s\n' "$source_revision" >"$output_root/source-revision.txt"
xcodebuild -version >"$output_root/xcode-version.txt"
macos_derived="$output_root/macos-derived"
ios_derived="$output_root/ios-derived"
qualified_products="$output_root/qualified-products"
macos_unsigned="$macos_derived/Build/Products/Release/RuneScrib.app"
macos_app="$qualified_products/macos/RuneScrib.app"
ios_app="$ios_derived/Build/Products/Release-iphonesimulator/RuneScrib.app"
macos_entitlements="$output_root/macos-local-entitlements.plist"

mkdir -p "$qualified_products/macos"

echo "Qualifying Rune Scribe source revision $source_revision"
echo "Evidence root: $output_root"

xcodebuild \
  -project "$project_file" \
  -scheme RuneScrib-macOS \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$macos_derived" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$output_root/macos-release-build.log"

test -d "$macos_unsigned"
ditto "$macos_unsigned" "$macos_app"
ditto "$macos_entitlements_source" "$macos_entitlements"
plutil -replace 'com\.apple\.developer\.ubiquity-kvstore-identifier' \
  -string "${development_team}.com.runescribe.app" \
  "$macos_entitlements"
plutil -insert 'com\.apple\.application-identifier' \
  -string "${development_team}.com.runescribe.app" \
  "$macos_entitlements"
plutil -insert 'com\.apple\.developer\.team-identifier' \
  -string "$development_team" \
  "$macos_entitlements"
codesign --force --deep --sign - --options runtime \
  --entitlements "$macos_entitlements" \
  "$macos_app"

xcodebuild \
  -project "$project_file" \
  -scheme RuneScrib-iOS \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$ios_derived" \
  "DEVELOPMENT_TEAM=$development_team" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  build 2>&1 | tee "$output_root/ios-simulator-release-build.log"

test -d "$ios_app"
"$checker" \
  --macos-app "$macos_app" \
  --ios-app "$ios_app" 2>&1 | tee "$output_root/shipping-products.log"

cat <<RESULT
Release-product qualification passed.
Source revision: $source_revision
macOS product: $macos_app
iOS Simulator product: $ios_app
Evidence root: $output_root
Distribution signing and publication were not assessed.
RESULT
