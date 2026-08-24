#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
checker="$script_directory/check-shipping-products.sh"

for tool in codesign file mkfile nm otool plutil rsync swift swiftc xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool is unavailable: $tool" >&2
    exit 2
  fi
done

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/RuneScribe-shipping-mutations.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

export RUNESCRIBE_REAL_FILE
export RUNESCRIBE_REAL_NM
export RUNESCRIBE_REAL_OTOOL
RUNESCRIBE_REAL_FILE=$(command -v file)
RUNESCRIBE_REAL_NM=$(command -v nm)
RUNESCRIBE_REAL_OTOOL=$(command -v otool)

fake_tools="$temporary_directory/tools"
mkdir -p "$fake_tools"

cat >"$fake_tools/file" <<'TOOL'
#!/bin/bash
path=${!#}
case "$(basename "$path")" in
  AppIcon.icns) echo "Mac OS X icon" ;;
  AppIcon*.png) echo "PNG image data" ;;
  raven-forge-spp-splash.mp4) echo "ISO Media" ;;
  default.metallib) echo "MetalLib" ;;
  *) exec "$RUNESCRIBE_REAL_FILE" "$@" ;;
esac
TOOL

cat >"$fake_tools/nm" <<'TOOL'
#!/bin/bash
executable=${!#}
"$RUNESCRIBE_REAL_NM" "$@" || exit $?
for module in \
  RuneScribeContracts RuneScribeRuntimeCore RuneScribeUIRuntime RuneScribePlatform \
  RuneScribeCoreModule RuneScribeProgressionModule RuneScribeThemeCoordinatorModule \
  RuneScribeNorseThemeModule RuneScribeThemeMoonleafModule RuneScribeThemeSunspireModule \
  RuneScribeThemeWildwoodModule RuneScribeThemeGloamthornModule RuneScribeCloudSyncModule \
  RuneScribeGameCenterModule RuneScribeUIModule
do
  printf '_%sSyntheticLinkage\n' "$module"
done
case "$executable" in
  */Contents/MacOS/*) app=${executable%/Contents/MacOS/*}; marker_root="$app/Contents/Resources" ;;
  *) app=${executable%/*}; marker_root=$app ;;
esac
[ ! -f "$marker_root/.emit-static-forbidden" ] || printf '_ForsettiSyntheticStaticLeak\n'
[ ! -f "$marker_root/.emit-test-support" ] || printf '_RuneScribeTestSupportSyntheticLeak\n'
TOOL

cat >"$fake_tools/otool" <<'TOOL'
#!/bin/bash
executable=${!#}
case "$executable" in
  */Contents/MacOS/*) app=${executable%/Contents/MacOS/*}; marker_root="$app/Contents/Resources"; platform=1; minos=15.0 ;;
  *) app=${executable%/*}; marker_root=$app; platform=2; minos=17.0 ;;
esac

case " $* " in
  *" -L "*)
    printf '%s:\n' "$executable"
    if [ ! -f "$marker_root/.omit-cloudkit-link" ]; then
      printf '\t/System/Library/Frameworks/CloudKit.framework/Versions/A/CloudKit (compatibility version 1.0.0, current version 1.0.0)\n'
    fi
    if [ ! -f "$marker_root/.omit-gamekit-link" ]; then
      printf '\t/System/Library/Frameworks/GameKit.framework/Versions/A/GameKit (compatibility version 1.0.0, current version 1.0.0)\n'
    fi
    printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
    ;;
  *" -l "*)
    [ ! -f "$marker_root/.wrong-build-platform" ] || platform=9
    cat <<EOF
Load command 1
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform $platform
    minos $minos
      sdk 26.2
   ntools 1
EOF
    ;;
  *) exec "$RUNESCRIBE_REAL_OTOOL" "$@" ;;
esac
TOOL

chmod +x "$fake_tools/file" "$fake_tools/nm" "$fake_tools/otool"

macos_entitlements="$temporary_directory/macos-entitlements.plist"
ios_entitlements="$temporary_directory/ios-entitlements.plist"

cat >"$macos_entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>ABCDE12345.com.runescribe.app</string>
<key>com.apple.developer.team-identifier</key><string>ABCDE12345</string>
<key>com.apple.developer.game-center</key><true/>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.runescribe.app</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key><string>ABCDE12345.com.runescribe.app</string>
<key>com.apple.developer.icloud-container-environment</key><string>Development</string>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.personal-information.addressbook</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.get-task-allow</key><false/>
</dict></plist>
PLIST

cat >"$ios_entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>ABCDE12345.com.runescribe.app</string>
<key>com.apple.developer.team-identifier</key><string>ABCDE12345</string>
<key>get-task-allow</key><false/>
<key>keychain-access-groups</key><array><string>ABCDE12345.com.runescribe.app</string></array>
<key>com.apple.developer.game-center</key><true/>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.runescribe.app</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key><string>ABCDE12345.com.runescribe.app</string>
<key>com.apple.developer.icloud-container-environment</key><string>Development</string>
</dict></plist>
PLIST

write_built_info_plists() {
  local macos_app=$1
  local ios_app=$2
  local macos_info="$macos_app/Contents/Info.plist"
  local ios_info="$ios_app/Info.plist"

  cp "$repository_root/Config/RuneScrib-macOS-Info.plist" "$macos_info"
  cp "$repository_root/Config/RuneScrib-iOS-Info.plist" "$ios_info"

  plutil -replace CFBundleDevelopmentRegion -string en "$macos_info"
  plutil -replace CFBundleExecutable -string RuneScrib "$macos_info"
  plutil -replace CFBundleIdentifier -string com.runescribe.app "$macos_info"
  plutil -replace CFBundleName -string RuneScrib "$macos_info"
  plutil -replace CFBundleShortVersionString -string 1.0.39 "$macos_info"
  plutil -replace CFBundleVersion -string 39 "$macos_info"
  plutil -insert CFBundleSupportedPlatforms -json '["MacOSX"]' "$macos_info"
  plutil -insert LSMinimumSystemVersion -string 15.0 "$macos_info"

  plutil -replace CFBundleDevelopmentRegion -string en "$ios_info"
  plutil -replace CFBundleExecutable -string RuneScrib "$ios_info"
  plutil -replace CFBundleIdentifier -string com.runescribe.app "$ios_info"
  plutil -replace CFBundleName -string RuneScrib "$ios_info"
  plutil -replace CFBundleShortVersionString -string 1.0.39 "$ios_info"
  plutil -replace CFBundleVersion -string 39 "$ios_info"
  plutil -insert CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$ios_info"
  plutil -insert MinimumOSVersion -string 17.0 "$ios_info"
  plutil -insert UIDeviceFamily -json '[1,2]' "$ios_info"
}

copy_flat_resources() {
  local source=$1
  local destination=$2
  local path
  local name

  mkdir -p "$destination"
  while IFS= read -r -d '' path; do
    case "$path" in
      */Source/*) continue ;;
    esac
    name=$(basename "$path")
    if [ -e "$destination/$name" ]; then
      echo "ERROR: synthetic fixture resource basename collision: $name" >&2
      exit 2
    fi
    cp "$path" "$destination/$name"
  done < <(find "$source" -type f -print0)
}

add_resource_bundle() {
  local resources=$1
  local module=$2
  local source=$3
  copy_flat_resources "$source" "$resources/RuneScribeArchitecture_${module}.bundle"
}

build_fixture() {
  local fixture=$1
  local macos_app="$fixture/macos/RuneScrib.app"
  local ios_app="$fixture/ios/RuneScrib.app"
  local macos_resources="$macos_app/Contents/Resources"
  local ios_resources="$ios_app"
  local main_source="$temporary_directory/main.swift"

  mkdir -p "$macos_app/Contents/MacOS" "$macos_resources" "$ios_resources"
  printf 'print("Rune Scribe shipping fixture")\n' >"$main_source"
  swiftc "$main_source" -o "$macos_app/Contents/MacOS/RuneScrib"
  cp "$macos_app/Contents/MacOS/RuneScrib" "$ios_app/RuneScrib"
  write_built_info_plists "$macos_app" "$ios_app"

  printf 'assets\n' >"$macos_resources/Assets.car"
  printf 'icon\n' >"$macos_resources/AppIcon.icns"
  printf 'video\n' >"$macos_resources/raven-forge-spp-splash.mp4"
  printf 'metal\n' >"$macos_resources/default.metallib"
  printf 'assets\n' >"$ios_resources/Assets.car"
  printf 'icon\n' >"$ios_resources/AppIcon60x60@2x.png"
  printf 'video\n' >"$ios_resources/raven-forge-spp-splash.mp4"
  printf 'metal\n' >"$ios_resources/default.metallib"

  for resources in "$macos_resources" "$ios_resources"; do
    add_resource_bundle "$resources" RuneScribeCoreModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Resources"
    add_resource_bundle "$resources" RuneScribePlatform \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/Feedback/Resources"
    add_resource_bundle "$resources" RuneScribeProgressionModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/Resources"
    add_resource_bundle "$resources" RuneScribeThemeCoordinatorModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/Resources"
    add_resource_bundle "$resources" RuneScribeNorseThemeModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources"
    add_resource_bundle "$resources" RuneScribeThemeMoonleafModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/Resources"
    add_resource_bundle "$resources" RuneScribeThemeSunspireModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeSunspireModule/Resources"
    add_resource_bundle "$resources" RuneScribeThemeWildwoodModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeWildwoodModule/Resources"
    add_resource_bundle "$resources" RuneScribeThemeGloamthornModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeGloamthornModule/Resources"
    add_resource_bundle "$resources" RuneScribeGameCenterModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeGameCenterModule/Resources"
    add_resource_bundle "$resources" RuneScribeUIModule \
      "$repository_root/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Resources"
  done
}

sign_fixture() {
  local fixture=$1
  local fixture_macos_entitlements="$macos_entitlements"
  local fixture_ios_entitlements="$ios_entitlements"
  [ ! -f "$fixture/macos-entitlements.plist" ] || fixture_macos_entitlements="$fixture/macos-entitlements.plist"
  [ ! -f "$fixture/ios-entitlements.plist" ] || fixture_ios_entitlements="$fixture/ios-entitlements.plist"

  codesign --force --deep --sign - --options runtime \
    --entitlements "$fixture_macos_entitlements" "$fixture/macos/RuneScrib.app" >/dev/null 2>&1
  codesign --force --deep --sign - \
    --entitlements "$fixture_ios_entitlements" "$fixture/ios/RuneScrib.app" >/dev/null 2>&1
}

run_checker() {
  local checker_path=$1
  local fixture=$2
  local output=$3
  PATH="$fake_tools:$PATH" "$checker_path" \
    --macos-app "$fixture/macos/RuneScrib.app" \
    --ios-app "$fixture/ios/RuneScrib.app" >"$output" 2>&1
}

baseline="$temporary_directory/baseline"
build_fixture "$baseline"
sign_fixture "$baseline"

graph_repository="$temporary_directory/graph-repository"
mkdir -p "$graph_repository"
rsync -a --exclude '.git/' --exclude '.build/' "$repository_root/" "$graph_repository/"
(CDPATH= cd -- "$graph_repository" && xcodegen generate >/dev/null)
graph_checker="$graph_repository/scripts/check-shipping-products.sh"

baseline_output="$temporary_directory/baseline.log"
if ! run_checker "$graph_checker" "$baseline" "$baseline_output"; then
  echo "ERROR: synthetic shipping-product baseline did not pass" >&2
  sed -n '1,260p' "$baseline_output" >&2
  exit 1
fi
echo "PASS: synthetic shipping-product baseline"

mutation_count=0

assert_rejected() {
  local name=$1
  local expected=$2
  local mutation=$3
  local checker_path=${4:-$graph_checker}
  local fixture="$temporary_directory/case-$name"
  local output="$temporary_directory/case-$name.log"
  local status

  /usr/bin/ditto "$baseline" "$fixture"
  "$mutation" "$fixture"
  sign_fixture "$fixture"
  set +e
  run_checker "$checker_path" "$fixture" "$output"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "ERROR: mutation was accepted: $name" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$output"; then
    echo "ERROR: mutation did not reach its promised rejection: $name" >&2
    echo "Expected: $expected" >&2
    sed -n '1,260p' "$output" >&2
    exit 1
  fi
  mutation_count=$((mutation_count + 1))
  echo "PASS: $name -> $expected"
}

macos_resources() {
  printf '%s/macos/RuneScrib.app/Contents/Resources\n' "$1"
}

mutate_missing_provider() {
  rm -rf "$(macos_resources "$1")/RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle"
}

mutate_misplaced_provider() {
  local resources
  resources=$(macos_resources "$1")
  mkdir -p "$resources/Nested"
  mv "$resources/RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle" "$resources/Nested/"
}

mutate_extra_bundle() {
  mkdir -p "$(macos_resources "$1")/UnexpectedProvider.bundle"
  printf 'unexpected\n' >"$(macos_resources "$1")/UnexpectedProvider.bundle/resource.dat"
}

mutate_theme_copy() {
  local resources
  resources=$(macos_resources "$1")
  cp "$resources/RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle/moonleaf-background-static.png" \
    "$resources/moonleaf-background-static.png"
}

mutate_theme_hash() {
  printf 'x' >>"$(macos_resources "$1")/RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle/moonleaf-background-static.png"
}

mutate_provider_criticality() {
  plutil -replace criticality -string required \
    "$(macos_resources "$1")/RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle/module-manifest.json"
}

mutate_provider_identity() {
  plutil -replace moduleID -string com.runescribe.module.theme.invalid \
    "$(macos_resources "$1")/RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle/Resource-Integrity-Manifest-v1.0.json"
}

mutate_duplicate_resource_id() {
  ruby -rjson - "$(macos_resources "$1")/RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle/Resource-Integrity-Manifest-v1.0.json" <<'RUBY'
path = ARGV.fetch(0)
document = JSON.parse(File.read(path))
document.fetch("files")[1]["resourceID"] = document.fetch("files")[0].fetch("resourceID")
File.write(path, JSON.pretty_generate(document) + "\n")
RUBY
}

mutate_theme_budget() {
  mkfile 65m "$(macos_resources "$1")/RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle/oversize.dat"
}

mutate_norse_required() {
  plutil -replace criticality -string optional \
    "$(macos_resources "$1")/RuneScribeArchitecture_RuneScribeNorseThemeModule.bundle/module-manifest.json"
}

mutate_placeholder_content() {
  printf '{"status":"place%s"}\n' 'holder' >"$(macos_resources "$1")/release-note.json"
}

mutate_debug_catalog() {
  mkdir -p "$(macos_resources "$1")/Debug"
  printf '{}\n' >"$(macos_resources "$1")/Debug/GameCenter-Achievement-Catalog-v1.0.json"
}

mutate_source_master() {
  printf '<svg/>\n' >"$(macos_resources "$1")/design-master.svg"
}

mutate_attribution() {
  printf '%s%s\n' 'Open' 'AI' >"$(macos_resources "$1")/release-note.txt"
}

mutate_static_forbidden() {
  : >"$(macos_resources "$1")/.emit-static-forbidden"
}

mutate_test_support() {
  : >"$(macos_resources "$1")/.emit-test-support"
}

mutate_gamekit_link() {
  : >"$(macos_resources "$1")/.omit-gamekit-link"
}

mutate_cloudkit_link() {
  : >"$(macos_resources "$1")/.omit-cloudkit-link"
}

mutate_build_platform() {
  : >"$(macos_resources "$1")/.wrong-build-platform"
}

mutate_entitlement_prefix() {
  cp "$macos_entitlements" "$1/macos-entitlements.plist"
  /usr/libexec/PlistBuddy -c \
    "Set :com.apple.developer.ubiquity-kvstore-identifier ZZZZZ99999.com.runescribe.app" \
    "$1/macos-entitlements.plist" >/dev/null
}

mutate_game_center_catalog() {
  rm "$(macos_resources "$1")/RuneScribeArchitecture_RuneScribeGameCenterModule.bundle/GameCenter-Achievement-Catalog-v1.0.json"
}

mutate_platform_audio() {
  printf 'x' >>"$(macos_resources "$1")/RuneScribeArchitecture_RuneScribePlatform.bundle/unlock_micro.wav"
}

mutate_built_version() {
  plutil -replace CFBundleShortVersionString -string 9.9.9 "$1/macos/RuneScrib.app/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string 9.9.9 "$1/ios/RuneScrib.app/Info.plist"
}

assert_rejected missing-provider \
  "macOS moonleaf provider bundle is not exactly once at its canonical direct path" \
  mutate_missing_provider
assert_rejected misplaced-provider \
  "macOS moonleaf provider bundle is not exactly once at its canonical direct path" \
  mutate_misplaced_provider
assert_rejected extra-bundle "macOS product resource bundle census differs" mutate_extra_bundle
assert_rejected misplaced-theme-resource \
  "macOS Theme resource appears outside its canonical module bundle" mutate_theme_copy
assert_rejected wrong-theme-hash \
  "macOS moonleaf output bytes or SHA-256 differ" mutate_theme_hash
assert_rejected provider-optional-criticality \
  "macOS moonleaf optional provider contract differs" mutate_provider_criticality
assert_rejected provider-manifest-identity \
  "macOS moonleaf integrity-manifest identity differs" mutate_provider_identity
assert_rejected duplicate-provider-resource-id \
  "macOS moonleaf output resource IDs are duplicated" mutate_duplicate_resource_id
assert_rejected theme-module-budget \
  "macOS moonleaf resource bundle exceeds the 64 MiB budget" mutate_theme_budget
assert_rejected norse-required-base \
  "macOS Norse Theme criticality differs" mutate_norse_required
assert_rejected placeholder-content \
  "macOS product contains placeholder content" mutate_placeholder_content
assert_rejected debug-catalog \
  "macOS product contains a debug or support-only catalog" mutate_debug_catalog
assert_rejected source-master \
  "macOS product contains a prohibited source master" mutate_source_master
assert_rejected prohibited-attribution \
  "macOS product contains prohibited attribution bytes" mutate_attribution
assert_rejected static-forbidden-linkage \
  "macOS product contains prohibited statically linked Forsetti symbols" mutate_static_forbidden
assert_rejected test-support-linkage \
  "macOS executable unexpectedly links RuneScribeTestSupport" mutate_test_support
assert_rejected missing-gamekit-linkage \
  "macOS product has no dynamic linkage evidence for runtime-owned GameKit adapters" mutate_gamekit_link
assert_rejected missing-cloudkit-linkage \
  "macOS product has no dynamic linkage evidence for runtime-owned CloudKit adapters" mutate_cloudkit_link
assert_rejected wrong-build-platform \
  "macOS executable LC_BUILD_VERSION does not match its declared platform" mutate_build_platform
assert_rejected entitlement-team-prefix \
  "macOS arm64 ubiquity key-value store prefix differs from the signing team" mutate_entitlement_prefix
assert_rejected missing-game-center-catalog \
  "macOS Game Center resource bytes or SHA-256 differ" mutate_game_center_catalog
assert_rejected wrong-platform-audio \
  "macOS Platform resource bytes or SHA-256 differ" mutate_platform_audio
assert_rejected changed-built-version \
  "built marketing version differs from frozen 1.0.39" mutate_built_version

mutate_platform_graph() {
  ruby - "$graph_repository/Packages/RuneScribeArchitecture/Package.swift" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
anchor = "            exclude: [\"Feedback/Resources/Source\"],\n"
abort "Platform exclusion anchor missing" unless source.scan(anchor).length == 1
File.write(path, source.sub(anchor, ""))
RUBY
}

mutate_source_version() {
  ruby - "$graph_repository/project.yml" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
anchor = "    MARKETING_VERSION: \"1.0.39\"\n"
abort "version anchor missing" unless source.scan(anchor).length == 1
File.write(path, source.sub(anchor, "    MARKETING_VERSION: \"9.9.9\"\n"))
RUBY
}

mutate_source_entitlements() {
  /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.game-center" \
    "$graph_repository/Config/RuneScrib-macOS.entitlements" >/dev/null
}

mutate_external_package() {
  ruby - "$graph_repository/Packages/RuneScribeArchitecture/Package.swift" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
anchor = "    ],\n    targets: ["
abort "package dependency anchor missing" unless source.scan(anchor).length == 1
replacement = "    ],\n    dependencies: [.package(path: \"/tmp/Forsetti\")],\n    targets: ["
File.write(path, source.sub(anchor, replacement))
RUBY
}

assert_rejected platform-source-exclusion \
  "Package.swift Platform resource processing or source exclusion differs" \
  mutate_platform_graph "$graph_checker"

rsync -a --delete --exclude '.git/' --exclude '.build/' "$repository_root/" "$graph_repository/"
(CDPATH= cd -- "$graph_repository" && xcodegen generate >/dev/null)
assert_rejected frozen-source-version \
  "project.yml version/build differ from frozen 1.0.39 (39)" \
  mutate_source_version "$graph_checker"

rsync -a --delete --exclude '.git/' --exclude '.build/' "$repository_root/" "$graph_repository/"
(CDPATH= cd -- "$graph_repository" && xcodegen generate >/dev/null)
assert_rejected source-entitlement-decision \
  "macOS source entitlement dictionary differs" \
  mutate_source_entitlements "$graph_checker"

rsync -a --delete --exclude '.git/' --exclude '.build/' "$repository_root/" "$graph_repository/"
(CDPATH= cd -- "$graph_repository" && xcodegen generate >/dev/null)
assert_rejected external-package-dependency \
  "Package.swift gained an external dependency" \
  mutate_external_package "$graph_checker"

echo "Shipping-product negative mutations: $mutation_count promised rejections exercised."
