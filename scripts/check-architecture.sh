#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
ratchet_file="$script_dir/architecture-ratchet.json"
alignment_file="${RUNESCRIBE_ROADMAP_ALIGNMENT_FILE:-$repository_root/docs/verification/roadmap-alignment.json}"

ruby - "$repository_root" "$ratchet_file" "$alignment_file" <<'RUBY'
require "json"
require "digest"
require "open3"
require "pathname"
require "set"
require "yaml"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

root = Pathname(ARGV.fetch(0)).realpath
ratchet_path = Pathname(ARGV.fetch(1)).realpath
alignment_path = Pathname(ARGV.fetch(2)).realpath
errors = []

def relative(path, root)
  Pathname(path).relative_path_from(root).to_s
end

def production_swift_files(root)
  Dir.glob(root.join("**/*.swift").to_s).reject do |path|
    relative = Pathname(path).relative_path_from(root).to_s
    relative.start_with?(
      ".git/", ".build/", "DerivedData/", "RuneScribMacParityHost/",
      "scripts/", "Packages/RuneScribeArchitecture/Sources/RuneScribeTestSupport/"
    ) ||
      relative.include?("/Resources/Source/") ||
      relative.split("/").any? { |component| component == "Tests" || component.end_with?("Tests") }
  end
end

def without_comments(text)
  text.gsub(%r{/\*.*?\*/}m, "").lines.map { |line| line.sub(%r{//.*$}, "") }.join
end

def without_comments_preserving_lines(text)
  text
    .gsub(%r{/\*.*?\*/}m) { |comment| comment.gsub(/[^\n]/, " ") }
    .lines
    .map { |line| line.sub(%r{//.*$}, "") }
    .join
end

MODULE_IMPORT_POLICY = {
  "RuneScribeContracts" => %w[Foundation],
  "RuneScribeUIPresentationContracts" => %w[Foundation SwiftUI RuneScribeContracts],
  "RuneScribeRuntimeCore" => %w[Foundation RuneScribeCloudSyncModule RuneScribeContracts RuneScribeGameCenterModule RuneScribeProgressionSyncDomain RuneScribeUIPresentationContracts],
  "RuneScribeUIRuntime" => %w[Foundation SwiftUI RuneScribeContracts RuneScribeRuntimeCore RuneScribeUIPresentationContracts AVFoundation AppKit Contacts ContactsUI CoreImage CoreTransferable LinkPresentation MessageUI Metal MetalKit Observation UIKit UniformTypeIdentifiers],
  "RuneScribePlatform" => %w[Foundation Darwin CoreData CryptoKit RuneScribeContracts Security Contacts CoreText AudioToolbox AppKit UIKit CloudKit GameKit],
  "RuneScribeCoreModule" => %w[Foundation CryptoKit CommonCrypto ImageIO RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeUIModule" => %w[Foundation SwiftUI Combine Accessibility CryptoKit AppKit RuneScribeContracts RuneScribeRuntimeCore RuneScribeUIPresentationContracts RuneScribeUIRuntime UIKit UniformTypeIdentifiers],
  "RuneScribeProgressionModule" => %w[Foundation RuneScribeContracts RuneScribeProgressionSyncDomain RuneScribeRuntimeCore],
  "RuneScribeThemeCoordinatorModule" => %w[Foundation RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeNorseThemeModule" => %w[Foundation CryptoKit RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeThemeMoonleafModule" => %w[Foundation CryptoKit RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeThemeSunspireModule" => %w[Foundation CryptoKit RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeThemeWildwoodModule" => %w[Foundation CryptoKit RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeThemeGloamthornModule" => %w[Foundation CryptoKit RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeProgressionSyncDomain" => %w[Foundation CryptoKit RuneScribeContracts],
  "RuneScribeCloudSyncModule" => %w[Foundation RuneScribeProgressionSyncDomain],
  "RuneScribeGameCenterModule" => %w[Foundation CryptoKit RuneScribeContracts],
  "RuneScribeTestSupport" => %w[Foundation CryptoKit RuneScribeContracts],
}.freeze

PROGRESSION_FORBIDDEN_REFERENCE_PATTERNS = [
  [/\b(?:[A-Za-z_][A-Za-z0-9_]*)?ModuleState(?:Store|Gateway|Adapter)\b/, "raw module-state store or adapter"],
  [/\bCoreDataStack\b/, "Core Data stack"],
  [/\bNSManagedObject[A-Za-z0-9_]*\b/, "NSManagedObject type"],
  [/\bNSPersistent(?:Container|Store|StoreCoordinator|StoreDescription)[A-Za-z0-9_]*\b/, "persistent-store handle"],
  [/\b(?:NSFetchRequest|NSEntityDescription|NSBatchInsertRequest|NSBatchDeleteRequest)\b/, "Core Data request or entity type"],
  [/\b(?:UserDefaults|CFPreferences)\b|@(?:AppStorage|SceneStorage)\b/, "preferences storage"],
  [/\b(?:storeURL|persistentStoreURL|moduleStateStoreURL|sqliteURL|databaseURL)\b/, "physical store URL"],
  [/\bFileHandle\b/, "file handle"],
  [/\bFileManager\b|\b(?:Data|String)\s*\(\s*contentsOf\s*:/, "direct file API"],
  [/\bURLSession\b|\bURLRequest\b|\bNW(?:Connection|ConnectionGroup|Listener|PathMonitor)\b/, "direct network API"],
  [/\bSecItem(?:CopyMatching|Add|Update|Delete)\b|\bkSec[A-Z][A-Za-z0-9_]*\b|\bKeychain[A-Za-z0-9_]*\b/, "Keychain facility"],
  [/\b(?:AVAudio[A-Za-z0-9_]*|AudioServices[A-Za-z0-9_]*|CHHaptic[A-Za-z0-9_]*|UIImpactFeedbackGenerator|UINotificationFeedbackGenerator|NSHapticFeedbackManager)\b/, "audio or haptic facility"],
].freeze

FEATURE_PREFERENCES_FORBIDDEN_PRODUCTS = Set.new(%w[
  RuneScribeCoreModule RuneScribeUIModule RuneScribeUIRuntime
  RuneScribeProgressionModule RuneScribeThemeCoordinatorModule
  RuneScribeNorseThemeModule RuneScribeThemeMoonleafModule
  RuneScribeThemeSunspireModule RuneScribeThemeWildwoodModule
  RuneScribeThemeGloamthornModule RuneScribeCloudSyncModule
  RuneScribeGameCenterModule
]).freeze

FEATURE_PREFERENCES_PATTERN =
  /\b(?:UserDefaults|CFPreferences)\b|@(?:AppStorage|SceneStorage)\b/

DIRECT_PEER_IMPLEMENTATION_PATTERNS = {
  "RuneScribeCoreModule" => [
    [/\bRuneScribeProgressionServiceActor\b/, "Progression service implementation"],
    [/\bRuneScribeProgressionService\b/, "Progression service protocol"],
    [/\bRuneScribeUIModule\b/, "UI module implementation"],
  ],
  "RuneScribeProgressionModule" => [
    [/\bRuneScribeCoreApplicationService\b/, "Core service implementation"],
    [/\bRuneScribe(?:OperationAware)?ApplicationService\b/, "Core application service protocol"],
    [/\bRuneScribeUIModule\b/, "UI module implementation"],
  ],
  "RuneScribeUIModule" => [
    [/\bRuneScribeCoreApplicationService\b/, "Core service implementation"],
    [/\bRuneScribeProgressionServiceActor\b/, "Progression service implementation"],
    [/\bRuneScribeProgressionService\b/, "Progression service protocol"],
    [/\bRuneScribe(?:OperationAware)?ApplicationService\b/, "Core application service protocol"],
  ],
}.freeze

UI_PROGRESSION_TRUTH_PATTERNS = [
  [/\bProgression(?:Reducer|RuleEvaluator|RuleOperator|CatalogDependencyAnalyzer)\b/, "Progression rule engine"],
  [/\b(?:AchievementCompletionRecord|MilestoneCompletionRecord|StatisticCounterRecord)\b/, "Progression domain record"],
  [/\b(?:distinctCountAtLeast|bucketCountAtLeast|allListedContentUsed|completedAchievementCountAtLeast)\b/, "Progression rule calculation"],
  [/\bProgressionEventFact\s*\(/, "Progression event creation"],
].freeze

UI_RESOURCE_DECODE_PATTERNS = [
  [/\bCGImageSource[A-Za-z0-9_]*\b/, "ImageIO image-source decoder"],
  [/\bCGDataProvider[A-Za-z0-9_]*\b/, "Core Graphics encoded-data provider"],
  [
    /\bCGPDF(?:Document|Page)[A-Za-z0-9_]*\b|\bdrawPDFPage\s*\(/,
    "Core Graphics PDF decoder",
  ],
  [
    /\b(?:NSImage|UIImage|NSBitmapImageRep|CIImage)(?:\.init)?\s*\(\s*(?:data|contentsOf[A-Za-z]*|byReferencing|coder)\s*:/m,
    "platform image-data decoder",
  ],
  [
    /\bCGImage(?:\.init)?\s*\(\s*(?:jpeg|png)DataProviderSource\s*:/m,
    "CGImage encoded-provider decoder",
  ],
  [/\bNSBitmapImageRep\.(?:imageRep|imageReps)\s*\(/, "AppKit image-representation decoder"],
  [/\bPDFDocument(?:\.init)?\s*\(\s*(?:data|url)\s*:/m, "PDFKit document decoder"],
].freeze

UI_SAFE_PREVIEW_DECODER_LINES = Set.new([
  "guard let image = NSImage(data: safePreviewData) else { return nil }",
  "guard let image = UIImage(data: safePreviewData) else { return nil }",
]).freeze

THEME_RULE_CATALOG_PATTERNS = [
  [/\bachievement\.[a-z0-9-]+\b/, "Achievement stable ID"],
  [/\brule\.codex\.[a-z0-9.-]+\b/, "Progression rule stable ID"],
  [/\bgrant-group\.[a-z0-9.-]+\b/, "Progression grant-group stable ID"],
  [/\bProgression(?:RuleOperator|AchievementDefinition|MilestoneDefinition)\b/, "Progression rule type"],
  [/\b(?:ProgressionEventFact|DomainEventEnvelope)\b/, "Progression event type"],
].freeze

THEME_PROGRESSION_COUPLING_PATTERNS = [
  [/\bRuntimeProgressionEndpointCatalog\b/, "runtime Progression endpoint catalog"],
  [/\bRuneScribeRoles\.progression\b/, "Progression runtime role"],
  [/\bprogression\.(?:diagnostics|entitlements|event|migration|recovery|reveal|state|title)\b/, "Progression endpoint identifier"],
].freeze

def swift_imports(text)
  pattern = /^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n)]*\))?[ \t\r\n]+)*import[ \t]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)/
  text.to_enum(:scan, pattern).map do
    match = Regexp.last_match
    line = text.byteslice(0, match.begin(0)).count("\n") + 1
    [match[1], line]
  end
end

def module_source_errors(
  product,
  path,
  text,
  allowed_imports,
  runtime_integrity_source: nil,
  ui_image_decode_source: nil,
  runtime_pdf_validation_source: nil
)
  code = without_comments_preserving_lines(text)
  swift_imports(code).each_with_object([]) do |(imported, line), findings|
    isolated_runtime_integrity_import = product == "RuneScribeRuntimeCore" &&
      imported == "CryptoKit" && path == runtime_integrity_source
    isolated_ui_image_decode_import = product == "RuneScribeUIRuntime" &&
      imported == "ImageIO" && path == ui_image_decode_source
    isolated_runtime_pdf_import = product == "RuneScribeRuntimeCore" &&
      imported == "CoreGraphics" && path == runtime_pdf_validation_source
    next if allowed_imports.include?(imported) ||
      isolated_runtime_integrity_import || isolated_ui_image_decode_import ||
      isolated_runtime_pdf_import
    findings << "#{path}:#{line}: #{product} may not import #{imported}"
  end
end

def progression_source_errors(path, text)
  code = without_comments_preserving_lines(text)
  code.lines.each_with_index.each_with_object([]) do |(line, index), findings|
    PROGRESSION_FORBIDDEN_REFERENCE_PATTERNS.each do |pattern, label|
      next unless line.match?(pattern)
      findings << "#{path}:#{index + 1}: RuneScribeProgressionModule may not reference #{label}"
    end
  end
end

def feature_preferences_source_errors(product, path, text)
  return [] unless FEATURE_PREFERENCES_FORBIDDEN_PRODUCTS.include?(product)
  code = without_comments_preserving_lines(text)
  code.lines.each_with_index.each_with_object([]) do |(line, index), findings|
    next unless line.match?(FEATURE_PREFERENCES_PATTERN)
    findings << "#{path}:#{index + 1}: #{product} may not own preferences storage"
  end
end

def module_boundary_source_errors(product, path, text)
  code = without_comments_preserving_lines(text)
  code.lines.each_with_index.each_with_object([]) do |(line, index), findings|
    Array(DIRECT_PEER_IMPLEMENTATION_PATTERNS[product]).each do |pattern, label|
      next unless line.match?(pattern)
      findings << "#{path}:#{index + 1}: #{product} may not retain direct #{label} handles"
    end
    if product != "RuneScribeRuntimeCore" && line.match?(/\bDomainEventEnvelope\s*\(/)
      findings << "#{path}:#{index + 1}: #{product} may not construct free-form Progression event envelopes"
    end
    next unless product == "RuneScribeUIModule"
    UI_PROGRESSION_TRUTH_PATTERNS.each do |pattern, label|
      next unless line.match?(pattern)
      findings << "#{path}:#{index + 1}: UI may not own #{label}"
    end
  end
end

def ui_resource_decode_errors(path, text, safe_preview_decode_source: nil)
  code = without_comments_preserving_lines(text)
  UI_RESOURCE_DECODE_PATTERNS.each_with_object([]) do |(pattern, label), findings|
    code.to_enum(:scan, pattern).each do
      match = Regexp.last_match
      line = code.byteslice(0, match.begin(0)).count("\n") + 1
      safe_preview_call = label == "platform image-data decoder" &&
        path == safe_preview_decode_source &&
        UI_SAFE_PREVIEW_DECODER_LINES.include?(code.lines.fetch(line - 1).strip)
      next if safe_preview_call
      findings << "#{path}:#{line}: UI-RUNTIME-IMAGE-DECODE RuneScribeUIModule may not decode provider resources with #{label}"
    end
  end
end

def theme_progression_coupling_errors(path, text)
  code = without_comments_preserving_lines(text)
  findings = swift_imports(code).each_with_object([]) do |(imported, line), imports|
    if imported.match?(/Progression/)
      imports << "#{path}:#{line}: Theme source may not import #{imported}"
    end
  end
  code.lines.each_with_index.each_with_object(findings) do |(line, index), references|
    THEME_PROGRESSION_COUPLING_PATTERNS.each do |pattern, label|
      next unless line.match?(pattern)
      references << "#{path}:#{index + 1}: Theme source may not reference #{label}"
    end
    binding_data = path.end_with?("/Resources/Production/Metadata/Norse-Progression-Bindings-v1.0.json") ||
      path.end_with?("/Resources/Production/Localization/norse-content.en.json")
    unless binding_data
      THEME_RULE_CATALOG_PATTERNS.each do |pattern, label|
        next unless line.match?(pattern)
        references << "#{path}:#{index + 1}: Theme source may not own #{label}"
      end
    end
  end
end

def progression_catalog_stable_id_errors(path)
  catalog = JSON.parse(File.read(path))
  identifiers = []
  {
    "Achievement" => ["achievements", "achievementID"],
    "rule" => ["milestones", "ruleID"],
    "content" => ["content", "contentID"],
    "grant group" => ["grantGroups", "grantGroupID"],
    "statistic" => ["statistics", "statisticID"],
  }.each do |label, (collection, key)|
    Array(catalog[collection]).each_with_index do |record, index|
      identifier = record.is_a?(Hash) ? record[key] : nil
      unless identifier.is_a?(String) && !identifier.empty?
        return ["#{path}: #{label} record #{index} has an invalid stable ID"]
      end
      identifiers << identifier
    end
  end
  nodes = catalog.dig("journeyGraph", "nodes")
  Array(nodes).each_with_index do |record, index|
    identifier = record.is_a?(Hash) ? record["nodeID"] : nil
    unless identifier.is_a?(String) && !identifier.empty?
      return ["#{path}: journey node #{index} has an invalid stable ID"]
    end
    identifiers << identifier
  end
  counts = Hash.new(0)
  identifiers.each { |identifier| counts[identifier] += 1 }
  duplicates = counts.select { |_identifier, count| count > 1 }.keys.sort
  duplicates.map { |identifier| "#{path}: duplicate Progression stable ID #{identifier}" }
rescue JSON::ParserError => error
  ["#{path}: invalid Progression catalog JSON: #{error.message}"]
end

catalog_fixture_value = ENV["RUNESCRIBE_ARCHITECTURE_CATALOG_FIXTURE"]
if catalog_fixture_value
  catalog_fixture = Pathname(catalog_fixture_value)
  unless catalog_fixture.file?
    warn "architecture catalog fixture is not a file: #{catalog_fixture}"
    exit 64
  end
  fixture_errors = progression_catalog_stable_id_errors(catalog_fixture)
  if fixture_errors.empty?
    puts "PASS architecture Progression catalog fixture"
    exit 0
  end
  fixture_errors.each { |error| warn "ERROR #{error}" }
  exit 1
end

fixture_root_value = ENV["RUNESCRIBE_ARCHITECTURE_MODULE_FIXTURE_ROOT"]
fixture_product = ENV["RUNESCRIBE_ARCHITECTURE_MODULE_FIXTURE_PRODUCT"]
fixture_safe_preview_value = ENV["RUNESCRIBE_ARCHITECTURE_UI_SAFE_PREVIEW_SOURCE"]
if fixture_root_value || fixture_product
  unless fixture_root_value && fixture_product
    warn "architecture fixture mode requires both fixture root and product"
    exit 64
  end
  allowed_imports = MODULE_IMPORT_POLICY[fixture_product]
  unless allowed_imports || fixture_product.match?(/Theme/)
    warn "architecture fixture mode does not recognize product #{fixture_product}"
    exit 64
  end
  fixture_root = Pathname(fixture_root_value)
  unless fixture_root.directory?
    warn "architecture fixture root is not a directory: #{fixture_root}"
    exit 64
  end
  fixture_safe_preview_source = fixture_safe_preview_value && Pathname(
    fixture_safe_preview_value
  ).to_s
  fixture_errors = []
  Dir.glob(fixture_root.join("**/*.swift").to_s).sort.each do |path|
    source = File.read(path)
    fixture_errors.concat(
      module_source_errors(fixture_product, path, source, allowed_imports)
    ) if allowed_imports
    fixture_errors.concat(module_boundary_source_errors(fixture_product, path, source)) if allowed_imports
    fixture_errors.concat(
      ui_resource_decode_errors(
        path,
        source,
        safe_preview_decode_source: fixture_safe_preview_source
      )
    ) if fixture_product == "RuneScribeUIModule"
    fixture_errors.concat(progression_source_errors(path, source)) if fixture_product == "RuneScribeProgressionModule"
    fixture_errors.concat(feature_preferences_source_errors(fixture_product, path, source))
    fixture_errors.concat(theme_progression_coupling_errors(path, source)) if fixture_product.match?(/Theme/)
  end
  if fixture_errors.empty?
    puts "PASS architecture module fixture #{fixture_product}"
    exit 0
  end
  fixture_errors.each { |error| warn "ERROR #{error}" }
  exit 1
end

def dependency_name(value)
  case value
  when String
    value
  when Array
    value.each do |item|
      name = dependency_name(item)
      return name if name
    end
    nil
  when Hash
    %w[target byName product].each do |key|
      next unless value.key?(key)
      name = dependency_name(value[key])
      return name if name
    end
    value.each_value do |item|
      name = dependency_name(item)
      return name if name
    end
    nil
  end
end

def compiled_source_paths(pbxproj, target_name)
  objects = pbxproj["objects"]
  return [[], ["generated project object graph is missing"]] unless objects.is_a?(Hash)

  targets = objects.values.select do |object|
    object.is_a?(Hash) && object["isa"] == "PBXNativeTarget" && object["name"] == target_name
  end
  return [[], ["generated project target #{target_name} is missing or duplicated"]] unless targets.length == 1

  source_phases = Array(targets.first["buildPhases"]).each_with_object([]) do |identifier, phases|
    phase = objects[identifier]
    phases << phase if phase.is_a?(Hash) && phase["isa"] == "PBXSourcesBuildPhase"
  end
  return [[], ["generated project #{target_name} Sources phase is missing or duplicated"]] unless source_phases.length == 1

  parent_groups = Hash.new { |hash, key| hash[key] = [] }
  objects.each do |identifier, object|
    next unless object.is_a?(Hash) && object["isa"] == "PBXGroup"
    Array(object["children"]).each { |child| parent_groups[child] << identifier }
  end
  project = objects[pbxproj["rootObject"]]
  main_group = project["mainGroup"] if project.is_a?(Hash) && project["isa"] == "PBXProject"
  return [[], ["generated project main group is missing"]] unless main_group

  errors = []
  paths = Array(source_phases.first["files"]).each_with_object([]) do |build_file_id, source_paths|
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
    source_paths << components.join("/") if current == main_group
  end
  [paths, errors]
end

unless ratchet_path.file?
  warn "architecture guard: missing #{ratchet_path}"
  exit 1
end

ratchet = JSON.parse(ratchet_path.read)
errors << "ratchet schemaVersion must be 1.1" unless ratchet["schemaVersion"] == "1.1"

alignment = JSON.parse(alignment_path.read)
forsetti_policy = alignment.fetch("forsettiPolicy")
expected_policy = {
  "status" => "active",
  "implementationOwnership" => "app-owned",
  "externalDependencyAllowed" => false,
  "perCallRuntimeMediationRequired" => true,
  "runtimeOwnsOperationalIO" => true,
  "runtimeOwnsPersistentSettings" => true,
  "uiModuleOwnsViews" => true
}
expected_policy.each do |field, expected|
  unless forsetti_policy[field] == expected
    errors << "FG-001: roadmap forsettiPolicy.#{field} must be #{expected.inspect}"
  end
end

policy_record = forsetti_policy.fetch("controllingPolicy", {})
ratchet_policy_record = ratchet.fetch("controllingPolicy", {})
policy_relative = policy_record["path"].to_s
policy_path = root.join(policy_relative)
unless policy_relative == "docs/architecture/FORSETTI_CONTROLLING_POLICY.md" && policy_path.file?
  errors << "FG-020: controlling policy path is missing or not canonical"
else
  actual_policy_hash = Digest::SHA256.file(policy_path).hexdigest
  errors << "FG-020: roadmap controlling policy hash drifted" unless policy_record["sha256"] == actual_policy_hash
  unless ratchet_policy_record == { "path" => policy_relative, "sha256" => actual_policy_hash }
    errors << "FG-020: architecture ratchet controlling policy record drifted"
  end
end

report_only_guard = ratchet.fetch("reportOnlyGuard", {})
unless report_only_guard == {
  "catalogPath" => "scripts/forsetti-compliance-rules.json",
  "checkerPath" => "scripts/check-forsetti-compliance.sh",
  "ruleCount" => 20,
  "mode" => "report-only"
}
  errors << "FG-020: report-only guard metadata is missing or malformed"
end

guard_catalog_path = root.join(report_only_guard["catalogPath"].to_s)
guard_checker_path = root.join(report_only_guard["checkerPath"].to_s)
unless guard_catalog_path.file?
  errors << "FG-020: report-only rule catalog is missing"
end
unless guard_checker_path.file? && guard_checker_path.executable?
  errors << "FG-020: report-only checker is missing or not executable"
end
if guard_catalog_path.file?
  begin
    guard_catalog = JSON.parse(guard_catalog_path.read)
    guard_ids = Array(guard_catalog["rules"]).map { |rule| rule["id"] }
    expected_guard_ids = (1..20).map { |number| format("FG-%03d", number) }
    unless guard_catalog["mode"] == "report-only" && guard_ids == expected_guard_ids
      errors << "FG-020: report-only rule catalog mode, count, or stable ordering drifted"
    end
  rescue JSON::ParserError => error
    errors << "FG-020: report-only rule catalog is invalid JSON: #{error.message}"
  end
end

required_products = Array(ratchet["requiredProducts"])
test_only_products = Array(ratchet["testOnlyProducts"])
all_products = required_products + test_only_products
errors << "ratchet product names must be unique" unless all_products.uniq == all_products
presentation_contract_products = ["RuneScribeUIPresentationContracts"]
architecture_package_products = required_products.dup
runtime_core_product_index = architecture_package_products.index("RuneScribeRuntimeCore")
if runtime_core_product_index
  architecture_package_products.insert(runtime_core_product_index, *presentation_contract_products)
else
  errors << "ratchet requiredProducts must include RuneScribeRuntimeCore"
end
architecture_package_products.concat(test_only_products)
unless architecture_package_products.uniq == architecture_package_products
  errors << "architecture package product names must be unique"
end
internal_architecture_targets = ["RuneScribeProgressionSyncDomain"]
architecture_package_targets = architecture_package_products.dup
progression_target_index = architecture_package_targets.index(
  "RuneScribeProgressionModule"
)
if progression_target_index
  architecture_package_targets.insert(
    progression_target_index + 1,
    *internal_architecture_targets
  )
else
  errors << "architecture package targets must include RuneScribeProgressionModule"
end
required_module_ids = ratchet.fetch("requiredModuleIDs", {})
metrics_policy = ratchet.fetch("metrics", {})

metrics_policy.each do |name, policy|
  %w[owner reason removalPhase].each do |field|
    value = policy[field]
    errors << "ratchet metric #{name} requires a non-empty #{field}" unless value.is_a?(String) && !value.strip.empty?
  end
  errors << "ratchet metric #{name} requires a non-negative integer maximum" unless policy["maximum"].is_a?(Integer) && policy["maximum"] >= 0
  errors << "ratchet metric #{name} has an invalid removalPhase" unless policy["removalPhase"].to_s.match?(/\AP(?:[0-9]|1[0-2]|4A|4B)\z/)
end

swift_files = Dir.glob(root.join("**/*.swift").to_s).reject { |path| path.include?("/.git/") || path.include?("/.build/") }
production_files = production_swift_files(root)

swift_files.each do |path|
  File.readlines(path).each_with_index do |line, index|
    match = line.match(/^\s*(?:@testable\s+)?import\s+(Forsetti[A-Za-z0-9_]*)/i)
    next unless match
    errors << "FG-001: #{relative(path, root)}:#{index + 1}: external Forsetti imports are permanently prohibited"
  end
end

dependency_files = Dir.glob(root.join("**/{Package.swift,Package.resolved,project.pbxproj,.gitmodules}").to_s, File::FNM_DOTMATCH)
dependency_files << root.join("project.yml").to_s if root.join("project.yml").file?
dependency_files.uniq.reject do |path|
  relative_path = relative(path, root)
  relative_path.start_with?(".git/", ".build/", "DerivedData/")
end.each do |path|
  text = File.read(path)
  relative_path = relative(path, root)
  forsetti_reference = text.match?(/github\.com[^\n\"']*forsetti|\.package\s*\([^)]*forsetti|(?:url|path|product)\s*:\s*[^\n]*forsetti/i)
  if forsetti_reference
    errors << "FG-001: #{relative_path}: external, local, product, submodule, or vendored Forsetti dependency references are permanently prohibited"
  end

  if File.basename(path) == "Package.swift"
    remote_clauses = text.scan(/\.package\s*\((.*?)\)/m).flatten.select { |clause| clause.match?(/\burl\s*:/) }
    errors << "#{relative_path}: remote package dependencies are outside the app-owned shipping graph" unless remote_clauses.empty?
  end

  if File.basename(path) == "project.pbxproj" && text.include?("XCRemoteSwiftPackageReference")
    errors << "#{relative_path}: remote package references are outside the app-owned shipping graph"
  end

  if File.basename(path) == "Package.resolved"
    begin
      resolved = JSON.parse(text)
      pins = Array(resolved["pins"] || resolved.dig("object", "pins"))
      errors << "#{relative_path}: resolved package pins are outside the app-owned shipping graph" unless pins.empty?
    rescue JSON::ParserError => error
      errors << "#{relative_path}: invalid resolved-package JSON: #{error.message}"
    end
  end
end

Dir.glob(root.join("**/*").to_s, File::FNM_DOTMATCH).each do |path|
  next unless File.directory?(path)
  relative_path = relative(path, root)
  next if relative_path.start_with?(".git/", ".build/", "DerivedData/", "docs/", "Docs/")
  if File.basename(path).match?(/forsetti/i)
    errors << "FG-001: #{relative_path}: vendored Forsetti directories are permanently prohibited"
  end
end

fetch_scan_files = Dir.glob(root.join("{scripts,.github}/**/*").to_s, File::FNM_DOTMATCH).select { |path| File.file?(path) }
fetch_scan_files.concat([
  root.join("project.yml").to_s,
  root.join("RuneScrib.xcodeproj/project.pbxproj").to_s
].select { |path| File.file?(path) })
fetch_scan_files.uniq!
fetch_scan_files.reject! do |path|
  %w[scripts/check-architecture.sh scripts/check-forsetti-compliance.sh].include?(relative(path, root))
end
fetch_scan_files.each do |path|
  File.readlines(path).each_with_index do |line, index|
    next unless line.match?(/(?:git\s+(?:clone|fetch|submodule)|curl|wget|download)[^\n]*forsetti/i)
    errors << "FG-001: #{relative(path, root)}:#{index + 1}: build-time Forsetti fetches are permanently prohibited"
  end
end

project_path = root.join("project.yml")
project = project_path.file? ? (YAML.load_file(project_path.to_s) || {}) : {}
project_packages = project.fetch("packages", {}) || {}
project_packages.each do |name, specification|
  if specification.is_a?(Hash) && specification.key?("url")
    prefix = JSON.generate(specification).match?(/forsetti/i) ? "FG-001: " : ""
    errors << "#{prefix}project.yml package #{name}: remote packages are outside the app-owned shipping graph"
  end
end
project_targets = project.fetch("targets", {}) || {}
app_target_names = %w[RuneScrib-macOS RuneScrib-iOS]
expected_shipping_source_declarations = [
  { "path" => "RuneScrib/AppHost" },
  { "path" => "RuneScrib/Metal/Shaders.metal" },
  { "path" => "RuneScrib/Resources" }
]
app_target_names.each do |target_name|
  actual_sources = Array(project_targets.dig(target_name, "sources"))
  unless actual_sources == expected_shipping_source_declarations
    errors << "project.yml target #{target_name} shipping sources differ from the exact allowlist"
  end
end

generated_project_path = root.join("RuneScrib.xcodeproj/project.pbxproj")
expected_compiled_sources = %w[
  RuneScrib/AppHost/AppDelegate.swift
  RuneScrib/AppHost/RuneScribApp.swift
  RuneScrib/AppHost/RuneScribeRuntimeComposition.swift
  RuneScrib/Metal/Shaders.metal
]
if generated_project_path.file?
  stdout, stderr, status = Open3.capture3(
    "plutil", "-convert", "json", "-o", "-", generated_project_path.to_s
  )
  if status.success?
    begin
      pbxproj = JSON.parse(stdout)
      app_target_names.each do |target_name|
        paths, path_errors = compiled_source_paths(pbxproj, target_name)
        errors.concat(path_errors)
        unless paths == expected_compiled_sources
          errors << "generated project #{target_name} compiled sources differ from the exact allowlist"
        end
      end
    rescue JSON::ParserError => error
      errors << "RuneScrib.xcodeproj/project.pbxproj: invalid converted JSON: #{error.message}"
    end
  else
    errors << "RuneScrib.xcodeproj/project.pbxproj: plutil conversion failed: #{stderr.strip}"
  end
else
  errors << "missing RuneScrib.xcodeproj/project.pbxproj"
end

if test_only_products == ["RuneScribeTestSupport"]
  test_support_consumers = project_targets.each_with_object([]) do |(target_name, target), consumers|
    dependencies = target.is_a?(Hash) ? Array(target["dependencies"]) : []
    consumers << target_name if dependencies.any? { |dependency| dependency_name(dependency) == "RuneScribeTestSupport" }
  end.sort
  expected_test_support_consumers = %w[
    RuneScribIOSTests RuneScribMacParityTests RuneScribTests
  ].sort
  unless test_support_consumers == expected_test_support_consumers
    errors << "project.yml RuneScribeTestSupport consumers differ: #{test_support_consumers.join(', ')}"
  end
end

architecture_package_relative = ratchet.fetch("architecturePackagePath")
architecture_package = root.join(architecture_package_relative)
package_manifest = architecture_package.join("Package.swift")
package_present = package_manifest.file?

package_reference_names = project_packages.each_with_object([]) do |(name, specification), names|
  next unless specification.is_a?(Hash)
  path = specification["path"].to_s.sub(%r{\A\./}, "").sub(%r{/\z}, "")
  names << name if path == architecture_package_relative.sub(%r{/\z}, "")
end
strict_package_mode = package_present && (
  !package_reference_names.empty? || ENV["RUNESCRIBE_ARCHITECTURE_STRICT"] == "1"
)

project_product_dependencies = {}
app_target_names.each do |target_name|
  dependencies = Array(project_targets.dig(target_name, "dependencies"))
  project_product_dependencies[target_name] = dependencies.each_with_object([]) do |dependency, products|
    next unless dependency.is_a?(Hash)
    package_name = dependency["package"]
    product_name = dependency["product"] || package_name
    products << product_name if package_reference_names.include?(package_name)
  end
end

monolithic_targets = app_target_names.count do |target_name|
  Array(project_targets.dig(target_name, "sources")).any? do |source|
    path = source.is_a?(Hash) ? source["path"] : source
    path.to_s.sub(%r{/\z}, "") == "RuneScrib"
  end
end

architecture_test_target_missing = project_targets.key?("RuneScribArchitectureTests") ? 0 : 1
architecture_test_file = root.join("RuneScribArchitectureTests/ArchitectureGuardrailTests.swift")
errors << "missing RuneScribArchitectureTests/ArchitectureGuardrailTests.swift" unless architecture_test_file.file?

if package_present
  stdout, stderr, status = Open3.capture3(
    "swift", "package", "--package-path", architecture_package.to_s, "dump-package",
    chdir: root.to_s
  )
  unless status.success?
    errors << "#{architecture_package_relative}/Package.swift: swift package dump-package failed: #{stderr.strip}"
  else
    begin
      package = JSON.parse(stdout)
      external_dependencies = Array(package["dependencies"])
      unless external_dependencies.empty?
        prefix = external_dependencies.any? { |dependency| JSON.generate(dependency).match?(/forsetti/i) } ? "FG-001: " : ""
        errors << "#{prefix}#{architecture_package_relative}/Package.swift: external package dependencies are outside the app-owned shipping graph"
      end

      products = Array(package["products"])
      product_names = products.map { |product| product["name"] }
      missing_products = required_products - product_names
      missing_presentation_contract_products = presentation_contract_products - product_names
      missing_test_products = test_only_products - product_names
      extra_products = product_names - architecture_package_products
      errors << "architecture package missing products: #{missing_products.join(', ')}" unless missing_products.empty?
      unless missing_presentation_contract_products.empty?
        errors << "architecture package missing presentation-contract products: #{missing_presentation_contract_products.join(', ')}"
      end
      errors << "architecture package missing test-only products: #{missing_test_products.join(', ')}" unless missing_test_products.empty?
      errors << "architecture package has unexpected products: #{extra_products.join(', ')}" unless extra_products.empty?
      unless product_names == architecture_package_products
        errors << "architecture package product order or duplication differs"
      end

      products.each do |product|
        next unless architecture_package_products.include?(product["name"])
        targets = Array(product["targets"])
        errors << "product #{product['name']} must expose only target #{product['name']}" unless targets == [product["name"]]
      end

      targets = Array(package["targets"]).to_h { |target| [target["name"], target] }
      missing_targets = architecture_package_targets - targets.keys
      errors << "architecture package missing targets: #{missing_targets.join(', ')}" unless missing_targets.empty?

      allowed_dependencies = {
        "RuneScribeContracts" => [],
        "RuneScribeUIPresentationContracts" => ["RuneScribeContracts"],
        "RuneScribeRuntimeCore" => ["RuneScribeCloudSyncModule", "RuneScribeContracts", "RuneScribeGameCenterModule", "RuneScribeProgressionSyncDomain", "RuneScribeUIPresentationContracts"],
        "RuneScribeUIRuntime" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIPresentationContracts"],
        "RuneScribePlatform" => ["RuneScribeContracts"],
        "RuneScribeCoreModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeProgressionModule" => ["RuneScribeContracts", "RuneScribeProgressionSyncDomain", "RuneScribeRuntimeCore"],
        "RuneScribeThemeCoordinatorModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeNorseThemeModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeThemeMoonleafModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeThemeSunspireModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeThemeWildwoodModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeThemeGloamthornModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeProgressionSyncDomain" => ["RuneScribeContracts"],
        "RuneScribeCloudSyncModule" => ["RuneScribeProgressionSyncDomain"],
        "RuneScribeGameCenterModule" => ["RuneScribeContracts"],
        "RuneScribeUIModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIPresentationContracts", "RuneScribeUIRuntime"],
        "RuneScribeTestSupport" => ["RuneScribeContracts"]
      }
      required_dependencies = {
        "RuneScribeContracts" => [],
        "RuneScribeUIPresentationContracts" => ["RuneScribeContracts"],
        "RuneScribeRuntimeCore" => ["RuneScribeCloudSyncModule", "RuneScribeContracts", "RuneScribeGameCenterModule", "RuneScribeProgressionSyncDomain", "RuneScribeUIPresentationContracts"],
        "RuneScribeUIRuntime" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIPresentationContracts"],
        "RuneScribePlatform" => ["RuneScribeContracts"],
        "RuneScribeCoreModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeProgressionModule" => ["RuneScribeContracts", "RuneScribeProgressionSyncDomain", "RuneScribeRuntimeCore"],
        "RuneScribeThemeCoordinatorModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeNorseThemeModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeThemeMoonleafModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeThemeSunspireModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeThemeWildwoodModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeThemeGloamthornModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeProgressionSyncDomain" => ["RuneScribeContracts"],
        "RuneScribeCloudSyncModule" => ["RuneScribeProgressionSyncDomain"],
        "RuneScribeGameCenterModule" => ["RuneScribeContracts"],
        "RuneScribeUIModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIPresentationContracts", "RuneScribeUIRuntime"],
        "RuneScribeTestSupport" => ["RuneScribeContracts"]
      }

      architecture_package_targets.each do |target_name|
        next unless targets[target_name]
        dependencies = Array(targets[target_name]["dependencies"]).map { |dependency| dependency_name(dependency) }.compact
        forbidden = dependencies - allowed_dependencies.fetch(target_name)
        missing = required_dependencies.fetch(target_name) - dependencies
        errors << "target #{target_name} has forbidden dependencies: #{forbidden.join(', ')}" unless forbidden.empty?
        errors << "target #{target_name} is missing dependencies: #{missing.join(', ')}" unless missing.empty?
      end

      test_support_consumers = targets.values.each_with_object([]) do |target, consumers|
        dependencies = Array(target["dependencies"]).map { |dependency| dependency_name(dependency) }.compact
        consumers << target["name"] if dependencies.include?("RuneScribeTestSupport")
      end.sort
      expected_test_support_consumers = %w[
        RuneScribeArchitectureTests RuneScribePlatformTests
        RuneScribeProgressionModuleTests RuneScribeRuntimeCoreTests
        RuneScribeThemeCoordinatorModuleTests RuneScribeThemeGloamthornModuleTests
        RuneScribeThemeMoonleafModuleTests RuneScribeThemeSunspireModuleTests
        RuneScribeThemeWildwoodModuleTests RuneScribeUIModuleTests
      ].sort
      unless test_support_consumers == expected_test_support_consumers
        errors << "package RuneScribeTestSupport consumers differ: #{test_support_consumers.join(', ')}"
      end
    rescue JSON::ParserError => error
      errors << "#{architecture_package_relative}/Package.swift: invalid dump-package JSON: #{error.message}"
    end
  end

  if strict_package_mode
    errors << "project.yml must reference #{architecture_package_relative} as a local package" if package_reference_names.empty?
    app_target_names.each do |target_name|
      missing = required_products - project_product_dependencies.fetch(target_name)
      unexpected = project_product_dependencies.fetch(target_name) - required_products
      errors << "project.yml target #{target_name} is missing package products: #{missing.join(', ')}" unless missing.empty?
      errors << "project.yml target #{target_name} has non-shipping package products: #{unexpected.join(', ')}" unless unexpected.empty?
    end
  end
end

runtime_integrity_source = architecture_package.join(
  "Sources/RuneScribeRuntimeCore/RuntimeBundledResourceIntegrity.swift"
).to_s
ui_image_decode_source = architecture_package.join(
  "Sources/RuneScribeUIRuntime/RuntimeApplicationResourcePresentation.swift"
).to_s
runtime_pdf_validation_source = architecture_package.join(
  "Sources/RuneScribeRuntimeCore/RuntimePDFResourceValidation.swift"
).to_s
ui_safe_preview_decode_source = architecture_package.join(
  "Sources/RuneScribeUIModule/Sharing/ReceivedPresentationSummary.swift"
).to_s
MODULE_IMPORT_POLICY.each do |product, allowed_imports|
  source_root = architecture_package.join("Sources/#{product}")
  next unless source_root.directory?
  Dir.glob(source_root.join("**/*.swift").to_s).each do |path|
    relative_path = relative(path, root)
    next if relative_path.include?("/Resources/Source/")
    source = File.read(path)
    errors.concat(
      module_source_errors(
        product,
        relative_path,
        source,
        allowed_imports,
        runtime_integrity_source: relative(runtime_integrity_source, root),
        ui_image_decode_source: relative(ui_image_decode_source, root),
        runtime_pdf_validation_source: relative(runtime_pdf_validation_source, root)
      )
    )
    errors.concat(module_boundary_source_errors(product, relative_path, source))
    errors.concat(
      ui_resource_decode_errors(
        relative_path,
        source,
        safe_preview_decode_source: relative(ui_safe_preview_decode_source, root)
      )
    ) if product == "RuneScribeUIModule"
    errors.concat(progression_source_errors(relative_path, source)) if product == "RuneScribeProgressionModule"
    errors.concat(feature_preferences_source_errors(product, relative_path, source))
  end
end

progression_catalog_paths = Dir.glob(
  architecture_package.join(
    "Sources/RuneScribeProgressionModule/Resources/Rune-Scribe-Progression-Catalog-v*.json"
  ).to_s
).sort
if progression_catalog_paths.empty?
  errors << "missing bundled Progression catalog for stable-ID validation"
else
  progression_catalog_paths.each do |progression_catalog_path|
    errors.concat(progression_catalog_stable_id_errors(progression_catalog_path))
  end
end

Dir.glob(
  architecture_package.join("Sources/*Theme*/**/*.{swift,json,yaml,yml,plist}").to_s
).sort.each do |path|
  errors.concat(
    theme_progression_coupling_errors(relative(path, root), File.read(path))
  )
end

manifest_allowed_keys = %w[
  schemaVersion policyProfile runtimeVersion moduleID displayName moduleVersion
  moduleType supportedPlatforms minimumOS capabilitiesRequested entryPoint
  runtimeRequirements defaultRole criticality consumedEndpoints publishedEndpoints
  entitlementRequirement diagnosticsVisibleInProduction policyClass
]
manifest_required_keys = %w[
  schemaVersion policyProfile runtimeVersion moduleID displayName moduleVersion
  moduleType supportedPlatforms capabilitiesRequested entryPoint runtimeRequirements
  defaultRole criticality consumedEndpoints publishedEndpoints diagnosticsVisibleInProduction
]

manifest_records = []
Dir.glob(architecture_package.join("Sources/**/Resources/module-manifest.json").to_s).each do |path|
  begin
    value = JSON.parse(File.read(path))
    manifest_records << [path, value] if value.is_a?(Hash) && value.key?("moduleID")
  rescue JSON::ParserError
    next
  end
end

manifest_groups = manifest_records.group_by { |_path, value| value["moduleID"] }
manifest_groups.each do |module_id, records|
  errors << "duplicate module manifest ID #{module_id}" if records.length > 1
  errors << "unknown module manifest ID #{module_id}" unless required_module_ids.key?(module_id)
end

required_module_ids.each do |module_id, policy|
  record = manifest_groups[module_id]&.first
  next unless record
  path, manifest = record
  relative_path = relative(path, root)
  missing_keys = manifest_required_keys - manifest.keys
  unknown_keys = manifest.keys - manifest_allowed_keys
  errors << "#{relative_path}: missing manifest keys: #{missing_keys.join(', ')}" unless missing_keys.empty?
  errors << "#{relative_path}: unknown manifest keys: #{unknown_keys.join(', ')}" unless unknown_keys.empty?
  errors << "#{relative_path}: schemaVersion must be 1.0" unless manifest["schemaVersion"] == "1.0"
  errors << "#{relative_path}: policyProfile must be forsetti-pattern-b-standalone" unless manifest["policyProfile"] == "forsetti-pattern-b-standalone"
  errors << "#{relative_path}: runtimeVersion must be semantic" unless manifest["runtimeVersion"].to_s.match?(/\A\d+\.\d+\.\d+\z/)
  errors << "#{relative_path}: moduleVersion must be semantic" unless manifest["moduleVersion"].to_s.match?(/\A\d+\.\d+\.\d+\z/)
  errors << "#{relative_path}: moduleType must be #{policy['moduleType']}" unless manifest["moduleType"] == policy["moduleType"]
  errors << "#{relative_path}: criticality must be required or optional" unless %w[required optional].include?(manifest["criticality"])
  if policy.key?("criticality") && manifest["criticality"] != policy["criticality"]
    errors << "#{relative_path}: criticality must be #{policy['criticality']}"
  end
  if policy.key?("policyClass") && manifest["policyClass"] != policy["policyClass"]
    errors << "#{relative_path}: policyClass must be #{policy['policyClass']}"
  end
  errors << "#{relative_path}: defaultRole must be #{policy['defaultRole']}" unless manifest["defaultRole"] == policy["defaultRole"]
  errors << "#{relative_path}: diagnostics must remain hidden in production" unless manifest["diagnosticsVisibleInProduction"] == false
  errors << "#{relative_path}: supportedPlatforms must contain iOS and macOS" unless Array(manifest["supportedPlatforms"]).sort == %w[iOS macOS].sort
  capabilities = Array(manifest["capabilitiesRequested"])
  errors << "#{relative_path}: capabilitiesRequested must be unique strings" unless capabilities.all? { |capability| capability.is_a?(String) } && capabilities.uniq == capabilities
  %w[consumedEndpoints publishedEndpoints].each do |key|
    endpoints = manifest[key]
    unless endpoints.is_a?(Array) && endpoints.all? { |endpoint| endpoint.is_a?(String) && !endpoint.empty? } && endpoints.uniq == endpoints
      errors << "#{relative_path}: #{key} must contain unique non-empty strings"
    end
  end
  requirements = manifest["runtimeRequirements"]
  unless requirements.is_a?(Hash) && requirements.keys.sort == %w[requiredModuleRoles requiredResources requiredServices].sort
    errors << "#{relative_path}: runtimeRequirements must contain only requiredServices, requiredResources, and requiredModuleRoles"
  end

  descriptor_sources = Dir.glob(architecture_package.join("Sources/#{policy['product']}/**/*.swift").to_s)
  descriptor_has_id = descriptor_sources.any? { |source| File.read(source).include?(module_id) }
  unless descriptor_has_id
    vocabulary_sources = Dir.glob(
      architecture_package.join("Sources/RuneScribeContracts/**/*.swift").to_s
    )
    constant_names = vocabulary_sources.flat_map do |source|
      File.read(source).scan(
        /static\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*ModuleIdentifier\s*=\s*"#{Regexp.escape(module_id)}"/
      ).flatten
    end
    descriptor_has_id = constant_names.any? do |constant_name|
      descriptor_sources.any? do |source|
        File.read(source).match?(/\bRuneScribeModuleIDs\.#{Regexp.escape(constant_name)}\b/)
      end
    end
  end
  unless descriptor_has_id
    errors << "#{relative_path}: no matching compiled descriptor ID in #{policy['product']}"
  end
end

if strict_package_mode
  missing_ids = required_module_ids.keys - manifest_groups.keys
  errors << "architecture package missing module manifests: #{missing_ids.join(', ')}" unless missing_ids.empty?
  ui_count = manifest_records.count { |_path, manifest| manifest["moduleType"] == "ui" }
  errors << "architecture package must contain exactly one UI module manifest; found #{ui_count}" unless ui_count == 1
end

singleton_names = %w[
  KeyManager ContactManager ImportCoordinator MessageCoordinator
  KeychainService ContactStore FontStore AppLock
]
singleton_reference_pattern = /\b(?:#{singleton_names.join('|')})\.shared\b/

production_text = production_files.map { |path| File.read(path) }.join("\n")
production_code = without_comments(production_text)
app_owned_singleton_declarations = production_text.scan(/\bstatic\s+let\s+shared\s*=/).length
app_owned_singleton_references = production_text.scan(singleton_reference_pattern).length
feature_notification_calls = production_text.scan(/NotificationCenter\.default\.(?:post|publisher)\b/).length
feature_notification_names = production_text.scan(/Notification\.Name\("com\.runescribe\./).length
notification_center_default_uses = production_text.scan(/NotificationCenter\.default\b/).length
allowed_notification_path = root.join(
  "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeApplicationResourcePresentation.swift"
).to_s
notification_center_use_records = production_files.flat_map do |path|
  File.readlines(path).each_with_index.map do |line, index|
    next unless line.include?("NotificationCenter.default")
    [path, index + 1, line]
  end.compact
end
unexpected_notification_center_uses = notification_center_use_records.count do |path, _line, source|
  path != allowed_notification_path ||
    !source.match?(/NotificationCenter\.default\.(?:addObserver|removeObserver)\b/)
end
allowed_notification_sources = notification_center_use_records
  .select { |path, _line, _source| path == allowed_notification_path }
  .map(&:last)
unless allowed_notification_sources.count { |source| source.include?(".addObserver") } == 1 &&
       allowed_notification_sources.count { |source| source.include?(".removeObserver") } == 1
  errors << "RuntimeApplicationResourcePresentation must contain exactly one AVPlayer observer registration and removal"
end
temporary_application_session_adapters = production_text.scan(
  /Architecture ratchet: temporary-application-session-adapter\./
).length
production_diagnostic_sink_references = production_code.scan(
  /\b(?:print|debugPrint|dump|NSLog|os_log)\s*\(|\bLogger\s*\(/
).length

host_files = Dir.glob(root.join("RuneScrib/AppHost/**/*.swift").to_s).sort
errors << "application host must contain Swift sources in RuneScrib/AppHost" if host_files.empty?
host_text = without_comments(host_files.map { |path| File.read(path) }.join("\n"))
host_legacy_boundary_references = host_text.scan(singleton_reference_pattern).length +
  host_text.scan(/\bInboundOpenRouter\b/).length +
  host_text.scan(/NotificationCenter\.default\b/).length
host_runtime_bypass_references = host_text.scan(/\bRuneScribeCoreApplicationService\b/).length
host_physical_lines = host_files.sum { |path| File.readlines(path).length }

host_files.each do |path|
  swift_imports(without_comments_preserving_lines(File.read(path))).each do |imported, line|
    allowed = %w[
      Foundation SwiftUI AppKit UIKit RuneScribeContracts RuneScribeRuntimeCore
      RuneScribePlatform RuneScribeCoreModule RuneScribeProgressionModule
      RuneScribeNorseThemeModule RuneScribeThemeCoordinatorModule
      RuneScribeThemeMoonleafModule RuneScribeThemeSunspireModule
      RuneScribeThemeWildwoodModule RuneScribeThemeGloamthornModule
      RuneScribeCloudSyncModule RuneScribeGameCenterModule
      RuneScribeUIModule RuneScribeUIRuntime
    ]
    errors << "#{relative(path, root)}:#{line}: host may not import #{imported}" unless allowed.include?(imported)
  end
end

missing_manifest_count = required_module_ids.keys.count { |module_id| !manifest_groups.key?(module_id) }
missing_project_product_dependencies = app_target_names.sum do |target_name|
  (required_products - project_product_dependencies.fetch(target_name)).length
end

metrics = {
  "architecturePackageMissing" => package_present ? 0 : 1,
  "moduleManifestsMissing" => missing_manifest_count,
  "projectPackageReferenceMissing" => package_reference_names.empty? ? 1 : 0,
  "projectProductDependenciesMissing" => missing_project_product_dependencies,
  "architectureTestTargetMissing" => architecture_test_target_missing,
  "monolithicAppTargets" => monolithic_targets,
  "appOwnedSingletonDeclarations" => app_owned_singleton_declarations,
  "appOwnedSingletonReferences" => app_owned_singleton_references,
  "featureNotificationCenterCalls" => feature_notification_calls,
  "featureNotificationNames" => feature_notification_names,
  "notificationCenterDefaultUses" => notification_center_default_uses,
  "unexpectedNotificationCenterUses" => unexpected_notification_center_uses,
  "temporaryApplicationSessionAdapters" => temporary_application_session_adapters,
  "productionDiagnosticSinkReferences" => production_diagnostic_sink_references,
  "hostLegacyBoundaryReferences" => host_legacy_boundary_references,
  "hostRuntimeBypassReferences" => host_runtime_bypass_references,
  "hostPhysicalLines" => host_physical_lines
}

missing_metric_policies = metrics.keys - metrics_policy.keys
unknown_metric_policies = metrics_policy.keys - metrics.keys
errors << "ratchet is missing metric policies: #{missing_metric_policies.join(', ')}" unless missing_metric_policies.empty?
errors << "ratchet has unknown metric policies: #{unknown_metric_policies.join(', ')}" unless unknown_metric_policies.empty?

metrics.each do |name, current|
  policy = metrics_policy[name]
  next unless policy
  maximum = policy["maximum"]
  if maximum.is_a?(Integer) && current > maximum
    errors << "ratchet #{name} increased to #{current}; maximum is #{maximum} (owner #{policy['owner']}, removal #{policy['removalPhase']})"
  else
    puts "PASS #{name}=#{current}/#{maximum} removal=#{policy['removalPhase']}"
  end
end

if errors.empty?
  puts "Architecture guardrails passed."
  exit 0
end

warn "Architecture guardrails failed:"
errors.uniq.each { |error| warn "- #{error}" }
exit 1
RUBY
