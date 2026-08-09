#!/bin/bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"

exec /usr/bin/ruby - "$repository_root" "$script_dir/forsetti-compliance-rules.json" "$@" <<'RUBY'
# encoding: UTF-8
require "fileutils"
require "digest"
require "json"
require "pathname"

BANNER = "REPORT ONLY — NOT A COMPLIANCE PASS"
CANONICAL_RULES = [
  ["FG-001", "permanent-no-external-forsetti-dependency", "Reject every Forsetti package URL, product import, binary, submodule, vendored directory, fetch script, local checkout path, or copied source. There is no future conditional allowance."],
  ["FG-002", "exactly-one-ui-module", "Exactly one shipping UI module manifest and runtime UI contribution."],
  ["FG-003", "no-runtime-module-import-edge", "No runtime module implementation target imports another runtime module implementation target."],
  ["FG-004", "no-provider-object-publication", "A module may register handlers/descriptors with runtime; it may not publish an implementation/service object for another module to retain."],
  ["FG-005", "no-peer-service-handle-retention", "Modules and hosts may retain runtime clients/proxies only, never provider-owned service protocol values."],
  ["FG-006", "runtime-in-every-call-path", "Every cross-module command/query/state operation invokes a runtime dispatcher that validates caller, destination, capability, lifecycle, and endpoint generation per call."],
  ["FG-007", "runtime-owned-io", "Only designated runtime/platform implementation directories may call operational storage, Contacts, camera, Messages, share, clipboard, audio, network, CloudKit, GameKit, external URL, and file APIs."],
  ["FG-008", "runtime-owned-settings", "Production modules may not use AppStorage, SceneStorage for durable app settings, UserDefaults, CFPreferences, or direct preferences files."],
  ["FG-009", "uniform-module-factory", "Shipping module factories capture no arbitrary operational dependency; all facilities arrive through standard runtime ports."],
  ["FG-010", "standard-module-ports", "Every module manifest declares identity, unique address, policy class, criticality, lifecycle, input/query, state, output/event, resources, settings, contributions, diagnostics, and migration surfaces as applicable."],
  ["FG-011", "unique-id-reusable-policy-class", "Unique module IDs/addresses are separate from reusable policy classes. Multiple theme providers may share one policy class."],
  ["FG-012", "explicit-dependencies-only", "Runtime activation graph uses only declared required dependencies; UI is not implicitly dependent on every service module."],
  ["FG-013", "optional-failure-isolation", "Optional module activation/validation failure is isolated and exposed as unavailable; required dependency failure remains fail-fast."],
  ["FG-014", "live-eligibility-reconciliation", "Runtime responds to progression-gate changes while running and activates/deactivates only affected modules idempotently."],
  ["FG-015", "keyed-contribution-lifecycle", "Multiple providers contribute by stable keys; duplicate IDs fail; contributions are removed automatically on stop/replacement."],
  ["FG-016", "opaque-resource-lifecycle", "Modules declare resources; runtime validates and returns opaque revocable handles; consumers never guess bundles/paths or retain provider URLs."],
  ["FG-017", "runtime-owned-operation-metadata", "Runtime stamps operational IDs, timestamps, correlation IDs, and source identity."],
  ["FG-018", "typed-declared-event-routing", "Modules receive only declared event schemas/types; progression-critical delivery supports durable replay and dedupe."],
  ["FG-019", "negative-mutation-suite", "Every blocking rule has a deliberately failing fixture executed in CI."],
  ["FG-020", "single-authority-documentation", "One committed Forsetti policy document records the operator's model; audits, ADRs, templates, and agent instructions may not contradict it."]
].freeze

EXPECTED_FINDINGS = {
  "FG-001" => ["FRC-015"],
  "FG-002" => [],
  "FG-003" => [],
  "FG-004" => ["FRC-001"],
  "FG-005" => ["FRC-002", "FRC-003"],
  "FG-006" => ["FRC-001", "FRC-002", "FRC-003"],
  "FG-007" => ["FRC-004", "FRC-005"],
  "FG-008" => ["FRC-006"],
  "FG-009" => ["FRC-004", "FRC-007"],
  "FG-010" => ["FRC-008", "FRC-012", "FRC-014"],
  "FG-011" => ["FRC-011", "FRC-014"],
  "FG-012" => ["FRC-010", "FRC-014"],
  "FG-013" => ["FRC-010"],
  "FG-014" => ["FRC-009"],
  "FG-015" => ["FRC-012"],
  "FG-016" => ["FRC-012", "FRC-017"],
  "FG-017" => ["FRC-017"],
  "FG-018" => ["FRC-013"],
  "FG-019" => ["FRC-016"],
  "FG-020" => ["FRC-015", "FRC-016", "FRC-018"]
}.freeze

EXPECTED_P01_STATUSES = CANONICAL_RULES.to_h do |id, _name, _requirement|
  status = if %w[FG-001 FG-002 FG-003 FG-020].include?(id)
    "pass"
  elsif id == "FG-019"
    "pending-enforcement"
  else
    "violation"
  end
  [id, status]
end.freeze

CONTROLLING_POLICY_SHA256 = "8392d9ad457ccb2afbf9e872d591ec887d383f4b8617236179d624d2f792fb53"
HASH_LOCKED_PRODUCT_DOCUMENTS = {
  "docs/product-roadmap/Rune-Scribe-Codex-System-Spec-v1.0.md" => "7c4c460815064fca87a6769766fb875f267eb692795bbab2635eec5d55d8f88d",
  "docs/product-roadmap/Rune-Scribe-Codex-Current-App-Delta-and-Implementation-Roadmap-v1.0.md" => "884ad563f7849ebda8326bc742493ce67fb89cfacc14b39e56c792c4f7c52db4"
}.freeze

def fail_with(code, message)
  warn BANNER
  warn "ERROR: #{message}"
  exit code
end

default_root = ARGV.shift
default_rules = ARGV.shift
options = {
  scan_root: default_root,
  rules: default_rules,
  fixture_root: nil,
  json_output: nil,
  markdown_output: nil,
  output_directory: nil
}

until ARGV.empty?
  option = ARGV.shift
  case option
  when "--scan-root"
    options[:scan_root] = ARGV.shift || fail_with(64, "--scan-root requires a path")
  when "--rules"
    options[:rules] = ARGV.shift || fail_with(64, "--rules requires a path")
  when "--fixture-root"
    options[:fixture_root] = ARGV.shift || fail_with(64, "--fixture-root requires a path")
  when "--json-output"
    options[:json_output] = ARGV.shift || fail_with(64, "--json-output requires a path")
  when "--markdown-output"
    options[:markdown_output] = ARGV.shift || fail_with(64, "--markdown-output requires a path")
  when "--output"
    options[:output_directory] = ARGV.shift || fail_with(64, "--output requires a directory")
  when "--help", "-h"
    puts "Usage: scripts/check-forsetti-compliance.sh [--scan-root PATH] [--rules PATH] [--output DIR | --json-output PATH --markdown-output PATH] [--fixture-root PATH]"
    exit 0
  else
    fail_with(64, "unknown option #{option.inspect}")
  end
end

if options[:output_directory]
  if options[:json_output] || options[:markdown_output]
    fail_with(64, "--output cannot be combined with explicit output paths")
  end
  options[:json_output] = File.join(options[:output_directory], "forsetti-compliance-report.json")
  options[:markdown_output] = File.join(options[:output_directory], "forsetti-compliance-report.md")
end

root = Pathname(options[:scan_root]).expand_path
fail_with(3, "scan root is not a directory: #{root}") unless root.directory?
root = root.realpath
fixture_root = options[:fixture_root] && Pathname(options[:fixture_root]).expand_path
if fixture_root && !fixture_root.directory?
  fail_with(3, "fixture root is not a directory: #{fixture_root}")
end
fixture_root = fixture_root.realpath if fixture_root

rules_path = Pathname(options[:rules]).expand_path
fail_with(2, "rule catalog is not a file: #{rules_path}") unless rules_path.file?

begin
  catalog = JSON.parse(rules_path.read)
rescue JSON::ParserError => error
  fail_with(2, "rule catalog JSON is invalid: #{error.message}")
rescue SystemCallError => error
  fail_with(2, "rule catalog cannot be read: #{error.message}")
end

schema_errors = []
schema_errors << "schemaVersion must be 1.0" unless catalog["schemaVersion"] == "1.0"
schema_errors << "mode must be report-only" unless catalog["mode"] == "report-only"
schema_errors << "humanBanner drifted" unless catalog["humanBanner"] == BANNER
schema_errors << "architecturalViolationExitCode must be 0" unless catalog["architecturalViolationExitCode"] == 0
rules = catalog["rules"]
schema_errors << "rules must be an array" unless rules.is_a?(Array)

if rules.is_a?(Array)
  actual_identity = rules.map { |rule| [rule["id"], rule["name"], rule["requirement"]] }
  schema_errors << "rule IDs, names, requirements, or order differ from the canonical FG-001 through FG-020 catalog" unless actual_identity == CANONICAL_RULES
  rules.each do |rule|
    id = rule["id"].to_s
    schema_errors << "#{id}: owningPhases must be a non-empty phase array" unless rule["owningPhases"].is_a?(Array) && !rule["owningPhases"].empty? && rule["owningPhases"].all? { |phase| phase.match?(/\AP(?:0[1-9]|1[0-2])\z/) }
    schema_errors << "#{id}: findingIDs drifted" unless rule["findingIDs"] == EXPECTED_FINDINGS[id]
    schema_errors << "#{id}: expectedP01Status drifted" unless rule["expectedP01Status"] == EXPECTED_P01_STATUSES[id]
    schema_errors << "#{id}: remediationOwner is missing" unless rule["remediationOwner"].is_a?(String) && !rule["remediationOwner"].empty?
    enforcement = rule["enforcement"]
    valid_enforcement = enforcement.is_a?(Hash) &&
      enforcement["mode"] == "report-only" &&
      enforcement["severity"] == "blocking" &&
      %w[complete evidence-only pending].include?(enforcement["detectorCoverage"]) &&
      enforcement["blockingPhase"] == "P11"
    schema_errors << "#{id}: enforcement metadata is invalid" unless valid_enforcement
    schema_errors << "#{id}: waiverStatus must be none" unless rule["waiverStatus"] == "none"
    anchors = rule["evidenceAnchors"]
    schema_errors << "#{id}: evidenceAnchors must be non-empty" unless anchors.is_a?(Array) && !anchors.empty? && anchors.all? { |path| path.is_a?(String) && !path.empty? }
  end
end

unless schema_errors.empty?
  fail_with(2, "rule catalog schema failure: #{schema_errors.sort.join('; ')}")
end

class RepositoryScanner
  attr_reader :errors

  def initialize(root, fixture_root)
    @root = root
    @fixture_root = fixture_root
    @errors = []
  end

  def actual_path(relative)
    fixture_path = @fixture_root&.join(relative)
    return fixture_path if fixture_path&.exist?
    @root.join(relative)
  end

  def lines(relative)
    path = actual_path(relative)
    return nil unless path.file?
    File.readlines(path, encoding: "UTF-8")
  rescue SystemCallError, ArgumentError => error
    @errors << "#{relative}: #{error.message}"
    nil
  end

  def evidence(relative, pattern, detail, all: false)
    content = lines(relative)
    return [] unless content
    matches = []
    content.each_with_index do |line, index|
      next unless pattern.match?(line)
      matches << {"path" => relative, "line" => index + 1, "detail" => detail}
      break unless all
    end
    matches
  rescue RegexpError => error
    @errors << "#{relative}: invalid detector expression: #{error.message}"
    []
  end

  def marker(relative, detail)
    content = lines(relative)
    return [] unless content
    [{"path" => relative, "line" => 1, "detail" => detail}]
  end

  def files(pattern)
    paths = {}
    [[@root, false], [@fixture_root, true]].each do |base, overlay|
      next unless base
      Dir.glob(base.join(pattern).to_s, File::FNM_DOTMATCH).sort.each do |path|
        next unless File.file?(path)
        relative = Pathname(path).relative_path_from(base).to_s
        next if relative.split("/").any? { |part| %w[.git .build DerivedData .remediation-execution].include?(part) }
        paths[relative] = Pathname(path) if overlay || !paths.key?(relative)
      end
    end
    paths.sort.to_h
  rescue SystemCallError => error
    @errors << "glob #{pattern}: #{error.message}"
    {}
  end

  def fixture_files(pattern)
    return {} unless @fixture_root
    Dir.glob(@fixture_root.join(pattern).to_s, File::FNM_DOTMATCH).sort.each_with_object({}) do |path, result|
      next unless File.file?(path)
      relative = Pathname(path).relative_path_from(@fixture_root).to_s
      result[relative] = Pathname(path)
    end
  rescue SystemCallError => error
    @errors << "fixture glob #{pattern}: #{error.message}"
    {}
  end

  def directories
    result = []
    [[@root, false], [@fixture_root, true]].each do |base, _overlay|
      next unless base
      Dir.glob(base.join("**/*").to_s, File::FNM_DOTMATCH).sort.each do |path|
        next unless File.directory?(path)
        relative = Pathname(path).relative_path_from(base).to_s
        next if relative.split("/").any? { |part| %w[.git .build DerivedData .remediation-execution].include?(part) }
        result << relative
      end
    end
    result.uniq.sort
  rescue SystemCallError => error
    @errors << "directory scan: #{error.message}"
    []
  end
end

scanner = RepositoryScanner.new(root, fixture_root)

unless root.join("project.yml").file? && root.join("Packages/RuneScribeArchitecture").directory?
  fail_with(3, "scan root does not contain the Rune Scribe project markers")
end

def unique_evidence(values)
  values.flatten.uniq { |item| [item["path"], item["line"], item["detail"]] }
    .sort_by { |item| [item["path"], item["line"], item["detail"]] }
end

def external_dependency_evidence(scanner)
  evidence = []
  dependency_pattern = /(?:\.package\s*\([^)]*(?:url|path)[^)]*forsetti|github\.com[^\s"']*forsetti|XCRemoteSwiftPackageReference[^\n]*forsetti|(?:url|path|product)\s*:\s*[^\n]*forsetti)/i
  %w[**/Package.swift **/Package.resolved **/project.pbxproj project.yml .gitmodules].each do |glob|
    scanner.files(glob).each_key do |relative|
      evidence.concat(scanner.evidence(relative, dependency_pattern, "external Forsetti dependency reference"))
    end
  end
  scanner.files("**/*.swift").each_key do |relative|
    evidence.concat(scanner.evidence(relative, /^\s*(?:@testable\s+)?import\s+Forsetti[A-Za-z0-9_]*/i, "external Forsetti product import"))
  end
  scanner.directories.each do |relative|
    next if relative.start_with?("docs/")
    next unless File.basename(relative).match?(/forsetti/i)
    evidence << {"path" => relative, "line" => 1, "detail" => "vendored Forsetti directory"}
  end
  fetch_pattern = /(?:git\s+(?:clone|fetch|submodule)|curl|wget|download)[^\n]*forsetti/i
  %w[scripts/**/* .github/**/*].each do |glob|
    scanner.files(glob).each_key do |relative|
      next if %w[scripts/check-forsetti-compliance.sh scripts/check-architecture.sh].include?(relative)
      evidence.concat(scanner.evidence(relative, fetch_pattern, "Forsetti fetch or submodule command"))
    end
  end
  unique_evidence(evidence)
end

PRESENCE_DETECTORS = {
  "FG-004" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Services.swift", /let value: any Sendable/, "registry entry stores a raw provider value"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Services.swift", /func publishService/, "module publishes a service object"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Services.swift", /func resolveService/, "consumer resolves a provider-owned service value"]
  ],
  "FG-005" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/UIModule.swift", /RuneScribeApplicationService.*resolveService|resolveService\(/, "UI resolves the Core application service"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession.swift", /applicationServiceHandle:.*RuneScribeApplicationService/, "UI session retains the Core service handle"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/SerialInboundInputForwarder.swift", /private var service:.*RuneScribeInboundInputService/, "host forwarder retains the inbound provider service"]
  ],
  "FG-006" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Services.swift", /func resolveService/, "lookup returns a provider value instead of a per-call dispatch identity"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession+Commands.swift", /requireApplicationService\(/, "UI command path calls through a retained provider handle"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/SerialInboundInputForwarder.swift", /service\.receive\(/, "host ingress invokes the retained provider directly"]
  ],
  "FG-007" => [
    ["RuneScrib/AppHost/RuneScribeRuntimeComposition.swift", /registerHostService\(/, "host registers raw operational adapters as services"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/QRScannerView.swift", /AVCaptureSession|requestAccess/, "UI owns camera authorization or capture session"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/ContactPicker.swift", /CNContact|CNContactPicker/, "UI receives or extracts Contacts values"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/MessageComposeView.swift", /MFMessageComposeViewController/, "UI owns Messages presentation operations"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RuneScribeFileShareLink.swift", /UIActivityViewController|NSSharingServicePicker/, "UI owns native share operations"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VideoSplashView.swift", /AVAudioSession|UserDefaults/, "UI owns an operational platform side effect"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/CipherLibraryView.swift", /fileImporter|fileExporter/, "UI directly owns file presentation and URLs"]
  ],
  "FG-008" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/CipherLibraryView.swift", /@AppStorage/, "UI persists a setting with AppStorage"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VideoSplashView.swift", /UserDefaults/, "UI reads or writes UserDefaults"]
  ],
  "FG-009" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/UIModule.swift", /dependencies: RuneScribeUIDependencies/, "UI factory captures arbitrary dependencies"],
    ["RuneScrib/AppHost/RuneScribeRuntimeComposition.swift", /OpaqueSharePresentationProvider/, "host injects an operational share closure"]
  ],
  "FG-010" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Module.swift", /protocol RuneScribeModule/, "current module contract exposes only the pre-standard lifecycle surface"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/ModuleManifest.swift", /struct ModuleManifest/, "current manifest lacks the complete standard-port vocabulary"],
    ["RuneScrib/AppHost/RuneScribeRuntimeComposition.swift", /registerFactory/, "host performs module-specific manual registration"]
  ],
  "FG-011" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift", /defaultRole|duplicateRole/, "runtime treats reusable roles as unique activation identity"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Policy.swift", /RuneScribeModuleRoles\.(?:core|ui)/, "policy is hard-coded to concrete Core/UI roles"]
  ],
  "FG-012" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift", /activationPlan\(for eligible/, "activation plan synthesizes dependencies from eligible modules"],
    ["RuneScrib/AppHost/RuneScribeRuntimeComposition.swift", /RuneScribeCoreModuleBootstrap|RuneScribeUIModuleBootstrap/, "host manually wires a fixed module graph"]
  ],
  "FG-013" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift", /stopActivatedModules\(markFailed: true\)/, "activation failure stops every activated module and fails the runtime"]
  ],
  "FG-014" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift", /private func eligibleRegistrations/, "eligibility is evaluated by the start-time path only"]
  ],
  "FG-016" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/UIModule.swift", /Bundle\.module\.url|ApplicationResourceLocator/, "UI resolves a concrete resource URL"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/OpaqueSharePresentation.swift", /URL|url/, "share presentation carries a concrete provider URL"]
  ],
  "FG-017" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession+Commands.swift", /UUID\(\)|Date\(\)/, "UI stamps operational ingress metadata"]
  ],
  "FG-018" => [
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Events.swift", /payload: Data/, "event bus exposes opaque Data without declared subscription schema"],
    ["Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Messages.swift", /payload: Data/, "directed messages use opaque Data without durable delivery semantics"]
  ]
}.freeze

def one_ui_module(scanner)
  manifests = scanner.files("Packages/RuneScribeArchitecture/Sources/**/Resources/module-manifest.json")
  ui = []
  manifests.each_key do |relative|
    content = scanner.lines(relative)
    next unless content
    begin
      value = JSON.parse(content.join)
      ui << relative if value["moduleType"] == "ui"
    rescue JSON::ParserError => error
      scanner.errors << "#{relative}: invalid module manifest JSON: #{error.message}"
    end
  end
  evidence = ui.flat_map { |relative| scanner.evidence(relative, /"moduleType"\s*:\s*"ui"/, "shipping UI module manifest") }

  compiled_ui = []
  root_contributions = []
  scanner.files("Packages/RuneScribeArchitecture/Sources/*Module/**/*.swift").each_key do |relative|
    compiled_ui.concat(scanner.evidence(relative, /kind:\s*\.ui\b/, "compiled shipping UI descriptor"))
    root_contributions.concat(scanner.evidence(relative, /RootViewContribution\s*\(/, "runtime UI root contribution"))
  end
  host_registrations = scanner.evidence(
    "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift",
    /runtime\.register\([^\n]*RuneScribeUIModuleBootstrap\.factory/,
    "host registers the single runtime UI factory"
  )
  evidence.concat(compiled_ui)
  evidence.concat(root_contributions)
  evidence.concat(host_registrations)

  counts = [ui.length, compiled_ui.length, root_contributions.length, host_registrations.length]
  status = counts == [1, 1, 1, 1] ? "pass" : "violation"
  if status == "violation"
    evidence.concat(scanner.marker("project.yml", "UI manifest/descriptor/contribution/factory counts are #{counts.join('/')} instead of 1/1/1/1"))
  end
  [status, unique_evidence(evidence)]
end

def module_import_edges(scanner)
  evidence = []
  implementation_files = scanner.files("Packages/RuneScribeArchitecture/Sources/*Module/**/*.swift")
  implementation_targets = implementation_files.keys.map do |relative|
    relative.split("/")[3]
  end.compact.uniq.sort

  implementation_files.each_key do |relative|
    owner = relative.split("/")[3]
    content = scanner.lines(relative)
    next unless content
    content.each_with_index do |line, index|
      match = line.match(/^\s*(?:@testable\s+)?import\s+([A-Za-z0-9_]+Module)\b/)
      next unless match
      imported = match[1]
      next unless implementation_targets.include?(imported) && imported != owner
      evidence << {
        "path" => relative,
        "line" => index + 1,
        "detail" => "#{owner} imports peer implementation target #{imported}"
      }
    end
  end
  if evidence.empty?
    evidence = scanner.marker(
      "Packages/RuneScribeArchitecture/Package.swift",
      "all shipping *Module implementation sources were scanned with no peer implementation import edge: #{implementation_targets.join(', ')}"
    )
  end
  [evidence.first["detail"].include?("scanned with no") ? "pass" : "violation", unique_evidence(evidence)]
end

def documentation_authority(scanner)
  requirements = [
    ["docs/architecture/FORSETTI_CONTROLLING_POLICY.md", /^# Rune Scribe Controlling Forsetti Policy$/, "canonical controlling policy title"],
    ["docs/architecture/FORSETTI_CONTROLLING_POLICY.md", /single repository authority/, "policy declares single authority"],
    ["docs/architecture/FORSETTI_CONTROLLING_POLICY.md", /Documentation alone cannot close a compliance finding/, "policy prohibits paper-only closure"],
    ["docs/architecture/FORSETTI_CONTROLLING_POLICY.md", /^7\. General conventions\.$/, "source precedence includes general conventions last"],
    ["docs/architecture/FORSETTI_CONTROLLING_POLICY.md", /must not ship external Forsetti code/, "policy permanently prohibits external shipping code"],
    ["docs/architecture/ForsettiSupersessionIndex.md", /^# Forsetti Architecture Supersession Index$/, "supersession index is present"],
    ["docs/architecture/ForsettiSupersessionIndex.md", /^## No paper compliance$/, "supersession index rejects paper compliance"],
    ["README.md", /FORSETTI_CONTROLLING_POLICY\.md/, "repository README links the controlling policy"],
    ["docs/architecture/decisions/ADR-RS-001-module-packaging-and-target-graph.md", /Status:\*\* Superseded by the controlling Forsetti policy/, "conflicting dependency ADR is superseded"],
    ["docs/architecture/ForsettiCompliance.md", /Superseded architecture assessment/, "old compliance assessment is historical"],
    ["docs/architecture/ContractsAndCapabilities.md", /historical description/, "old contract description is historical"],
    ["docs/architecture/ModuleGraph.md", /Superseded architecture snapshot/, "old module graph is historical"],
    ["docs/architecture/RoadmapAlignment.md", /Superseded dependency sequencing/, "old dependency sequence is superseded"],
    ["docs/architecture/MigrationDecisions.md", /Historical decision record/, "old migration conclusions are historical"]
  ]
  pass_evidence = []
  violations = []
  requirements.each do |relative, pattern, detail|
    matches = scanner.evidence(relative, pattern, detail)
    if matches.empty?
      marker = scanner.marker(relative, "required authority marker is missing: #{detail}")
      marker = [{"path" => relative, "line" => 1, "detail" => "required authority document is missing: #{detail}"}] if marker.empty?
      violations.concat(marker)
    else
      pass_evidence.concat(matches)
    end
  end

  policy_path = scanner.actual_path("docs/architecture/FORSETTI_CONTROLLING_POLICY.md")
  if policy_path.file?
    actual_hash = Digest::SHA256.file(policy_path).hexdigest
    if actual_hash == CONTROLLING_POLICY_SHA256
      pass_evidence << {"path" => "docs/architecture/FORSETTI_CONTROLLING_POLICY.md", "line" => 1, "detail" => "controlling policy hash is locked to #{CONTROLLING_POLICY_SHA256}"}
    else
      violations << {"path" => "docs/architecture/FORSETTI_CONTROLLING_POLICY.md", "line" => 1, "detail" => "controlling policy hash drifted from #{CONTROLLING_POLICY_SHA256}"}
    end
  end

  index_text = scanner.lines("docs/architecture/ForsettiSupersessionIndex.md")&.join.to_s
  hash_locked_paths = []
  HASH_LOCKED_PRODUCT_DOCUMENTS.each do |relative, expected_hash|
    path = scanner.actual_path(relative)
    actual_hash = path.file? ? Digest::SHA256.file(path).hexdigest : nil
    index_is_narrow = index_text.include?(relative) &&
      index_text.include?(expected_hash) &&
      index_text.include?("No statement inside") &&
      index_text.include?("Any content change invalidates this exception")
    if actual_hash == expected_hash && index_is_narrow
      hash_locked_paths << relative
      pass_evidence << {"path" => relative, "line" => 1, "detail" => "historical product input matches its narrow hash lock #{expected_hash}"}
    else
      violations << {"path" => relative, "line" => 1, "detail" => "historical product input or its narrow supersession hash lock is invalid"}
    end
  rescue SystemCallError => error
    scanner.errors << "#{relative}: hash detector failed: #{error.message}"
  end

  scanner.files("docs/architecture/**/*.md").each_key do |relative|
    next if relative == "docs/architecture/FORSETTI_CONTROLLING_POLICY.md"
    links = scanner.evidence(relative, /FORSETTI_CONTROLLING_POLICY\.md/, "architecture document links the controlling policy")
    if links.empty?
      marker = scanner.marker(relative, "architecture document does not link the controlling policy")
      violations.concat(marker.empty? ? [{"path" => relative, "line" => 1, "detail" => "architecture document is unreadable or missing"}] : marker)
    else
      pass_evidence.concat(links)
    end
  end

  contradiction_patterns = [
    /future.{0,100}(?:external|official)\s+Forsetti.{0,100}(?:permitted|allowed|required)/i,
    /(?:allow|permit|require).{0,100}(?:external|official)\s+Forsetti\s+(?:dependency|package|products?)/i,
    /(?:lookup-time|lookup|resolution)\s+authorization.{0,80}(?:is|equals|provides).{0,40}(?:full\s+)?runtime\s+mediation/i
  ]
  scanner.files("docs/**/*.md").each_key do |relative|
    next if hash_locked_paths.include?(relative)
    content = scanner.lines(relative)
    next unless content
    text = content.join
    next unless contradiction_patterns.any? { |pattern| pattern.match?(text) }
    content.each_with_index do |line, index|
      next unless contradiction_patterns.any? { |pattern| pattern.match?(line) }
      violations << {"path" => relative, "line" => index + 1, "detail" => "document contradicts the controlling policy"}
      break
    end
  end

  governance_files = scanner.files(".github/**/*").merge(scanner.files("**/AGENTS.md"))
  governance_violations_before = violations.length
  governance_files.each_key do |relative|
    next unless %w[.md .yml .yaml].include?(File.extname(relative)) || File.basename(relative) == "AGENTS.md"
    content = scanner.lines(relative)
    next unless content
    content.each_with_index do |line, index|
      next unless contradiction_patterns.any? { |pattern| pattern.match?(line) }
      violations << {"path" => relative, "line" => index + 1, "detail" => "repository template or instruction contradicts the controlling policy"}
      break
    end
  end
  if violations.length == governance_violations_before
    pass_evidence.concat(scanner.marker(".github/PULL_REQUEST_TEMPLATE.md", "repository templates and agent-instruction paths were scanned for authority contradictions"))
  end

  violations = unique_evidence(violations)
  [violations.empty? ? "pass" : "violation", violations.empty? ? unique_evidence(pass_evidence) : violations]
end

results = rules.map do |rule|
  id = rule.fetch("id")
  status = nil
  evidence = []
  evidence_kind = nil

  case id
  when "FG-001"
    evidence = external_dependency_evidence(scanner)
    if evidence.empty?
      status = "pass"
      evidence = scanner.marker("project.yml", "dependency, import, vendor, and fetch surfaces were scanned with no external Forsetti edge")
      evidence_kind = "detector-proof"
    else
      status = "violation"
      evidence_kind = "detected-source-anchor"
    end
  when "FG-002"
    status, evidence = one_ui_module(scanner)
    evidence_kind = status == "pass" ? "detector-proof" : "detected-source-anchor"
  when "FG-003"
    status, evidence = module_import_edges(scanner)
    evidence_kind = status == "pass" ? "detector-proof" : "detected-source-anchor"
  when "FG-015"
    registry_hits = []
    scanner.files("Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/**/*.swift").each_key do |relative|
      registry_hits.concat(scanner.evidence(relative, /(?:actor|class|struct)\s+\w*ContributionRegistry\b/, "keyed contribution registry declaration"))
    end
    if registry_hits.empty?
      status = "violation"
      evidence = scanner.marker("Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift", "runtime source scan found no keyed contribution registry")
      evidence_kind = "detected-absence-anchor"
    else
      status = "not-evaluated"
      evidence = registry_hits
      evidence_kind = "insufficient-detector-evidence"
    end
  when "FG-019"
    status = "pending-enforcement"
    evidence = scanner.evidence("scripts/forsetti-compliance-rules.json", /"id": "FG-019"/, "full FG-001 through FG-018 negative-mutation coverage is deferred to P11")
    evidence = [{"path" => "scripts/forsetti-compliance-rules.json", "line" => 1, "detail" => "full negative-mutation enforcement is deferred to P11"}] if evidence.empty?
    evidence_kind = "detector-pending"
  when "FG-020"
    status, evidence = documentation_authority(scanner)
    evidence_kind = status == "pass" ? "detector-proof" : "detected-source-anchor"
  else
    detectors = PRESENCE_DETECTORS.fetch(id)
    detectors.each do |relative, pattern, detail|
      evidence.concat(scanner.evidence(relative, pattern, detail))
    end
    evidence = unique_evidence(evidence)
    if evidence.empty?
      status = "not-evaluated"
      evidence = scanner.marker(rule.fetch("evidenceAnchors").first, "no violation anchor remains, but this report-only detector cannot prove compliance")
      evidence = [{"path" => rule.fetch("evidenceAnchors").first, "line" => 1, "detail" => "detector has insufficient evidence"}] if evidence.empty?
      evidence_kind = "insufficient-detector-evidence"
    else
      status = "violation"
      evidence_kind = "detected-source-anchor"
    end
  end

  evidence = unique_evidence(evidence)
  if status == "pass" && (rule.dig("enforcement", "detectorCoverage") != "complete" || evidence.empty?)
    scanner.errors << "#{id}: a pass requires complete detector coverage and concrete evidence"
  end
  if evidence.empty?
    scanner.errors << "#{id}: result has no source path and line evidence"
  end

  {
    "id" => id,
    "name" => rule.fetch("name"),
    "requirement" => rule.fetch("requirement"),
    "status" => status,
    "expectedP01Status" => rule.fetch("expectedP01Status"),
    "matchesP01Baseline" => status == rule.fetch("expectedP01Status"),
    "owningPhases" => rule.fetch("owningPhases"),
    "findingIDs" => rule.fetch("findingIDs"),
    "enforcement" => rule.fetch("enforcement"),
    "remediationOwner" => rule.fetch("remediationOwner"),
    "waiverStatus" => rule.fetch("waiverStatus"),
    "evidenceKind" => evidence_kind,
    "evidence" => evidence
  }
end

unless scanner.errors.empty?
  fail_with(3, "detector failure: #{scanner.errors.uniq.sort.join('; ')}")
end

counts = Hash.new(0)
results.each { |result| counts[result["status"]] += 1 }
report = {
  "schemaVersion" => "1.0",
  "mode" => "report-only",
  "banner" => BANNER,
  "overallStatus" => "report-only",
  "ruleOrder" => CANONICAL_RULES.map(&:first),
  "summary" => {
    "total" => results.length,
    "pass" => counts["pass"],
    "violation" => counts["violation"],
    "pendingEnforcement" => counts["pending-enforcement"],
    "notEvaluated" => counts["not-evaluated"]
  },
  "rules" => results
}

json = JSON.pretty_generate(report) + "\n"
markdown_lines = [
  BANNER,
  "",
  "Mode: `report-only`. Architectural violations are findings, not a successful compliance verdict.",
  "",
  "| Rule | Status | Findings | Owner | Waiver |",
  "|---|---|---|---|---|"
]
results.each do |result|
  findings = result["findingIDs"].empty? ? "—" : result["findingIDs"].join(", ")
  markdown_lines << "| #{result['id']} | #{result['status']} | #{findings} | #{result['remediationOwner']} | #{result['waiverStatus']} |"
end
markdown_lines.concat(["", "## Evidence", ""])
results.each do |result|
  markdown_lines << "### #{result['id']} — #{result['name']}"
  markdown_lines << ""
  markdown_lines << "Status: `#{result['status']}`. Enforcement: `#{result.dig('enforcement', 'mode')}`."
  markdown_lines << ""
  result["evidence"].each do |item|
    detail = item["detail"].to_s.gsub("|", "\\|").gsub("\n", " ")
    markdown_lines << "- `#{item['path']}:#{item['line']}` — #{detail}"
  end
  markdown_lines << ""
end
markdown = markdown_lines.join("\n") + "\n"

begin
  [[options[:json_output], json], [options[:markdown_output], markdown]].each do |path, content|
    next unless path
    destination = Pathname(path).expand_path
    FileUtils.mkdir_p(destination.dirname)
    destination.write(content)
  end
rescue SystemCallError => error
  fail_with(4, "cannot write report output: #{error.message}")
end

puts BANNER
puts "Mode: report-only"
puts "Rules: #{results.length}; pass=#{counts['pass']}; violation=#{counts['violation']}; pending-enforcement=#{counts['pending-enforcement']}; not-evaluated=#{counts['not-evaluated']}"
results.each do |result|
  anchor = result.fetch("evidence").first
  puts "#{result['id']} #{result['status']} #{anchor['path']}:#{anchor['line']}"
end
exit 0
RUBY
