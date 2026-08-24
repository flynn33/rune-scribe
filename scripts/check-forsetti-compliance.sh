#!/bin/bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"

exec /usr/bin/ruby - "$repository_root" "$script_dir/forsetti-compliance-rules.json" "$@" <<'RUBY'
# encoding: UTF-8
require "fileutils"
require "digest"
require "json"
require "open3"
require "pathname"
require "set"

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
  "docs/product-roadmap/Rune-Scribe-Codex-Current-App-Delta-and-Implementation-Roadmap-v1.0.md" => "884ad563f7849ebda8326bc742493ce67fb89cfacc14b39e56c792c4f7c52db4",
  "docs/product-roadmap/Rune-Scribe-Codex-Roadmap-Remediation-Amendment-v1.1.md" => "2b6ce54c50538419d324692ebfeec1bb29de46add9f354368d39169d6f74ed40"
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
    @swift_findings = []
  end

  def attach_swift_findings(findings)
    @swift_findings = findings
  end

  def swift_finding_evidence(rule_id)
    @swift_findings.each_with_object([]) do |finding, evidence|
      next unless finding["ruleID"] == rule_id
      evidence << {
        "path" => finding.fetch("path"),
        "line" => finding.fetch("line"),
        "detail" => finding.fetch("detail")
      }
    end
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

  def swift_code_lines(relative)
    @swift_code_lines ||= {}
    return @swift_code_lines[relative] if @swift_code_lines.key?(relative)
    content = lines(relative)
    return @swift_code_lines[relative] = nil unless content

    source = content.join
    sanitized = +""
    index = 0
    contexts = [{kind: :code}]
    regex_closer_exists = lambda do |start_index|
      cursor = start_index + 1
      escaped = false
      while cursor < source.bytesize
        value = source.byteslice(cursor, 1)
        break if value == "\n"
        if escaped
          escaped = false
        elsif value == "\\"
          escaped = true
        elsif value == "/"
          break true
        end
        cursor += 1
      end
    end
    literal_at = lambda do |start_index|
      hash_count = 0
      hash_count += 1 while source.byteslice(start_index + hash_count, 1) == "#"
      marker_index = start_index + hash_count
      quote_width = if source.byteslice(marker_index, 3) == '"""'
        3
      elsif source.byteslice(marker_index, 1) == '"'
        1
      end
      if quote_width
        {
          kind: :literal,
          opening_width: hash_count + quote_width,
          closer: ('"' * quote_width) + ('#' * hash_count),
          interpolation: "\\" + ('#' * hash_count) + "(",
          escaped: hash_count.zero? && quote_width == 1
        }
      elsif source.byteslice(marker_index, 1) == "/" &&
          (hash_count.positive? || (
            source.byteslice(marker_index + 1, 1)&.match?(/\S/) &&
            regex_closer_exists.call(marker_index)
          ))
        {
          kind: :literal,
          opening_width: hash_count + 1,
          closer: "/" + ('#' * hash_count),
          interpolation: "\\" + ('#' * hash_count) + "(",
          escaped: hash_count.zero?
        }
      end
    end

    while index < source.bytesize
      context = contexts.last
      pair = source.byteslice(index, 2)
      byte = source.byteslice(index, 1)
      if context[:kind] == :line_comment
        if byte == "\n"
          sanitized << "\n"
          contexts.pop
        else
          sanitized << " "
        end
        index += 1
        next
      end
      if context[:kind] == :block_comment
        if pair == "/*"
          sanitized << "  "
          context[:depth] += 1
          index += 2
        elsif pair == "*/"
          sanitized << "  "
          context[:depth] -= 1
          contexts.pop if context[:depth].zero?
          index += 2
        else
          sanitized << (byte == "\n" ? "\n" : " ")
          index += 1
        end
        next
      end
      if context[:kind] == :literal
        if source.byteslice(index, context[:closer].bytesize) == context[:closer]
          sanitized << (" " * context[:closer].bytesize)
          index += context[:closer].bytesize
          contexts.pop
        elsif source.byteslice(index, context[:interpolation].bytesize) == context[:interpolation]
          sanitized << (" " * context[:interpolation].bytesize)
          index += context[:interpolation].bytesize
          contexts << {kind: :interpolation, depth: 1}
        elsif context[:escaped] && byte == "\\"
          width = [2, source.bytesize - index].min
          sanitized << (" " * width)
          index += width
        else
          sanitized << (byte == "\n" ? "\n" : " ")
          index += 1
        end
        next
      end

      if context[:kind] == :interpolation
        if byte == "("
          context[:depth] += 1
          sanitized << byte
          index += 1
          next
        elsif byte == ")"
          context[:depth] -= 1
          if context[:depth].zero?
            sanitized << " "
            contexts.pop
          else
            sanitized << byte
          end
          index += 1
          next
        end
      end

      if pair == "//"
        sanitized << "  "
        index += 2
        contexts << {kind: :line_comment}
        next
      end
      if pair == "/*"
        sanitized << "  "
        index += 2
        contexts << {kind: :block_comment, depth: 1}
        next
      end

      literal = literal_at.call(index)
      if literal
        sanitized << (" " * literal[:opening_width])
        index += literal[:opening_width]
        contexts << literal
        next
      end

      sanitized << byte
      index += 1
    end
    @swift_code_lines[relative] = sanitized.lines
  rescue SystemCallError, ArgumentError => error
    @errors << "#{relative}: Swift lexical scan failed: #{error.message}"
    @swift_code_lines[relative] = nil
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

  def swift_code_evidence(relative, pattern, detail, all: false)
    content = swift_code_lines(relative)
    return [] unless content
    matches = []
    content.each_with_index do |line, index|
      next unless pattern.match?(line)
      matches << {"path" => relative, "line" => index + 1, "detail" => detail}
      break unless all
    end
    matches
  rescue RegexpError => error
    @errors << "#{relative}: invalid Swift detector expression: #{error.message}"
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

def run_swift_compliance_scan(root, fixture_root)
  source = root.join("scripts/swift-compliance-scanner.swift")
  return [[], ["Swift compliance scanner is missing: #{source}"]] unless source.file?

  swiftc_output, swiftc_error, swiftc_status = Open3.capture3(
    "/usr/bin/xcrun",
    "--find",
    "swiftc"
  )
  unless swiftc_status.success?
    diagnostic = swiftc_error.strip.empty? ? swiftc_output.strip : swiftc_error.strip
    return [[], ["cannot resolve the Xcode Swift toolchain: #{diagnostic}"]]
  end

  swiftc = Pathname(swiftc_output.strip)
  host_libraries = swiftc.dirname.parent.join("lib/swift/host")
  unless host_libraries.directory?
    return [[], ["Xcode Swift host libraries are missing: #{host_libraries}"]]
  end

  command = [
    "/usr/bin/xcrun",
    "swift",
    "-I", host_libraries.to_s,
    "-L", host_libraries.to_s,
    "-lSwiftSyntax",
    "-lSwiftParser",
    "-lSwiftParserDiagnostics",
    "-lSwiftDiagnostics",
    source.to_s,
    "--scan-root", root.to_s
  ]
  command.concat(["--fixture-root", fixture_root.to_s]) if fixture_root
  output, error, status = Open3.capture3(*command)
  unless status.success?
    diagnostic = error.strip.empty? ? output.strip : error.strip
    return [[], ["Swift compliance scanner failed with exit #{status.exitstatus}: #{diagnostic}"]]
  end

  begin
    report = JSON.parse(output)
  rescue JSON::ParserError => parse_error
    return [[], ["Swift compliance scanner returned invalid JSON: #{parse_error.message}"]]
  end
  unless report.is_a?(Hash) && report["schemaVersion"] == "1.0"
    return [[], ["Swift compliance scanner schemaVersion must be 1.0"]]
  end
  findings = report["findings"]
  errors = report["errors"]
  metadata = report["metadata"]
  unless findings.is_a?(Array) && errors.is_a?(Array) && errors.all? { |item| item.is_a?(String) }
    return [[], ["Swift compliance scanner findings/errors payload is malformed"]]
  end
  expected_scope = "conservative fail-closed source-tree symbol and type-flow analysis"
  unless metadata.is_a?(Hash) && metadata["engine"] == "SwiftSyntax/SwiftParser" &&
      metadata["analysisScope"] == expected_scope &&
      metadata["scannedSourceCount"].is_a?(Integer) && metadata["scannedSourceCount"].positive? &&
      metadata["overlaySourceCount"].is_a?(Integer) && metadata["overlaySourceCount"] >= 0 &&
      metadata["parseFailureCount"].is_a?(Integer) && metadata["parseFailureCount"] >= 0
    return [[], ["Swift compliance scanner metadata is malformed or does not declare fail-closed source-tree analysis"]]
  end

  finding_errors = []
  findings.each_with_index do |finding, index|
    valid = finding.is_a?(Hash) &&
      %w[FG-004 FG-005 FG-006 FG-007 FG-009 FG-016].include?(finding["ruleID"]) &&
      finding["category"].is_a?(String) && !finding["category"].empty? &&
      finding["path"].is_a?(String) && !finding["path"].empty? &&
      !Pathname(finding["path"]).absolute? &&
      !finding["path"].split("/").include?("..") &&
      finding["line"].is_a?(Integer) && finding["line"].positive? &&
      finding["detail"].is_a?(String) && !finding["detail"].empty?
    finding_errors << "Swift compliance scanner finding #{index} is malformed" unless valid
  end
  [findings, errors.map { |item| "Swift compliance scanner: #{item}" } + finding_errors]
rescue SystemCallError, ArgumentError => error
  [[], ["Swift compliance scanner invocation failed: #{error.message}"]]
end

scanner = RepositoryScanner.new(root, fixture_root)

unless root.join("project.yml").file? && root.join("Packages/RuneScribeArchitecture").directory?
  fail_with(3, "scan root does not contain the Rune Scribe project markers")
end

swift_findings, swift_scan_errors = run_swift_compliance_scan(root, fixture_root)
scanner.attach_swift_findings(swift_findings)
scanner.errors.concat(swift_scan_errors)

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

def shipping_swift_paths(scanner)
  scanner.files("Packages/RuneScribeArchitecture/Sources/**/*.swift")
    .merge(scanner.files("RuneScrib/**/*.swift"))
    .keys
    .sort
end

def peer_service_consumer_paths(scanner)
  excluded_prefixes = [
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/",
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/",
    "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/"
  ]
  package_consumers = scanner.files(
    "Packages/RuneScribeArchitecture/Sources/**/*.swift"
  ).keys.reject do |relative|
    excluded_prefixes.any? { |prefix| relative.start_with?(prefix) }
  end
  (package_consumers + scanner.files("RuneScrib/**/*.swift").keys).uniq.sort
end

def swift_type_usage_evidence(scanner, relative, type_name, detail)
  lines = scanner.swift_code_lines(relative)
  return [] unless lines
  escaped = Regexp.escape(type_name)
  qualified = "(?:[A-Za-z_][A-Za-z0-9_]*\\s*\\.\\s*)?#{escaped}"
  contexts = [
    /:\s*(?:any\s+|some\s+)?[^=\{;]*\b#{qualified}\b/,
    /->\s*(?:any\s+|some\s+)?[^\{;]*\b#{qualified}\b/,
    /\b(?:as[!?]?|is)\s+(?:any\s+|some\s+)?\b#{qualified}\b/,
    /\b(?:any|some)\s+\b#{qualified}\b/,
    /\b#{qualified}\s*(?:\(|\.|\.self\b)/,
    /\btypealias\s+[A-Za-z_][A-Za-z0-9_]*[^=]*=\s*[^;\{]*\b#{qualified}\b/
  ]
  evidence = []
  lines.each_index do |index|
    next unless lines[index].match?(/\b#{escaped}\b/)
    first = [0, index - 4].max
    window = lines[first, 9].to_a.join(" ").gsub(/\s+/, " ")
    next unless contexts.any? { |pattern| window.match?(pattern) }
    evidence << {"path" => relative, "line" => index + 1, "detail" => detail}
  end
  unique_evidence(evidence)
end

def transitive_peer_service_types(scanner, root_type)
  declarations = []
  clean_declaration_line = lambda do |line|
    line.sub(%r{//.*$}, " ").gsub(%r{/\*.*?\*/}, " ").strip
  end
  type_expression_complete = lambda do |expression, following_line|
    value = expression.sub(/\bwhere\b.*$/, "").strip
    next false if value.empty?
    delimiter_open = value.count("(") - value.count(")") > 0 ||
      value.count("[") - value.count("]") > 0 ||
      value.count("<") - value.count(">") > 0
    trailing_continuation = value.match?(/(?:->|[,&|\.\(\[<])\s*\z/) ||
      value.match?(/\A(?:any|some|borrowing|consuming)\z/)
    leading_continuation = following_line&.match?(/\A(?:\.|&|,|\||->)/) || false
    !delimiter_open && !trailing_continuation && !leading_continuation
  end

  shipping_swift_paths(scanner).each do |relative|
    lines = scanner.swift_code_lines(relative)
    next unless lines
    lines.each_index do |index|
      declaration_line = clean_declaration_line.call(lines[index])
      alias_match = declaration_line.match(
        /\A(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|public|package|internal|fileprivate|private|nonisolated)\s+)*typealias\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*<[^=]*>)?\s*=\s*(.*)\z/
      )
      if alias_match
        parts = [alias_match[2]]
        cursor = index
        loop do
          expression = parts.join(" ").gsub(/\s+/, " ").strip
          following = cursor + 1 < lines.length ? clean_declaration_line.call(lines[cursor + 1]) : nil
          break if type_expression_complete.call(expression, following)
          break if cursor - index >= 15 || cursor + 1 >= lines.length
          cursor += 1
          parts << clean_declaration_line.call(lines[cursor])
        end
        relationships = parts.join(" ").gsub(/\s+/, " ").sub(/\bwhere\b.*$/, "").strip
        declarations << {
          kind: "typealias",
          name: alias_match[1],
          relationships: relationships,
          path: relative,
          line: index + 1
        } unless relationships.empty?
      end

      protocol_match = declaration_line.match(
        /\A(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|public|package|internal|fileprivate|private|nonisolated|actor|class)\s+)*protocol\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*<[^>]*>)?\s*(.*)\z/
      )
      if protocol_match
        parts = [protocol_match[2]]
        cursor = index
        while !parts.join(" ").include?("{") && cursor - index < 15 && cursor + 1 < lines.length
          cursor += 1
          parts << clean_declaration_line.call(lines[cursor])
        end
        header = parts.join(" ").gsub(/\s+/, " ").split("{", 2).first.to_s.strip
        inheritance_match = header.match(/\A:\s*(.+)\z/)
        relationships = inheritance_match && inheritance_match[1].sub(/\bwhere\b.*$/, "").strip
        declarations << {
          kind: "protocol refinement",
          name: protocol_match[1],
          relationships: relationships,
          path: relative,
          line: index + 1
        } if relationships && !relationships.empty?
      end
    end
  end

  names = Set.new([root_type])
  discovered = []
  loop do
    added = false
    declarations.each do |declaration|
      next if names.include?(declaration[:name])
      next unless names.any? do |name|
        declaration[:relationships].match?(/\b#{Regexp.escape(name)}\b/)
      end
      names << declaration[:name]
      discovered << declaration
      added = true
    end
    break unless added
  end

  names.delete(root_type)
  [names.to_a.sort, discovered]
end

def concealed_peer_service_evidence(scanner, paths, root_type, detail)
  concealed_types, declarations = transitive_peer_service_types(scanner, root_type)
  return [] if concealed_types.empty?

  evidence = []
  paths.each do |relative|
    concealed_types.each do |type_name|
      evidence.concat(
        swift_type_usage_evidence(
          scanner,
          relative,
          type_name,
          "#{detail} through transitive alias or protocol-refinement type #{type_name}"
        )
      )
    end
  end
  return [] if evidence.empty?

  declaration_evidence = declarations.map do |declaration|
    {
      "path" => declaration[:path],
      "line" => declaration[:line],
      "detail" => "#{declaration[:kind]} #{declaration[:name]} participates in the #{root_type} concealment chain"
    }
  end
  unique_evidence(evidence + declaration_evidence)
end

def provider_returning_symbol_evidence(scanner, consumer_paths, root_type)
  concealed_types, = transitive_peer_service_types(scanner, root_type)
  provider_types = Set.new(concealed_types + [root_type])
  declarations = []
  shipping_swift_paths(scanner).each do |relative|
    lines = scanner.swift_code_lines(relative)
    next unless lines
    lines.each_index do |index|
      line = lines[index].strip
      next unless line.match?(/\b(?:public|package)\b/)
      match = line.match(
        /\A(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|public|package|internal|nonisolated|static|class|final|override)\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)\b/
      )
      next unless match
      parts = [line]
      cursor = index
      while !parts.join(" ").include?("{") && cursor - index < 15 && cursor + 1 < lines.length
        cursor += 1
        parts << lines[cursor].strip
      end
      signature = parts.join(" ").gsub(/\s+/, " ")
      return_type = signature.split("->", 2)[1]&.split("{", 2)&.first&.sub(/\bwhere\b.*$/, "")
      returns_provider = return_type && provider_types.any? do |type_name|
        return_type.match?(/\b#{Regexp.escape(type_name)}\b/)
      end
      next unless returns_provider
      declarations << {
        name: match[1],
        path: relative,
        line: index + 1,
        return_type: return_type.strip
      }
    end
  end
  return [] if declarations.empty?

  evidence = []
  consumer_paths.each do |relative|
    declarations.each do |declaration|
      evidence.concat(
        scanner.swift_code_evidence(
          relative,
          /\b#{Regexp.escape(declaration[:name])}\s*\(/,
          "consumer invokes #{declaration[:name]}, which returns concealed provider type #{declaration[:return_type]}",
          all: true
        )
      )
    end
  end
  return [] if evidence.empty?

  evidence + declarations.map do |declaration|
    {
      "path" => declaration[:path],
      "line" => declaration[:line],
      "detail" => "provider-returning symbol #{declaration[:name]} exposes #{declaration[:return_type]}"
    }
  end
end

def swift_owner_names(lines)
  owners = Array.new(lines.length)
  stack = []
  pending_owner = nil
  depth = 0
  lines.each_with_index do |line, index|
    owners[index] = stack.last && stack.last[:name]
    declaration = line.match(
      /\b(?:actor|class|enum|struct|extension)\s+([A-Za-z_][A-Za-z0-9_]*)\b/
    )
    pending_owner = declaration[1] if declaration
    openings = line.count("{")
    closings = line.count("}")
    if pending_owner && openings.positive?
      stack << {name: pending_owner, depth: depth + openings}
      pending_owner = nil
    end
    depth += openings - closings
    stack.pop while stack.any? && stack.last[:depth] > depth
  end
  owners
end

def direct_core_operation_evidence(scanner, consumer_paths, root_type)
  concealed_types, = transitive_peer_service_types(scanner, root_type)
  provider_types = Set.new(concealed_types + [root_type])
  declarations = []
  allowed_bootstrap_operations = Set.new([
    "RuneScribeCoreModuleBootstrap.factory",
    "RuneScribeCoreModuleBootstrap.manifest",
    "RuneScribeCoreModuleBootstrap.manifestData"
  ])
  scanner.files(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/**/*.swift"
  ).each_key do |relative|
    lines = scanner.swift_code_lines(relative)
    next unless lines
    owners = swift_owner_names(lines)
    lines.each_index do |index|
      next unless lines[index].match?(/\b(?:public|package)\b/)
      parts = []
      cursor = index
      while cursor < lines.length && cursor - index < 20
        parts << lines[cursor].strip
        break if parts.join(" ").include?("{")
        cursor += 1
      end
      declaration = parts.join(" ").gsub(/\s+/, " ")
      owner = owners[index]

      function = declaration.match(
        /\b(?:public|package)\b.*?\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\b(.*?)(?:\{|\z)/
      )
      if function
        name = function[1]
        prefix = declaration.split(/\bfunc\b/, 2).first
        type_operation = prefix.match?(/\b(?:static|class)\b/)
        return_type = declaration.split("->", 2)[1]&.split("{", 2)&.first&.sub(/\bwhere\b.*$/, "")
        returns_provider = return_type && provider_types.any? do |type_name|
          return_type.match?(/\b#{Regexp.escape(type_name)}\b/)
        end
        qualified = owner ? "#{owner}.#{name}" : name
        next if allowed_bootstrap_operations.include?(qualified)
        if owner.nil? || type_operation || returns_provider
          declarations << {
            owner: owner,
            name: name,
            path: relative,
            line: index + 1,
            detail: returns_provider ? "returns a concrete Core provider" : "is a public Core operation"
          }
        end
        next
      end

      property = declaration.match(
        /\b(?:public|package)\b.*?\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^\{=]+)/
      )
      next unless property
      name = property[1]
      property_type = property[2].sub(/\bwhere\b.*$/, "")
      returns_provider = provider_types.any? do |type_name|
        property_type.match?(/\b#{Regexp.escape(type_name)}\b/)
      end
      prefix = declaration.split(/\b(?:let|var)\b/, 2).first
      next unless returns_provider && (owner.nil? || prefix.match?(/\b(?:static|class)\b/))
      declarations << {
        owner: owner,
        name: name,
        path: relative,
        line: index + 1,
        detail: "returns a concrete Core provider"
      }
    end
  end
  declarations.uniq! { |item| [item[:owner], item[:name], item[:path], item[:line]] }
  return [] if declarations.empty?

  evidence = []
  consumer_paths.each do |relative|
    declarations.each do |declaration|
      pattern = if declaration[:owner]
        /\b#{Regexp.escape(declaration[:owner])}\s*\.\s*#{Regexp.escape(declaration[:name])}\b/
      else
        /\b#{Regexp.escape(declaration[:name])}\s*\(/
      end
      evidence.concat(
        scanner.swift_code_evidence(
          relative,
          pattern,
          "consumer invokes #{declaration[:owner] && declaration[:owner] + '.'}#{declaration[:name]}, which #{declaration[:detail]}",
          all: true
        )
      )
    end
  end
  return [] if evidence.empty?

  evidence + declarations.map do |declaration|
    {
      "path" => declaration[:path],
      "line" => declaration[:line],
      "detail" => "Core operation declaration #{declaration[:owner] && declaration[:owner] + '.'}#{declaration[:name]} #{declaration[:detail]}"
    }
  end
end

def direct_core_type_evidence(scanner, consumer_paths)
  declarations = []
  scanner.files(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/**/*.swift"
  ).each_key do |relative|
    lines = scanner.swift_code_lines(relative)
    next unless lines
    lines.each_index do |index|
      next unless lines[index].match?(/\b(?:public|package)\b/)
      parts = []
      cursor = index
      while cursor < lines.length && cursor - index < 12
        parts << lines[cursor].strip
        break if parts.join(" ").include?("{")
        cursor += 1
      end
      declaration = parts.join(" ").gsub(/\s+/, " ")
      match = declaration.match(
        /\A(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|public|package|internal|final|nonisolated)\s+)*(?:actor|class|enum|struct|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)\b/
      )
      next unless match
      next if match[1] == "RuneScribeCoreModuleBootstrap"
      declarations << {name: match[1], path: relative, line: index + 1}
    end
  end
  declarations.uniq! { |item| item[:name] }

  evidence = []
  declarations.each do |declaration|
    direct = consumer_paths.flat_map do |relative|
      swift_type_usage_evidence(
        scanner,
        relative,
        declaration[:name],
        "consumer retains, constructs, or invokes Core implementation type #{declaration[:name]}"
      )
    end
    concealed = concealed_peer_service_evidence(
      scanner,
      consumer_paths,
      declaration[:name],
      "consumer retains, constructs, or invokes Core implementation type #{declaration[:name]}"
    )
    next if direct.empty? && concealed.empty?
    evidence.concat(direct)
    evidence.concat(concealed)
    evidence << {
      "path" => declaration[:path],
      "line" => declaration[:line],
      "detail" => "public Core implementation type #{declaration[:name]} is consumer-inaccessible except through runtime registration"
    }
  end
  unique_evidence(evidence)
end

def required_anchor_evidence(scanner, requirements)
  present = []
  missing = []
  requirements.each do |relative, pattern, detail|
    matches = scanner.evidence(relative, pattern, detail)
    if matches.empty?
      marker = scanner.marker(relative, "required runtime proof is missing: #{detail}")
      missing.concat(
        marker.empty? ? [{"path" => relative, "line" => 1, "detail" => "required runtime proof file is missing: #{detail}"}] : marker
      )
    else
      present.concat(matches)
    end
  end
  [unique_evidence(present), unique_evidence(missing)]
end

def ordered_activation_completeness_evidence(scanner, runtime)
  lines = scanner.swift_code_lines(runtime)
  return [] unless lines
  call_index = lines.index { |line| line.match?(/\bdispatcher\.publishedEndpointsAvailable\s*\(/) }
  mark_index = lines.index { |line| line.match?(/\bdispatcher\.markActive\s*\(/) }
  return [] unless call_index && mark_index && call_index < mark_index

  call_text = lines[call_index, 10].to_a.join(" ").gsub(/\s+/, " ")
  mark_text = lines[mark_index, 6].to_a.join(" ").gsub(/\s+/, " ")
  same_generation_call = call_text.match?(
    /dispatcher\.publishedEndpointsAvailable\s*\(\s*moduleID:\s*moduleID,\s*generation:\s*moduleGeneration,\s*endpointIDs:\s*registration\.factory\.descriptor\.publishedEndpoints\s*\)/
  )
  same_generation_mark = mark_text.match?(
    /dispatcher\.markActive\s*\(\s*moduleID:\s*moduleID,\s*generation:\s*moduleGeneration\s*\)/
  )
  return [] unless same_generation_call && same_generation_mark

  [
    {
      "path" => runtime,
      "line" => call_index + 1,
      "detail" => "runtime verifies the same-generation declared published endpoints before marking the module active"
    },
    {
      "path" => runtime,
      "line" => mark_index + 1,
      "detail" => "module activation occurs only after same-generation endpoint completeness succeeds"
    }
  ]
end

def early_start_stop_safety_evidence(scanner, runtime)
  lines = scanner.swift_code_lines(runtime)
  return [] unless lines
  start_index = lines.index { |line| line.match?(/\bpublic\s+func\s+start\s*\(\s*\)\s+async\s+throws/) }
  return [] unless start_index
  search_limit = [lines.length, start_index + 100].min
  find_after = lambda do |pattern, after_index|
    ((after_index + 1)...search_limit).find { |index| lines[index].match?(pattern) }
  end

  reset_index = find_after.call(/\bstopRequestedWhileStarting\s*=\s*false\b/, start_index)
  coordinator_await = find_after.call(/\bawait\s+startCoordinator\.beforeInfrastructureActivation\s*\(/, start_index)
  return [] unless reset_index && coordinator_await && reset_index < coordinator_await

  await_patterns = [
    /\bawait\s+startCoordinator\.beforeInfrastructureActivation\s*\(/,
    /\bawait\s+dispatcher\.beginRuntimeStart\s*\(/,
    /\bawait\s+platformBridge\.activateRuntime\s*\(/,
    /\bawait\s+dispatcher\.registerHostSource\s*\(/
  ]
  checkpoints = []
  cursor = reset_index
  await_patterns.each do |pattern|
    await_index = find_after.call(pattern, cursor)
    return [] unless await_index
    check_index = find_after.call(/\bif\s+stopRequestedWhileStarting\b/, await_index)
    return [] unless check_index && check_index - await_index <= 8
    checkpoints << [await_index, check_index]
    cursor = check_index
  end

  last_check = checkpoints.last[1]
  unsafe_reset = ((coordinator_await + 1)..last_check).any? do |index|
    lines[index].match?(/\bstopRequestedWhileStarting\s*=\s*false\b/)
  end
  return [] if unsafe_reset

  evidence = [
    {
      "path" => runtime,
      "line" => reset_index + 1,
      "detail" => "start clears the stop-request flag before its first suspension point"
    }
  ]
  checkpoints.each do |await_index, check_index|
    evidence << {
      "path" => runtime,
      "line" => check_index + 1,
      "detail" => "start rechecks stopRequestedWhileStarting after the early await at line #{await_index + 1}"
    }
  end
  evidence
end

def ordered_stop_quiescence_evidence(scanner, runtime)
  lines = scanner.swift_code_lines(runtime)
  return [] unless lines
  stop_index = lines.index { |line| line.match?(/\bpublic\s+func\s+stop\s*\(\s*\)\s+async/) }
  return [] unless stop_index
  search_limit = [lines.length, stop_index + 120].min
  quiesce_index = (stop_index...search_limit).find do |index|
    lines[index].match?(/\bawait\s+dispatcher\.beginRuntimeQuiesce\s*\(\s*\)/)
  end
  return [] unless quiesce_index
  admission_index = (stop_index...quiesce_index).to_a.reverse.find do |index|
    lines[index].match?(/\bhostIngress\.quiesceAdmissions\s*\(\s*\)/)
  end
  coordinator_index = ((quiesce_index + 1)...search_limit).find do |index|
    lines[index].match?(/\bawait\s+startCoordinator\.afterClientQuiesceBeforeIngressDrain\s*\(\s*\)/)
  end
  return [] unless admission_index && coordinator_index
  flush_index = ((coordinator_index + 1)...search_limit).find do |index|
    lines[index].match?(/\bawait\s+hostIngress\.flush\s*\(\s*\)/)
  end
  suspend_index = flush_index && ((flush_index + 1)...search_limit).find do |index|
    lines[index].match?(/\bhostIngress\.suspend\s*\(\s*\)/)
  end
  begin_stop_index = suspend_index && ((suspend_index + 1)...search_limit).find do |index|
    lines[index].match?(/\bawait\s+dispatcher\.beginRuntimeStop\s*\(\s*\)/)
  end
  return [] unless flush_index && suspend_index && begin_stop_index

  premature_stop = ((quiesce_index + 1)...flush_index).any? do |index|
    lines[index].match?(/\bdispatcher\.beginRuntimeStop\s*\(/)
  end
  return [] if premature_stop

  [
    [admission_index, "runtime closes host ingress admissions before client quiescence"],
    [quiesce_index, "runtime denies new module calls while preserving the accepted ingress drain"],
    [coordinator_index, "runtime exposes the deterministic post-client-quiesce pre-drain seam"],
    [flush_index, "runtime drains accepted host ingress before suspending delivery"],
    [begin_stop_index, "runtime begins full dispatcher stop only after the accepted ingress drain"]
  ].map do |line_index, detail|
    {"path" => runtime, "line" => line_index + 1, "detail" => detail}
  end
end

def generic_cast_return_evidence(scanner)
  evidence = []
  shipping_swift_paths(scanner).each do |relative|
    lines = scanner.swift_code_lines(relative)
    next unless lines
    lines.each_index do |start_index|
      next unless lines[start_index].match?(/\bfunc\b/)
      signature_end = start_index
      signature = +""
      while signature_end < lines.length && signature_end < start_index + 12
        signature << " " << lines[signature_end].strip
        break if lines[signature_end].include?("{")
        signature_end += 1
      end
      match = signature.match(/\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*<([^>]+)>.*?->\s*([A-Za-z_][A-Za-z0-9_]*)\b/)
      next unless match
      generic_parameters = match[1].scan(/(?:\A|,)\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/).flatten
      returned_parameter = match[2]
      next unless generic_parameters.include?(returned_parameter)

      depth = 0
      body_started = false
      (start_index...[lines.length, start_index + 120].min).each do |line_index|
        line = lines[line_index]
        body_started ||= line.include?("{")
        if body_started && line.match?(/\bas\?\s*#{Regexp.escape(returned_parameter)}\b/)
          evidence << {
            "path" => relative,
            "line" => line_index + 1,
            "detail" => "generic function casts stored data and returns it as its caller-selected type"
          }
          break
        end
        depth += line.count("{") - line.count("}") if body_started
        break if body_started && depth <= 0
      end
    end
  end
  unique_evidence(evidence)
end

def multiline_provider_publication_evidence(scanner)
  evidence = []
  shipping_swift_paths(scanner).each do |relative|
    lines = scanner.swift_code_lines(relative)
    next unless lines
    lines.each_index do |index|
      next unless lines[index].match?(/\bpublishService\s*\(/)
      invocation = lines[index, 12].to_a.join(" ").gsub(/\s+/, " ")
      next unless invocation.match?(/\bpublishService\s*\(\s*self\b/)
      evidence << {
        "path" => relative,
        "line" => index + 1,
        "detail" => "module publishes its provider implementation"
      }
    end
  end
  unique_evidence(evidence)
end

def raw_generic_provider_storage_evidence(scanner)
  evidence = []
  shipping_swift_paths(scanner).each do |relative|
    lines = scanner.swift_code_lines(relative)
    next unless lines
    storages = []
    lines.each_index do |index|
      declaration = lines[index, 8].to_a.join(" ").gsub(/\s+/, " ")
      match = declaration.match(
        /\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\[[^\]]+:\s*(?:Any|any\s+Sendable)\s*\]/
      )
      storages << {name: match[1], line: index + 1} if match
    end
    storages.uniq! { |item| item[:name] }
    next if storages.empty?

    lines.each_index do |index|
      next unless lines[index].match?(/\bfunc\b/)
      signature_lines = []
      cursor = index
      while cursor < lines.length && cursor - index < 16
        signature_lines << lines[cursor].strip
        break if signature_lines.join(" ").include?("{")
        cursor += 1
      end
      signature = signature_lines.join(" ").gsub(/\s+/, " ")
      generic = signature.match(/\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*<([^>]+)>/)
      generic_types = generic ? generic[1].scan(/(?:\A|,)\s*([A-Za-z_][A-Za-z0-9_]*)\b/).flatten : []
      parameter_names = []
      generic_types.each do |generic_type|
        parameter_names.concat(
          signature.scan(
            /(?:\b|_)\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*#{Regexp.escape(generic_type)}\b/
          ).flatten
        )
      end
      parameter_names.concat(
        signature.scan(
          /(?:\b|_)\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:any\s+)?Any\b/
        ).flatten
      )
      parameter_names.uniq!
      next if parameter_names.empty?

      body_lines = lines[index, 120].to_a
      body = body_lines.join(" ").gsub(/\s+/, " ")
      storages.each do |storage|
        parameter_names.each do |parameter|
          assignment = /\b#{Regexp.escape(storage[:name])}\s*\[[^\]]+\]\s*=\s*#{Regexp.escape(parameter)}\b/
          next unless body.match?(assignment)
          assignment_line = body_lines.index { |line| line.match?(/\b#{Regexp.escape(storage[:name])}\s*\[/) }
          evidence << {
            "path" => relative,
            "line" => index + (assignment_line || 0) + 1,
            "detail" => "generic or Any provider value is published into raw storage #{storage[:name]}"
          }
        end
      end
    end
  end
  unique_evidence(evidence)
end

def provider_publication_rule(scanner)
  forbidden = [
    [/\b(?:actor|class|struct)\s+ScopedServiceRegistry\b/, "raw provider-value service registry remains"],
    [/\b(?:let|var)\s+(?!handlerBox\b)[A-Za-z_][A-Za-z0-9_]*:\s*any\s+Sendable\b/, "generic raw Sendable storage remains outside the private typed handler box"],
    [/\bas\?\s*(?:Value|T|Element|Payload|Stored|Service)\b/, "generic raw registry casts a stored object back to its requested type"],
    [/\[ServiceIdentifier:\s*Entry\]/, "service registry is keyed to raw value entries"],
    [/\bfunc\s+register(?:Host|Module)?Service\s*<\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*Sendable\b/, "generic raw service registration remains"],
    [/\bfunc\s+resolve\s*<\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*Sendable\b/, "generic raw registry resolution remains"],
    [/\bfunc\s+resolve(?:Host)?Service\s*<\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*Sendable\b/, "generic service resolver can return a provider object"],
    [/\bfunc\s+registerModuleService\b/, "module service object registration remains"],
    [/\bfunc\s+publishService\s*<\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*Sendable\b/, "generic module provider publication API remains"],
    [/\bpublishService\s*\(\s*self\b/, "module publishes its provider implementation"],
    [/\bfunc\s+register(?!HostService\b)[A-Za-z0-9_]*Service\s*\([^)]*\bany\s+[A-Za-z0-9_]*Service\b/, "raw module service actor or existential registration remains"]
  ]
  violations = scanner.swift_finding_evidence("FG-004")
  shipping_swift_paths(scanner).each do |relative|
    forbidden.each do |pattern, detail|
      violations.concat(scanner.swift_code_evidence(relative, pattern, detail, all: true))
    end
  end
  violations = unique_evidence(
    violations + generic_cast_return_evidence(scanner) +
      multiline_provider_publication_evidence(scanner) +
      raw_generic_provider_storage_evidence(scanner)
  )
  return ["violation", violations, "detected-source-anchor"] unless violations.empty?

  dispatcher = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeOperationDispatcher.swift"
  compatibility = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
  ingress = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/SerialInboundInputForwarder.swift"
  platform_bridge = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimePlatformBridge.swift"
  swift_scanner = "scripts/swift-compliance-scanner.swift"
  guard_tests = "RuneScribArchitectureTests/ComplianceGuardTests.swift"
  requirements = [
    [swift_scanner, /import SwiftParser/, "Swift source is parsed as syntax rather than line-shaped text"],
    [swift_scanner, /import SwiftSyntax/, "provider publication is inspected through Swift syntax nodes"],
    [swift_scanner, /analysisScope: "conservative fail-closed source-tree symbol and type-flow analysis"/, "scanner declares its conservative fail-closed source-tree coverage boundary"],
    [dispatcher, /private struct RuntimeTypedEndpoint</, "runtime stores only a private typed endpoint handler"],
    [dispatcher, /let handler: @Sendable/, "endpoint entry retains an invocation handler rather than a provider object"],
    [dispatcher, /private struct RuntimeEndpointEntry\b/, "runtime endpoint entry is implementation-private"],
    [dispatcher, /func registerEndpoint</, "modules register typed endpoint descriptors and handlers"],
    [dispatcher, /handler: @escaping @Sendable/, "endpoint registration accepts a runtime-owned invocation closure"],
    [dispatcher, /handlerBox: RuntimeTypedEndpoint\(/, "registered provider behavior is wrapped as a typed handler"],
    [platform_bridge, /actor RuntimePlatformBridge\b/, "host platform adapters are isolated in an exact-member bridge"],
    [compatibility, /func registerApplicationEndpoints\(/, "Core application behavior is translated into runtime endpoint handlers"],
    [compatibility, /func registerInboundInputEndpoint\(/, "Core inbound behavior is translated into a runtime ingress handler"],
    [compatibility, /func applicationClient\(\) async throws -> RuntimeApplicationClient/, "UI resolution constructs a runtime-owned application client"],
    [compatibility, /public struct RuntimeApplicationClient: Sendable\b/, "the application client is runtime-owned and is not a provider protocol value"],
    [compatibility, /private let command: RuntimeCommandClient/, "the application client retains a runtime command client"],
    [compatibility, /private let query: RuntimeQueryClient/, "the application client retains a runtime query client"],
    [ingress, /public final class RuntimeHostIngressRail\b/, "the runtime owns the host ingress rail"],
    [ingress, /typealias Delivery = @Sendable/, "the ingress rail retains only a runtime delivery closure"],
    [guard_tests, /"NM-FG-004-01"/, "provider self-publication negative mutation is present"],
    [guard_tests, /"NM-FG-004-02"/, "raw actor registration negative mutation is present"],
    [guard_tests, /func testGenericRawResolverRegressionReportsFG004\(/, "generic resolver and cast-return regression test is present"],
    [guard_tests, /func testProviderResultPublicationSurfacesReportOnlyFG004\(/, "public provider-result publication regressions are present"],
    [guard_tests, /func testProviderSemanticPublicationSurfacesReportOnlyFG004\(/, "open, aliased-self, erased-storage, and inferred provider publication regressions are present"],
    [guard_tests, /func testProviderHandlerAllowlistRequiresCanonicalModuleContextReportsOnlyFG004\(/, "provider handler allowlisting requires the unshadowed runtime ModuleContext receiver"],
    [guard_tests, /func testCanonicalProviderRegistrationCannotRetainProviderReportsOnlyFG004\(/, "canonical endpoint registration cannot retain provider objects in raw storage"],
    [guard_tests, /func testGenericAndCollectionProviderWrappersReportOnlyFG004\(/, "generic, collection, alias, accessor, and result-root provider publication regressions are present"],
    [guard_tests, /func testProviderSemanticNoChangeControlsRemainClean\(/, "qualified canonical context and non-publication provider transformations remain clean"],
    [guard_tests, /func testExtensionConformanceProviderPublicationReportsOnlyFG004\(/, "extension-conformance provider publication regression is present"],
    [guard_tests, /func testProviderPublicationLexicalAndMultilineRegressions\(/, "multiline publication and lexical false-positive regressions are present"]
  ]
  present, missing = required_anchor_evidence(scanner, requirements)
  unless missing.empty?
    return ["violation", missing, "detected-absence-anchor"]
  end

  proof = present + scanner.marker(
    dispatcher,
    "Conservative fail-closed SwiftSyntax source-tree analysis scanned shipping declarations and data flow with no raw module provider publication, generic registry, cast, or return surface"
  )
  ["pass", unique_evidence(proof), "detector-proof"]
end

def peer_service_retention_rule(scanner)
  dispatcher = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeOperationDispatcher.swift"
  compatibility = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
  ingress = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/SerialInboundInputForwarder.swift"
  runtime = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift"
  ui_module = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/UIModule.swift"
  ui_session = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession.swift"
  host = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
  ui_tests = "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/RuneScribeUISessionTests.swift"
  ingress_tests = "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/InboundInputForwarderTests.swift"
  swift_scanner = "scripts/swift-compliance-scanner.swift"
  guard_tests = "RuneScribArchitectureTests/ComplianceGuardTests.swift"

  violations = scanner.swift_finding_evidence("FG-005")
  consumer_paths = peer_service_consumer_paths(scanner)
  consumer_paths.each do |relative|
    violations.concat(
      scanner.swift_code_evidence(
        relative,
        /\.attach\s*\(\s*service:/,
        "host attaches a provider-owned service handle",
        all: true
      )
    )
  end
  shipping_swift_paths(scanner).each do |relative|
    violations.concat(
      scanner.swift_code_evidence(
        relative,
        /\bresolveHostService\b/,
        "shipping source exposes or invokes host provider resolution",
        all: true
      )
    )
    violations.concat(
      scanner.swift_code_evidence(
        relative,
        /\bRuntime(?:Application|InboundInput)ServiceProxy\b/,
        "shipping source retains a provider-protocol compatibility proxy",
        all: true
      )
    )
  end
  violations.concat(
    scanner.swift_code_evidence(
      ingress,
      /\bservice\.receive\s*\(/,
      "host ingress delivery directly invokes a retained provider service",
      all: true
    )
  )

  requirements = [
    [swift_scanner, /import SwiftParser/, "peer type-flow is parsed with SwiftParser"],
    [swift_scanner, /import SwiftSyntax/, "peer type-flow is inspected through Swift syntax nodes"],
    [swift_scanner, /analysisScope: "conservative fail-closed source-tree symbol and type-flow analysis"/, "scanner declares its conservative fail-closed source-tree coverage boundary"],
    [compatibility, /func applicationClient\(\) async throws -> RuntimeApplicationClient/, "module context vends the runtime-owned application client"],
    [compatibility, /public struct RuntimeApplicationClient: Sendable\b/, "runtime owns the UI application client"],
    [compatibility, /private let command: RuntimeCommandClient/, "application client retains only a runtime command client"],
    [compatibility, /private let query: RuntimeQueryClient/, "application client retains only a runtime query client"],
    [compatibility, /RuntimeStateStream<RuneScribeApplicationSnapshot>/, "application state remains in the runtime-owned revocable stream"],
    [ui_module, /context\.applicationClient\(\)/, "UI module requests a runtime application client"],
    [ui_session, /applicationClientHandle: RuntimeApplicationClient\?/, "UI session retains a runtime client rather than a provider service"],
    [ui_session, /func requireApplicationClient\(\) throws -> RuntimeApplicationClient/, "UI operations require the runtime client"],
    [ui_session, /client\.applicationStateEnvelopes/, "UI state consumption uses the runtime state rail"],
    [ui_session, /client\.menuCommandEnvelopes/, "UI menu routing uses the runtime state rail"],
    [ingress, /public enum ExternalInputEnvelope\b/, "host submits a provider-neutral external input envelope"],
    [ingress, /public final class RuntimeHostIngressRail\b/, "runtime owns bounded host ingress"],
    [ingress, /typealias Delivery = @Sendable/, "ingress retains a runtime delivery closure rather than a service value"],
    [runtime, /RuntimeHostIngressRail\(/, "runtime constructs its host ingress rail"],
    [runtime, /public (?:nonisolated )?func submit\(/, "runtime exposes provider-neutral host submission"],
    [dispatcher, /func dispatchHostIngress\(/, "host ingress dispatch remains internal to the runtime dispatcher"],
    [runtime, /dispatcher\.dispatchHostIngress\(/, "runtime connects its host ingress rail directly to the dispatcher"],
    [host, /runtime\.submit\(/, "host callbacks submit directly to the runtime"],
    [ui_tests, /func testRuntimeApplicationClientMediatesCommandQueryStateAndLedger\(/, "live UI client mediation test is present"],
    [ui_tests, /func testRuntimeApplicationClientFailsAfterCoreReplacementWithoutSessionCleanup\(/, "retained UI client replacement test is present"],
    [ingress_tests, /func testRuntimeIngressRetainsAcrossStopStartAndRoutesToReplacement\(/, "runtime ingress replacement behavior test is present"],
    [guard_tests, /"NM-FG-005-01"/, "UI service-retention negative mutation is present"],
    [guard_tests, /"NM-FG-005-02"/, "host service-retention negative mutation is present"],
    [guard_tests, /func testHostResolverProxyRegressionReportsFG005\(/, "resolver/proxy regression mutation is present"],
    [guard_tests, /func testTransitivePeerServiceAliasRetentionReportsOnlyFG005\(/, "transitive provider-protocol alias regressions are present"],
    [guard_tests, /func testTransitivePeerServiceProtocolRefinementReportsOnlyFG005\(/, "transitive provider-protocol refinement regressions are present"],
    [guard_tests, /func testProtocolWhereConstraintDoesNotMasqueradeAsServiceRefinement\(/, "protocol where-constraint parsing regression is present"],
    [guard_tests, /func testPeerTypeNameShadowingDoesNotTriggerFG005\(/, "consumer-local and generic type-name shadowing regression is present"],
    [guard_tests, /func testPeerTypeNameShadowingCannotSuppressDisjointScopeRetention\(/, "lexically disjoint type-name shadows cannot suppress peer retention detection"],
    [guard_tests, /func testPeerServiceNamesInCommentsAndStringsDoNotTriggerFG005\(/, "Swift comment and string false-positive regression is present"],
    [guard_tests, /func testPeerAndCoreNamesInRegexLiteralsDoNotTriggerGuards\(/, "Swift regex-literal false-positive regression is present"],
    [guard_tests, /func testNonProviderShippingTargetRetentionReportsOnlyFG005\(/, "non-provider shipping-target retention regression is present"],
    [guard_tests, /func testPeerServiceInitializerAssignmentAndResultFlowReportsOnlyFG005\(/, "initializer, assignment, and resolver-result type-flow regression is present"],
    [guard_tests, /func testPeerServiceGenericConstraintRetentionReportsOnlyFG005\(/, "generic constraint and where-clause peer retention regressions are present"],
    [guard_tests, /func testPeerServiceErasedRetentionFlowsReportOnlyFG005\(/, "direct, helper-erased, aliased, and cross-file retained storage flows are rejected"],
    [guard_tests, /func testPeerServiceLocalShadowsAndAssociatedMemberConstraintsDoNotTriggerFG005\(/, "local alias and protocol shadows plus associated-member constraints remain scope-correct"]
  ]
  present, missing = required_anchor_evidence(scanner, requirements)
  violations = unique_evidence(violations + missing)
  unless violations.empty?
    kind = missing.empty? ? "detected-source-anchor" : "detected-absence-anchor"
    return ["violation", violations, kind]
  end

  proof = present + scanner.marker(
    ui_module,
    "Conservative fail-closed SwiftSyntax source-tree type-flow scanned every non-provider shipping module and host with no provider protocol, resolver, attachment, or compatibility-proxy retention"
  )
  ["pass", unique_evidence(proof), "detector-proof"]
end

def runtime_dispatch_rule(scanner)
  contracts = "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimeOperationContracts.swift"
  dispatcher = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeOperationDispatcher.swift"
  payload_sizer = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimePayloadSizer.swift"
  compatibility = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeApplicationEndpoints.swift"
  ingress = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/SerialInboundInputForwarder.swift"
  runtime = "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift"
  ui_module = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/UIModule.swift"
  ui_session = "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession.swift"
  host = "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift"
  guard_tests = "RuneScribArchitectureTests/ComplianceGuardTests.swift"
  runtime_tests = "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeOperationDispatcherTests.swift"
  lifecycle_tests = "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeLifecycleTests.swift"
  stop_start_tests = "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeStopDuringStartTests.swift"
  ui_tests = "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/RuneScribeUISessionTests.swift"
  ingress_tests = "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/InboundInputForwarderTests.swift"
  composition_tests = "RuneScribTests/RuntimeCompositionTests.swift"
  swift_scanner = "scripts/swift-compliance-scanner.swift"
  requirements = [
    [swift_scanner, /import SwiftParser/, "direct cross-target calls are parsed with SwiftParser"],
    [swift_scanner, /import SwiftSyntax/, "direct cross-target calls are inspected through Swift syntax nodes"],
    [swift_scanner, /analysisScope: "conservative fail-closed source-tree symbol and type-flow analysis"/, "scanner declares its conservative fail-closed source-tree coverage boundary"],
    [contracts, /public struct RuntimeStateEndpointDescriptor<State: Sendable>/, "state endpoints declare a typed relay descriptor"],
    [contracts, /public let bufferingPolicy: RuntimeStateRelayBufferingPolicy/, "state endpoint descriptors carry bounded relay policy"],
    [contracts, /bufferingPolicy: RuntimeStateRelayBufferingPolicy = \.bufferingNewest\(1\)/, "state relay buffering has an explicit bounded default"],
    [dispatcher, /public actor RuntimeOperationDispatcher\b/, "runtime owns the operation dispatcher"],
    [dispatcher, /struct RuntimeClientLease\b/, "runtime clients carry generation-pinned identities"],
    [dispatcher, /func registerEndpoint</, "providers register typed endpoints with runtime"],
    [dispatcher, /func dispatch</, "cross-module clients enter the runtime dispatcher"],
    [dispatcher, /let endpoint = try validateBeforeCall\(/, "every dispatch invokes the pre-call validator"],
    [dispatcher, /try validateRuntimeGeneration\(lease\)/, "every call checks runtime generation"],
    [dispatcher, /try validateSourceLifecycle\(/, "every call checks runtime and source lifecycle plus generation"],
    [dispatcher, /try validateDestinationLifecycle\(/, "every call checks destination lifecycle plus endpoint generation"],
    [dispatcher, /try validateEndpointDeclarations\(/, "every call checks source and destination endpoint declarations"],
    [dispatcher, /try validateCapability\(/, "every call checks source capability and runtime policy"],
    [dispatcher, /try validateDescriptorAndSchemas\(/, "every call checks endpoint identity, types, kind, and schemas"],
    [dispatcher, /try validateRequestBounds\(/, "every call checks request bounds"],
    [dispatcher, /try validateRateBounds\(/, "every call checks runtime rate and concurrency policy"],
    [payload_sizer, /enum RuntimePayloadSizer\b/, "runtime owns deterministic payload sizing"],
    [dispatcher, /RuntimePayloadSizer\.byteCount\(/, "dispatcher applies runtime-owned payload sizing"],
    [dispatcher, /inFlight\[operationID\] = RuntimeInFlightOperation\(/, "runtime owns in-flight operation cancellation"],
    [dispatcher, /operation\.cancel\(\)/, "module or runtime invalidation cancels affected operations"],
    [dispatcher, /try validateAfterCall\(lease: lease, endpoint: endpoint\)/, "dispatch revalidates generations after provider execution"],
    [dispatcher, /guard responseBytes <= endpoint\.descriptor\.maximumResponseBytes/, "post-call validation checks response bounds"],
    [dispatcher, /private func appendLedgerStart\(/, "runtime records every attempted operation"],
    [dispatcher, /private func completeLedger\(/, "runtime records operation completion or denial"],
    [dispatcher, /let hadIdempotencyKey: Bool/, "ledger records only whether an idempotency key existed"],
    [dispatcher, /idempotencyKey: nil/, "ledger removes the idempotency key value"],
    [dispatcher, /public struct RuntimeCommandClient\b/, "command calls use a runtime-owned client"],
    [dispatcher, /public struct RuntimeQueryClient\b/, "query calls use a runtime-owned client"],
    [dispatcher, /public struct RuntimeStateClient\b/, "state calls use a runtime-owned client"],
    [dispatcher, /public struct RuntimeStateStream<State: Sendable>: AsyncSequence, Sendable/, "state delivery remains generation-validating through a runtime-owned AsyncSequence"],
    [dispatcher, /public struct RuntimeIngressClient\b/, "ingress calls use a runtime-owned client"],
    [dispatcher, /guard typedEndpoint\.bufferingPolicy == descriptor\.bufferingPolicy else/, "state subscription rejects client/provider buffering-policy drift"],
    [dispatcher, /func publishedEndpointsAvailable\(/, "dispatcher validates same-generation published endpoint availability"],
    [compatibility, /public struct RuntimeApplicationClient: Sendable\b/, "UI application operations use a runtime-owned client"],
    [compatibility, /private let command: RuntimeCommandClient/, "application mutations enter the runtime command rail"],
    [compatibility, /private let query: RuntimeQueryClient/, "application reads enter the runtime query rail"],
    [compatibility, /RuntimeStateStream<RuneScribeApplicationSnapshot>/, "application state remains on the runtime-owned revocable state rail"],
    [compatibility, /RuntimeStateStream<ApplicationMenuCommandDTO>/, "menu delivery remains inside the runtime-owned revocable state stream"],
    [compatibility, /try await command\.send\(/, "application client methods dispatch commands through runtime"],
    [compatibility, /try await query\.fetch\(/, "application client methods dispatch queries through runtime"],
    [compatibility, /state\("application\.menu-commands", bufferingPolicy: \.bufferingOldest\(16\)\)/, "menu command state relay preserves bounded FIFO delivery"],
    [ui_module, /context\.applicationClient\(\)/, "UI module receives its client from runtime context"],
    [ui_session, /func requireApplicationClient\(\) throws -> RuntimeApplicationClient/, "UI session operations require the runtime client"],
    [ingress, /public final class RuntimeHostIngressRail\b/, "runtime owns FIFO host ingress"],
    [ingress, /public static let menuCapacity = 16/, "runtime ingress owns the authoritative bounded menu capacity"],
    [ingress, /retainedMenuCount < Self\.menuCapacity/, "menu capacity is enforced before an ingress item is retained"],
    [ingress, /typealias Delivery = @Sendable/, "host ingress calls an internal runtime delivery closure"],
    [runtime, /public (?:nonisolated )?func submit\(/, "host operations enter the runtime submission API"],
    [runtime, /hostIngress\.quiesceAdmissions\(\)/, "runtime closes host admissions before stop-time drain"],
    [dispatcher, /func beginRuntimeQuiesce\(\)/, "dispatcher has a distinct client-quiescence state"],
    [dispatcher, /let quiescingIngressAllowed = runtimeIsQuiescing/, "accepted ingress remains authorized while new module calls are quiesced"],
    [dispatcher, /func dispatchHostIngress\(/, "runtime dispatcher resolves and mediates each host ingress item"],
    [runtime, /dispatcher\.dispatchHostIngress\(/, "runtime host ingress reaches the dispatcher internally"],
    [host, /runtime\.submit\(/, "host callbacks never leave runtime mediation"],
    [host, /runtime\.observeHostIngressFailures/, "host composition observes bounded runtime ingress failures"],
    [host, /presentNotice\(\.inputRejected\)/, "ingress admission failures map to a sanitized rejected-input notice"],
    [host, /presentNotice\(\.inputUnavailable\)/, "destination failures map to a sanitized unavailable-input notice"],
    [guard_tests, /"NM-FG-006-01"/, "stopped-provider negative mutation is present"],
    [guard_tests, /"NM-FG-006-02"/, "provider-replacement negative mutation is present"],
    [guard_tests, /"NM-FG-006-03"/, "undeclared-endpoint negative mutation is present"],
    [guard_tests, /func testDirectCoreBypassReportsOnlyFG006\(/, "direct Core implementation bypass regression is present"],
    [guard_tests, /func testNonProviderShippingTargetDirectCoreBypassReportsOnlyFG006\(/, "non-provider shipping-target Core bypass regression is present"],
    [guard_tests, /func testConcreteCoreAliasBypassInCompositionReportsOnlyFG006\(/, "concealed concrete Core implementation bypass regression is present"],
    [guard_tests, /func testConcreteCoreAliasStaticOperationReportsOnlyFG006\(/, "concealed concrete Core static-operation bypass regression is present"],
    [guard_tests, /func testConcreteCoreOperationSurfacesReportOnlyFG006\(/, "computed and neutral Core operation regressions are present"],
    [guard_tests, /func testCoreExtensionOperationReportsOnlyFG006\(/, "Core extension operation regression is present"],
    [guard_tests, /func testCoreSymbolCollisionConservativelyReportsOnlyFG006\(/, "Core symbol collisions are conservatively rejected"],
    [guard_tests, /func testRetainedTopLevelCoreFunctionReportsOnlyFG006\(/, "retained top-level Core function references are rejected"],
    [guard_tests, /func testPublicRuntimeClientExtensionMustDispatchReportsOnlyFG006\(/, "public RuntimeApplicationClient extensions must retain typed dispatch"],
    [guard_tests, /func testRuntimeClientDummyDispatchCannotMaskBypassReportsOnlyFG006\(/, "nested dummy dispatch cannot mask a public client bypass"],
    [guard_tests, /func testRuntimeClientRequiresCanonicalCommandAndEndpointReportsOnlyFG006\(/, "runtime client dispatch must bind to canonical client and endpoint symbols"],
    [guard_tests, /func testTypedRuntimeClientOverloadsMustDispatchReportsOnlyFG006\(/, "every typed runtime-client overload must enter its declared dispatcher"],
    [guard_tests, /func testTypedRuntimeClientForwardedArgumentsRemainCanonicalFG006\(/, "typed runtime clients preserve exact schema, descriptor, and idempotency forwarding"],
    [guard_tests, /func testTypedRuntimeClientTupleResultCannotMaskDispatchReportsOnlyFG006\(/, "typed runtime dispatch must be the exact terminal result"],
    [guard_tests, /func testRuntimeClientSameShapeEndpointSwapReportsOnlyFG006\(/, "same-shape endpoint substitution cannot satisfy method dispatch"],
    [guard_tests, /func testRuntimeApplicationClientPayloadAndExtraArgumentsReportOnlyFG006\(/, "application clients preserve exact payload and argument shape"],
    [guard_tests, /func testRuntimeApplicationEndpointCatalogShadowCannotMaskDispatchReportsOnlyFG006\(/, "lexical catalog shadows cannot satisfy endpoint identity"],
    [guard_tests, /func testRuntimeClientDecoyEndpointReferenceReportsOnlyFG006\(/, "decoy and qualified-lookalike catalog references cannot satisfy endpoint identity"],
    [guard_tests, /func testExplicitTerminalRuntimeClientReturnDoesNotTriggerFG006\(/, "an exact top-level terminal runtime-client return remains a valid dispatch path"],
    [guard_tests, /func testRuntimeIngressShadowBindingsCannotSatisfyDispatchRailsFG006\(/, "shadowed runtime ingress and dispatcher bindings cannot satisfy dispatch rails"],
    [guard_tests, /func testRuntimeClientAndSubmitConditionalPathsReportOnlyFG006\(/, "conditional, early-exit, and short-circuit paths cannot mask runtime dispatch"],
    [guard_tests, /func testRuntimeStartConditionalDummyActivationCannotMaskBypassFG006\(/, "conditional dummy ingress activation cannot mask the effective activation path"],
    [guard_tests, /func testModuleContextDummyApplicationClientCallsReportOnlyFG006\(/, "dummy client-shaped calls cannot satisfy ModuleContext application-client wiring"],
    [guard_tests, /func testModuleContextTopLevelClientOverloadCannotMaskBindingReportsOnlyFG006\(/, "top-level client overloads cannot mask exact ModuleContext receiver binding"],
    [guard_tests, /func testModuleContextTupleSelectedClientCannotMaskBindingReportsOnlyFG006\(/, "tuple-selected forged clients cannot satisfy ModuleContext binding"],
    [guard_tests, /func testModuleContextApplicationClientExactFactoryReportsOnlyFG006\(/, "ModuleContext application-client construction preserves the exact seven-statement factory"],
    [guard_tests, /func testCoreBootstrapAliasOutsideCompositionReportsOnlyFG006\(/, "Core bootstrap aliases cannot escape the exact composition allowlist"],
    [guard_tests, /func testOpenCoreOperationReportsOnlyFG006\(/, "open Core operations remain direct-cross-target bypass scope"],
    [guard_tests, /func testCoreInitializerOperationReportsOnlyFG006\(/, "public Core initializers and defaulted initializer calls remain bypass scope"],
    [guard_tests, /func testCoreExtensionOwnerAliasOperationsReportOnlyFG006\(/, "consumer aliases cannot conceal Core extension operations or initializers"],
    [guard_tests, /func testCoreCallAsFunctionOperationReportsOnlyFG006\(/, "Core callAsFunction operations and unknown member receivers are rejected"],
    [guard_tests, /func testCoreContextualKeyPathAndVariadicSurfacesReportOnlyFG006\(/, "contextual members, key paths, initializer references, and variadic Core surfaces are rejected"],
    [guard_tests, /func testCoreCollectionSugarExtensionOperationReportsOnlyFG006\(/, "collection-sugar receiver types cannot conceal Core extension operations"],
    [guard_tests, /func testOptionalCoreExtensionOperationReportsOnlyFG006\(/, "optional and optional-chained receivers preserve Core extension owner identity"],
    [guard_tests, /func testTypedLocalCoreExtensionCollisionDoesNotTriggerFG006\(/, "lexically typed disjoint receiver collisions remain clean"],
    [guard_tests, /func testDirectCoreBypassInsideStringInterpolationReportsOnlyFG006\(/, "string interpolation remains executable Core-bypass scan scope"],
    [guard_tests, /func testPeerAndCoreNamesInRegexLiteralsDoNotTriggerGuards\(/, "Swift regex-literal false-positive regression is present"],
    [guard_tests, /func testLegacyServiceEndpointTranslationReportsOnlyFG006\(/, "legacy service-to-endpoint authorization regression is present"],
    [guard_tests, /func testConsumerMenuBufferReportsOnlyFG006\(/, "consumer-owned menu buffering regression is present"],
    [guard_tests, /func testAliasedConsumerMenuBufferReportsOnlyFG006\(/, "aliased consumer-owned menu buffering remains rejected"],
    [guard_tests, /func testActivationCompletenessCallRemovalReportsOnlyFG006\(/, "activation endpoint-completeness removal regression is present"],
    [guard_tests, /func testRuntimeSubmitRailRemovalReportsOnlyFG006\(/, "Runtime.submit host-ingress rail removal regression is present"],
    [guard_tests, /func testStopQuiescenceDrainRemovalReportsOnlyFG006\(/, "stop quiescence/drain ordering regression is present"],
    [guard_tests, /func testMenuCapacityAuthorityRemovalReportsOnlyFG006\(/, "authoritative menu-capacity regression is present"],
    [guard_tests, /func testIngressFailureObserverRemovalReportsOnlyFG006\(/, "host ingress failure-presentation regression is present"],
    [guard_tests, /func testEarlyStartStopCheckRemovalReportsOnlyFG006\(/, "early-start stop-check removal regression is present"],
    [runtime_tests, /func testTRT001AuthorizedCommandIsMediatedAndLedgered\(/, "authorized command mediation and ledger test is present"],
    [runtime_tests, /func testLedgerUsesRuntimeStampedBoundedMetadata\(/, "runtime-stamped bounded metadata test is present"],
    [runtime_tests, /func testTRT002UnauthorizedAndUndeclaredSourcesFailClosed\(/, "unauthorized and undeclared source test is present"],
    [runtime_tests, /func testEveryRejectedAttemptCreatesOneCompletedClassifiedLedgerRow\(/, "rejected-attempt ledger classification table test is present"],
    [runtime_tests, /func testStoppedClientFailsBeforeEndpointLookup\(/, "stopped client rejection test is present"],
    [runtime_tests, /func testSourceInvalidationMakesRetainedClientStale\(/, "retained client source invalidation test is present"],
    [runtime_tests, /func testProviderInvalidationMakesRetainedClientStale\(/, "retained client provider invalidation test is present"],
    [runtime_tests, /func testProviderInvalidationWhileInFlightDiscardsResultAndFinalizesLedgerAsStale\(/, "in-flight provider invalidation ledger test is present"],
    [runtime_tests, /func testRuntimeRestartMakesPriorGenerationClientStale\(/, "runtime-generation restart test is present"],
    [runtime_tests, /func testResponseSchemaOverrideIsDeniedBeforeHandler\(/, "response schema rejection test is present"],
    [runtime_tests, /func testNoEligibleDestinationReturnsBoundedTypedFailure\(/, "missing destination bounded failure test is present"],
    [runtime_tests, /func testRuntimeIngressClientMediatesAndLedgersAcceptedInput\(/, "runtime ingress mediation test is present"],
    [runtime_tests, /func testProviderCannotRegisterUndeclaredEndpoint\(/, "undeclared provider endpoint test is present"],
    [runtime_tests, /func testWrongSchemaTypeDescriptorAndOversizedRequestFailClosed\(/, "schema, type, descriptor, and request-bound test is present"],
    [runtime_tests, /func testHandlerFailureCreatesOneCompletedFailureLedgerRow\(/, "handler failure ledger test is present"],
    [runtime_tests, /func testTRT003ReplacementInvalidatesOldClientAndNewClientUsesNewHandler\(/, "provider replacement invalidation test is present"],
    [runtime_tests, /func testStopWhileInFlightDiscardsHandlerResultAfterAwait\(/, "stop-during-call cancellation race test is present"],
    [runtime_tests, /func testReplacementWhileInFlightDiscardsStaleResultAfterAwait\(/, "replacement-during-call generation race test is present"],
    [runtime_tests, /func testStopWhileInFlightReplacesLateHandlerFailureWithRuntimeFailure\(/, "stop-during-call late failure precedence test is present"],
    [runtime_tests, /func testCooperativeInFlightCancellationCreatesOneCancelledLedgerRow\(/, "cooperative cancellation ledger test is present"],
    [runtime_tests, /func testReplacementWhileInFlightReplacesLateHandlerFailureWithStaleFailure\(/, "replacement-during-call late failure precedence test is present"],
    [runtime_tests, /func testTRT014LedgerNeverRetainsPayloadResultOrIdempotencySecret\(/, "secret-safe call ledger test is present"],
    [runtime_tests, /func testLedgerEvictsOldestRecordsAtDeterministicBound\(/, "deterministic ledger eviction test is present"],
    [runtime_tests, /func testStateRelayIsRuntimeOwnedAndFinishesOnProviderInvalidation\(/, "runtime-owned state relay invalidation test is present"],
    [runtime_tests, /func testStateSubscriptionSchemaMismatchIsDeniedBeforeProviderStreamCreation\(/, "state subscription schema rejection test is present"],
    [runtime_tests, /func testOversizedStateDeliveryIsSuppressedAndLedgered\(/, "oversized state delivery ledger test is present"],
    [runtime_tests, /func testNormallyCompletedStateRelayCreatesSucceededLedgerRow\(/, "normal state relay completion ledger test is present"],
    [runtime_tests, /func testStateRelayRejectsClientBufferingPolicyDriftBeforeProviderStreamCreation\(/, "client buffering-policy drift fails before provider stream creation"],
    [runtime_tests, /func testStateRelaySuppressesLateValueWhenProviderInvalidationWinsDeliveryRace\(/, "state relay suppresses a late value when provider invalidation wins the delivery race"],
    [runtime_tests, /func testStateRelayPurgesUnreadBufferedValueAfterProviderInvalidation\(/, "state stream purges unread buffered values after provider invalidation"],
    [runtime_tests, /func testSessionBoundRejectsSaturationWithoutRetry\(/, "in-flight session bound test is present"],
    [runtime_tests, /func testPerSourceRateBoundRejectsWithoutInvokingHandlerAndResetsAfterWindow\(/, "per-source rate bound test is present"],
    [runtime_tests, /func testApplicationEndpointUsesComputedPayloadBound\(/, "application payload bound test is present"],
    [runtime_tests, /func testHostRegistrationRejectsMismatchedExactKey\(/, "exact host platform registration key test is present"],
    [runtime_tests, /func testFailedActivationInvalidatesCapturedContextBeforeReturning\(/, "failed activation context invalidation test is present"],
    [runtime_tests, /func testRetainedSynchronousPlatformClientsReturnDeterministicSentinelsAfterStop\(/, "retained platform proxy invalidation test is present"],
    [lifecycle_tests, /func testRuntimeActivationRejectsMissingDeclaredPublishedEndpoint\(/, "activation rejects a declared published endpoint that was not registered"],
    [runtime, /protocol RuntimeStartCoordinating: Sendable/, "runtime start exposes a deterministic early-suspension seam"],
    [stop_start_tests, /func testStopDuringEarlyInfrastructureStartCannotBeErasedOrStrandWaiter\(/, "early infrastructure stop/start race regression is present"],
    [ui_tests, /func testRuntimeApplicationClientMediatesCommandQueryStateAndLedger\(/, "UI command, query, state, and ledger mediation test is present"],
    [ui_tests, /func testRuntimeApplicationClientFailsAfterCoreReplacementWithoutSessionCleanup\(/, "retained UI client replacement test is present"],
    [ui_tests, /func testRuntimeApplicationClientPreservesBurstMenuCommandFIFO\(/, "burst menu commands preserve runtime FIFO delivery"],
    [ui_tests, /func testRuntimeMenuCommandRailRejectsCapacityPlusOneAndPreservesFIFO\(/, "runtime-owned menu rail routes capacity items and rejects capacity plus one"],
    [ui_tests, /func testRuntimeMenuCommandRailPurgesUnreadBufferedValueAfterStop\(/, "runtime-owned menu stream purges unread buffered values after stop"],
    [ui_tests, /func testCancelledMenuConsumerAllowsImmediateReplacementSubscription\(/, "cancelled menu consumption revokes the old relay before an immediate replacement subscription"],
    [ui_tests, /func testRuntimeStopDeniesNewClientCallsWhileAcceptedMenuDrainsToSubscriber\(/, "stop quiescence denies new module calls while accepted menu delivery drains"],
    [ingress_tests, /func testRuntimeIngressPreservesFIFOAndAuthoritativeMetadata\(/, "T-RT-004 FIFO and runtime metadata test is present"],
    [ingress_tests, /func testRuntimeIngressEnforcesBoundsCapacityAndSecurityReserves\(/, "T-RT-004 ingress bounds test is present"],
    [ingress_tests, /func testRuntimeIngressRejectsMenuCapacityPlusOneAndReleasesAfterOffer\(/, "authoritative runtime menu capacity rejects capacity plus one without silent drop"],
    [ingress_tests, /func testQuiescedFlushWaitsForAcceptedReservationStampingBeforeSuspend\(/, "quiesced flush preserves every already-authorized ingress reservation"],
    [ingress_tests, /func testRuntimeIngressRetainsAcrossStopStartAndRoutesToReplacement\(/, "T-RT-004 cold-start and replacement test is present"],
    [ingress_tests, /func testRuntimeIngressRetriesDestinationResolutionOnceWithoutReordering\(/, "ingress performs one ordered destination-resolution retry"],
    [ingress_tests, /func testRuntimeIngressDoesNotReplayOfferedInputAcrossReplacement\(/, "ingress replacement does not replay an offered input"],
    [ingress_tests, /func testRuntimeIngressReportsNoEligibleDestinationWithBoundedCounts\(/, "missing-destination failure proves one bounded retry, sanitized ledger rows, and observer notification"],
    [composition_tests, /func testIngressAdmissionFailurePresentsSanitizedRootNotice\(/, "host admission failure presents a sanitized root notice"],
    [composition_tests, /func testUnavailableDestinationFailurePresentsSanitizedRootNotice\(/, "unavailable destination failure presents a sanitized root notice"]
  ]
  present, missing = required_anchor_evidence(scanner, requirements)
  activation_completeness = ordered_activation_completeness_evidence(scanner, runtime)
  if activation_completeness.empty?
    missing.concat(
      scanner.marker(
        runtime,
        "required runtime proof is missing: same-generation published endpoint completeness must precede markActive"
      )
    )
  else
    present.concat(activation_completeness)
  end
  early_start_safety = early_start_stop_safety_evidence(scanner, runtime)
  if early_start_safety.empty?
    missing.concat(
      scanner.marker(
        runtime,
        "required runtime proof is missing: start must clear the stop flag before suspension and recheck it after every early await"
      )
    )
  else
    present.concat(early_start_safety)
  end
  stop_quiescence = ordered_stop_quiescence_evidence(scanner, runtime)
  if stop_quiescence.empty?
    missing.concat(
      scanner.marker(
        runtime,
        "required runtime proof is missing: client quiescence and accepted ingress drain must precede full dispatcher stop"
      )
    )
  else
    present.concat(stop_quiescence)
  end
  present = unique_evidence(present)
  missing = unique_evidence(missing)

  forbidden = [
    [/\bunsafeEndpointWithoutValidation\b/, "consumer or client can bypass runtime validation"],
    [/\bdispatchWithoutValidation\b/, "consumer or client can bypass runtime dispatch validation"],
    [/\bcallSkippingGenerationCheck\b/, "retained client can bypass generation checks"]
  ]
  violations = scanner.swift_finding_evidence("FG-006")
  shipping_swift_paths(scanner).each do |relative|
    forbidden.each do |pattern, detail|
      violations.concat(scanner.swift_code_evidence(relative, pattern, detail, all: true))
    end
  end
  consumer_paths = peer_service_consumer_paths(scanner)
  violations.concat(direct_core_type_evidence(scanner, consumer_paths))
  consumer_paths.each do |relative|
    unless relative == host
      violations.concat(
        scanner.swift_code_evidence(
          relative,
          /^\s*(?:@testable\s+)?import\s+RuneScribeCoreModule\b/,
          "UI or host consumer imports the Core implementation target",
          all: true
        )
      )
    end
    violations.concat(
      swift_type_usage_evidence(
        scanner,
        relative,
        "RuneScribeCoreApplicationService",
        "UI or host consumer retains or invokes a concrete Core service implementation"
      )
    )
  end
  violations.concat(
    concealed_peer_service_evidence(
      scanner,
      consumer_paths,
      "RuneScribeCoreApplicationService",
      "UI or host consumer retains or invokes a concrete Core service implementation"
    )
  )
  violations.concat(
    provider_returning_symbol_evidence(
      scanner,
      consumer_paths,
      "RuneScribeCoreApplicationService"
    )
  )
  violations.concat(
    direct_core_operation_evidence(
      scanner,
      consumer_paths,
      "RuneScribeCoreApplicationService"
    )
  )
  legacy_translation_forbidden = [
    [/\bmergeDeclarations\b/, "runtime retains the legacy declaration-merging authorization path"],
    [/\bconsumedEndpointIDs\b/, "runtime derives consumed endpoint authorization from legacy service declarations"],
    [/\bpublishedEndpointIDs\b/, "runtime derives published endpoint authorization from legacy service declarations"]
  ]
  scanner.files(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/**/*.swift"
  ).each_key do |relative|
    legacy_translation_forbidden.each do |pattern, detail|
      violations.concat(scanner.swift_code_evidence(relative, pattern, detail, all: true))
    end
  end
  violations.concat(
    scanner.swift_code_evidence(
      dispatcher,
      /public let (?:payload|request|response|errorDescription|filePath|url|pin|content):/,
      "runtime call ledger exposes secret-bearing operation data",
      all: true
    )
  )
  violations = unique_evidence(violations + missing)
  unless violations.empty?
    kind = missing.empty? ? "detected-source-anchor" : "detected-absence-anchor"
    return ["violation", violations, kind]
  end

  proof = present + scanner.marker(
    dispatcher,
    "Conservative fail-closed SwiftSyntax source-tree analysis traced typed command, query, state, and ingress clients through per-call runtime validation; consumer and runtime sources contain no direct Core bypass or legacy service-to-endpoint authorization translation"
  )
  ["pass", unique_evidence(proof), "detector-proof"]
end

def p04_semantic_rule(scanner, rule_id)
  guard_tests = "RuneScribArchitectureTests/ComplianceGuardTests.swift"
  required_fixture_markers = {
    "FG-007" => [
      [/testP04SemanticNegativeMutationsReportOnlyTheirExactRuleIDs/, "P04 semantic mutation test"],
      [/P04OperationalMutation\.swift/, "module operational API mutation fixture"],
      [/P04UnknownNativeBridgeMutation\.swift/, "UIRuntime bridge-path mutation fixture"],
      [/AVAudioRecorder is not allowlisted/, "UIRuntime bridge-symbol mutation fixture"],
      [/import AVFoundation/, "operational framework mutation fixture"],
      [/@AppStorage/, "AppStorage mutation fixture"],
      [/UserDefaults\.standard/, "UserDefaults mutation fixture"],
      [/session\.unvalidatedOpen\(\)/, "opaque authority acquisition mutation fixture"]
    ],
    "FG-009" => [
      [/P04FactoryMutation\.swift/, "uniform factory mutation fixture"],
      [/RuntimeTesting descriptor-and-closure/, "RuntimeTesting factory initializer mutation fixture"],
      [/imports the RuntimeTesting SPI/, "RuntimeTesting SPI import mutation fixture"],
      [/alternateFactory/, "labeled make and contextual init mutation fixture"],
      [/bootstrapFactory/, "closure-valued bootstrap factory mutation fixture"]
    ],
    "FG-016" => [
      [/P04ResourceBoundaryMutation\.swift/, "opaque resource boundary mutation fixture"],
      [/runtime generation and revocation validation/, "generation and revocation mutation fixture"],
      [/imports the RuntimeResourceHost SPI outside/, "unauthorized RuntimeResourceHost fixture"],
      [/guessedResourceViaInit/, "contextual ApplicationResource init mutation fixture"],
      [/subscript\(resource name:/, "raw resource subscript mutation fixture"],
      [/runtimeGeneration == lease\.runtimeGeneration/,
       "dead lifecycle-validation comparison mutation fixture"],
      [/if false \{/, "dead lifecycle-validation branch mutation fixture"]
    ]
  }

  qualification = []
  missing_qualification = []
  required_fixture_markers.fetch(rule_id).each do |pattern, detail|
    matches = scanner.evidence(guard_tests, pattern, detail)
    if matches.empty?
      missing_qualification.concat(
        scanner.marker(guard_tests, "required negative fixture is missing: #{detail}")
      )
    else
      qualification.concat(matches)
    end
  end

  violations = unique_evidence(
    scanner.swift_finding_evidence(rule_id) + missing_qualification
  )
  unless violations.empty?
    return ["violation", violations, "detected-source-anchor"]
  end

  proof = scanner.marker(
    "scripts/swift-compliance-scanner.swift",
    "SwiftSyntax fail-closed P04 analysis found no #{rule_id} violation across shipping module, runtime, host, platform, and UIRuntime sources"
  )
  proof = [{
    "path" => "scripts/swift-compliance-scanner.swift",
    "line" => 1,
    "detail" => "SwiftSyntax fail-closed P04 analysis found no #{rule_id} violation"
  }] if proof.empty?
  ["pass", unique_evidence(proof + qualification), "detector-proof"]
end

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
  when "FG-004"
    status, evidence, evidence_kind = provider_publication_rule(scanner)
  when "FG-005"
    status, evidence, evidence_kind = peer_service_retention_rule(scanner)
  when "FG-006"
    status, evidence, evidence_kind = runtime_dispatch_rule(scanner)
  when "FG-007", "FG-009", "FG-016"
    status, evidence, evidence_kind = p04_semantic_rule(scanner, id)
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
