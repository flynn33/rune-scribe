#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
ratchet_file="$script_dir/architecture-ratchet.json"

ruby - "$repository_root" "$ratchet_file" <<'RUBY'
require "json"
require "open3"
require "pathname"
require "yaml"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

root = Pathname(ARGV.fetch(0)).realpath
ratchet_path = Pathname(ARGV.fetch(1)).realpath
errors = []

def relative(path, root)
  Pathname(path).relative_path_from(root).to_s
end

def production_swift_files(root)
  Dir.glob(root.join("**/*.swift").to_s).reject do |path|
    relative = Pathname(path).relative_path_from(root).to_s
    relative.start_with?(".git/", ".build/", "DerivedData/") ||
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

unless ratchet_path.file?
  warn "architecture guard: missing #{ratchet_path}"
  exit 1
end

ratchet = JSON.parse(ratchet_path.read)
errors << "ratchet schemaVersion must be 1.0" unless ratchet["schemaVersion"] == "1.0"

required_products = Array(ratchet["requiredProducts"])
required_module_ids = ratchet.fetch("requiredModuleIDs", {})
metrics_policy = ratchet.fetch("metrics", {})

metrics_policy.each do |name, policy|
  %w[owner reason removalPhase].each do |field|
    value = policy[field]
    errors << "ratchet metric #{name} requires a non-empty #{field}" unless value.is_a?(String) && !value.strip.empty?
  end
  errors << "ratchet metric #{name} requires a non-negative integer maximum" unless policy["maximum"].is_a?(Integer) && policy["maximum"] >= 0
  errors << "ratchet metric #{name} has an invalid removalPhase" unless policy["removalPhase"].to_s.match?(/\AP(?:[0-8]|4A|4B)\z/)
end

swift_files = Dir.glob(root.join("**/*.swift").to_s).reject { |path| path.include?("/.git/") || path.include?("/.build/") }
production_files = production_swift_files(root)

swift_files.each do |path|
  File.readlines(path).each_with_index do |line, index|
    if line.match?(/^\s*(?:@testable\s+)?import\s+Forsetti(?:\b|\.)/i)
      errors << "#{relative(path, root)}:#{index + 1}: prohibited Forsetti import"
    end
  end
end

dependency_files = Dir.glob(root.join("**/{Package.swift,Package.resolved,project.pbxproj,.gitmodules}").to_s, File::FNM_DOTMATCH)
dependency_files << root.join("project.yml").to_s if root.join("project.yml").file?
dependency_files.uniq.each do |path|
  text = File.read(path)
  if text.match?(/github\.com[^\n\"']*forsetti|\.package\s*\([^)]*forsetti|(?:url|path|product)\s*:\s*[^\n]*forsetti/i)
    errors << "#{relative(path, root)}: prohibited Forsetti dependency reference"
  end
  if File.basename(path) == "Package.swift" && text.match?(/\.package\s*\(\s*url\s*:/m)
    errors << "#{relative(path, root)}: remote package dependencies are not allowed"
  end
  if File.basename(path) == "project.pbxproj" && text.include?("XCRemoteSwiftPackageReference")
    errors << "#{relative(path, root)}: remote package references are not allowed"
  end
end

Dir.glob(root.join("**/*").to_s, File::FNM_DOTMATCH).each do |path|
  next unless File.directory?(path)
  relative_path = relative(path, root)
  next if relative_path.start_with?(".git/", "docs/", "Docs/")
  if File.basename(path).match?(/forsetti/i)
    errors << "#{relative_path}: vendored Forsetti directory is not allowed"
  end
end

project_path = root.join("project.yml")
project = project_path.file? ? (YAML.load_file(project_path.to_s) || {}) : {}
project_packages = project.fetch("packages", {}) || {}
project_packages.each do |name, specification|
  if specification.is_a?(Hash) && specification.key?("url")
    errors << "project.yml package #{name}: remote package references are not allowed"
  end
end
project_targets = project.fetch("targets", {}) || {}

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

app_target_names = %w[RuneScrib-macOS RuneScrib-iOS]
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
      unless Array(package["dependencies"]).empty?
        errors << "#{architecture_package_relative}/Package.swift: external package dependencies are not allowed"
      end

      products = Array(package["products"])
      product_names = products.map { |product| product["name"] }
      missing_products = required_products - product_names
      extra_products = product_names - required_products
      errors << "architecture package missing products: #{missing_products.join(', ')}" unless missing_products.empty?
      errors << "architecture package has unexpected products: #{extra_products.join(', ')}" unless extra_products.empty?

      products.each do |product|
        next unless required_products.include?(product["name"])
        targets = Array(product["targets"])
        errors << "product #{product['name']} must expose only target #{product['name']}" unless targets == [product["name"]]
      end

      targets = Array(package["targets"]).to_h { |target| [target["name"], target] }
      missing_targets = required_products - targets.keys
      errors << "architecture package missing targets: #{missing_targets.join(', ')}" unless missing_targets.empty?

      allowed_dependencies = {
        "RuneScribeContracts" => [],
        "RuneScribeRuntimeCore" => ["RuneScribeContracts"],
        "RuneScribeUIRuntime" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribePlatform" => ["RuneScribeContracts"],
        "RuneScribeCoreModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeUIModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIRuntime"]
      }
      required_dependencies = {
        "RuneScribeContracts" => [],
        "RuneScribeRuntimeCore" => [],
        "RuneScribeUIRuntime" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribePlatform" => ["RuneScribeContracts"],
        "RuneScribeCoreModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore"],
        "RuneScribeUIModule" => ["RuneScribeContracts", "RuneScribeRuntimeCore", "RuneScribeUIRuntime"]
      }

      required_products.each do |target_name|
        next unless targets[target_name]
        dependencies = Array(targets[target_name]["dependencies"]).map { |dependency| dependency_name(dependency) }.compact
        forbidden = dependencies - allowed_dependencies.fetch(target_name)
        missing = required_dependencies.fetch(target_name) - dependencies
        errors << "target #{target_name} has forbidden dependencies: #{forbidden.join(', ')}" unless forbidden.empty?
        errors << "target #{target_name} is missing dependencies: #{missing.join(', ')}" unless missing.empty?
      end
    rescue JSON::ParserError => error
      errors << "#{architecture_package_relative}/Package.swift: invalid dump-package JSON: #{error.message}"
    end
  end

  if strict_package_mode
    errors << "project.yml must reference #{architecture_package_relative} as a local package" if package_reference_names.empty?
    app_target_names.each do |target_name|
      missing = required_products - project_product_dependencies.fetch(target_name)
      errors << "project.yml target #{target_name} is missing package products: #{missing.join(', ')}" unless missing.empty?
    end
  end
end

module_import_policy = {
  "RuneScribeContracts" => %w[Foundation],
  "RuneScribeRuntimeCore" => %w[Foundation RuneScribeContracts],
  "RuneScribeUIRuntime" => %w[Foundation SwiftUI RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribePlatform" => %w[Foundation Darwin RuneScribeContracts Security Contacts CoreText AppKit UIKit],
  "RuneScribeCoreModule" => %w[Foundation CryptoKit CommonCrypto RuneScribeContracts RuneScribeRuntimeCore],
  "RuneScribeUIModule" => %w[Foundation SwiftUI Combine RuneScribeContracts RuneScribeRuntimeCore RuneScribeUIRuntime AppKit UIKit MessageUI Metal MetalKit CoreImage CoreTransferable AVFoundation Contacts ContactsUI UniformTypeIdentifiers]
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
app_owned_singleton_declarations = production_text.scan(/\bstatic\s+let\s+shared\s*=/).length
app_owned_singleton_references = production_text.scan(singleton_reference_pattern).length
feature_notification_calls = production_text.scan(/NotificationCenter\.default\.(?:post|publisher)\b/).length
feature_notification_names = production_text.scan(/Notification\.Name\("com\.runescribe\./).length
notification_center_default_uses = production_text.scan(/NotificationCenter\.default\b/).length
temporary_application_session_adapters = production_text.scan(
  /Architecture ratchet: temporary-application-session-adapter\./
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
  "temporaryApplicationSessionAdapters" => temporary_application_session_adapters,
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
