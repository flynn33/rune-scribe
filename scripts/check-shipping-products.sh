#!/bin/bash

set -u
set -o pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/check-shipping-products.sh \
    --macos-app /path/to/Release/RuneScrib.app \
    --ios-app /path/to/Release-iphoneos-or-iphonesimulator/RuneScrib.app

Checks the built products and the repository dependency graph used for the T-028
configuration gate. Both paths are required. Build Release products first;
Debug products contain test-only dynamic libraries and are rejected.
USAGE
}

macos_app=""
ios_app=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --macos-app)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      macos_app=$2
      shift 2
      ;;
    --ios-app)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ios_app=$2
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

if [ -z "$macos_app" ] || [ -z "$ios_app" ]; then
  echo "ERROR: --macos-app and --ios-app are both required" >&2
  usage >&2
  exit 2
fi

for tool in codesign file lipo nm otool plutil ruby swift; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool is unavailable: $tool" >&2
    exit 2
  fi
done

check_count=0
failure_count=0

pass_check() {
  check_count=$((check_count + 1))
  printf 'PASS: %s\n' "$1"
}

fail_check() {
  check_count=$((check_count + 1))
  failure_count=$((failure_count + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

check_nonempty_file() {
  if [ -f "$1" ] && [ -s "$1" ]; then
    pass_check "$2"
  else
    fail_check "$2 (missing or empty)"
  fi
}

check_file_type() {
  local path=$1
  local expected=$2
  local label=$3
  local description

  if [ ! -s "$path" ]; then
    fail_check "$label (missing or empty)"
    return
  fi

  description=$(file -b "$path" 2>/dev/null || true)
  if printf '%s\n' "$description" | grep -Fq "$expected"; then
    pass_check "$label"
  else
    fail_check "$label (unexpected file type)"
  fi
}

check_absent() {
  if [ ! -e "$1" ]; then
    pass_check "$2"
  else
    fail_check "$2 (unexpected file is present)"
  fi
}

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/RuneScribe-shipping-check.XXXXXX") || exit 2
trap 'rm -rf "$temporary_directory"' EXIT

if [ ! -d "$macos_app" ]; then
  echo "ERROR: macOS app bundle not found: $macos_app" >&2
  exit 2
fi
if [ ! -d "$ios_app" ]; then
  echo "ERROR: iOS app bundle not found: $ios_app" >&2
  exit 2
fi

macos_info="$macos_app/Contents/Info.plist"
ios_info="$ios_app/Info.plist"

if ! plutil -lint "$macos_info" >/dev/null 2>&1; then
  echo "ERROR: macOS product has no valid Contents/Info.plist" >&2
  exit 2
fi
if ! plutil -lint "$ios_info" >/dev/null 2>&1; then
  echo "ERROR: iOS product has no valid Info.plist" >&2
  exit 2
fi

macos_executable_name=$(plutil -extract CFBundleExecutable raw -o - "$macos_info" 2>/dev/null || true)
ios_executable_name=$(plutil -extract CFBundleExecutable raw -o - "$ios_info" 2>/dev/null || true)

if [ -z "$macos_executable_name" ] || [ -z "$ios_executable_name" ]; then
  echo "ERROR: a product Info.plist is missing CFBundleExecutable" >&2
  exit 2
fi

macos_executable="$macos_app/Contents/MacOS/$macos_executable_name"
ios_executable="$ios_app/$ios_executable_name"
macos_resources="$macos_app/Contents/Resources"
ios_resources="$ios_app"

check_nonempty_file "$macos_executable" "macOS main executable is present"
check_nonempty_file "$ios_executable" "iOS main executable is present"

if find "$macos_app" "$ios_app" -type f -name '*.debug.dylib' -print -quit | grep -q .; then
  fail_check "products have Release bundle shape (no test-only debug dylib)"
else
  pass_check "products have Release bundle shape (no test-only debug dylib)"
fi

plutil -convert json -o "$temporary_directory/macos-info.json" "$macos_info"
plutil -convert json -o "$temporary_directory/ios-info.json" "$ios_info"

if ruby -rjson - "$temporary_directory/macos-info.json" "$temporary_directory/ios-info.json" \
    >"$temporary_directory/info-errors" <<'RUBY'
macos = JSON.parse(File.read(ARGV.fetch(0)))
ios = JSON.parse(File.read(ARGV.fetch(1)))
errors = []

CONTACTS_USAGE = "Rune Scribe can organize your ciphers by contact. Contacts stay on your device, encrypted, and are never uploaded."
CAMERA_USAGE = "Rune Scribe uses the camera to scan a cipher QR code so you can import it. Frames are processed on-device and never saved or sent anywhere."
EXPECTED_UTI = "com.runescribe.runescribe"

def expect_equal(errors, actual, expected, label)
  errors << "#{label} is not the preserved value" unless actual == expected
end

def expect_true(errors, actual, label)
  errors << "#{label} is not true" unless actual == true
end

def expect_false(errors, actual, label)
  errors << "#{label} is not false" unless actual == false
end

def validate_common(errors, info, platform)
  expect_equal(errors, info["CFBundleIdentifier"], "com.runescribe.app", "#{platform} CFBundleIdentifier")
  expect_equal(errors, info["CFBundleDisplayName"], "Rune Scribe", "#{platform} CFBundleDisplayName")
  expect_equal(errors, info["CFBundleExecutable"], "RuneScrib", "#{platform} CFBundleExecutable")
  expect_equal(errors, info["CFBundlePackageType"], "APPL", "#{platform} CFBundlePackageType")
  expect_equal(errors, info["LSApplicationCategoryType"], "public.app-category.lifestyle", "#{platform} category")
  expect_equal(errors, info["NSContactsUsageDescription"], CONTACTS_USAGE, "#{platform} Contacts privacy string")

  url_types = info["CFBundleURLTypes"]
  url_types = [] unless url_types.is_a?(Array)
  import_type = url_types.find { |entry| entry.is_a?(Hash) && entry["CFBundleURLName"] == "com.runescribe.import" }
  if import_type.nil?
    errors << "#{platform} URL import registration is missing"
  else
    expect_equal(errors, import_type["CFBundleURLSchemes"], ["runescribe"], "#{platform} URL scheme")
  end
  all_schemes = url_types.flat_map do |entry|
    entry.is_a?(Hash) && entry["CFBundleURLSchemes"].is_a?(Array) ? entry["CFBundleURLSchemes"] : []
  end
  expect_equal(errors, all_schemes, ["runescribe"], "#{platform} complete URL-scheme set")

  declarations = info["UTExportedTypeDeclarations"]
  declarations = [] unless declarations.is_a?(Array)
  declaration = declarations.find { |entry| entry.is_a?(Hash) && entry["UTTypeIdentifier"] == EXPECTED_UTI }
  if declaration.nil?
    errors << "#{platform} exported UTI is missing"
  else
    expect_equal(errors, declaration["UTTypeConformsTo"], ["public.content", "public.data"], "#{platform} UTI conformance")
    tags = declaration["UTTypeTagSpecification"]
    tags = {} unless tags.is_a?(Hash)
    expect_equal(errors, tags["public.filename-extension"], ["runescribe"], "#{platform} UTI extension")
  end
  exported_ids = declarations.map { |entry| entry["UTTypeIdentifier"] if entry.is_a?(Hash) }.compact
  expect_equal(errors, exported_ids, [EXPECTED_UTI], "#{platform} complete exported-UTI set")

  document_types = info["CFBundleDocumentTypes"]
  document_types = [] unless document_types.is_a?(Array)
  document = document_types.find do |entry|
    entry.is_a?(Hash) && entry["LSItemContentTypes"].is_a?(Array) && entry["LSItemContentTypes"].include?(EXPECTED_UTI)
  end
  if document.nil?
    errors << "#{platform} document registration is missing"
  else
    expect_equal(errors, document["LSItemContentTypes"], [EXPECTED_UTI], "#{platform} document content types")
    expect_equal(errors, document["CFBundleTypeRole"], "Editor", "#{platform} document role")
    expect_equal(errors, document["LSHandlerRank"], "Owner", "#{platform} document handler rank")
  end

  unresolved = []
  walk = lambda do |value, path|
    case value
    when Hash
      value.each { |key, child| walk.call(child, path + [key]) }
    when Array
      value.each_with_index { |child, index| walk.call(child, path + [index.to_s]) }
    when String
      unresolved << path.join(".") if value.include?("$(")
    end
  end
  walk.call(info, [])
  errors << "#{platform} Info.plist contains unresolved build variables" unless unresolved.empty?
end

validate_common(errors, macos, "macOS")
validate_common(errors, ios, "iOS")

expect_equal(errors, macos["CFBundleSupportedPlatforms"], ["MacOSX"], "macOS supported platform")
expect_equal(errors, macos["LSMinimumSystemVersion"], "15.0", "macOS deployment target")

ios_platforms = ios["CFBundleSupportedPlatforms"]
unless ios_platforms == ["iPhoneOS"] || ios_platforms == ["iPhoneSimulator"]
  errors << "iOS supported platform is neither iPhoneOS nor iPhoneSimulator"
end
expect_equal(errors, ios["MinimumOSVersion"], "17.0", "iOS deployment target")
expect_true(errors, ios["LSRequiresIPhoneOS"], "iOS LSRequiresIPhoneOS")
expect_false(errors, ios["LSSupportsOpeningDocumentsInPlace"], "iOS opening-documents-in-place policy")
expect_equal(errors, ios["NSCameraUsageDescription"], CAMERA_USAGE, "iOS Camera privacy string")
expect_equal(errors, ios["UIDeviceFamily"], [1, 2], "iOS device family")

iphone_orientations = ios["UISupportedInterfaceOrientations~iphone"]
ipad_orientations = ios["UISupportedInterfaceOrientations~ipad"]
expect_equal(
  errors,
  iphone_orientations,
  ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
  "iPhone orientations"
)
expect_equal(
  errors,
  ipad_orientations,
  ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
  "iPad orientations"
)

marketing_versions = [macos["CFBundleShortVersionString"], ios["CFBundleShortVersionString"]]
build_versions = [macos["CFBundleVersion"], ios["CFBundleVersion"]]
errors << "platform marketing versions differ" unless marketing_versions.uniq.length == 1
errors << "platform build numbers differ" unless build_versions.uniq.length == 1
errors << "marketing version is malformed" unless marketing_versions.first.to_s.match?(/\A\d+(?:\.\d+){1,2}\z/)
errors << "build number is malformed" unless build_versions.first.to_s.match?(/\A\d+\z/)

puts errors
exit(errors.empty? ? 0 : 1)
RUBY
then
  pass_check "built Info.plists preserve identifiers, URL/UTI registration, privacy strings, versions, and platform settings"
else
  validation_detail=false
  while IFS= read -r error; do
    if [ -n "$error" ]; then
      validation_detail=true
      printf 'DETAIL: Info.plist: %s\n' "$error" >&2
    fi
  done < "$temporary_directory/info-errors"
  [ "$validation_detail" = true ] || printf 'DETAIL: Info.plist validator did not return diagnostics.\n' >&2
  fail_check "built Info.plists do not preserve the required configuration contract"
fi

verify_signature() {
  local app=$1
  local platform=$2
  local details_file="$temporary_directory/${platform}-signature-details"

  if codesign --verify --all-architectures --deep --strict "$app" >/dev/null 2>&1; then
    pass_check "$platform code signature and nested seals verify"
  else
    fail_check "$platform code signature or nested seal is invalid"
  fi

  codesign -dvvv "$app" > /dev/null 2>"$details_file" || true
  if grep -Fq 'Signature=adhoc' "$details_file"; then
    printf 'INFO: %s product uses an ad hoc local signature; distribution identity is not assessed.\n' "$platform"
  else
    printf 'INFO: %s product uses a non-ad-hoc signature.\n' "$platform"
  fi
}

verify_signature "$macos_app" "macOS"
verify_signature "$ios_app" "iOS"

macos_runtime_details="$temporary_directory/macOS-runtime-details"
: >"$macos_runtime_details"
macos_runtime_valid=true
macos_runtime_architectures=$(lipo -archs "$macos_executable" 2>/dev/null || true)
if [ -z "$macos_runtime_architectures" ]; then
  macos_runtime_valid=false
else
  for architecture in $macos_runtime_architectures; do
    architecture_details="$temporary_directory/macOS-${architecture}-signature-details"
    if ! codesign -dvvv --arch "$architecture" "$macos_app" > /dev/null 2>"$architecture_details" ||
       ! grep -Eq 'flags=.*runtime|Runtime Version=' "$architecture_details"; then
      macos_runtime_valid=false
    fi
    printf 'Architecture: %s\n' "$architecture" >>"$macos_runtime_details"
    sed -n '1,40p' "$architecture_details" >>"$macos_runtime_details"
  done
fi

if [ "$macos_runtime_valid" = true ]; then
  pass_check "macOS hardened runtime is present in the signed product"
else
  fail_check "macOS hardened runtime is absent from one or more executable architectures (use a Release product)"
fi

extract_codesign_entitlements() {
  local app=$1
  local executable=$2
  local output_directory=$3
  local architectures
  local architecture
  local plist

  architectures=$(lipo -archs "$executable" 2>/dev/null || true)
  [ -n "$architectures" ] || return 1
  mkdir -p "$output_directory" || return 1
  : >"$output_directory/architectures.txt"

  for architecture in $architectures; do
    case "$architecture" in
      ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    printf '%s\n' "$architecture" >>"$output_directory/architectures.txt"
    plist="$output_directory/${architecture}.plist"
    codesign -d --arch "$architecture" --entitlements :- "$app" >"$plist" 2>/dev/null || return 1
    plutil -lint "$plist" >/dev/null 2>&1 || return 1
    plutil -convert json -o "$output_directory/${architecture}.json" "$plist" >/dev/null || return 1
  done
}

extract_simulator_entitlements() {
  local executable=$1
  local output_directory=$2
  local architectures
  local architecture
  local plist

  architectures=$(lipo -archs "$executable" 2>/dev/null || true)
  [ -n "$architectures" ] || return 1
  mkdir -p "$output_directory" || return 1
  : >"$output_directory/architectures.txt"

  for architecture in $architectures; do
    case "$architecture" in
      ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    printf '%s\n' "$architecture" >>"$output_directory/architectures.txt"
    plist="$output_directory/${architecture}.plist"
    otool -arch "$architecture" -X -s __TEXT __entitlements "$executable" 2>/dev/null | \
      ruby -e '
        STDIN.each_line do |line|
          fields = line.split
          fields.shift
          fields.each do |word|
            next unless word.match?(/\A[0-9a-fA-F]+\z/) && word.length.even?
            STDOUT.write([word].pack("H*").reverse)
          end
        end
      ' >"$plist" || return 1

    plutil -lint "$plist" >/dev/null 2>&1 || return 1
    plutil -convert json -o "$output_directory/${architecture}.json" "$plist" >/dev/null || return 1
  done
}

macos_entitlements="$temporary_directory/macos-entitlements"
ios_entitlements="$temporary_directory/ios-entitlements"

if extract_codesign_entitlements "$macos_app" "$macos_executable" "$macos_entitlements"; then
  pass_check "macOS entitlements decode from every executable architecture"
else
  fail_check "macOS entitlements cannot be decoded from every executable architecture"
fi

ios_is_simulator=false
if ruby -rjson -e 'exit(JSON.parse(File.read(ARGV.fetch(0))).fetch("CFBundleSupportedPlatforms", []).include?("iPhoneSimulator") ? 0 : 1)' \
    "$temporary_directory/ios-info.json"; then
  ios_is_simulator=true
fi

if [ "$ios_is_simulator" = true ]; then
  if extract_simulator_entitlements "$ios_executable" "$ios_entitlements"; then
    pass_check "iOS simulated entitlements decode from every executable architecture"
  else
    fail_check "iOS simulated entitlements cannot be decoded from every executable architecture"
  fi
elif extract_codesign_entitlements "$ios_app" "$ios_executable" "$ios_entitlements"; then
  pass_check "iOS entitlements decode from every executable architecture"
else
  fail_check "iOS entitlements cannot be decoded from every executable architecture"
fi

if ruby -rjson - "$macos_entitlements" "$ios_entitlements" \
    >"$temporary_directory/entitlement-errors" <<'RUBY'
def load_architecture_entitlements(directory, platform, errors)
  architecture_file = File.join(directory, "architectures.txt")
  unless File.file?(architecture_file)
    errors << "#{platform} architecture entitlement manifest is missing"
    return {}
  end

  architectures = File.readlines(architecture_file, chomp: true).reject(&:empty?)
  if architectures.empty? || architectures.uniq != architectures
    errors << "#{platform} architecture entitlement manifest is empty or duplicated"
    return {}
  end

  expected_json = architectures.map { |architecture| "#{architecture}.json" }.sort
  actual_json = Dir.glob(File.join(directory, "*.json")).map { |path| File.basename(path) }.sort
  errors << "#{platform} architecture entitlement files differ from the executable" unless actual_json == expected_json

  architectures.each_with_object({}) do |architecture, values|
    path = File.join(directory, "#{architecture}.json")
    begin
      values[architecture] = JSON.parse(File.read(path))
    rescue Errno::ENOENT, JSON::ParserError => error
      errors << "#{platform} #{architecture} entitlements are unreadable: #{error.class}"
    end
  end
end

errors = []
macos_by_architecture = load_architecture_entitlements(ARGV.fetch(0), "macOS", errors)
ios_by_architecture = load_architecture_entitlements(ARGV.fetch(1), "iOS", errors)

macos_required = [
  "com.apple.security.app-sandbox",
  "com.apple.security.personal-information.addressbook",
  "com.apple.security.files.user-selected.read-write"
]
macos_signing_keys = [
  "com.apple.application-identifier",
  "com.apple.developer.team-identifier",
  "com.apple.security.get-task-allow"
]

macos_by_architecture.each do |architecture, macos|
  label = "macOS #{architecture}"
  macos_required.each do |key|
    errors << "#{label} required entitlement #{key} is absent" unless macos[key] == true
  end

  unexpected_macos = macos.keys - macos_required - macos_signing_keys
  unless unexpected_macos.empty?
    errors << "#{label} contains unexpected entitlements: #{unexpected_macos.sort.join(', ')}"
  end

  if macos.key?("com.apple.security.get-task-allow") && macos["com.apple.security.get-task-allow"] != false
    errors << "#{label} Release product enables get-task-allow"
  end

  macos_application_identifier = macos["com.apple.application-identifier"]
  macos_team_identifier = macos["com.apple.developer.team-identifier"]
  if macos_application_identifier || macos_team_identifier
    if macos_team_identifier.to_s.empty? ||
        macos_application_identifier != "#{macos_team_identifier}.com.runescribe.app"
      errors << "#{label} signing-injected identifiers are inconsistent"
    end
  end
end

ios_allowed = [
  "application-identifier",
  "com.apple.developer.team-identifier",
  "get-task-allow",
  "keychain-access-groups"
]
ios_by_architecture.each do |architecture, ios|
  label = "iOS #{architecture}"
  unexpected_ios = ios.keys - ios_allowed
  unless unexpected_ios.empty?
    errors << "#{label} contains unexpected entitlements: #{unexpected_ios.sort.join(', ')}"
  end

  if ios.key?("get-task-allow") && ios["get-task-allow"] != false
    errors << "#{label} Release product enables get-task-allow"
  end

  groups = ios["keychain-access-groups"]
  application_identifier = ios["application-identifier"]
  if !groups.is_a?(Array) || groups.length != 1 ||
      application_identifier.to_s.empty? || groups.first != application_identifier ||
      !application_identifier.to_s.end_with?(".com.runescribe.app")
    errors << "#{label} keychain access group does not preserve com.runescribe.app"
  end

  ios_team_identifier = ios["com.apple.developer.team-identifier"]
  if ios_team_identifier && application_identifier != "#{ios_team_identifier}.com.runescribe.app"
    errors << "#{label} signing-injected team identifier is inconsistent"
  end
end

if macos_by_architecture.values.uniq.length > 1
  errors << "macOS entitlement dictionaries differ across executable architectures"
end
if ios_by_architecture.values.uniq.length > 1
  errors << "iOS entitlement dictionaries differ across executable architectures"
end

puts errors
exit(errors.empty? ? 0 : 1)
RUBY
then
  pass_check "every architecture preserves sandbox, Contacts, file access, and Keychain entitlements without extras"
else
  validation_detail=false
  while IFS= read -r error; do
    if [ -n "$error" ]; then
      validation_detail=true
      printf 'DETAIL: entitlements: %s\n' "$error" >&2
    fi
  done < "$temporary_directory/entitlement-errors"
  [ "$validation_detail" = true ] || printf 'DETAIL: entitlement validator did not return diagnostics.\n' >&2
  fail_check "built entitlements do not preserve the required per-architecture capability contract"
fi

check_nonempty_file "$macos_resources/Assets.car" "macOS compiled asset catalog is present"
check_file_type "$macos_resources/AppIcon.icns" "Mac OS X icon" "macOS app icon is present and valid"
check_absent "$macos_resources/NotoSansRunic-Regular.ttf" "macOS app root does not duplicate the Norse module font"
check_file_type "$macos_resources/raven-forge-spp-splash.mp4" "ISO Media" "macOS splash video is present and valid"
check_file_type "$macos_resources/default.metallib" "MetalLib" "macOS Metal shader library is present and valid"

check_nonempty_file "$ios_resources/Assets.car" "iOS compiled asset catalog is present"
ios_icon=$(find "$ios_resources" -maxdepth 1 -type f -name 'AppIcon*.png' -size +0c -print -quit)
if [ -n "$ios_icon" ] && file -b "$ios_icon" 2>/dev/null | grep -Fq 'PNG image data'; then
  pass_check "iOS app icon is present and valid"
else
  fail_check "iOS app icon is missing or invalid"
fi
check_absent "$ios_resources/NotoSansRunic-Regular.ttf" "iOS app root does not duplicate the Norse module font"
check_file_type "$ios_resources/raven-forge-spp-splash.mp4" "ISO Media" "iOS splash video is present and valid"
check_file_type "$ios_resources/default.metallib" "MetalLib" "iOS Metal shader library is present and valid"

write_module_bundle_list() {
  local root=$1
  local bundle_name=$2
  local output=$3

  find "$root" -type d -name "${bundle_name}.bundle" -print0 >"$output"
}

module_bundle_count() {
  ruby -e '
    entries = File.binread(ARGV.fetch(0)).split("\0", -1)
    entries.pop if entries.last == ""
    puts entries.length
  ' "$1"
}

first_module_bundle() {
  ruby -e '
    entries = File.binread(ARGV.fetch(0)).split("\0", -1)
    entries.pop if entries.last == ""
    STDOUT.write(entries.first.to_s)
  ' "$1"
}

module_resource_root() {
  local bundle=$1

  if [ -d "$bundle/Contents/Resources" ]; then
    printf '%s\n' "$bundle/Contents/Resources"
  else
    printf '%s\n' "$bundle"
  fi
}

check_exact_module_bundle() {
  local list=$1
  local label=$2
  local count

  count=$(module_bundle_count "$list")
  if [ "$count" -eq 1 ]; then
    pass_check "$label"
  else
    fail_check "$label (found $count)"
  fi
}

macos_core_bundles="$temporary_directory/macos-core-bundles"
macos_progression_bundles="$temporary_directory/macos-progression-bundles"
macos_theme_coordinator_bundles="$temporary_directory/macos-theme-coordinator-bundles"
macos_norse_theme_bundles="$temporary_directory/macos-norse-theme-bundles"
macos_ui_bundles="$temporary_directory/macos-ui-bundles"
ios_core_bundles="$temporary_directory/ios-core-bundles"
ios_progression_bundles="$temporary_directory/ios-progression-bundles"
ios_theme_coordinator_bundles="$temporary_directory/ios-theme-coordinator-bundles"
ios_norse_theme_bundles="$temporary_directory/ios-norse-theme-bundles"
ios_ui_bundles="$temporary_directory/ios-ui-bundles"

write_module_bundle_list "$macos_resources" "RuneScribeArchitecture_RuneScribeCoreModule" "$macos_core_bundles"
write_module_bundle_list "$macos_resources" "RuneScribeArchitecture_RuneScribeProgressionModule" "$macos_progression_bundles"
write_module_bundle_list "$macos_resources" "RuneScribeArchitecture_RuneScribeThemeCoordinatorModule" "$macos_theme_coordinator_bundles"
write_module_bundle_list "$macos_resources" "RuneScribeArchitecture_RuneScribeNorseThemeModule" "$macos_norse_theme_bundles"
write_module_bundle_list "$macos_resources" "RuneScribeArchitecture_RuneScribeUIModule" "$macos_ui_bundles"
write_module_bundle_list "$ios_resources" "RuneScribeArchitecture_RuneScribeCoreModule" "$ios_core_bundles"
write_module_bundle_list "$ios_resources" "RuneScribeArchitecture_RuneScribeProgressionModule" "$ios_progression_bundles"
write_module_bundle_list "$ios_resources" "RuneScribeArchitecture_RuneScribeThemeCoordinatorModule" "$ios_theme_coordinator_bundles"
write_module_bundle_list "$ios_resources" "RuneScribeArchitecture_RuneScribeNorseThemeModule" "$ios_norse_theme_bundles"
write_module_bundle_list "$ios_resources" "RuneScribeArchitecture_RuneScribeUIModule" "$ios_ui_bundles"

check_exact_module_bundle "$macos_core_bundles" "macOS product contains exactly one Core module resource bundle"
check_exact_module_bundle "$macos_progression_bundles" "macOS product contains exactly one Progression module resource bundle"
check_exact_module_bundle "$macos_theme_coordinator_bundles" "macOS product contains exactly one Theme Coordinator module resource bundle"
check_exact_module_bundle "$macos_norse_theme_bundles" "macOS product contains exactly one Norse Theme module resource bundle"
check_exact_module_bundle "$macos_ui_bundles" "macOS product contains exactly one UI module resource bundle"
check_exact_module_bundle "$ios_core_bundles" "iOS product contains exactly one Core module resource bundle"
check_exact_module_bundle "$ios_progression_bundles" "iOS product contains exactly one Progression module resource bundle"
check_exact_module_bundle "$ios_theme_coordinator_bundles" "iOS product contains exactly one Theme Coordinator module resource bundle"
check_exact_module_bundle "$ios_norse_theme_bundles" "iOS product contains exactly one Norse Theme module resource bundle"
check_exact_module_bundle "$ios_ui_bundles" "iOS product contains exactly one UI module resource bundle"

macos_core_bundle=$(first_module_bundle "$macos_core_bundles")
macos_progression_bundle=$(first_module_bundle "$macos_progression_bundles")
macos_theme_coordinator_bundle=$(first_module_bundle "$macos_theme_coordinator_bundles")
macos_norse_theme_bundle=$(first_module_bundle "$macos_norse_theme_bundles")
macos_ui_bundle=$(first_module_bundle "$macos_ui_bundles")
ios_core_bundle=$(first_module_bundle "$ios_core_bundles")
ios_progression_bundle=$(first_module_bundle "$ios_progression_bundles")
ios_theme_coordinator_bundle=$(first_module_bundle "$ios_theme_coordinator_bundles")
ios_norse_theme_bundle=$(first_module_bundle "$ios_norse_theme_bundles")
ios_ui_bundle=$(first_module_bundle "$ios_ui_bundles")

macos_core_resource_root=""
macos_progression_resource_root=""
macos_theme_coordinator_resource_root=""
macos_norse_theme_resource_root=""
macos_ui_resource_root=""
ios_core_resource_root=""
ios_progression_resource_root=""
ios_theme_coordinator_resource_root=""
ios_norse_theme_resource_root=""
ios_ui_resource_root=""
[ -n "$macos_core_bundle" ] && macos_core_resource_root=$(module_resource_root "$macos_core_bundle")
[ -n "$macos_progression_bundle" ] && macos_progression_resource_root=$(module_resource_root "$macos_progression_bundle")
[ -n "$macos_theme_coordinator_bundle" ] && macos_theme_coordinator_resource_root=$(module_resource_root "$macos_theme_coordinator_bundle")
[ -n "$macos_norse_theme_bundle" ] && macos_norse_theme_resource_root=$(module_resource_root "$macos_norse_theme_bundle")
[ -n "$macos_ui_bundle" ] && macos_ui_resource_root=$(module_resource_root "$macos_ui_bundle")
[ -n "$ios_core_bundle" ] && ios_core_resource_root=$(module_resource_root "$ios_core_bundle")
[ -n "$ios_progression_bundle" ] && ios_progression_resource_root=$(module_resource_root "$ios_progression_bundle")
[ -n "$ios_theme_coordinator_bundle" ] && ios_theme_coordinator_resource_root=$(module_resource_root "$ios_theme_coordinator_bundle")
[ -n "$ios_norse_theme_bundle" ] && ios_norse_theme_resource_root=$(module_resource_root "$ios_norse_theme_bundle")
[ -n "$ios_ui_bundle" ] && ios_ui_resource_root=$(module_resource_root "$ios_ui_bundle")

macos_core_manifest=""
macos_progression_manifest=""
macos_theme_coordinator_manifest=""
macos_norse_theme_manifest=""
macos_ui_manifest=""
ios_core_manifest=""
ios_progression_manifest=""
ios_theme_coordinator_manifest=""
ios_norse_theme_manifest=""
ios_ui_manifest=""
[ -n "$macos_core_resource_root" ] && macos_core_manifest="$macos_core_resource_root/module-manifest.json"
[ -n "$macos_progression_resource_root" ] && macos_progression_manifest="$macos_progression_resource_root/module-manifest.json"
[ -n "$macos_theme_coordinator_resource_root" ] && macos_theme_coordinator_manifest="$macos_theme_coordinator_resource_root/module-manifest.json"
[ -n "$macos_norse_theme_resource_root" ] && macos_norse_theme_manifest="$macos_norse_theme_resource_root/module-manifest.json"
[ -n "$macos_ui_resource_root" ] && macos_ui_manifest="$macos_ui_resource_root/module-manifest.json"
[ -n "$ios_core_resource_root" ] && ios_core_manifest="$ios_core_resource_root/module-manifest.json"
[ -n "$ios_progression_resource_root" ] && ios_progression_manifest="$ios_progression_resource_root/module-manifest.json"
[ -n "$ios_theme_coordinator_resource_root" ] && ios_theme_coordinator_manifest="$ios_theme_coordinator_resource_root/module-manifest.json"
[ -n "$ios_norse_theme_resource_root" ] && ios_norse_theme_manifest="$ios_norse_theme_resource_root/module-manifest.json"
[ -n "$ios_ui_resource_root" ] && ios_ui_manifest="$ios_ui_resource_root/module-manifest.json"

check_nonempty_file "$macos_core_manifest" "macOS Core module manifest resource is present"
check_nonempty_file "$macos_progression_manifest" "macOS Progression module manifest resource is present"
check_nonempty_file "$macos_theme_coordinator_manifest" "macOS Theme Coordinator module manifest resource is present"
check_nonempty_file "$macos_norse_theme_manifest" "macOS Norse Theme module manifest resource is present"
check_nonempty_file "$macos_ui_manifest" "macOS UI module manifest resource is present"
check_nonempty_file "$ios_core_manifest" "iOS Core module manifest resource is present"
check_nonempty_file "$ios_progression_manifest" "iOS Progression module manifest resource is present"
check_nonempty_file "$ios_theme_coordinator_manifest" "iOS Theme Coordinator module manifest resource is present"
check_nonempty_file "$ios_norse_theme_manifest" "iOS Norse Theme module manifest resource is present"
check_nonempty_file "$ios_ui_manifest" "iOS UI module manifest resource is present"

if [ "$(module_bundle_count "$macos_progression_bundles")" -eq 1 ] && \
   [ "$(module_bundle_count "$ios_progression_bundles")" -eq 1 ]; then
  if ruby -rdigest - "$macos_progression_resource_root" "$ios_progression_resource_root" \
      >"$temporary_directory/progression-resource-errors" <<'RUBY'
macos_root = ARGV.fetch(0)
ios_root = ARGV.fetch(1)
errors = []

expected = {
  "PACKAGE-MANIFEST.json" => [
    2064,
    "93984e063bcdb0e8408a6bc8e95ccf9902efcca67b7358ecb99c2494c04993f9"
  ],
  "Rune-Scribe-Progression-Catalog-Schema-v1.0.json" => [
    3108,
    "4c0d538229877a035ad9444d4e89a6ae13ae46cb190f9677761b945c173ed6dd"
  ],
  "Rune-Scribe-Progression-Catalog-v1.0.json" => [
    101246,
    "7b7586d0749abab41aded3e9b3457b665c3a8869ae6d849f9adc55e621a5a142"
  ],
  "Rune-Scribe-Progression-Event-Catalog-v1.0.json" => [
    8950,
    "b2ae5b795f75b0c6847d195990d62365d57a7d715d20aff8f44c2c420bd8c2a9"
  ],
  "Rune-Scribe-Progression-Future-Theme-Binding-Contract-v1.0.json" => [
    2684,
    "2236c49f7e7096701c90acc17283871685577780a05aeb8b8a673f4b35d8277b"
  ],
  "module-manifest.json" => [
    2494,
    "b6a25bb50010cf68c68c94dd6331a8a30ff27fcdb90872c61e2b628e508f4ca7"
  ]
}

def inventory(root)
  packaging_entries = ["Info.plist", "_CodeSignature"]
  Dir.children(root).reject { |entry| packaging_entries.include?(entry) }.sort
end

{
  "macOS" => macos_root,
  "iOS" => ios_root
}.each do |platform, root|
  actual_inventory = inventory(root)
  unless actual_inventory == expected.keys.sort
    errors << "#{platform} Progression resource inventory differs: #{actual_inventory.join(', ')}"
  end

  expected.each do |name, (expected_bytes, expected_sha256)|
    path = File.join(root, name)
    unless File.file?(path) && !File.symlink?(path)
      errors << "#{platform} Progression resource #{name} is missing or is not a regular file"
      next
    end

    bytes = File.size(path)
    sha256 = Digest::SHA256.file(path).hexdigest
    errors << "#{platform} Progression resource #{name} byte count differs" unless bytes == expected_bytes
    errors << "#{platform} Progression resource #{name} SHA-256 differs" unless sha256 == expected_sha256
  end
end

expected.each_key do |name|
  macos_path = File.join(macos_root, name)
  ios_path = File.join(ios_root, name)
  next unless File.file?(macos_path) && File.file?(ios_path)
  errors << "Progression resource #{name} differs between platforms" unless File.binread(macos_path) == File.binread(ios_path)
end

puts errors
exit(errors.empty? ? 0 : 1)
RUBY
  then
    pass_check "Progression bundles preserve the exact six-file byte, SHA-256, and cross-platform resource contract"
  else
    validation_detail=false
    while IFS= read -r error; do
      if [ -n "$error" ]; then
        validation_detail=true
        printf 'DETAIL: Progression resource: %s\n' "$error" >&2
      fi
    done <"$temporary_directory/progression-resource-errors"
    [ "$validation_detail" = true ] || printf 'DETAIL: Progression resource validator did not return diagnostics.\n' >&2
    fail_check "Progression bundles differ from the exact six-file resource contract"
  fi
fi

if [ "$(module_bundle_count "$macos_theme_coordinator_bundles")" -eq 1 ] && \
   [ "$(module_bundle_count "$macos_norse_theme_bundles")" -eq 1 ] && \
   [ "$(module_bundle_count "$ios_theme_coordinator_bundles")" -eq 1 ] && \
   [ "$(module_bundle_count "$ios_norse_theme_bundles")" -eq 1 ]; then
  if ruby -rdigest -rjson - \
      "$macos_theme_coordinator_resource_root" "$macos_norse_theme_resource_root" \
      "$ios_theme_coordinator_resource_root" "$ios_norse_theme_resource_root" \
      >"$temporary_directory/theme-resource-errors" <<'RUBY'
roots = {
  "macOS Theme Coordinator" => ARGV.fetch(0),
  "macOS Norse Theme" => ARGV.fetch(1),
  "iOS Theme Coordinator" => ARGV.fetch(2),
  "iOS Norse Theme" => ARGV.fetch(3)
}
errors = []

expected_by_module = {
  "Theme Coordinator" => {
    "module-manifest.json" => [
      1215,
      "aaa6a0e08f4b7ae9c1fa39a26990dbd7909824aaf6efae08492ab8f86f48507c"
    ]
  },
  "Norse Theme" => {}
}

norse_integrity_name = "Norse-Resource-Integrity-Manifest-v1.0.json"
norse_integrity_contract = [
  24_610,
  "8bfb935ca4d3b82bdee00ce0f21756811e0d34460c9002dfed4c56ce13f1eb0a"
]
norse_fixed_resources = {
  "module-manifest.json" => [
    11_726,
    "cd7d1d28ef3efff04daf2f6ad9103dc83d174e00470592a9d918d187ac8cb804"
  ],
  norse_integrity_name => norse_integrity_contract,
  "crest.norse.forge-master.png" => [123_379, "50a2620294a19c3fa6be7129e1d4973c90ee7abea3fe71ce5640f60ca4a6635f"],
  "frame.norse.carved-knotwork.png" => [120_537, "632dc82de68d83a8ecec315d7ca7bbda54bbf242b3d5afed3691af0af0d4d36a"],
  "seal.norse.echo-rune.png" => [159_691, "f98d9f2de501b78586363c3abe0b4949142bdd46523bc2e7c6a4e5d95da6aa36"],
  "seal.norse.forge-flame.png" => [145_780, "431f95199fd660c29d73d381236b7570bd70da380bf9cdbbd5ffefdfb89d9d2d"],
  "seal.norse.forge-hammer.png" => [154_174, "5734f5802b5af981ea8691fb720e1e258f32eaf5e7cd38eb447c86fd0f98b126"],
  "seal.norse.knotwork.png" => [163_306, "b08af25f444603ef8ae702d0317db5eb8dc072e518fb5a0d3ab296166e0091b6"],
  "seal.norse.longship.png" => [155_920, "0dd5edbb301588219bbc4d12a07d24e558f47db794ee5e9150f650be1b0e769f"],
  "seal.norse.raven.png" => [152_556, "8ffb0a2bd84838e6142e16130dff93277929cc442629edda2af7570537789448"]
}

norse_root = roots.fetch("macOS Norse Theme")
norse_integrity_path = File.join(norse_root, norse_integrity_name)
if !File.file?(norse_integrity_path) || File.size(norse_integrity_path) != norse_integrity_contract[0] ||
   Digest::SHA256.file(norse_integrity_path).hexdigest != norse_integrity_contract[1]
  errors << "macOS Norse Theme frozen integrity manifest is missing or invalid"
else
  begin
    integrity = JSON.parse(File.read(norse_integrity_path))
    resources = integrity.fetch("resources")
    errors << "Norse Theme integrity manifest does not declare exactly 47 production resources" unless resources.length == 47
    manifest_resources = resources.to_h do |resource|
      [File.basename(resource.fetch("path")), [resource.fetch("byteLength"), resource.fetch("sha256")]]
    end
    errors << "Norse Theme integrity manifest has colliding shipping basenames" unless manifest_resources.length == resources.length
    errors << "Norse Theme fixed resources collide with the frozen manifest" unless (manifest_resources.keys & norse_fixed_resources.keys).empty?
    expected_by_module["Norse Theme"] = manifest_resources.merge(norse_fixed_resources)
  rescue JSON::ParserError, KeyError, TypeError => error
    errors << "Norse Theme integrity manifest cannot define the shipping inventory: #{error.class}"
  end
end

def inventory(root)
  packaging_entries = ["Info.plist", "_CodeSignature"]
  Dir.children(root).reject { |entry| packaging_entries.include?(entry) }.sort
end

roots.each do |label, root|
  module_name = label.end_with?("Theme Coordinator") ? "Theme Coordinator" : "Norse Theme"
  expected = expected_by_module.fetch(module_name)
  actual_inventory = inventory(root)
  unless actual_inventory == expected.keys.sort
    errors << "#{label} resource inventory differs: #{actual_inventory.join(', ')}"
  end

  expected.each do |name, (expected_bytes, expected_sha256)|
    resource_path = File.join(root, name)
    unless File.file?(resource_path) && !File.symlink?(resource_path)
      errors << "#{label} resource #{name} is missing or is not a regular file"
      next
    end

    bytes = File.size(resource_path)
    sha256 = Digest::SHA256.file(resource_path).hexdigest
    errors << "#{label} resource #{name} byte count differs" unless bytes == expected_bytes
    errors << "#{label} resource #{name} SHA-256 differs" unless sha256 == expected_sha256
  end
end

expected_by_module.each do |module_name, expected|
  expected.each_key do |name|
    macos_path = File.join(roots.fetch("macOS #{module_name}"), name)
    ios_path = File.join(roots.fetch("iOS #{module_name}"), name)
    next unless File.file?(macos_path) && File.file?(ios_path)
    errors << "#{module_name} resource #{name} differs between platforms" unless File.binread(macos_path) == File.binread(ios_path)
  end
end

puts errors
exit(errors.empty? ? 0 : 1)
RUBY
  then
    pass_check "Theme bundles preserve exact inventories, byte counts, SHA-256 values, source exclusion, and cross-platform parity"
  else
    validation_detail=false
    while IFS= read -r error; do
      if [ -n "$error" ]; then
        validation_detail=true
        printf 'DETAIL: Theme resource: %s\n' "$error" >&2
      fi
    done <"$temporary_directory/theme-resource-errors"
    [ "$validation_detail" = true ] || printf 'DETAIL: Theme resource validator did not return diagnostics.\n' >&2
    fail_check "Theme bundles differ from their exact resource contracts"
  fi
fi

if [ -s "$macos_core_manifest" ] && [ -s "$macos_progression_manifest" ] && \
   [ -s "$macos_theme_coordinator_manifest" ] && [ -s "$macos_norse_theme_manifest" ] && \
   [ -s "$macos_ui_manifest" ] && [ -s "$ios_core_manifest" ] && \
   [ -s "$ios_progression_manifest" ] && [ -s "$ios_theme_coordinator_manifest" ] && \
   [ -s "$ios_norse_theme_manifest" ] && [ -s "$ios_ui_manifest" ]; then
  if ruby -rjson - "$macos_core_manifest" "$macos_progression_manifest" \
      "$macos_theme_coordinator_manifest" "$macos_norse_theme_manifest" "$macos_ui_manifest" \
      "$ios_core_manifest" "$ios_progression_manifest" \
      "$ios_theme_coordinator_manifest" "$ios_norse_theme_manifest" "$ios_ui_manifest" \
      "$temporary_directory/macos-info.json" "$temporary_directory/ios-info.json" \
      >"$temporary_directory/manifest-errors" <<'RUBY'
paths = ARGV.take(10)
macos_info = JSON.parse(File.read(ARGV.fetch(10)))
ios_info = JSON.parse(File.read(ARGV.fetch(11)))
errors = []

expectations = [
  ["com.runescribe.module.core", "service", "RuneScribeCoreModule", "Core", nil, "app"],
  ["com.runescribe.module.progression", "service", "RuneScribeProgressionModule", "Progression", nil, "app"],
  ["com.runescribe.module.theme-coordinator", "service", "RuneScribeThemeCoordinatorModule", "Theme Coordinator", "policy.theme-coordinator", "1.0.0"],
  ["com.runescribe.module.theme.norse", "service", "RuneScribeNorseThemeModule", "Norse Theme", "policy.theme-provider", "1.0.0"],
  ["com.runescribe.module.ui", "ui", "RuneScribeUIModule", "UI", nil, "app"]
]

paths.each_with_index do |path, index|
  manifest = JSON.parse(File.read(path))
  expected = expectations[index % 5]
  platform = index < 5 ? "macOS" : "iOS"
  label = expected[3]
  errors << "#{platform} #{label} manifest moduleID differs" unless manifest["moduleID"] == expected[0]
  errors << "#{platform} #{label} manifest moduleType differs" unless manifest["moduleType"] == expected[1]
  errors << "#{platform} #{label} manifest entryPoint differs" unless manifest["entryPoint"] == expected[2]
  errors << "#{platform} #{label} manifest policy class differs" unless manifest["policyClass"] == expected[4]
  errors << "#{platform} #{label} manifest policy profile differs" unless manifest["policyProfile"] == "forsetti-pattern-b-standalone"
  errors << "#{platform} #{label} production diagnostics are enabled" unless manifest["diagnosticsVisibleInProduction"] == false
  errors << "#{platform} #{label} supported platforms differ" unless manifest["supportedPlatforms"] == ["iOS", "macOS"]
  expected_version = if expected[5] == "app"
    platform == "macOS" ? macos_info["CFBundleShortVersionString"] : ios_info["CFBundleShortVersionString"]
  else
    expected[5]
  end
  version_contract = expected[5] == "app" ? "the app" : "the exact contract version"
  errors << "#{platform} #{label} module version differs from #{version_contract}" unless manifest["moduleVersion"] == expected_version

  next unless expected[0] == "com.runescribe.module.progression"

  owner = "com.runescribe.module.progression"
  expected_required_resources = [
    { "name" => "module-manifest", "fileExtension" => "json", "subdirectory" => nil, "ownerModuleID" => owner },
    { "name" => "PACKAGE-MANIFEST", "fileExtension" => "json", "subdirectory" => nil, "ownerModuleID" => owner },
    { "name" => "Rune-Scribe-Progression-Catalog-Schema-v1.0", "fileExtension" => "json", "subdirectory" => nil, "ownerModuleID" => owner },
    { "name" => "Rune-Scribe-Progression-Catalog-v1.0", "fileExtension" => "json", "subdirectory" => nil, "ownerModuleID" => owner },
    { "name" => "Rune-Scribe-Progression-Event-Catalog-v1.0", "fileExtension" => "json", "subdirectory" => nil, "ownerModuleID" => owner },
    { "name" => "Rune-Scribe-Progression-Future-Theme-Binding-Contract-v1.0", "fileExtension" => "json", "subdirectory" => nil, "ownerModuleID" => owner }
  ]
  expected_required_services = ["ApplicationResourceLocator", "ModuleStateStore"]
  expected_published_endpoints = [
    "progression.diagnostics.summary",
    "progression.entitlements",
    "progression.event.apply",
    "progression.migration.existing-user.apply",
    "progression.migration.existing-user.page.apply",
    "progression.recovery.rebuild",
    "progression.reveal.acknowledge",
    "progression.reveal.mark-presented",
    "progression.state",
    "progression.title.select"
  ]
  requirements = manifest["runtimeRequirements"]

  errors << "#{platform} Progression criticality is not optional" unless manifest["criticality"] == "optional"
  unless requirements.is_a?(Hash)
    errors << "#{platform} Progression runtime requirements are missing"
    next
  end
  unless requirements["requiredResources"] == expected_required_resources
    errors << "#{platform} Progression owner-scoped required resource declarations differ"
  end
  unless requirements["requiredServices"] == expected_required_services
    errors << "#{platform} Progression required services differ"
  end
  unless manifest["publishedEndpoints"] == expected_published_endpoints
    errors << "#{platform} Progression published endpoints differ"
  end
end

paths.each_with_index do |path, index|
  manifest = JSON.parse(File.read(path))
  expected = expectations[index % 5]
  platform = index < 5 ? "macOS" : "iOS"

  case expected[0]
  when "com.runescribe.module.theme-coordinator"
    expected_requirements = {
      "requiredServices" => [],
      "requiredResources" => [],
      "requiredModuleRoles" => ["runescribe.theme.norse"]
    }
    expected_capabilities = [
      "runtime.contributions.read",
      "runtime.resources.opaque.resolve",
      "runtime.settings.read",
      "runtime.settings.write",
      "runtime.availability.read",
      "runtime.events.publish"
    ]
    expected_endpoints = [
      "theme.codex.select",
      "theme.diagnostics.summary",
      "theme.resource.resolve",
      "theme.state",
      "theme.state.current"
    ]

    errors << "#{platform} Theme Coordinator criticality differs" unless manifest["criticality"] == "required"
    errors << "#{platform} Theme Coordinator default role differs" unless manifest["defaultRole"] == "runescribe.theme.coordinator"
    errors << "#{platform} Theme Coordinator runtime requirements differ" unless manifest["runtimeRequirements"] == expected_requirements
    errors << "#{platform} Theme Coordinator requested capabilities differ" unless manifest["capabilitiesRequested"] == expected_capabilities
    errors << "#{platform} Theme Coordinator published endpoints differ" unless manifest["publishedEndpoints"] == expected_endpoints
    errors << "#{platform} Theme Coordinator consumed endpoints differ" unless manifest["consumedEndpoints"] == []
    errors << "#{platform} Theme Coordinator entitlement requirement differs" unless manifest["entitlementRequirement"].nil?
  when "com.runescribe.module.theme.norse"
    owner = "com.runescribe.module.theme.norse"
    requirements = manifest["runtimeRequirements"]
    required_resources = requirements.is_a?(Hash) ? requirements["requiredResources"] : nil
    expected_entitlement = { "kind" => "always", "identifier" => "unlock.codex.norse" }
    expected_capabilities = [
      "resources.read",
      "runtime.contributions.publish",
      "runtime.resources.opaque.publish"
    ]

    errors << "#{platform} Norse Theme criticality differs" unless manifest["criticality"] == "required"
    errors << "#{platform} Norse Theme default role differs" unless manifest["defaultRole"] == "runescribe.theme.norse"
    errors << "#{platform} Norse Theme runtime requirements are missing" unless requirements.is_a?(Hash)
    errors << "#{platform} Norse Theme required services differ" unless requirements.is_a?(Hash) && requirements["requiredServices"] == ["ApplicationResourceLocator"]
    errors << "#{platform} Norse Theme required module roles differ" unless requirements.is_a?(Hash) && requirements["requiredModuleRoles"] == []
    unless required_resources.is_a?(Array) && required_resources.length == 57
      errors << "#{platform} Norse Theme does not declare exactly 57 required resources"
    else
      identities = required_resources.map { |resource| [resource["name"], resource["fileExtension"]] }
      errors << "#{platform} Norse Theme required resource identities are not unique" unless identities.uniq.length == 57
      errors << "#{platform} Norse Theme required resources are not flat owner-scoped declarations" unless required_resources.all? { |resource| resource["subdirectory"].nil? && resource["ownerModuleID"] == owner }
    end
    errors << "#{platform} Norse Theme requested capabilities differ" unless manifest["capabilitiesRequested"] == expected_capabilities
    errors << "#{platform} Norse Theme published endpoints differ" unless manifest["publishedEndpoints"] == []
    errors << "#{platform} Norse Theme consumed endpoints differ" unless manifest["consumedEndpoints"] == []
    errors << "#{platform} Norse Theme entitlement requirement differs" unless manifest["entitlementRequirement"] == expected_entitlement
  end
end

expectations.each_index do |index|
  errors << "#{expectations[index][3]} module manifest differs between platforms" unless File.binread(paths[index]) == File.binread(paths[index + 5])
end

puts errors
exit(errors.empty? ? 0 : 1)
RUBY
  then
    pass_check "embedded module manifests preserve identity, policy, version, and cross-platform parity"
  else
    validation_detail=false
    while IFS= read -r error; do
      if [ -n "$error" ]; then
        validation_detail=true
        printf 'DETAIL: module manifest: %s\n' "$error" >&2
      fi
    done < "$temporary_directory/manifest-errors"
    [ "$validation_detail" = true ] || printf 'DETAIL: module-manifest validator did not return diagnostics.\n' >&2
    fail_check "embedded module manifests do not preserve the required contract"
  fi
fi

collect_macho_files() {
  local app=$1
  local output=$2
  local candidate
  local description

  : >"$output"
  while IFS= read -r -d '' candidate; do
    description=$(file -b "$candidate" 2>/dev/null || true)
    case "$description" in
      *Mach-O*) printf '%s\0' "$candidate" >>"$output" ;;
    esac
  done < <(find "$app" -type f -print0)
}

write_macho_dependencies() {
  local executable=$1
  local output=$2
  local architectures
  local architecture

  architectures=$(lipo -archs "$executable" 2>/dev/null || true)
  [ -n "$architectures" ] || return 1
  : >"$output"
  for architecture in $architectures; do
    case "$architecture" in
      ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    otool -arch "$architecture" -L "$executable" >>"$output" 2>/dev/null || return 1
  done
}

validate_dependency_table() {
  local table=$1
  local executable=$2

  ruby -rpathname - "$table" "$executable" <<'RUBY'
table = ARGV.fetch(0)
executable = ARGV.fetch(1)
errors = []

File.foreach(table) do |line|
  next unless line.start_with?("\t")

  rendered = line.delete_prefix("\t").chomp
  marker = rendered.rindex(" (compatibility version ")
  if marker.nil?
    errors << "#{executable}: unreadable dependency row: #{rendered.inspect}"
    next
  end

  dependency = rendered[0...marker]
  canonical = Pathname.new(dependency).cleanpath.to_s
  unless dependency == canonical
    errors << "#{executable}: noncanonical dynamic dependency: #{dependency}"
    next
  end

  unless dependency.start_with?("/System/Library/") || dependency.start_with?("/usr/lib/")
    errors << "#{executable}: unexpected dynamic dependency: #{dependency}"
  end
end

puts errors
exit(errors.empty? ? 0 : 1)
RUBY
}

inspect_linkage() {
  local executable=$1
  local platform=$2
  local app=$3
  local symbols="$temporary_directory/${platform}-symbols"
  local links="$temporary_directory/${platform}-links"
  local macho_files="$temporary_directory/${platform}-macho-files"
  local unexpected_links="$temporary_directory/${platform}-unexpected-links"
  local binary
  local binary_links
  local binary_index=0
  local macho_count=0
  local dependency_tables_readable=true
  local dependencies_valid=true
  local expected_main_seen=false

  : >"$links"
  : >"$unexpected_links"
  collect_macho_files "$app" "$macho_files"

  while IFS= read -r -d '' binary; do
    binary_index=$((binary_index + 1))
    macho_count=$((macho_count + 1))
    [ "$binary" = "$executable" ] && expected_main_seen=true
    binary_links="$temporary_directory/${platform}-links-${binary_index}"
    if write_macho_dependencies "$binary" "$binary_links"; then
      printf 'BINARY: %s\n' "$binary" >>"$links"
      cat "$binary_links" >>"$links"
      if ! validate_dependency_table "$binary_links" "$binary" >>"$unexpected_links"; then
        dependencies_valid=false
      fi
    else
      printf '%s: Mach-O dependency table is unreadable\n' "$binary" >>"$unexpected_links"
      dependency_tables_readable=false
      dependencies_valid=false
    fi
  done <"$macho_files"

  if [ "$dependency_tables_readable" = true ] && [ "$macho_count" -gt 0 ]; then
    pass_check "$platform Mach-O dependency tables are readable for every bundled executable"
  else
    while IFS= read -r detail; do
      [ -n "$detail" ] && printf 'DETAIL: %s linkage: %s\n' "$platform" "$detail" >&2
    done <"$unexpected_links"
    fail_check "$platform has an unreadable bundled Mach-O dependency table"
  fi

  if [ "$dependencies_valid" = true ]; then
    pass_check "$platform bundled Mach-O files link only canonical platform system libraries"
  else
    while IFS= read -r detail; do
      [ -n "$detail" ] && printf 'DETAIL: %s linkage: %s\n' "$platform" "$detail" >&2
    done <"$unexpected_links"
    fail_check "$platform bundled Mach-O files contain an unexpected or noncanonical dependency"
  fi

  if [ "$expected_main_seen" = true ] && [ "$macho_count" -eq 1 ]; then
    pass_check "$platform product contains only its expected main Mach-O executable"
  else
    while IFS= read -r -d '' binary; do
      if [ "$binary" != "$executable" ]; then
        printf 'DETAIL: %s unexpected bundled Mach-O: %s\n' "$platform" "$binary" >&2
      fi
    done <"$macho_files"
    [ "$expected_main_seen" = true ] || printf 'DETAIL: %s expected main executable is not Mach-O: %s\n' "$platform" "$executable" >&2
    fail_check "$platform product contains unexpected nested executable code"
  fi

  if grep -iFq 'forsetti' "$links" || find "$app" -iname '*forsetti*' -print -quit | grep -q .; then
    fail_check "$platform product contains a prohibited Forsetti binary dependency"
  else
    pass_check "$platform product has no Forsetti binary or dynamic linkage"
  fi

  if ! nm -gj "$executable" >"$symbols" 2>/dev/null; then
    fail_check "$platform executable symbols cannot be inspected for package linkage"
    return
  fi

  for module in \
    RuneScribeContracts \
    RuneScribeRuntimeCore \
    RuneScribeUIRuntime \
    RuneScribePlatform \
    RuneScribeCoreModule \
    RuneScribeProgressionModule \
    RuneScribeThemeCoordinatorModule \
    RuneScribeNorseThemeModule \
    RuneScribeUIModule
  do
    if grep -Fq "$module" "$symbols"; then
      pass_check "$platform executable links $module"
    else
      fail_check "$platform executable has no linkage evidence for $module"
    fi
  done

  if grep -Fq "RuneScribeTestSupport" "$symbols"; then
    fail_check "$platform executable unexpectedly links RuneScribeTestSupport"
  else
    pass_check "$platform executable excludes RuneScribeTestSupport"
  fi
}

inspect_linkage "$macos_executable" "macOS" "$macos_app"
inspect_linkage "$ios_executable" "iOS" "$ios_app"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
project_source="$repository_root/project.yml"
generated_project="$repository_root/RuneScrib.xcodeproj/project.pbxproj"
package_path="$repository_root/Packages/RuneScribeArchitecture"
macos_entitlement_source="$repository_root/Config/RuneScrib-macOS.entitlements"
ios_entitlement_source="$repository_root/Config/RuneScrib-iOS.entitlements"

if [ ! -f "$project_source" ] || [ ! -f "$generated_project" ] || [ ! -f "$package_path/Package.swift" ] ||
   [ ! -f "$macos_entitlement_source" ] || [ ! -f "$ios_entitlement_source" ]; then
  fail_check "dependency-graph sources are present"
else
  pass_check "dependency-graph sources are present"

  if swift package --package-path "$package_path" dump-package >"$temporary_directory/package.json" 2>/dev/null; then
    pass_check "Swift package manifest resolves for dependency-graph inspection"
  else
    fail_check "Swift package manifest does not resolve for dependency-graph inspection"
  fi

  graph_inputs_valid=true
  if ! plutil -convert json -o "$temporary_directory/project.pbxproj.json" "$generated_project" >/dev/null 2>&1; then
    printf 'generated project cannot be parsed as an OpenStep property list\n' >"$temporary_directory/graph-input-errors"
    graph_inputs_valid=false
  fi
  if ! plutil -convert json -o "$temporary_directory/macos-source-entitlements.json" "$macos_entitlement_source" >/dev/null 2>&1; then
    printf 'macOS source entitlements cannot be decoded\n' >>"$temporary_directory/graph-input-errors"
    graph_inputs_valid=false
  fi
  if ! plutil -convert json -o "$temporary_directory/ios-source-entitlements.json" "$ios_entitlement_source" >/dev/null 2>&1; then
    printf 'iOS source entitlements cannot be decoded\n' >>"$temporary_directory/graph-input-errors"
    graph_inputs_valid=false
  fi

  if [ -s "$temporary_directory/package.json" ] && [ "$graph_inputs_valid" = true ]; then
    if ruby -rjson -ryaml - "$project_source" "$temporary_directory/project.pbxproj.json" \
        "$temporary_directory/package.json" "$temporary_directory/macos-source-entitlements.json" \
        "$temporary_directory/ios-source-entitlements.json" \
        >"$temporary_directory/graph-errors" <<'RUBY'
project = YAML.load_file(ARGV.fetch(0))
pbxproj = JSON.parse(File.read(ARGV.fetch(1)))
package = JSON.parse(File.read(ARGV.fetch(2)))
macos_source_entitlements = JSON.parse(File.read(ARGV.fetch(3)))
ios_source_entitlements = JSON.parse(File.read(ARGV.fetch(4)))
require "set"
errors = []

shipping_products = [
  "RuneScribeContracts",
  "RuneScribeRuntimeCore",
  "RuneScribeUIRuntime",
  "RuneScribePlatform",
  "RuneScribeCoreModule",
  "RuneScribeProgressionModule",
  "RuneScribeThemeCoordinatorModule",
  "RuneScribeNorseThemeModule",
  "RuneScribeUIModule"
]
app_product_names = [
  "RuneScribeContracts",
  "RuneScribeRuntimeCore",
  "RuneScribeUIRuntime",
  "RuneScribePlatform",
  "RuneScribeCoreModule",
  "RuneScribeProgressionModule",
  "RuneScribeNorseThemeModule",
  "RuneScribeThemeCoordinatorModule",
  "RuneScribeUIModule"
]
presentation_contract_products = ["RuneScribeUIPresentationContracts"]
test_only_products = ["RuneScribeTestSupport"]
all_products = [shipping_products.first] + presentation_contract_products +
  shipping_products.drop(1) + test_only_products
expected_app_dependencies = app_product_names.map do |product|
  { "package" => "RuneScribeArchitecture", "product" => product }
end

expected_packages = {
  "RuneScribeArchitecture" => { "path" => "Packages/RuneScribeArchitecture" }
}
errors << "project.yml package declarations differ" unless project.fetch("packages", {}) == expected_packages

expected_macos_entitlements = {
  "com.apple.security.app-sandbox" => true,
  "com.apple.security.personal-information.addressbook" => true,
  "com.apple.security.files.user-selected.read-write" => true
}
expected_ios_entitlements = {
  "keychain-access-groups" => ["$(AppIdentifierPrefix)com.runescribe.app"]
}
expected_entitlement_sources = {
  "RuneScrib-macOS" => {
    "path" => "Config/RuneScrib-macOS.entitlements",
    "properties" => expected_macos_entitlements
  },
  "RuneScrib-iOS" => {
    "path" => "Config/RuneScrib-iOS.entitlements",
    "properties" => expected_ios_entitlements
  }
}
expected_shipping_source_declarations = [
  { "path" => "RuneScrib/AppHost" },
  { "path" => "RuneScrib/Metal/Shaders.metal" },
  { "path" => "RuneScrib/Resources" }
]

errors << "macOS source entitlement dictionary differs" unless macos_source_entitlements == expected_macos_entitlements
errors << "iOS source entitlement dictionary differs" unless ios_source_entitlements == expected_ios_entitlements

["RuneScrib-macOS", "RuneScrib-iOS"].each do |target_name|
  target = project.fetch("targets", {})[target_name]
  if !target.is_a?(Hash)
    errors << "project.yml target #{target_name} is missing"
    next
  end

  actual_dependencies = target.fetch("dependencies", [])
  unless actual_dependencies == expected_app_dependencies
    errors << "project.yml #{target_name} dependencies differ"
  end
  unless target.fetch("sources", []) == expected_shipping_source_declarations
    errors << "project.yml #{target_name} shipping sources differ from the exact allowlist"
  end
  unless target["entitlements"] == expected_entitlement_sources.fetch(target_name)
    errors << "project.yml #{target_name} entitlement declaration differs"
  end
end

macos_release_settings = project.dig(
  "targets", "RuneScrib-macOS", "settings", "configs", "Release"
)
unless macos_release_settings.is_a?(Hash) &&
    macos_release_settings["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] == "NO"
  errors << "project.yml macOS Release base-entitlement injection is not disabled"
end

package_product_rows = package.fetch("products", [])
package_products = package_product_rows.map { |product| product["name"] }
errors << "Package.swift public products differ" unless package_products == all_products
errors << "Package.swift gained an external dependency" unless package.fetch("dependencies", []).empty?
package_product_rows.each do |product|
  next unless all_products.include?(product["name"])
  unless product["targets"] == [product["name"]]
    errors << "Package.swift product #{product['name']} exposes unexpected targets"
  end
  unless product["type"] == { "library" => ["automatic"] }
    errors << "Package.swift product #{product['name']} library type differs"
  end
end

target_edges = {}
package_targets = package.fetch("targets", [])
package_targets.each do |target|
  dependencies = target.fetch("dependencies", []).map do |dependency|
    by_name = dependency["byName"]
    by_name.is_a?(Array) ? by_name.first : nil
  end.compact
  target_edges[target["name"]] = dependencies
end

regular_target_names = package_targets.select { |target| target["type"] == "regular" }.map { |target| target["name"] }
errors << "Package.swift regular target set differs" unless regular_target_names == all_products

test_target_names = package_targets.select { |target| target["type"] == "test" }.map { |target| target["name"] }
expected_test_target_names = [
  "RuneScribeRuntimeCoreTests",
  "RuneScribePlatformTests",
  "RuneScribeCoreModuleTests",
  "RuneScribeProgressionModuleTests",
  "RuneScribeNorseThemeModuleTests",
  "RuneScribeThemeCoordinatorModuleTests",
  "RuneScribeUIModuleTests",
  "RuneScribeArchitectureTests"
]
errors << "Package.swift test target set differs" unless test_target_names == expected_test_target_names
errors << "Package.swift complete target order differs" unless package_targets.map { |target| target["name"] } == all_products + expected_test_target_names

expected_edges = {
  "RuneScribeContracts" => [],
  "RuneScribeUIPresentationContracts" => ["RuneScribeContracts"],
  "RuneScribeRuntimeCore" => ["RuneScribeContracts", "RuneScribeUIPresentationContracts"],
  "RuneScribeUIRuntime" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIPresentationContracts"],
  "RuneScribePlatform" => ["RuneScribeContracts"],
  "RuneScribeCoreModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
  "RuneScribeProgressionModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
  "RuneScribeThemeCoordinatorModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
  "RuneScribeNorseThemeModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
  "RuneScribeUIModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIPresentationContracts", "RuneScribeUIRuntime"],
  "RuneScribeTestSupport" => ["RuneScribeContracts"]
}

expected_edges.each do |target, edges|
  errors << "Package.swift target edges differ for #{target}" unless target_edges[target] == edges
end


expected_test_edges = {
  "RuneScribeRuntimeCoreTests" => [
    "RuneScribeContracts",
    "RuneScribeRuntimeCore",
    "RuneScribeTestSupport",
    "RuneScribeUIPresentationContracts"
  ],
  "RuneScribePlatformTests" => [
    "RuneScribeContracts",
    "RuneScribePlatform",
    "RuneScribeTestSupport"
  ],
  "RuneScribeCoreModuleTests" => [
    "RuneScribeCoreModule",
    "RuneScribeRuntimeCore"
  ],
  "RuneScribeProgressionModuleTests" => [
    "RuneScribeContracts",
    "RuneScribeProgressionModule",
    "RuneScribeRuntimeCore",
    "RuneScribeTestSupport"
  ],
  "RuneScribeNorseThemeModuleTests" => [
    "RuneScribeContracts",
    "RuneScribeNorseThemeModule",
    "RuneScribeRuntimeCore"
  ],
  "RuneScribeThemeCoordinatorModuleTests" => [
    "RuneScribeContracts",
    "RuneScribeNorseThemeModule",
    "RuneScribeRuntimeCore",
    "RuneScribeTestSupport",
    "RuneScribeThemeCoordinatorModule"
  ],
  "RuneScribeUIModuleTests" => [
    "RuneScribeContracts",
    "RuneScribeNorseThemeModule",
    "RuneScribeRuntimeCore",
    "RuneScribeTestSupport",
    "RuneScribeThemeCoordinatorModule",
    "RuneScribeUIPresentationContracts",
    "RuneScribeUIRuntime",
    "RuneScribeUIModule"
  ],
  "RuneScribeArchitectureTests" => [
    "RuneScribeContracts",
    "RuneScribeRuntimeCore",
    "RuneScribeUIRuntime",
    "RuneScribePlatform",
    "RuneScribeCoreModule",
    "RuneScribeNorseThemeModule",
    "RuneScribeProgressionModule",
    "RuneScribeThemeCoordinatorModule",
    "RuneScribeUIModule",
    "RuneScribeTestSupport"
  ]
}

expected_test_edges.each do |target, edges|
  errors << "Package.swift target edges differ for #{target}" unless target_edges[target] == edges
end

progression_target = package_targets.find { |target| target["name"] == "RuneScribeProgressionModule" }
expected_progression_resources = [
  { "path" => "Resources", "rule" => { "process" => {} } }
]
unless progression_target.is_a?(Hash) && progression_target["resources"] == expected_progression_resources
  errors << "Package.swift Progression resource processing declaration differs"
end

theme_coordinator_target = package_targets.find do |target|
  target["name"] == "RuneScribeThemeCoordinatorModule"
end
unless theme_coordinator_target.is_a?(Hash) &&
    theme_coordinator_target["resources"] == expected_progression_resources
  errors << "Package.swift Theme Coordinator resource processing declaration differs"
end

norse_theme_target = package_targets.find do |target|
  target["name"] == "RuneScribeNorseThemeModule"
end
unless norse_theme_target.is_a?(Hash) &&
    norse_theme_target["resources"] == expected_progression_resources &&
    norse_theme_target["exclude"] == ["Resources/Source"]
  errors << "Package.swift Norse Theme resource processing or source exclusion differs"
end

test_support_package_consumers = target_edges.each_with_object([]) do |(target, dependencies), consumers|
  consumers << target if dependencies.include?("RuneScribeTestSupport")
end.sort
unless test_support_package_consumers == %w[
  RuneScribeArchitectureTests RuneScribePlatformTests
  RuneScribeProgressionModuleTests RuneScribeRuntimeCoreTests
  RuneScribeThemeCoordinatorModuleTests RuneScribeUIModuleTests
].sort
  errors << "Package.swift RuneScribeTestSupport consumers differ"
end

project_test_support_consumers = project.fetch("targets", {}).each_with_object([]) do |(target_name, target), consumers|
  dependencies = target.is_a?(Hash) ? target.fetch("dependencies", []) : []
  uses_test_support = dependencies.any? do |dependency|
    dependency.is_a?(Hash) && dependency["package"] == "RuneScribeArchitecture" &&
      dependency["product"] == "RuneScribeTestSupport"
  end
  consumers << target_name if uses_test_support
end.sort
unless project_test_support_consumers == %w[RuneScribIOSTests RuneScribMacParityTests RuneScribTests].sort
  errors << "project.yml RuneScribeTestSupport consumers differ"
end

objects = pbxproj["objects"]
unless objects.is_a?(Hash)
  errors << "generated project object graph is missing"
  objects = {}
end

project_object = objects[pbxproj["rootObject"]]
unless project_object.is_a?(Hash) && project_object["isa"] == "PBXProject"
  errors << "generated project root object differs"
  project_object = {}
end

package_reference_ids = Array(project_object["packageReferences"])
package_reference_objects = package_reference_ids.map { |identifier| objects[identifier] }
unless package_reference_objects == [
  { "isa" => "XCLocalSwiftPackageReference", "relativePath" => "Packages/RuneScribeArchitecture" }
]
  errors << "generated project package references differ"
end
local_package_objects = objects.values.select do |object|
  object.is_a?(Hash) && object["isa"] == "XCLocalSwiftPackageReference"
end
errors << "generated project local package object set differs" unless local_package_objects == package_reference_objects
if objects.values.any? { |object| object.is_a?(Hash) && object["isa"] == "XCRemoteSwiftPackageReference" }
  errors << "generated project gained a remote package reference"
end

forbidden_build_settings = %w[
  FRAMEWORK_SEARCH_PATHS
  LIBRARY_SEARCH_PATHS
  OTHER_CODE_SIGN_FLAGS
  OTHER_LDFLAGS
  OTHER_SWIFT_FLAGS
]

def configurations_for(objects, owner, label, errors)
  list = objects[owner["buildConfigurationList"]]
  unless list.is_a?(Hash) && list["isa"] == "XCConfigurationList"
    errors << "#{label} configuration list is missing"
    return []
  end

  Array(list["buildConfigurations"]).each_with_object([]) do |identifier, configurations|
    configuration = objects[identifier]
    unless configuration.is_a?(Hash) && configuration["isa"] == "XCBuildConfiguration"
      errors << "#{label} contains an invalid build configuration"
      next
    end
    errors << "#{label} #{configuration['name']} uses an external base configuration" if configuration.key?("baseConfigurationReference")
    configurations << configuration
  end
end

def compiled_source_paths(objects, main_group, target, target_name, errors)
  source_phases = Array(target["buildPhases"]).each_with_object([]) do |identifier, phases|
    phase = objects[identifier]
    phases << phase if phase.is_a?(Hash) && phase["isa"] == "PBXSourcesBuildPhase"
  end
  unless source_phases.length == 1
    errors << "generated project #{target_name} Sources phase is missing or duplicated"
    return []
  end

  parent_groups = Hash.new { |hash, key| hash[key] = [] }
  objects.each do |identifier, object|
    next unless object.is_a?(Hash) && object["isa"] == "PBXGroup"
    Array(object["children"]).each { |child| parent_groups[child] << identifier }
  end

  Array(source_phases.first["files"]).each_with_object([]) do |build_file_id, paths|
    build_file = objects[build_file_id]
    unless build_file.is_a?(Hash) && build_file["isa"] == "PBXBuildFile" && build_file["fileRef"]
      errors << "generated project #{target_name} contains an invalid source build file"
      next
    end
    file_id = build_file["fileRef"]
    file = objects[file_id]
    unless file.is_a?(Hash) && file["isa"] == "PBXFileReference" && file["sourceTree"] == "<group>"
      errors << "generated project #{target_name} contains an invalid source file reference"
      next
    end

    components = [file["path"] || file["name"]].compact
    current = file_id
    visited = Set.new
    while current != main_group
      if visited.include?(current)
        errors << "generated project #{target_name} source group graph contains a cycle"
        break
      end
      visited << current
      parents = parent_groups[current]
      if parents.length != 1
        errors << "generated project #{target_name} source reference has #{parents.length} parent groups"
        break
      end
      current = parents.first
      next if current == main_group
      group = objects[current]
      unless group.is_a?(Hash) && group["isa"] == "PBXGroup" && group["sourceTree"] == "<group>"
        errors << "generated project #{target_name} source parent is invalid"
        break
      end
      component = group["path"] || group["name"]
      components.unshift(component) if component
    end
    paths << components.join("/") if current == main_group
  end
end

configurations_for(objects, project_object, "generated project", errors).each do |configuration|
  settings = configuration.fetch("buildSettings", {})
  forbidden_build_settings.each do |setting|
    errors << "generated project #{configuration['name']} injects #{setting}" if settings.key?(setting)
  end
end

expected_entitlement_paths = {
  "RuneScrib-macOS" => "Config/RuneScrib-macOS.entitlements",
  "RuneScrib-iOS" => "Config/RuneScrib-iOS.entitlements"
}
expected_phase_types = ["PBXSourcesBuildPhase", "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase"]
expected_compiled_sources = %w[
  RuneScrib/AppHost/AppDelegate.swift
  RuneScrib/AppHost/RuneScribApp.swift
  RuneScrib/AppHost/RuneScribeRuntimeComposition.swift
  RuneScrib/Metal/Shaders.metal
]

["RuneScrib-macOS", "RuneScrib-iOS"].each do |target_name|
  matching_targets = objects.values.select do |object|
    object.is_a?(Hash) && object["isa"] == "PBXNativeTarget" && object["name"] == target_name
  end
  if matching_targets.length != 1
    errors << "generated project target #{target_name} is missing or duplicated"
    next
  end

  target = matching_targets.first
  errors << "generated project #{target_name} target dependencies differ" unless Array(target["dependencies"]).empty?
  errors << "generated project #{target_name} build rules differ" unless Array(target["buildRules"]).empty?
  compiled_sources = compiled_source_paths(
    objects,
    project_object["mainGroup"],
    target,
    target_name,
    errors
  )
  unless compiled_sources == expected_compiled_sources
    errors << "generated project #{target_name} compiled sources differ from the exact allowlist"
  end

  product_ids = Array(target["packageProductDependencies"])
  product_objects = product_ids.map { |identifier| objects[identifier] }
  product_names = product_objects.map do |object|
    object["productName"] if object.is_a?(Hash) && object["isa"] == "XCSwiftPackageProductDependency"
  end
  errors << "generated project #{target_name} package products differ" unless product_names == app_product_names
  errors << "generated project #{target_name} package product identifiers are duplicated" unless product_ids.uniq == product_ids
  product_objects.each_with_index do |object, index|
    expected_object = {
      "isa" => "XCSwiftPackageProductDependency",
      "productName" => app_product_names[index]
    }
    errors << "generated project #{target_name} package product object differs" unless object == expected_object
  end

  phase_objects = Array(target["buildPhases"]).map { |identifier| objects[identifier] }
  phase_types = phase_objects.map { |phase| phase["isa"] if phase.is_a?(Hash) }
  errors << "generated project #{target_name} build phases differ" unless phase_types == expected_phase_types

  framework_phases = phase_objects.select { |phase| phase.is_a?(Hash) && phase["isa"] == "PBXFrameworksBuildPhase" }
  if framework_phases.length != 1
    errors << "generated project #{target_name} Frameworks phase is missing or duplicated"
  else
    build_file_ids = Array(framework_phases.first["files"])
    build_files = build_file_ids.map { |identifier| objects[identifier] }
    framework_product_ids = build_files.each_with_index.map do |build_file, index|
      expected_build_file = {
        "isa" => "PBXBuildFile",
        "productRef" => product_ids[index]
      }
      build_file == expected_build_file ? build_file["productRef"] : nil
    end
    errors << "generated project #{target_name} Frameworks phase differs" unless framework_product_ids == product_ids
  end

  configurations = configurations_for(objects, target, "generated project #{target_name}", errors)
  configuration_names = configurations.map { |configuration| configuration["name"] }
  errors << "generated project #{target_name} configuration set differs" unless configuration_names == ["Debug", "Release"]
  configurations.each do |configuration|
    settings = configuration.fetch("buildSettings", {})
    unless settings["CODE_SIGN_ENTITLEMENTS"] == expected_entitlement_paths.fetch(target_name)
      errors << "generated project #{target_name} #{configuration['name']} entitlement source differs"
    end
    if target_name == "RuneScrib-macOS" && configuration["name"] == "Release" &&
        settings["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] != "NO"
      errors << "generated project macOS Release base-entitlement injection is not disabled"
    end
    forbidden_build_settings.each do |setting|
      errors << "generated project #{target_name} #{configuration['name']} injects #{setting}" if settings.key?(setting)
    end
  end
end


generated_test_support_consumers = objects.values.each_with_object([]) do |object, consumers|
  next unless object.is_a?(Hash) && object["isa"] == "PBXNativeTarget"
  product_names = Array(object["packageProductDependencies"]).each_with_object([]) do |identifier, names|
    product = objects[identifier]
    names << product["productName"] if product.is_a?(Hash) && product["isa"] == "XCSwiftPackageProductDependency"
  end
  consumers << object["name"] if product_names.include?("RuneScribeTestSupport")
end.sort
unless generated_test_support_consumers == %w[RuneScribIOSTests RuneScribMacParityTests RuneScribTests].sort
  errors << "generated project RuneScribeTestSupport consumers differ"
end

puts errors
exit(errors.empty? ? 0 : 1)
RUBY
    then
      pass_check "source entitlements, project.yml, structural app targets, and Package.swift preserve the exact shipping graph"
    else
      validation_detail=false
      while IFS= read -r error; do
        if [ -n "$error" ]; then
          validation_detail=true
          printf 'DETAIL: dependency graph: %s\n' "$error" >&2
        fi
      done < "$temporary_directory/graph-errors"
      [ "$validation_detail" = true ] || printf 'DETAIL: dependency-graph validator did not return diagnostics.\n' >&2
      fail_check "project.yml, generated app targets, or Package.swift dependency graph differs"
    fi
  elif [ -s "$temporary_directory/package.json" ]; then
    while IFS= read -r error; do
      [ -n "$error" ] && printf 'DETAIL: dependency graph: %s\n' "$error" >&2
    done <"$temporary_directory/graph-input-errors"
    fail_check "project.yml, generated app targets, or Package.swift dependency graph differs"
  fi
fi

printf 'Shipping-product inspection: %d checks, %d failures.\n' "$check_count" "$failure_count"

if [ "$failure_count" -ne 0 ]; then
  exit 1
fi

echo "T-028 shipping-product/configuration inspection passed."
