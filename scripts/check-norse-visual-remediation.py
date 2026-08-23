#!/usr/bin/env python3
"""Validate the Norse visual remediation source, policy, and final evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional, Sequence, Union


EXPECTED_VERSION = "1.0.38"
EXPECTED_BUILD = "38"
EXPECTED_MANIFEST_SHA256 = (
    "8bfb935ca4d3b82bdee00ce0f21756811e0d34460c9002dfed4c56ce13f1eb0a"
)
EXPECTED_FONT_SHA256 = (
    "615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b"
)

REQUIRED_EVIDENCE_JSON = (
    "Baseline.json",
    "ResourceCoverage.json",
    "ActiveVisualPlanValidation.json",
    "RuntimeResolutionValidation.json",
    "InteractiveStaticParity.json",
    "AccessibilityValidation.json",
    "SimulatorVisualValidation.json",
    "CrossProviderVisualValidation.json",
    "NegativeMutations.json",
    "FullRegression.json",
)
REQUIRED_EVIDENCE_MARKDOWN = (
    "Diagnosis.md",
    "FinalSelfAudit.md",
    "OwnerTestHandoff.md",
)
REQUIRED_SCREENSHOTS = (
    "iphone-workspace-norse.png",
    "iphone-artifact-picker-norse.png",
    "iphone-settings-norse.png",
    "iphone-vault-norse.png",
    "ipad-workspace-norse.png",
    "ipad-vault-norse.png",
    "macos-workspace-norse.png",
    "macos-settings-norse.png",
    "macos-vault-norse.png",
)
EXPECTED_SWIFTPM_TEST_TARGETS = {
    "RuneScribeRuntimeCoreTests",
    "RuneScribePlatformTests",
    "RuneScribeCoreModuleTests",
    "RuneScribeProgressionModuleTests",
    "RuneScribeNorseThemeModuleTests",
    "RuneScribeThemeMoonleafModuleTests",
    "RuneScribeThemeSunspireModuleTests",
    "RuneScribeThemeWildwoodModuleTests",
    "RuneScribeThemeGloamthornModuleTests",
    "RuneScribeCloudSyncModuleTests",
    "RuneScribeGameCenterModuleTests",
    "RuneScribeThemeCoordinatorModuleTests",
    "RuneScribeUIModuleTests",
    "RuneScribeArchitectureTests",
}
EXPECTED_XCODE_TEST_TARGETS = {
    "RuneScribTests",
    "RuneScribIOSTests",
    "RuneScribIOSUITests",
    "RuneScribMacParityTests",
    "RuneScribArchitectureTests",
}
EXPECTED_SCHEMES = {
    "RuneScrib-macOS",
    "RuneScrib-iOS",
    "RuneScrib-iOS-Parity",
    "RuneScrib-macOS-Parity",
}
EXPECTED_GUARD_SCRIPTS = {
    "check-architecture.sh",
    "check-roadmap-alignment.sh",
    "check-roadmap-completion.py",
    "check-documentation-alignment.py",
    "check-forsetti-compliance.sh",
    "check-shipping-products.sh",
    "test-shipping-products.sh",
    "validate-elven-recovery-state.py",
}


@dataclass(frozen=True)
class Finding:
    gate: str
    rule: str
    message: str
    path: Optional[str] = None


class Validator:
    def __init__(self, root: Path, profile: str) -> None:
        self.root = root.resolve()
        self.profile = profile
        self.findings: list[Finding] = []
        self.checks: list[str] = []

    def add(
        self,
        gate: str,
        rule: str,
        message: str,
        path: Optional[Union[Path, str]] = None,
    ) -> None:
        relative: Optional[str]
        if isinstance(path, Path):
            try:
                relative = path.resolve().relative_to(self.root).as_posix()
            except ValueError:
                relative = str(path)
        else:
            relative = path
        self.findings.append(Finding(gate, rule, message, relative))

    def require(
        self,
        condition: bool,
        gate: str,
        rule: str,
        message: str,
        path: Optional[Union[Path, str]] = None,
    ) -> None:
        self.checks.append(f"{gate}/{rule}")
        if not condition:
            self.add(gate, rule, message, path)

    def read(self, relative: str, gate: str, rule: str) -> str:
        path = self.root / relative
        if not path.is_file():
            self.add(gate, rule, "required file is missing", relative)
            return ""
        try:
            return path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            self.add(gate, rule, f"cannot read UTF-8 source: {error}", relative)
            return ""

    def json_record(self, relative: str, gate: str, rule: str) -> Optional[dict[str, Any]]:
        text = self.read(relative, gate, rule)
        if not text:
            return None
        try:
            value = json.loads(text)
        except json.JSONDecodeError as error:
            self.add(gate, rule, f"invalid JSON: {error}", relative)
            return None
        if not isinstance(value, dict):
            self.add(gate, rule, "JSON root must be an object", relative)
            return None
        return value

    def run(self) -> None:
        self.check_release_boundary()
        self.check_resource_integrity()
        self.check_generic_architecture()
        self.check_visual_plan()
        self.check_runtime_resolution_and_cache()
        self.check_atomic_state()
        self.check_shared_rendering_and_surfaces()
        self.check_fallback_and_access_semantics()
        self.check_required_tests_and_identifiers()
        self.check_regression_inventory()
        self.check_owner_operator_boundary()
        if self.profile == "final":
            self.check_evidence_package()

    def check_release_boundary(self) -> None:
        project = self.read("project.yml", "NRV-024", "version-build")
        version = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', project)
        build = re.search(r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', project)
        self.require(
            version is not None and version.group(1) == EXPECTED_VERSION,
            "NRV-024",
            "version-build",
            f"MARKETING_VERSION must remain {EXPECTED_VERSION}",
            "project.yml",
        )
        self.require(
            build is not None and build.group(1) == EXPECTED_BUILD,
            "NRV-024",
            "version-build",
            f"CURRENT_PROJECT_VERSION must remain {EXPECTED_BUILD}",
            "project.yml",
        )
        pbx = self.read(
            "RuneScrib.xcodeproj/project.pbxproj", "NRV-024", "generated-version-build"
        )
        self.require(
            set(re.findall(r"MARKETING_VERSION = ([^;]+);", pbx)) == {EXPECTED_VERSION},
            "NRV-024",
            "generated-version-build",
            "generated project marketing version drifted",
            "RuneScrib.xcodeproj/project.pbxproj",
        )
        self.require(
            set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", pbx)) == {EXPECTED_BUILD},
            "NRV-024",
            "generated-version-build",
            "generated project build number drifted",
            "RuneScrib.xcodeproj/project.pbxproj",
        )

    def check_resource_integrity(self) -> None:
        relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
            "Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v1.0.json"
        )
        manifest_path = self.root / relative
        if not manifest_path.is_file():
            self.add("NRV-002", "norse-resource-integrity", "accepted manifest is missing", relative)
            return
        manifest_data = manifest_path.read_bytes()
        self.require(
            hashlib.sha256(manifest_data).hexdigest() == EXPECTED_MANIFEST_SHA256,
            "NRV-002",
            "norse-resource-integrity",
            "accepted Norse integrity manifest bytes changed",
            relative,
        )
        try:
            manifest = json.loads(manifest_data)
        except json.JSONDecodeError as error:
            self.add("NRV-002", "norse-resource-integrity", f"invalid manifest JSON: {error}", relative)
            return
        entries = manifest.get("resources", []) if isinstance(manifest, dict) else []
        self.require(
            isinstance(entries, list) and len(entries) == 47,
            "NRV-002",
            "norse-resource-integrity",
            "accepted manifest must contain exactly 47 resources",
            relative,
        )
        resource_root = manifest_path.parents[3]
        candidates: dict[str, list[Path]] = {}
        for path in resource_root.rglob("*"):
            if path.is_file() and path != manifest_path:
                candidates.setdefault(path.name, []).append(path)
        for entry in entries if isinstance(entries, list) else []:
            if not isinstance(entry, dict):
                self.add("NRV-002", "norse-resource-integrity", "manifest resource is not an object", relative)
                continue
            basename = Path(str(entry.get("path", ""))).name
            matches = candidates.get(basename, [])
            if len(matches) != 1:
                self.add(
                    "NRV-002",
                    "norse-resource-integrity",
                    f"resource {basename!r} does not resolve uniquely in the provider module",
                    relative,
                )
                continue
            data = matches[0].read_bytes()
            expected_length = entry.get("byteLength")
            expected_hash = entry.get("sha256")
            if len(data) != expected_length or hashlib.sha256(data).hexdigest() != expected_hash:
                self.add(
                    "NRV-002",
                    "norse-resource-integrity",
                    f"resource bytes differ from accepted manifest: {basename}",
                    matches[0],
                )

        test_relative = (
            "Packages/RuneScribeArchitecture/Tests/RuneScribeNorseThemeModuleTests/"
            "NorseBaseThemeModuleTests.swift"
        )
        test_source = self.read(test_relative, "NRV-002", "resource-hash-fixture")
        self.require(
            test_source.count(EXPECTED_FONT_SHA256) >= 2,
            "NRV-002",
            "resource-hash-fixture",
            "frozen font hash fixture no longer checks descriptor and copied bytes",
            test_relative,
        )
        descriptor_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
            "NorseBaseThemeDescriptor.swift"
        )
        descriptor = self.read(descriptor_relative, "NRV-004", "norse-script-identity")
        self.require(
            'ScriptID(rawValue: "script.base-runes")!' in descriptor,
            "NRV-004",
            "norse-script-identity",
            "required Base Script identity changed",
            descriptor_relative,
        )

    def check_generic_architecture(self) -> None:
        ui_root = self.root / "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule"
        swift_files = sorted(ui_root.rglob("*.swift")) if ui_root.is_dir() else []
        self.require(
            bool(swift_files),
            "NRV-017",
            "generic-ui-module",
            "production UI source root is missing",
            ui_root,
        )
        provider_import = re.compile(
            r"^\s*import\s+RuneScribe(?:NorseTheme|Theme(?:Moonleaf|Sunspire|Wildwood|Gloamthorn))Module\s*$",
            re.MULTILINE,
        )
        for path in swift_files:
            source = path.read_text(encoding="utf-8")
            self.require(
                provider_import.search(source) is None,
                "NRV-017",
                "provider-import",
                "production UI imports a Theme provider module",
                path,
            )
            if path.name != "UIModule.swift":
                self.require(
                    "Bundle.module" not in source,
                    "NRV-005",
                    "runtime-resource-boundary",
                    "production UI bypasses runtime resolution with Bundle.module",
                    path,
                )
                self.require(
                    ".resourceBundle" not in source,
                    "NRV-005",
                    "runtime-resource-boundary",
                    "production UI references a provider resource bundle",
                    path,
                )

        generic_visual_paths = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
            "SemanticThemePresentation.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
            "ThemeVisualComponents.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/"
            "ShareArtifactRenderer.swift",
        )
        provider_id = re.compile(
            r'\b(?:theme|codex|relic|seal|frame|crest)\.(?:norse|moonleaf|sunspire|wildwood|gloamthorn)(?:\.|"|$)',
            re.IGNORECASE,
        )
        provider_branch = re.compile(
            r"(?:if|guard|switch|case).{0,180}(?:RuneScribeCodexIDs\.(?:norse|moonleaf|sunspire|wildwood|gloamthorn)|"
            r"(?:codex|theme)\.(?:norse|moonleaf|sunspire|wildwood|gloamthorn))",
            re.IGNORECASE | re.DOTALL,
        )
        for relative in generic_visual_paths:
            source = self.read(relative, "NRV-017", "provider-neutral-visual-path")
            self.require(
                provider_id.search(source) is None and provider_branch.search(source) is None,
                "NRV-017",
                "provider-neutral-visual-path",
                "generic production visual code contains a provider-specific ID or branch",
                relative,
            )
        share_policy = self.read(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/"
            "ShareArtifactRenderer.swift",
            "NRV-017",
            "required-base-semantics",
        )
        selection_body = swift_function_body(share_policy, "selection")
        self.require(
            selection_body is not None
            and "descriptor.criticality == .requiredBase" in selection_body,
            "NRV-017",
            "required-base-semantics",
            "generic selection policy does not use provider-neutral required-base semantics",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/"
            "ShareArtifactRenderer.swift",
        )

    def check_visual_plan(self) -> None:
        relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
            "SemanticThemePresentation.swift"
        )
        source = self.read(relative, "NRV-004", "active-visual-plan")
        image_plan = swift_declaration_body(source, "struct", "ThemeVisualImagePlan")
        self.require(
            image_plan is not None
            and all(
                token in image_plan
                for token in (
                    "let role",
                    "let mediaType",
                    "let byteLength",
                    "let pixelSize",
                    "let sha256",
                    "ThemeResourceReference",
                )
            ),
            "NRV-004",
            "resource-reference-metadata",
            "visual image plan must preserve role, media, length, dimensions, and hash",
            relative,
        )
        plan = swift_declaration_body(source, "struct", "ActiveThemeVisualResourcePlan")
        required_plan_tokens = (
            "let revision",
            "let codex",
            "let scriptID",
            "let relics",
            "let seals",
            "let frames",
            "let crests",
            "let selectedRelicID",
            "let selectedSealID",
            "let selectedFrameID",
            "descriptor.resources",
            "descriptor.codex.relics.compactMap",
            "descriptor.codex.seals.compactMap",
            "descriptor.codex.frames.compactMap",
            "descriptor.codex.crests.compactMap",
        )
        self.require(
            plan is not None and all(token in plan for token in required_plan_tokens),
            "NRV-004",
            "active-visual-plan",
            "descriptor-derived active plan is incomplete",
            relative,
        )
        self.require(
            plan is not None
            and "relics = try descriptor.codex.relics.compactMap" in plan
            and "selectedRelic" in plan,
            "NRV-004",
            "active-relic-plan",
            "active Relic resources are not represented in the visual plan",
            relative,
        )
        self.require(
            plan is not None
            and all(
                token in plan
                for token in (
                    "card: try image(vault.cardResourceID)",
                    "locked: try image(vault.lockedSilhouetteResourceID)",
                    "encountered: try image(vault.encounteredResourceID)",
                    "selected: try image(vault.selectedResourceID)",
                )
            ),
            "NRV-004",
            "codex-card-plan",
            "Codex card states are not resolved from descriptor-declared roles",
            relative,
        )
        selected_seal = swift_property_body(plan or "", "selectedSeal")
        self.require(
            selected_seal is not None
            and "selectedSealID.flatMap" in selected_seal
            and "seals.first" in selected_seal,
            "NRV-007",
            "selected-seal-thumbnail",
            "selected Seal no longer has a descriptor-derived visual path",
            relative,
        )

    def check_runtime_resolution_and_cache(self) -> None:
        contracts_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
            "ThemeCoordinatorContracts.swift"
        )
        contracts = self.read(contracts_relative, "NRV-005", "resolution-purpose")
        self.require(
            all(
                token in contracts
                for token in (
                    "ThemeResourceResolutionPurpose",
                    "activePresentation",
                    "catalogPreview",
                    "ResolveThemeResourceRequestDTO",
                    "let purpose",
                )
            ),
            "NRV-005",
            "resolution-purpose",
            "runtime contract does not distinguish active and catalog-preview authorization",
            contracts_relative,
        )
        service_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/"
            "ThemeCoordinatorService.swift"
        )
        service = self.read(service_relative, "NRV-005", "catalog-preview-authorization")
        self.require(
            "isCatalogPreviewResource" in service
            and ".activePresentation" in service
            and ".catalogPreview" in service
            and "declaredPreviewResourceIDs" in service
            and "availability != .reservedInactive" in service,
            "NRV-005",
            "catalog-preview-authorization",
            "coordinator does not authorize descriptor-declared catalog previews by purpose",
            service_relative,
        )
        runtime_core_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift"
        )
        runtime_core = self.read(
            runtime_core_relative,
            "NRV-005",
            "locked-preview-publisher",
        )
        self.require(
            "isThemePreviewPublisher" in runtime_core
            and "registration.themeDiscovery != nil" in runtime_core
            and "RuneScribePolicyClasses.themeProvider" in runtime_core,
            "NRV-005",
            "locked-preview-publisher",
            "locked preview publication is not constrained to validated Theme providers",
            runtime_core_relative,
        )
        runtime_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/"
            "RuntimeApplicationResourcePresentation.swift"
        )
        runtime = self.read(runtime_relative, "NRV-005", "bounded-image-reference")
        required_runtime_tokens = (
            "RuntimeThemeImageReference",
            "RuntimeThemeImageKind",
            "makeThemeImageReference",
            "resolvedResource:",
            "expectedReference:",
            "expectedCodexID:",
            "contentRevision:",
            "maximumEncodedImageByteCount",
            "maximumTotalEncodedImageByteCount",
            "maximumDecodedByteCount",
            "maximumEntryCount",
            "retain",
            "release",
        )
        self.require(
            all(token in runtime for token in required_runtime_tokens),
            "NRV-005",
            "bounded-image-reference",
            "runtime image references or bounded cache semantics are incomplete",
            runtime_relative,
        )
        limits = {
            "maximumEncodedImageByteCount": 8 * 1_024 * 1_024,
            "maximumTotalEncodedImageByteCount": 64 * 1_024 * 1_024,
            "maximumDecodedByteCount": 64 * 1_024 * 1_024,
            "maximumEntryCount": 512,
        }
        for name, ceiling in limits.items():
            value = swift_integer_constant(runtime, name)
            self.require(
                value is not None and 0 < value <= ceiling,
                "NRV-005",
                "cache-budget",
                f"{name} must be present and no greater than {ceiling}",
                runtime_relative,
            )
        self.require(
            "DispatchSourceMemoryPressure" in runtime
            and ("purge" in runtime or "removeAll" in runtime),
            "NRV-005",
            "memory-pressure-eviction",
            "decoded resource cache lacks memory-pressure eviction",
            runtime_relative,
        )

    def check_atomic_state(self) -> None:
        relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/"
            "RuneScribeUISession.swift"
        )
        source = self.read(relative, "NRV-006", "atomic-visual-state")
        self.require(
            all(
                token in source
                for token in (
                    "themeResourceTask?.cancel()",
                    "themeAdoptionGeneration &+= 1",
                    "themeAdoptionGeneration == adoptionGeneration",
                    "activeThemeVisualPresentation",
                    "ActiveThemeVisualResourcePlan",
                    "ActiveThemeVisualPresentation",
                )
            ),
            "NRV-006",
            "stale-adoption",
            "visual adoption lacks cancellation, generation validation, or revisioned state",
            relative,
        )
        body = swift_function_body(source, "resolveAndCommitTheme")
        prepared_index = max(
            (body or "").find("ActiveThemeVisualPresentation"),
            (body or "").find("preparedVisual"),
        )
        commit_index = (body or "").rfind("activeThemeVisualPresentation =")
        last_resolution_index = max(
            (body or "").rfind("await"),
            (body or "").rfind("makeThemeImageReference"),
        )
        self.require(
            body is not None
            and prepared_index >= 0
            and commit_index > prepared_index
            and commit_index > last_resolution_index,
            "NRV-006",
            "atomic-visual-state",
            "active visual state publishes before preparation and required resolution finish",
            relative,
        )

    def check_shared_rendering_and_surfaces(self) -> None:
        renderer_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/"
            "ShareArtifactRenderer.swift"
        )
        renderer = self.read(renderer_relative, "NRV-012", "shared-composition")
        composition = swift_declaration_body(renderer, "struct", "ThemeArtifactCompositionPlan")
        policy = swift_declaration_body(renderer, "enum", "ThemeArtifactCompositionPolicy")
        canvas = swift_declaration_body(renderer, "struct", "ThemeArtifactCanvas")
        self.require(
            composition is not None
            and policy is not None
            and "interactivePlan" in policy
            and "ShareArtifactRenderPolicy" in renderer
            and "ThemeArtifactCompositionPolicy.plan" in renderer,
            "NRV-012",
            "shared-composition",
            "interactive and static rendering do not share one composition policy",
            renderer_relative,
        )
        compact_canvas = re.sub(r"\s+", "", canvas or "")
        self.require(
            canvas is not None
            and "regionImage(plan.relicResourceID" in compact_canvas
            and "plan.sealResourceID" in canvas
            and "plan.frameResourceID" in canvas,
            "NRV-008",
            "artifact-canvas-layers",
            "shared Artifact canvas no longer renders Relic, Seal, and Frame layers",
            renderer_relative,
        )
        self.require(
            policy is not None
            and "case .highContrast: relic.highContrastResourceID" in policy
            and "descriptor.codex.background.highContrastResourceID" in policy,
            "NRV-015",
            "high-contrast-fallback",
            "high-contrast Relic or background fallback is missing",
            renderer_relative,
        )
        self.require(
            policy is not None
            and "else if reduceMotion" in policy
            and "descriptor.codex.background.reduceMotionResourceID" in policy,
            "NRV-015",
            "reduce-motion-fallback",
            "Reduce Motion background fallback is missing",
            renderer_relative,
        )
        self.require(
            canvas is not None and ".accessibilityLabel(Text(plan.accessibilityLabel))" in canvas,
            "NRV-015",
            "artifact-accessibility-label",
            "shared Artifact canvas lacks its descriptor-backed accessibility label",
            renderer_relative,
        )

        components_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
            "ThemeVisualComponents.swift"
        )
        components = self.read(components_relative, "NRV-008", "interactive-artifact-preview")
        preview = swift_declaration_body(components, "struct", "ThemeArtifactPreview")
        self.require(
            preview is not None
            and "ThemeArtifactCanvas" in preview,
            "NRV-008",
            "interactive-artifact-preview",
            "interactive Artifact preview does not render the shared canvas",
            components_relative,
        )
        for name in (
            "ThemeCodexCardView",
            "ThemeArtifactSelectionControl",
            "ThemeArtifactBrowserView",
            "ThemeArtifactTile",
        ):
            self.require(
                swift_declaration_body(components, "struct", name) is not None,
                "NRV-007" if "Selection" in name or "Browser" in name else "NRV-009",
                "generic-visual-components",
                f"generic component {name} is missing",
                components_relative,
            )

        content_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContentView.swift"
        )
        settings_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/SettingsView.swift"
        )
        vault_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VaultProgressView.swift"
        )
        content = self.read(content_relative, "NRV-008", "workspace-visual-surface")
        settings = self.read(settings_relative, "NRV-009", "settings-codex-card")
        vault = self.read(vault_relative, "NRV-010", "vault-visual-surface")
        self.require(
            "ThemeArtifactSelectionControl" in content and "ThemeArtifactPreview" in content,
            "NRV-008",
            "workspace-visual-surface",
            "workspace does not use visual selection controls and settled Artifact preview",
            content_relative,
        )
        self.require(
            "ThemeCodexCardView" in settings,
            "NRV-009",
            "settings-codex-card",
            "Settings does not render descriptor-declared Codex card visuals",
            settings_relative,
        )
        self.require(
            "ThemeCodexCardView" in vault and "ThemeArtifactTile" in vault,
            "NRV-010",
            "vault-visual-surface",
            "Vault retains metadata-only Codex or Artifact presentation",
            vault_relative,
        )

    def check_fallback_and_access_semantics(self) -> None:
        selection_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/"
            "RuneScribeUISession+ThemeArtifacts.swift"
        )
        selection = self.read(selection_relative, "NRV-013", "locked-selection")
        select_body = swift_function_body(selection, "selectThemeArtifact")
        self.require(
            select_body is not None
            and "$0.id == artifactID && $0.isSelectable" in select_body,
            "NRV-013",
            "locked-selection",
            "Artifact selection no longer enforces isSelectable",
            selection_relative,
        )
        fallback_relative = (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/"
            "ReceivedPresentationAvailabilityBinding.swift"
        )
        fallback = self.read(fallback_relative, "NRV-014", "optional-provider-fallback")
        self.require(
            "usesRequestedCodex" in fallback
            and ": RuneScribeCodexIDs.norse" in fallback
            and ".norseInteractiveFallback" in fallback,
            "NRV-014",
            "optional-provider-fallback",
            "optional-provider failure does not deterministically fall back to Norse",
            fallback_relative,
        )

    def check_required_tests_and_identifiers(self) -> None:
        ui_source_root = self.root / "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule"
        source = "\n".join(
            path.read_text(encoding="utf-8") for path in sorted(ui_source_root.rglob("*.swift"))
        ) if ui_source_root.is_dir() else ""
        identifier_semantics = {
            "theme.codex-card.<codexID>": (
                '"theme.codex-card"',
                '"\(identifierPrefix).\(codexID.rawValue)"',
            ),
            "theme.artifact-selection.<kind>": (
                '"theme.artifact-selection.\(kind.rawValue.lowercased())"',
                "case relic",
                "case seal",
                "case frame",
            ),
            "theme.artifact-thumbnail.<artifactID>": (
                '"theme.artifact-thumbnail.\($0.id.rawValue)"',
            ),
            "theme.artifact-picker": ('"theme.artifact-picker"',),
            "theme.artifact-preview.<relicID>": (
                '"theme.artifact-preview"',
                '"theme.artifact-preview.\(plan.selection.relicID.rawValue)"',
            ),
            "theme.vault.<codexID>": ('identifierPrefix: "theme.vault"',),
            "theme.vault-artifact.<artifactID>": (
                'identifierPrefix: "theme.vault-artifact"',
            ),
        }
        for identifier, tokens in identifier_semantics.items():
            self.require(
                all(token in source for token in tokens),
                "NRV-015",
                "stable-accessibility-identifiers",
                f"production visual path lacks identifier semantics {identifier}",
                ui_source_root,
            )

        ios_ui_relative = "RuneScribIOSUITests/RuneScribeParityUITests.swift"
        ios_ui = self.read(ios_ui_relative, "NRV-021", "focused-ios-visual-test")
        required_norse_ids = (
            "theme.codex-card.codex.norse",
            "theme.artifact-thumbnail.relic.norse.runestone.weathered",
            "theme.artifact-thumbnail.seal.norse.knotwork",
            "theme.artifact-preview",
            "theme.artifact-preview.relic.norse.runestone.weathered",
            "theme.vault.codex.norse",
        )
        positive_visual_tests = [
            body
            for name, body in swift_test_function_bodies(ios_ui)
            if name != "testCaptureNorseVisualPresentationBaseline"
            and all(identifier in body for identifier in required_norse_ids)
            and "XCTAssertTrue" in body
        ]
        self.require(
            bool(positive_visual_tests),
            "NRV-021",
            "focused-ios-visual-test",
            "focused positive Norse visual UI test or required assertions are missing",
            ios_ui_relative,
        )

        test_root = self.root / "Packages/RuneScribeArchitecture/Tests"
        test_files = sorted(test_root.rglob("*.swift")) if test_root.is_dir() else []
        tests = "\n".join(
            path.read_text(encoding="utf-8") for path in test_files
        )
        semantic_test_markers = (
            "ActiveThemeVisualResourcePlan",
            "RuntimeThemeImageReference",
            "maximumTotalEncodedImageByteCount",
            "ThemeArtifactCompositionPolicy",
            "interactivePlan",
            "highContrast",
            "reduceMotion",
            "accessibilityLabel",
            "theme.norse.base",
            "isEmergencyPresentation",
            "codex.norse",
            "testPreparedBackgroundDoesNotPublishUntilCommitted",
            "testEncodedBudgetHonorsLeasesAndMemoryPressureRehydrates",
            "testSuspendedOlderReconcileCannotReplaceNewerProviderState",
            "testLockedProvidersActivateSelectResolveAndFallBackAfterRevocation",
            "testBuilderShowsLockedContentButCannotSelectIt",
        )
        for marker in semantic_test_markers:
            self.require(
                marker in tests,
                "NRV-019",
                "semantic-regression-tests",
                f"required semantic test marker is missing: {marker}",
                test_root,
            )
        adoption_tests = [
            (name, body)
            for path in test_files
            for name, body in swift_test_function_bodies(path.read_text(encoding="utf-8"))
            if ("stale" in name.lower() or "atomic" in name.lower())
            and ("visual" in name.lower() or "theme" in name.lower())
            and "XCTAssert" in body
        ]
        self.require(
            bool(adoption_tests),
            "NRV-006",
            "visual-adoption-executable-test",
            "no executable test directly proves atomic or stale active-visual adoption",
            test_root,
        )

    def check_regression_inventory(self) -> None:
        package_relative = "Packages/RuneScribeArchitecture/Package.swift"
        package = self.read(package_relative, "NRV-019", "test-target-ratchet")
        package_targets = set(
            re.findall(r"\.testTarget\s*\(\s*name:\s*\"([^\"]+)\"", package)
        )
        self.require(
            EXPECTED_SWIFTPM_TEST_TARGETS.issubset(package_targets),
            "NRV-019",
            "test-target-ratchet",
            "one or more pre-remediation SwiftPM test targets were removed",
            package_relative,
        )
        project = self.read("project.yml", "NRV-019", "xcode-test-target-ratchet")
        project_targets = set(
            re.findall(r"^  ([A-Za-z0-9_-]+Tests):\s*$", project, re.MULTILINE)
        )
        self.require(
            EXPECTED_XCODE_TEST_TARGETS.issubset(project_targets),
            "NRV-019",
            "xcode-test-target-ratchet",
            "one or more pre-remediation Xcode test targets were removed",
            "project.yml",
        )
        schemes = set(re.findall(r"^  (RuneScrib-[^:]+):\s*$", project, re.MULTILINE))
        self.require(
            EXPECTED_SCHEMES.issubset(schemes),
            "NRV-019",
            "scheme-ratchet",
            "one or more pre-remediation shared schemes were removed",
            "project.yml",
        )
        scripts_root = self.root / "scripts"
        present_scripts = {path.name for path in scripts_root.iterdir()} if scripts_root.is_dir() else set()
        self.require(
            EXPECTED_GUARD_SCRIPTS.issubset(present_scripts),
            "NRV-019",
            "guard-ratchet",
            "one or more pre-remediation regression or inspection scripts were removed",
            scripts_root,
        )
        package_tests = self.root / "Packages/RuneScribeArchitecture/Tests"
        package_sources = "\n".join(
            path.read_text(encoding="utf-8") for path in package_tests.rglob("*.swift")
        ) if package_tests.is_dir() else ""
        xcode_test_paths = [
            self.root / "RuneScribTests",
            self.root / "RuneScribIOSTests",
            self.root / "RuneScribIOSUITests",
            self.root / "RuneScribMacParityTests",
            self.root / "RuneScribArchitectureTests",
        ]
        xcode_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for root in xcode_test_paths
            if root.is_dir()
            for path in root.rglob("*.swift")
        )
        self.require(
            len(re.findall(r"\bfunc\s+test[A-Za-z0-9_]*\s*\(", package_sources)) >= 893,
            "NRV-019",
            "test-declaration-floor",
            "SwiftPM XCTest declaration count fell below the 893-method baseline",
            package_tests,
        )
        self.require(
            len(re.findall(r"@Test\b", package_sources)) >= 129,
            "NRV-019",
            "test-declaration-floor",
            "Swift Testing declaration count fell below the 129-test baseline",
            package_tests,
        )
        self.require(
            len(re.findall(r"\bfunc\s+test[A-Za-z0-9_]*\s*\(", xcode_sources)) >= 120,
            "NRV-019",
            "test-declaration-floor",
            "Xcode-hosted/UI declaration count fell below the 120-method baseline",
            "project.yml",
        )

    def check_owner_operator_boundary(self) -> None:
        active_paths = (
            "README.md",
            "CHANGELOG.md",
            "docs/SUPPORT.md",
            "docs/APP_STORE_SUBMISSION.md",
            "docs/architecture/RoadmapAlignment.md",
            "docs/architecture/ForsettiSupersessionIndex.md",
        )
        patterns = (
            re.compile(r"\bowner[- ]test\s+required\b", re.IGNORECASE),
            re.compile(r"\bowner(?:/operator|\s+or\s+operator)?\s+input\s+required\b", re.IGNORECASE),
            re.compile(r"\bdo\s+not\s+(?:ship|merge|publish).{0,100}\bowner\s+approv", re.IGNORECASE),
            re.compile(
                r"\b(?:physical[- ]device|physical\s+hardware)"
                r"(?![^.\n]{0,80}\bnot\s+required\b)[^.\n]{0,80}"
                r"\b(?:required|pending|block(?:ed|er)?|gate)\b",
                re.IGNORECASE,
            ),
        )
        for relative in active_paths:
            content = self.read(relative, "NRV-023", "no-owner-operator-gate")
            for pattern in patterns:
                self.require(
                    pattern.search(content) is None,
                    "NRV-023",
                    "no-owner-operator-gate",
                    "active status documentation retains a physical-hardware or owner/operator gate",
                    relative,
                )
        evidence_root = self.root / "docs/verification/norse-visual-remediation"
        if evidence_root.is_dir():
            for suffix_pattern in ("*.md", "*.json"):
                for path in sorted(evidence_root.glob(suffix_pattern)):
                    content = path.read_text(encoding="utf-8")
                    for pattern in patterns:
                        self.require(
                            pattern.search(content) is None,
                            "NRV-023",
                            "no-owner-operator-gate",
                            "NRV evidence retains a physical-hardware or owner/operator gate",
                            path,
                        )
        test_roots = (
            self.root / "Packages/RuneScribeArchitecture/Tests",
            self.root / "RuneScribTests",
            self.root / "RuneScribIOSTests",
            self.root / "RuneScribIOSUITests",
            self.root / "RuneScribMacParityTests",
            self.root / "RuneScribArchitectureTests",
        )
        for root in test_roots:
            if not root.is_dir():
                continue
            for path in root.rglob("*.swift"):
                content = path.read_text(encoding="utf-8")
                self.require(
                    not any(pattern.search(content) for pattern in patterns),
                    "NRV-023",
                    "no-owner-operator-test-gate",
                    "test source requests physical hardware or owner/operator input",
                    path,
                )

    def check_evidence_package(self) -> None:
        evidence_root = self.root / "docs/verification/norse-visual-remediation"
        self.require(
            evidence_root.is_dir(),
            "NRV-025",
            "evidence-package",
            "NRV evidence directory is missing",
            evidence_root,
        )
        if not evidence_root.is_dir():
            return
        records: dict[str, dict[str, Any]] = {}
        for name in REQUIRED_EVIDENCE_JSON:
            relative = f"docs/verification/norse-visual-remediation/{name}"
            record = self.json_record(relative, "NRV-025", "evidence-metadata")
            if record is None:
                continue
            records[name] = record
            self.check_evidence_metadata(relative, record)

        evidence_markers = {
            "Baseline.json": (
                "theme.norse.base",
                "codex.norse",
                "isEmergencyPresentation",
                "relic.norse.runestone.weathered",
                EXPECTED_MANIFEST_SHA256,
            ),
            "ResourceCoverage.json": (
                EXPECTED_MANIFEST_SHA256,
                EXPECTED_FONT_SHA256,
                "descriptorResourceCount",
                "verifiedEntries",
            ),
            "ActiveVisualPlanValidation.json": (
                "ActiveThemeVisualResourcePlan",
                "codex.norse",
                "relic.norse.runestone.weathered",
                "seal.norse.knotwork",
                "frame",
                "crest",
            ),
            "RuntimeResolutionValidation.json": (
                "RuntimeThemeImageReference",
                "maximumEncodedImageByteCount",
                "maximumTotalEncodedImageByteCount",
                "maximumDecodedByteCount",
                "maximumEntryCount",
                "atomic",
                "stale",
            ),
            "InteractiveStaticParity.json": (
                "ThemeArtifactCompositionPolicy",
                "interactive",
                "static",
                "relic",
                "seal",
                "frame",
            ),
            "AccessibilityValidation.json": (
                "accessibility",
                "High Contrast",
                "Reduce Motion",
                "Dynamic Type",
            ),
            "CrossProviderVisualValidation.json": (
                "codex.moonleaf",
                "codex.sunspire",
                "codex.wildwood",
                "codex.gloamthorn",
                "codex.norse",
            ),
        }
        for name, markers in evidence_markers.items():
            if name not in records:
                continue
            flattened = json.dumps(records[name], sort_keys=True)
            self.require(
                all(marker.lower() in flattened.lower() for marker in markers),
                "NRV-025",
                "evidence-semantic-coverage",
                f"{name} lacks one or more required semantic coverage markers: {markers}",
                evidence_root / name,
            )
        for name in REQUIRED_EVIDENCE_MARKDOWN:
            path = evidence_root / name
            self.require(
                path.is_file() and bool(path.read_text(encoding="utf-8").strip()),
                "NRV-025",
                "evidence-package",
                f"required evidence document is missing or empty: {name}",
                path,
            )

        screenshot_root = evidence_root / "screenshots"
        for name in REQUIRED_SCREENSHOTS:
            path = screenshot_root / name
            valid, detail = valid_png(path)
            self.require(
                valid,
                "NRV-025",
                "automated-screenshot-evidence",
                f"required screenshot {name} is invalid: {detail}",
                path,
            )

        simulator = records.get("SimulatorVisualValidation.json")
        if simulator is not None:
            flattened = json.dumps(simulator, sort_keys=True)
            command_text = json.dumps(simulator.get("command", ""), sort_keys=True)
            self.require(
                all(name in flattened for name in REQUIRED_SCREENSHOTS)
                and "xcodebuild" in command_text
                and ("xcresulttool" in flattened or "XCTAttachment" in flattened)
                and "screencapture" not in command_text.lower()
                and "manual" not in command_text.lower(),
                "NRV-025",
                "automated-screenshot-provenance",
                "SimulatorVisualValidation.json does not prove automated production of all screenshots",
                evidence_root / "SimulatorVisualValidation.json",
            )

        mutation = records.get("NegativeMutations.json")
        if mutation is not None:
            mutations = mutation.get("mutations")
            self.require(
                isinstance(mutations, list)
                and len(mutations) == 20
                and all(
                    isinstance(item, dict)
                    and item.get("result") == "PASS"
                    and item.get("actualOutcome") == "REJECTED"
                    for item in mutations
                ),
                "NRV-018",
                "negative-mutation-evidence",
                "NegativeMutations.json must record 20 deterministically rejected mutations",
                evidence_root / "NegativeMutations.json",
            )
            restoration = mutation.get("sourceRestoration", {})
            self.require(
                isinstance(restoration, dict)
                and restoration.get("originalWorktreeUntouched") is True
                and restoration.get("beforeFingerprint") == restoration.get("afterFingerprint"),
                "NRV-018",
                "negative-mutation-restoration",
                "negative-mutation evidence does not prove source restoration",
                evidence_root / "NegativeMutations.json",
            )

        regression = records.get("FullRegression.json")
        if regression is not None:
            flattened = json.dumps(regression, sort_keys=True)
            command_markers = (
                "swift test",
                "check-architecture.sh",
                "check-roadmap-alignment.sh",
                "check-roadmap-completion.py",
                "check-documentation-alignment.py",
                "check-forsetti-compliance.sh",
                "validate-elven-recovery-state.py",
                "test-shipping-products.sh",
                "xcodebuild",
                "RuneScrib-macOS",
                "RuneScrib-iOS",
                "RuneScrib-iOS-Parity",
                "RuneScrib-macOS-Parity",
            )
            self.require(
                all(marker in flattened for marker in command_markers),
                "NRV-019",
                "full-regression-evidence",
                "FullRegression.json does not record the complete required matrix",
                evidence_root / "FullRegression.json",
            )

        owner_path = evidence_root / "OwnerTestHandoff.md"
        if owner_path.is_file():
            owner = owner_path.read_text(encoding="utf-8")
            owner_lower = owner.lower()
            self.require(
                "discretionary before distribution" in owner_lower
                and "pull-request readiness" in owner_lower
                and "not performed" in owner_lower
                and "not required" in owner_lower
                and "not requested" in owner_lower,
                "NRV-023",
                "owner-test-handoff",
                "owner handoff lacks the discretionary and non-gating verification boundary",
                owner_path,
            )

        audit_path = evidence_root / "FinalSelfAudit.md"
        if audit_path.is_file():
            audit = audit_path.read_text(encoding="utf-8")
            for number in range(1, 26):
                gate = f"NRV-{number:03d}"
                self.require(
                    re.search(rf"{re.escape(gate)}[^\n]{{0,160}}\bPASS\b", audit) is not None,
                    "NRV-025",
                    "final-self-audit",
                    f"FinalSelfAudit.md does not record {gate} PASS",
                    audit_path,
                )
            forbidden_status = re.compile(
                r"(?:\|\s*(?:SKIPPED|WAIVED|FLAKY|AMBIGUOUS|PENDING)\s*\|"
                r"|\b(?:result|status)\s*:\s*(?:SKIPPED|WAIVED|FLAKY|AMBIGUOUS|PENDING)\b)",
                re.IGNORECASE,
            )
            self.require(
                re.search(r"Open findings\s*:\s*(?:none|0)\b", audit, re.IGNORECASE) is not None
                and forbidden_status.search(audit) is None,
                "NRV-025",
                "final-self-audit",
                "final self-audit retains an open, skipped, waived, flaky, ambiguous, or pending item",
                audit_path,
            )

    def check_evidence_metadata(self, relative: str, record: dict[str, Any]) -> None:
        path = self.root / relative
        self.require(
            isinstance(record.get("schemaVersion"), str) and bool(record["schemaVersion"].strip()),
            "NRV-025",
            "evidence-metadata",
            "schemaVersion is missing",
            path,
        )
        self.require(
            isinstance(record.get("sourceSHA"), str)
            and re.fullmatch(r"[0-9a-f]{40}", record["sourceSHA"]) is not None,
            "NRV-025",
            "evidence-metadata",
            "sourceSHA must be a full lowercase Git SHA",
            path,
        )
        command = record.get("command")
        self.require(
            (isinstance(command, str) and bool(command.strip()))
            or (
                isinstance(command, list)
                and bool(command)
                and all(isinstance(item, str) and bool(item.strip()) for item in command)
            ),
            "NRV-025",
            "evidence-metadata",
            "exact command is missing",
            path,
        )
        destination = record.get("destination")
        self.require(
            (isinstance(destination, str) and bool(destination.strip()))
            or (isinstance(destination, dict) and bool(destination)),
            "NRV-025",
            "evidence-metadata",
            "destination is missing",
            path,
        )
        start = parse_utc_timestamp(record.get("startTimestamp"))
        end = parse_utc_timestamp(record.get("endTimestamp"))
        self.require(
            start is not None and end is not None and end >= start,
            "NRV-025",
            "evidence-metadata",
            "start/end timestamps must be ordered UTC timestamps",
            path,
        )
        self.require(
            record.get("result") == "PASS",
            "NRV-025",
            "evidence-metadata",
            "evidence result is not PASS",
            path,
        )
        self.require(
            record.get("failures") == [],
            "NRV-025",
            "evidence-metadata",
            "evidence failures must be present and empty",
            path,
        )
        self.require(
            isinstance(record.get("artifactPaths"), list)
            and all(isinstance(item, str) and bool(item) for item in record["artifactPaths"]),
            "NRV-025",
            "evidence-metadata",
            "artifactPaths must be a list of paths",
            path,
        )
        self.require(
            isinstance(record.get("toolchainVersions"), dict)
            and bool(record["toolchainVersions"]),
            "NRV-025",
            "evidence-metadata",
            "toolchainVersions is missing",
            path,
        )


def strip_comments_and_strings(source: str) -> str:
    """Return Swift text with comments and string contents replaced by spaces."""
    chars = list(source)
    index = 0
    state = "code"
    block_depth = 0
    while index < len(chars):
        pair = source[index : index + 2]
        triple = source[index : index + 3]
        if state == "code":
            if pair == "//":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "line-comment"
                continue
            if pair == "/*":
                chars[index] = chars[index + 1] = " "
                index += 2
                block_depth = 1
                state = "block-comment"
                continue
            if triple == '\"\"\"':
                chars[index : index + 3] = [" ", " ", " "]
                index += 3
                state = "triple-string"
                continue
            if source[index] == '"':
                chars[index] = " "
                index += 1
                state = "string"
                continue
        elif state == "line-comment":
            if source[index] == "\n":
                state = "code"
            else:
                chars[index] = " "
        elif state == "block-comment":
            if pair == "/*":
                chars[index] = chars[index + 1] = " "
                block_depth += 1
                index += 2
                continue
            if pair == "*/":
                chars[index] = chars[index + 1] = " "
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
                continue
            if source[index] != "\n":
                chars[index] = " "
        elif state == "string":
            if source[index] == "\\" and index + 1 < len(chars):
                chars[index] = chars[index + 1] = " "
                index += 2
                continue
            if source[index] == '"':
                chars[index] = " "
                state = "code"
            elif source[index] != "\n":
                chars[index] = " "
        elif state == "triple-string":
            if triple == '\"\"\"':
                chars[index : index + 3] = [" ", " ", " "]
                index += 3
                state = "code"
                continue
            if source[index] != "\n":
                chars[index] = " "
        index += 1
    return "".join(chars)


def balanced_body_from_masked(
    source: str,
    masked: str,
    opening_brace: int,
) -> Optional[str]:
    if opening_brace < 0 or opening_brace >= len(masked) or masked[opening_brace] != "{":
        return None
    depth = 0
    for index in range(opening_brace, len(masked)):
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening_brace + 1 : index]
    return None


def balanced_body(source: str, opening_brace: int) -> Optional[str]:
    return balanced_body_from_masked(
        source,
        strip_comments_and_strings(source),
        opening_brace,
    )


def swift_declaration_body(source: str, kind: str, name: str) -> Optional[str]:
    masked = strip_comments_and_strings(source)
    match = re.search(rf"\b{re.escape(kind)}\s+{re.escape(name)}\b[^{{]*{{", masked)
    if match is None:
        return None
    return balanced_body_from_masked(source, masked, masked.find("{", match.start()))


def swift_function_body(source: str, name: str) -> Optional[str]:
    masked = strip_comments_and_strings(source)
    match = re.search(rf"\bfunc\s+{re.escape(name)}\s*\([^{{]*{{", masked)
    if match is None:
        return None
    return balanced_body_from_masked(source, masked, masked.find("{", match.start()))


def swift_property_body(source: str, name: str) -> Optional[str]:
    masked = strip_comments_and_strings(source)
    match = re.search(rf"\bvar\s+{re.escape(name)}\b[^{{=]*{{", masked)
    if match is None:
        return None
    return balanced_body_from_masked(source, masked, masked.find("{", match.start()))


def swift_test_function_bodies(source: str) -> list[tuple[str, str]]:
    masked = strip_comments_and_strings(source)
    results: list[tuple[str, str]] = []
    pattern = re.compile(
        r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\([^{}]*\)\s*"
        r"(?:async\s+)?(?:throws\s+)?\{"
    )
    for match in pattern.finditer(masked):
        body = balanced_body_from_masked(
            source,
            masked,
            masked.find("{", match.start()),
        )
        if body is not None:
            results.append((match.group(1), body))
    return results


def swift_integer_constant(source: str, name: str) -> Optional[int]:
    match = re.search(
        rf"\b(?:static\s+)?let\s+{re.escape(name)}(?:\s*:\s*Int)?\s*=\s*([^\n;]+)",
        strip_comments_and_strings(source),
    )
    if match is None:
        return None
    expression = match.group(1).replace("_", "").strip()
    if re.fullmatch(r"[0-9*() +\-/]+", expression) is None:
        return None
    try:
        value = eval(expression, {"__builtins__": {}}, {})
    except (SyntaxError, TypeError, ZeroDivisionError):
        return None
    return value if isinstance(value, int) else None


def parse_utc_timestamp(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value.endswith("Z"):
        return None
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return None
    return parsed if parsed.tzinfo == timezone.utc else None


def valid_png(path: Path) -> tuple[bool, str]:
    if not path.is_file():
        return False, "missing"
    try:
        data = path.read_bytes()
    except OSError as error:
        return False, str(error)
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return False, "not a PNG"
    if data[12:16] != b"IHDR":
        return False, "missing IHDR"
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    if width < 100 or height < 100:
        return False, f"dimensions are only {width}x{height}"
    return True, f"{width}x{height}"


def render_result(validator: Validator, output_format: str) -> int:
    unique_checks = sorted(set(validator.checks))
    payload = {
        "schemaVersion": "1.0",
        "profile": validator.profile,
        "result": "PASS" if not validator.findings else "FAIL",
        "checksPerformed": unique_checks,
        "findings": [asdict(finding) for finding in validator.findings],
    }
    if output_format == "json":
        print(json.dumps(payload, indent=2, sort_keys=True))
    elif validator.findings:
        for finding in validator.findings:
            suffix = f" ({finding.path})" if finding.path else ""
            print(f"FAIL [{finding.gate}/{finding.rule}] {finding.message}{suffix}")
        print(
            f"Norse visual remediation validation failed: "
            f"{len(validator.findings)} finding(s)."
        )
    else:
        print(
            "Norse visual remediation validation passed: "
            f"{len(unique_checks)} semantic rules, profile={validator.profile}."
        )
    return 0 if not validator.findings else 1


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the script's repository)",
    )
    parser.add_argument(
        "--profile",
        choices=("implementation", "final"),
        default="final",
        help="implementation omits final evidence checks; final is the blocking profile",
    )
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_arguments(argv)
    validator = Validator(arguments.repo_root, arguments.profile)
    validator.run()
    return render_result(validator, arguments.format)


if __name__ == "__main__":
    sys.exit(main())
