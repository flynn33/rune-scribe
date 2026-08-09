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
check_file_type "$macos_resources/NotoSansRunic-Regular.ttf" "TrueType Font" "macOS Runic font is present and valid"
check_file_type "$macos_resources/raven-forge-spp-splash.mp4" "ISO Media" "macOS splash video is present and valid"
check_file_type "$macos_resources/default.metallib" "MetalLib" "macOS Metal shader library is present and valid"

check_nonempty_file "$ios_resources/Assets.car" "iOS compiled asset catalog is present"
ios_icon=$(find "$ios_resources" -maxdepth 1 -type f -name 'AppIcon*.png' -size +0c -print -quit)
if [ -n "$ios_icon" ] && file -b "$ios_icon" 2>/dev/null | grep -Fq 'PNG image data'; then
  pass_check "iOS app icon is present and valid"
else
  fail_check "iOS app icon is missing or invalid"
fi
check_file_type "$ios_resources/NotoSansRunic-Regular.ttf" "TrueType Font" "iOS Runic font is present and valid"
check_file_type "$ios_resources/raven-forge-spp-splash.mp4" "ISO Media" "iOS splash video is present and valid"
check_file_type "$ios_resources/default.metallib" "MetalLib" "iOS Metal shader library is present and valid"

find_module_manifest() {
  local root=$1
  local bundle_name=$2
  find "$root" -type f -path "*/${bundle_name}.bundle/*" -name module-manifest.json -print -quit
}

macos_core_manifest=$(find_module_manifest "$macos_resources" "RuneScribeArchitecture_RuneScribeCoreModule")
macos_ui_manifest=$(find_module_manifest "$macos_resources" "RuneScribeArchitecture_RuneScribeUIModule")
ios_core_manifest=$(find_module_manifest "$ios_resources" "RuneScribeArchitecture_RuneScribeCoreModule")
ios_ui_manifest=$(find_module_manifest "$ios_resources" "RuneScribeArchitecture_RuneScribeUIModule")

check_nonempty_file "$macos_core_manifest" "macOS Core module manifest resource is present"
check_nonempty_file "$macos_ui_manifest" "macOS UI module manifest resource is present"
check_nonempty_file "$ios_core_manifest" "iOS Core module manifest resource is present"
check_nonempty_file "$ios_ui_manifest" "iOS UI module manifest resource is present"

if [ -s "$macos_core_manifest" ] && [ -s "$macos_ui_manifest" ] && \
   [ -s "$ios_core_manifest" ] && [ -s "$ios_ui_manifest" ]; then
  if ruby -rjson - "$macos_core_manifest" "$macos_ui_manifest" "$ios_core_manifest" "$ios_ui_manifest" \
      "$temporary_directory/macos-info.json" "$temporary_directory/ios-info.json" \
      >"$temporary_directory/manifest-errors" <<'RUBY'
paths = ARGV.take(4)
macos_info = JSON.parse(File.read(ARGV.fetch(4)))
ios_info = JSON.parse(File.read(ARGV.fetch(5)))
errors = []

expectations = [
  ["com.runescribe.module.core", "service", "RuneScribeCoreModule"],
  ["com.runescribe.module.ui", "ui", "RuneScribeUIModule"]
]

paths.each_with_index do |path, index|
  manifest = JSON.parse(File.read(path))
  expected = expectations[index % 2]
  platform = index < 2 ? "macOS" : "iOS"
  errors << "#{platform} #{expected[1]} manifest moduleID differs" unless manifest["moduleID"] == expected[0]
  errors << "#{platform} #{expected[1]} manifest moduleType differs" unless manifest["moduleType"] == expected[1]
  errors << "#{platform} #{expected[1]} manifest entryPoint differs" unless manifest["entryPoint"] == expected[2]
  errors << "#{platform} #{expected[1]} manifest policy profile differs" unless manifest["policyProfile"] == "forsetti-pattern-b-standalone"
  errors << "#{platform} #{expected[1]} production diagnostics are enabled" unless manifest["diagnosticsVisibleInProduction"] == false
  errors << "#{platform} #{expected[1]} supported platforms differ" unless manifest["supportedPlatforms"] == ["iOS", "macOS"]
  expected_version = platform == "macOS" ? macos_info["CFBundleShortVersionString"] : ios_info["CFBundleShortVersionString"]
  errors << "#{platform} #{expected[1]} module version differs from the app" unless manifest["moduleVersion"] == expected_version
end

errors << "Core module manifest differs between platforms" unless File.binread(paths[0]) == File.binread(paths[2])
errors << "UI module manifest differs between platforms" unless File.binread(paths[1]) == File.binread(paths[3])

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
  "RuneScribeUIModule"
]
test_only_products = ["RuneScribeTestSupport"]
all_products = shipping_products + test_only_products
expected_app_dependencies = shipping_products.map do |product|
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

expected_edges = {
  "RuneScribeContracts" => [],
  "RuneScribeRuntimeCore" => ["RuneScribeContracts"],
  "RuneScribeUIRuntime" => ["RuneScribeContracts"],
  "RuneScribePlatform" => ["RuneScribeContracts"],
  "RuneScribeCoreModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
  "RuneScribeUIModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIRuntime"],
  "RuneScribeTestSupport" => ["RuneScribeContracts"]
}

expected_edges.each do |target, edges|
  errors << "Package.swift target edges differ for #{target}" unless target_edges[target] == edges
end

test_support_package_consumers = target_edges.each_with_object([]) do |(target, dependencies), consumers|
  consumers << target if dependencies.include?("RuneScribeTestSupport")
end.sort
unless test_support_package_consumers == %w[RuneScribeArchitectureTests RuneScribePlatformTests].sort
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
  errors << "generated project #{target_name} package products differ" unless product_names == shipping_products
  errors << "generated project #{target_name} package product identifiers are duplicated" unless product_ids.uniq == product_ids
  product_objects.each_with_index do |object, index|
    expected_object = {
      "isa" => "XCSwiftPackageProductDependency",
      "productName" => shipping_products[index]
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
