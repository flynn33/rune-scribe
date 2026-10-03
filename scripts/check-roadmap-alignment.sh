#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
alignment_file="${1:-${RUNESCRIBE_ROADMAP_ALIGNMENT_FILE:-$repository_root/docs/verification/roadmap-alignment.json}}"

ruby - "$repository_root" "$alignment_file" <<'RUBY'
require "date"
require "digest"
require "json"
require "pathname"
require "set"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

root = Pathname(ARGV.fetch(0)).realpath
alignment_path = Pathname(ARGV.fetch(1)).expand_path

EXPECTED_TOP_LEVEL_KEYS = %w[
  schemaVersion asOfDate applicationVersion authority sourcePriority forsettiPolicy statusVocabulary taskCount taskGroups
].freeze
EXPECTED_APPLICATION_VERSION_KEYS = %w[marketing build].freeze
EXPECTED_AUTHORITY_KEYS = %w[
  systemSpec implementationRoadmap remediationAmendment repositoryAuditBaseline
].freeze
EXPECTED_FORSETTI_POLICY_KEYS = %w[
  status implementationOwnership externalDependencyAllowed perCallRuntimeMediationRequired
  runtimeOwnsOperationalIO runtimeOwnsPersistentSettings uiModuleOwnsViews controllingPolicy
].freeze
EXPECTED_GROUP_KEYS = %w[prefix wave dependsOn items].freeze
EXPECTED_ITEM_KEYS = %w[id status dependsOn evidence notes].freeze
EXPECTED_STATUSES = %w[
  satisfied transitional partial decision-frozen superseded owner-optional
  not-started not-applicable complete open variance-accepted-app-owned-equivalent
  simulator-replacement-complete non-gating-external deferred
].freeze
SIMULATOR_REPLACEMENT_TASKS = %w[BAS-006 SHR-001 SHR-015].freeze
NON_GATING_EXTERNAL_TASKS = %w[REL-011].freeze
EXPECTED_SOURCE_PRIORITY = [
  "active operator instructions",
  "operator-approved product-release scope and repository-controlled release gates",
  "actual local repository behavior and compatibility identifiers",
  "Forsetti Compliance Audit v2.0 factual findings",
  "locked product decisions not superseded by later operator clarification",
  "third-party audit nonconflicting facts only",
  "general conventions"
].freeze
EXPECTED_GROUPS = {
  "BAS" => ["0A", 10],
  "FOR" => ["0B", 11],
  "MOD" => ["1A", 13],
  "DOM" => ["1B", 7],
  "PKG" => ["1B", 6],
  "THM" => ["2", 12],
  "PRO" => ["3", 16],
  "SHR" => ["4", 17],
  "CLD" => ["5A", 11],
  "GC" => ["5B", 10],
  "REL" => ["6", 11]
}.freeze
EXPECTED_DOCUMENTS = {
  "systemSpec" => {
    "path" => "docs/product-roadmap/Rune-Scribe-Codex-System-Spec-v1.0.md",
    "sha256" => "7c4c460815064fca87a6769766fb875f267eb692795bbab2635eec5d55d8f88d"
  },
  "implementationRoadmap" => {
    "path" => "docs/product-roadmap/Rune-Scribe-Codex-Current-App-Delta-and-Implementation-Roadmap-v1.0.md",
    "sha256" => "884ad563f7849ebda8326bc742493ce67fb89cfacc14b39e56c792c4f7c52db4"
  },
  "remediationAmendment" => {
    "path" => "docs/product-roadmap/Rune-Scribe-Codex-Roadmap-Remediation-Amendment-v1.1.md",
    "sha256" => "2b6ce54c50538419d324692ebfeec1bb29de46add9f354368d39169d6f74ed40"
  }
}.freeze
EXPECTED_FORSETTI_POLICY = {
  "status" => "active",
  "implementationOwnership" => "app-owned",
  "externalDependencyAllowed" => false,
  "perCallRuntimeMediationRequired" => true,
  "runtimeOwnsOperationalIO" => true,
  "runtimeOwnsPersistentSettings" => true,
  "uiModuleOwnsViews" => true
}.freeze
EXPECTED_CONTROLLING_POLICY = {
  "path" => "docs/architecture/FORSETTI_CONTROLLING_POLICY.md",
  "sha256" => "2e7c3729d51724929838269d29c71bb2dd92caa4976167cb4275f9ece6d55db6"
}.freeze
EXPECTED_ADRS = %w[
  ADR-RS-001-module-packaging-and-target-graph.md
  ADR-RS-002-cipher-and-script.md
  ADR-RS-003-legacy-font-compatibility.md
  ADR-RS-004-typed-runescribe-container.md
  ADR-RS-005-forward-compatibility.md
  ADR-RS-006-share-route-completion.md
  ADR-RS-007-themed-follow-up-transport.md
  ADR-RS-008-progression-persistence.md
  ADR-RS-009-relationship-token.md
  ADR-RS-010-theme-resource-budgets.md
  ADR-RS-011-game-center-records.md
  ADR-RS-012-cipher-invitation-presentation.md
  ADR-RS-013-production-theme-resource-budgets.md
  ADR-RS-014-interactive-messages-cipher-invitations.md
].freeze

def exact_keys(value, expected, label, errors)
  unless value.is_a?(Hash)
    errors << "#{label} must be an object"
    return false
  end

  missing = expected - value.keys
  unknown = value.keys - expected
  errors << "#{label} is missing keys: #{missing.join(', ')}" unless missing.empty?
  errors << "#{label} has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
  missing.empty? && unknown.empty?
end

def nonempty_unique_strings(value)
  value.is_a?(Array) && !value.empty? &&
    value.all? { |item| item.is_a?(String) && !item.strip.empty? } &&
    value.uniq == value
end

def optional_unique_strings(value)
  value.is_a?(Array) &&
    value.all? { |item| item.is_a?(String) && !item.strip.empty? } &&
    value.uniq == value
end

def expected_task_ids
  EXPECTED_GROUPS.flat_map do |prefix, (_wave, count)|
    (1..count).map { |number| format("%s-%03d", prefix, number) }
  end
end

def prohibited_credit?(text)
  credit_phrases = [
    %w[co authored by].join("-"),
    %w[generated with].join(" "),
    %w[generated by].join(" "),
    %w[written with].join(" "),
    %w[written by].join(" "),
    %w[authored with].join(" "),
    %w[authored by].join(" ")
  ]
  tool_tokens = [
    %w[cl aude].join,
    %w[chat gpt].join,
    %w[open ai].join,
    %w[anthro pic].join,
    %w[co pilot].join,
    %w[gem ini].join,
    %w[cur sor].join,
    %w[code ium].join,
    %w[aid er].join,
    %w[dev in].join,
    %w[co dy].join,
    %w[tab nine].join,
    %w[sour cery].join,
    %w[assi stant].join,
    %w[l lm].join
  ]

  text.downcase.lines.any? do |line|
    credit_phrases.any? { |phrase| line.include?(phrase) } &&
      tool_tokens.any? { |token| line.match?(/(?:\A|[^a-z0-9])#{Regexp.escape(token)}(?:\z|[^a-z0-9])/) }
  end || text.include?("\u{1F916}")
end

def validate(document, root)
  errors = []
  return ["roadmap alignment root must be an object"] unless document.is_a?(Hash)

  exact_keys(document, EXPECTED_TOP_LEVEL_KEYS, "roadmap alignment", errors)
  errors << "schemaVersion must be 1.2" unless document["schemaVersion"] == "1.2"
  begin
    Date.iso8601(document["asOfDate"])
  rescue ArgumentError, TypeError
    errors << "asOfDate must be an ISO-8601 calendar date"
  end

  application_version = document["applicationVersion"]
  if exact_keys(application_version, EXPECTED_APPLICATION_VERSION_KEYS, "applicationVersion", errors)
    errors << "applicationVersion.marketing must be 1.0.45" unless application_version["marketing"] == "1.0.45"
    errors << "applicationVersion.build must be 45" unless application_version["build"] == "45"
  end

  authority = document["authority"]
  if exact_keys(authority, EXPECTED_AUTHORITY_KEYS, "authority", errors)
    EXPECTED_DOCUMENTS.each do |name, expected|
      record = authority[name]
      exact_keys(record, %w[path sha256], "authority.#{name}", errors)
      unless record == expected
        errors << "authority.#{name} must retain the locked path and SHA-256"
        next
      end

      path = root.join(record["path"])
      if !path.file?
        errors << "authority.#{name} file is missing: #{record['path']}"
      elsif Digest::SHA256.file(path).hexdigest != record["sha256"]
        errors << "authority.#{name} content differs from its locked SHA-256"
      end
    end
    baseline = authority["repositoryAuditBaseline"]
    errors << "authority.repositoryAuditBaseline must be a full Git revision" unless baseline.to_s.match?(/\A[0-9a-f]{40}\z/)
  end

  unless document["sourcePriority"] == EXPECTED_SOURCE_PRIORITY
    errors << "FG-020: sourcePriority must retain the exact controlling authority order"
  end

  forsetti_policy = document["forsettiPolicy"]
  if exact_keys(forsetti_policy, EXPECTED_FORSETTI_POLICY_KEYS, "forsettiPolicy", errors)
    EXPECTED_FORSETTI_POLICY.each do |field, expected|
      rule_id = field == "externalDependencyAllowed" ? "FG-001" : "FG-020"
      unless forsetti_policy[field] == expected
        errors << "#{rule_id}: forsettiPolicy.#{field} must be #{expected.inspect}"
      end
    end

    policy_record = forsetti_policy["controllingPolicy"]
    exact_keys(policy_record, %w[path sha256], "forsettiPolicy.controllingPolicy", errors)
    unless policy_record == EXPECTED_CONTROLLING_POLICY
      errors << "FG-020: forsettiPolicy.controllingPolicy must retain the canonical path and SHA-256"
    end

    if policy_record.is_a?(Hash)
      policy_path = root.join(policy_record["path"].to_s)
      if !policy_path.file?
        errors << "FG-020: controlling policy file is missing: #{policy_record['path']}"
      elsif Digest::SHA256.file(policy_path).hexdigest != policy_record["sha256"]
        errors << "FG-020: controlling policy content differs from its locked SHA-256"
      end
    end
  end

  vocabulary = document["statusVocabulary"]
  if vocabulary.is_a?(Hash)
    errors << "statusVocabulary must contain the exact allowed statuses" unless vocabulary.keys == EXPECTED_STATUSES
    vocabulary.each do |status, description|
      errors << "statusVocabulary.#{status} must have a non-empty description" unless description.is_a?(String) && !description.strip.empty?
    end
  else
    errors << "statusVocabulary must be an object"
  end

  expected_ids = expected_task_ids
  errors << "taskCount must be #{expected_ids.length}" unless document["taskCount"] == expected_ids.length

  groups = document["taskGroups"]
  unless groups.is_a?(Array)
    errors << "taskGroups must be an array"
    groups = []
  end
  errors << "taskGroups must contain the exact ordered prefix universe" unless groups.map { |group| group.is_a?(Hash) ? group["prefix"] : nil } == EXPECTED_GROUPS.keys

  all_items = []
  groups.each_with_index do |group, group_index|
    label = "taskGroups[#{group_index}]"
    next unless exact_keys(group, EXPECTED_GROUP_KEYS, label, errors)

    prefix = group["prefix"]
    policy = EXPECTED_GROUPS[prefix]
    errors << "#{label}.prefix is unknown" unless policy
    errors << "#{label}.wave must be #{policy[0]}" if policy && group["wave"] != policy[0]
    errors << "#{label}.dependsOn must contain unique strings" unless optional_unique_strings(group["dependsOn"])

    items = group["items"]
    unless items.is_a?(Array)
      errors << "#{label}.items must be an array"
      next
    end
    errors << "#{label}.items must contain #{policy[1]} tasks" if policy && items.length != policy[1]

    items.each_with_index do |item, item_index|
      item_label = "#{label}.items[#{item_index}]"
      next unless exact_keys(item, EXPECTED_ITEM_KEYS, item_label, errors)
      all_items << item
      errors << "#{item_label}.id must use prefix #{prefix}" unless item["id"].to_s.match?(/\A#{Regexp.escape(prefix.to_s)}-\d{3}\z/)
      errors << "#{item_label}.status is not allowed" unless EXPECTED_STATUSES.include?(item["status"])
      errors << "#{item_label}.dependsOn must contain unique strings" unless optional_unique_strings(item["dependsOn"])
      errors << "#{item_label}.evidence must contain non-empty unique strings" unless nonempty_unique_strings(item["evidence"])
      errors << "#{item_label}.notes must be non-empty" unless item["notes"].is_a?(String) && !item["notes"].strip.empty?
      if prefix == "FOR" && item["status"] != "variance-accepted-app-owned-equivalent"
        errors << "#{item_label} must remain variance-accepted-app-owned-equivalent and may not be complete as written"
      end
    end
  end

  ids = all_items.map { |item| item["id"] }
  errors << "task IDs must be unique" unless ids.uniq == ids
  errors << "task IDs must match the exact roadmap universe" unless ids == expected_ids

  simulator_replacement_ids = all_items
    .select { |item| item["status"] == "simulator-replacement-complete" }
    .map { |item| item["id"] }
  unless simulator_replacement_ids == SIMULATOR_REPLACEMENT_TASKS
    errors << "simulator-replacement-complete tasks must be exactly #{SIMULATOR_REPLACEMENT_TASKS.join(', ')}"
  end
  all_items.each do |item|
    if item["status"] == "owner-optional"
      errors << "owner-optional status is superseded by the remediation amendment"
    end
    if item["status"] == "simulator-replacement-complete" && !Array(item["dependsOn"]).empty?
      errors << "simulator-replacement-complete task #{item['id']} may not retain dependencies"
    end
    blocked_replacement = Array(item["dependsOn"]) & SIMULATOR_REPLACEMENT_TASKS
    unless blocked_replacement.empty?
      errors << "task #{item['id']} may not depend on simulator replacement #{blocked_replacement.join(', ')}"
    end
  end

  non_gating_external_ids = all_items
    .select { |item| item["status"] == "non-gating-external" }
    .map { |item| item["id"] }
  unless non_gating_external_ids == NON_GATING_EXTERNAL_TASKS
    errors << "non-gating-external tasks must be exactly #{NON_GATING_EXTERNAL_TASKS.join(', ')}"
  end

  permitted_dependencies = (expected_ids + (1..12).map { |number| format("ADR-RS-%03d", number) }).to_set
  groups.each_with_index do |group, group_index|
    next unless group.is_a?(Hash)
    Array(group["dependsOn"]).each do |dependency|
      errors << "taskGroups[#{group_index}] has unknown dependency #{dependency}" unless permitted_dependencies.include?(dependency)
      if group["prefix"] != "FOR" && dependency.to_s.start_with?("FOR-")
        errors << "taskGroups[#{group_index}] active group may not depend on variance-classified #{dependency}"
      end
    end
    Array(group["items"]).each do |item|
      next unless item.is_a?(Hash)
      Array(item["dependsOn"]).each do |dependency|
        errors << "task #{item['id']} has unknown dependency #{dependency}" unless permitted_dependencies.include?(dependency)
        if group["prefix"] != "FOR" && dependency.to_s.start_with?("FOR-")
          errors << "task #{item['id']} may not depend on variance-classified #{dependency}"
        end
      end
      Array(item["evidence"]).each do |evidence|
        begin
          path = Pathname(evidence)
          if path.absolute? || path.each_filename.any? { |component| component == ".." }
            errors << "task #{item['id']} evidence must be repository-relative: #{evidence}"
          elsif !root.join(path).exist?
            errors << "task #{item['id']} evidence path is missing: #{evidence}"
          end
        rescue TypeError
          errors << "task #{item['id']} evidence path is invalid"
        end
      end
    end
  end

  decisions_root = root.join("docs/architecture/decisions")
  actual_adrs = Dir.glob(decisions_root.join("ADR-RS-*.md").to_s).map { |path| File.basename(path) }.sort
  errors << "architecture decisions must contain exactly ADR-RS-001 through ADR-RS-014" unless actual_adrs == EXPECTED_ADRS.sort
  index_path = decisions_root.join("README.md")
  if !index_path.file?
    errors << "architecture decision index is missing"
  else
    index_text = index_path.read
    EXPECTED_ADRS.each do |basename|
      errors << "architecture decision index must link #{basename}" unless index_text.include?(basename)
    end
  end

  EXPECTED_ADRS.each_with_index do |basename, index|
    path = decisions_root.join(basename)
    next unless path.file?
    text = path.read
    identifier = format("ADR-RS-%03d", index + 1)
    errors << "#{basename} must have the expected decision heading" unless text.lines.first.to_s.include?(identifier)
    status_line = text.lines.find { |line| line.match?(/\*\*Status:\*\*/i) }
    expected_status = index.zero? ? /Superseded/i : /Accepted/i
    errors << "#{basename} must retain its recorded decision status" unless status_line&.match?(expected_status)
  end

  errors << "roadmap alignment contains prohibited authorship credit" if prohibited_credit?(JSON.generate(document))
  errors
end

unless alignment_path.file?
  warn "Roadmap alignment guard failed:"
  warn "- missing #{alignment_path}"
  exit 1
end

begin
  document = JSON.parse(alignment_path.read)
rescue JSON::ParserError => error
  warn "Roadmap alignment guard failed:"
  warn "- invalid JSON: #{error.message}"
  exit 1
end

errors = validate(document, root)

negative_cases = {
  "duplicate task" => {
    "expected" => "task IDs must be unique",
    "mutation" => lambda do |copy|
      copy["taskGroups"][0]["items"][1]["id"] = copy["taskGroups"][0]["items"][0]["id"]
    end
  },
  "external dependency permission" => {
    "expected" => "FG-001: forsettiPolicy.externalDependencyAllowed must be false",
    "mutation" => lambda do |copy|
      copy["forsettiPolicy"]["externalDependencyAllowed"] = true
    end
  },
  "authority hash drift" => {
    "expected" => "authority.systemSpec must retain the locked path and SHA-256",
    "mutation" => lambda do |copy|
      copy["authority"]["systemSpec"]["sha256"] = "0" * 64
    end
  },
  "amendment hash drift" => {
    "expected" => "authority.remediationAmendment must retain the locked path and SHA-256",
    "mutation" => lambda do |copy|
      copy["authority"]["remediationAmendment"]["sha256"] = "0" * 64
    end
  },
  "external framework task called complete" => {
    "expected" => "taskGroups[1].items[0] must remain variance-accepted-app-owned-equivalent and may not be complete as written",
    "mutation" => lambda do |copy|
      copy["taskGroups"][1]["items"][0]["status"] = "complete"
    end
  },
  "public rollout called complete" => {
    "expected" => "non-gating-external tasks must be exactly REL-011",
    "mutation" => lambda do |copy|
      copy["taskGroups"].last["items"].last["status"] = "complete"
    end
  },
  "controlling policy hash drift" => {
    "expected" => "FG-020: forsettiPolicy.controllingPolicy must retain the canonical path and SHA-256",
    "mutation" => lambda do |copy|
      copy["forsettiPolicy"]["controllingPolicy"]["sha256"] = "0" * 64
    end
  },
  "authorship credit" => {
    "expected" => "roadmap alignment contains prohibited authorship credit",
    "mutation" => lambda do |copy|
      credit = %w[generated with].join(" ")
      tool = %w[chat gpt].join
      copy["taskGroups"][0]["items"][0]["notes"] = [credit, tool].join(" ")
    end
  }
}

negative_cases.each do |name, test_case|
  copy = Marshal.load(Marshal.dump(document))
  test_case.fetch("mutation").call(copy)
  negative_errors = validate(copy, root)
  expected_error = test_case.fetch("expected")
  unless negative_errors.include?(expected_error)
    errors << "internal negative check failed: #{name}; expected #{expected_error.inspect}"
  end
end

if errors.empty?
  puts "Roadmap alignment guard passed: #{expected_task_ids.length} tasks, 14 decisions, immutable v1.0 authorities, remediation amendment, and variance semantics verified."
  exit 0
end

warn "Roadmap alignment guard failed:"
errors.uniq.each { |error| warn "- #{error}" }
exit 1
RUBY

python3 "$repository_root/scripts/check-roadmap-completion.py"
