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
      relative.split("/").any? { |component| component == "Tests" || component.end_with?("Tests") }
  end
end

def without_comments(text)
  text.gsub(%r{/\*.*?\*/}m, "").lines.map { |line| line.sub(%r{//.*$}, "") }.join
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
      missing_test_products = test_only_products - product_names
      extra_products = product_names - all_products
      errors << "architecture package missing products: #{missing_products.join(', ')}" unless missing_products.empty?
      errors << "architecture package missing test-only products: #{missing_test_products.join(', ')}" unless missing_test_products.empty?
      errors << "architecture package has unexpected products: #{extra_products.join(', ')}" unless extra_products.empty?
      errors << "architecture package product order or duplication differs" unless product_names == all_products

      products.each do |product|
        next unless all_products.include?(product["name"])
        targets = Array(product["targets"])
        errors << "product #{product['name']} must expose only target #{product['name']}" unless targets == [product["name"]]
      end

      targets = Array(package["targets"]).to_h { |target| [target["name"], target] }
      missing_targets = all_products - targets.keys
      errors << "architecture package missing targets: #{missing_targets.join(', ')}" unless missing_targets.empty?

      allowed_dependencies = {
        "RuneScribeContracts" => [],
        "RuneScribeRuntimeCore" => ["RuneScribeContracts"],
        "RuneScribeUIRuntime" => ["RuneScribeContracts"],
        "RuneScribePlatform" => ["RuneScribeContracts"],
        "RuneScribeCoreModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeUIModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIRuntime"],
        "RuneScribeTestSupport" => ["RuneScribeContracts"]
      }
      required_dependencies = {
        "RuneScribeContracts" => [],
        "RuneScribeRuntimeCore" => [],
        "RuneScribeUIRuntime" => ["RuneScribeContracts"],
        "RuneScribePlatform" => ["RuneScribeContracts"],
        "RuneScribeCoreModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeUIModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIRuntime"],
        "RuneScribeTestSupport" => ["RuneScribeContracts"]
      }

      all_products.each do |target_name|
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

module_import_policy = {
  "RuneScribeContracts" => %w[Foundation],
  "RuneScribeRuntimeCore" => %w[Foundation RuneScribeContracts],
  "RuneScribeUIRuntime" => %w[Foundation SwiftUI RuneScribeContracts],
  "RuneScribePlatform" => %w[Foundation Darwin RuneScribeContracts Security Contacts CoreText AppKit UIKit],
  "RuneScribeCoreModule" => %w[Foundation CryptoKit CommonCrypto RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeUIModule" => %w[Foundation SwiftUI Combine RuneScribeContracts RuneScribeRuntimeCore RuneScribeUIRuntime AppKit UIKit LinkPresentation MessageUI Metal MetalKit CoreImage CoreTransferable AVFoundation Contacts ContactsUI UniformTypeIdentifiers],
  "RuneScribeTestSupport" => %w[Foundation RuneScribeContracts]
}
module_import_policy.each do |product, allowed_imports|
  source_root = architecture_package.join("Sources/#{product}")
  next unless source_root.directory?
  Dir.glob(source_root.join("**/*.swift").to_s).each do |path|
    File.readlines(path).each_with_index do |line, index|
      match = line.match(/^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)/)
      next unless match
      imported = match[1]
      unless allowed_imports.include?(imported)
        errors << "#{relative(path, root)}:#{index + 1}: #{product} may not import #{imported}"
      end
    end
  end
end

manifest_allowed_keys = %w[
  schemaVersion policyProfile runtimeVersion moduleID displayName moduleVersion
  moduleType supportedPlatforms minimumOS capabilitiesRequested entryPoint
  runtimeRequirements defaultRole entitlementRequirement diagnosticsVisibleInProduction
]
manifest_required_keys = %w[
  schemaVersion policyProfile runtimeVersion moduleID displayName moduleVersion
  moduleType supportedPlatforms capabilitiesRequested entryPoint runtimeRequirements
  defaultRole diagnosticsVisibleInProduction
]

manifest_records = []
Dir.glob(architecture_package.join("Sources/**/*.json").to_s).each do |path|
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
  errors << "#{relative_path}: defaultRole must be #{policy['defaultRole']}" unless manifest["defaultRole"] == policy["defaultRole"]
  errors << "#{relative_path}: diagnostics must remain hidden in production" unless manifest["diagnosticsVisibleInProduction"] == false
  errors << "#{relative_path}: supportedPlatforms must contain iOS and macOS" unless Array(manifest["supportedPlatforms"]).sort == %w[iOS macOS].sort
  capabilities = Array(manifest["capabilitiesRequested"])
  errors << "#{relative_path}: capabilitiesRequested must be unique strings" unless capabilities.all? { |capability| capability.is_a?(String) } && capabilities.uniq == capabilities
  requirements = manifest["runtimeRequirements"]
  unless requirements.is_a?(Hash) && requirements.keys.sort == %w[requiredModuleRoles requiredServices].sort
    errors << "#{relative_path}: runtimeRequirements must contain only requiredServices and requiredModuleRoles"
  end

  descriptor_sources = Dir.glob(architecture_package.join("Sources/#{policy['product']}/**/*.swift").to_s)
  unless descriptor_sources.any? { |source| File.read(source).include?(module_id) }
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
  "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VideoSplashView.swift"
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
  errors << "VideoSplashView must contain exactly one AVPlayer observer registration and removal"
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
  File.readlines(path).each_with_index do |line, index|
    match = line.match(/^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)/)
    next unless match
    allowed = %w[
      Foundation SwiftUI AppKit UIKit RuneScribeContracts RuneScribeRuntimeCore
      RuneScribePlatform RuneScribeCoreModule RuneScribeUIModule RuneScribeUIRuntime
    ]
    errors << "#{relative(path, root)}:#{index + 1}: host may not import #{match[1]}" unless allowed.include?(match[1])
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
