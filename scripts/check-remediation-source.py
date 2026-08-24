#!/usr/bin/env python3
"""Check source invariants required by the remediation mutation suite."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable


@dataclass(frozen=True)
class Finding:
    code: str
    check: str
    path: str
    detail: str


SHARE_BUILDER_SESSION = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
    "Presentation/RuneScribeUISession+ShareBuilder.swift"
)
SHARE_BUILDER_MODEL = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
    "Sharing/ShareBuilderModel.swift"
)
SHARE_BUILDER_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
    "Sharing/ShareBuilderView.swift"
)
CIPHER_LIBRARY_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
    "Views/CipherLibraryView.swift"
)
CONTENT_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContentView.swift"
)
ROOT_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RootView.swift"
)
RUNE_THEME_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RuneTheme.swift"
)
PRIMARY_SEMANTIC_PRESENTATIONS = (
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
        "SettingsView.swift"
    ),
    CIPHER_LIBRARY_VIEW,
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
        "ContactsView.swift"
    ),
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
        "VaultProgressView.swift"
    ),
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
        "ImportConfirmView.swift"
    ),
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
        "ReceivedMessageView.swift"
    ),
    SHARE_BUILDER_VIEW,
)
LOCK_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/LockView.swift"
)
SHARE_COMPLETION = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
    "ShareCompletionContracts.swift"
)
PROGRESSION_FACTORY = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/"
    "CoreProgressionFactFactory.swift"
)
CIPHER = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Domain/Cipher.swift"
)
PACKAGE_CODEC = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/"
    "Domain/Formats/RuneScribePackage.swift"
)
ARTIFACT_SELECTION = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
    "RuntimeArtifactSelectionContracts.swift"
)
SETTINGS_CONTRACT_TESTS = Path(
    "Packages/RuneScribeArchitecture/Tests/RuneScribeArchitectureTests/"
    "RuntimeSettingsContractTests.swift"
)
NORSE_RESOURCE_ROOT = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources"
)
NORSE_PROVENANCE = (
    NORSE_RESOURCE_ROOT
    / "Production/Metadata/Norse-Production-Asset-Provenance-v1.0.json"
)
NORSE_INTEGRITY = (
    NORSE_RESOURCE_ROOT
    / "Production/Metadata/Norse-Resource-Integrity-Manifest-v1.0.json"
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def without_swift_comments(value: str) -> str:
    value = re.sub(r"/\*.*?\*/", "", value, flags=re.DOTALL)
    return "\n".join(re.sub(r"//.*$", "", line) for line in value.splitlines())


class Checker:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.findings: list[Finding] = []

    def add(self, code: str, check: str, relative: Path | str, detail: str) -> None:
        self.findings.append(Finding(code, check, Path(relative).as_posix(), detail))

    def read(self, relative: Path, code: str, check: str) -> str:
        path = self.root / relative
        try:
            return path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            self.add(code, check, relative, f"required source is unreadable: {error}")
            return ""

    def require(
        self,
        condition: bool,
        code: str,
        check: str,
        relative: Path,
        detail: str,
    ) -> None:
        if not condition:
            self.add(code, check, relative, detail)

    def run(self) -> list[Finding]:
        self.check_primary_cipher_share()
        self.check_share_builder_entry_points()
        self.check_security_summary()
        self.check_cancelled_progression()
        self.check_norse_source_resources()
        self.check_provider_neutral_ui()
        self.check_root_background()
        self.check_runtime_settings_ownership()
        self.check_external_dependency_edges()
        self.check_core_payload_reader()
        self.check_cipher_presentation_separation()
        self.check_schema_version_types()
        return sorted(
            set(self.findings),
            key=lambda item: (item.code, item.path, item.detail),
        )

    def check_primary_cipher_share(self) -> None:
        check = "primary-cipher-file-share"
        source = self.read(SHARE_BUILDER_SESSION, "RMS-001", check)
        invitation = re.search(
            r"case \.cipherInvitation:(.*?)(?:\n\s*}\n\s*var transfer|\Z)",
            source,
            flags=re.DOTALL,
        )
        body = invitation.group(1) if invitation else ""
        self.require(
            invitation is not None
            and re.search(r"representation:\s*\.file\b", body) is not None
            and re.search(r"representation:\s*\.link\b", body) is None,
            "RMS-001",
            check,
            SHARE_BUILDER_SESSION,
            "cipher invitation primary preparation must request the typed file representation",
        )
        library = self.read(CIPHER_LIBRARY_VIEW, "RMS-001", check)
        primary = re.search(
            r"private func beginPrimaryShare\b(.*?)(?:\n\s*private func beginFallbackShare)",
            library,
            flags=re.DOTALL,
        )
        primary_body = primary.group(1) if primary else ""
        self.require(
            "prepareShareBuilderArtifact" in primary_body
            and "representation: .link" not in primary_body,
            "RMS-001",
            check,
            CIPHER_LIBRARY_VIEW,
            "Cipher Library primary Share must use Share Builder file preparation",
        )

    def check_share_builder_entry_points(self) -> None:
        check = "share-builder-entry-points"
        content = self.read(CONTENT_VIEW, "RMS-002", check)
        required_content = (
            "customizeShareButton",
            '"Customize Share"',
            '"slider.horizontal.3"',
            '.accessibilityIdentifier("message.customize-share")',
            ".sheet(item: $shareBuilderSource)",
            "ShareBuilderView(",
            "ShareBuilderSource.encryptedMessage(",
            "shareBuilderSource = source",
        )
        for anchor in required_content:
            self.require(
                anchor in content,
                "RMS-002",
                check,
                CONTENT_VIEW,
                f"message Share Builder entry is missing: {anchor}",
            )
        self.require(
            content.count("customizeShareButton") >= 2,
            "RMS-002",
            check,
            CONTENT_VIEW,
            "message Share Builder control is declared but not mounted",
        )
        library = self.read(CIPHER_LIBRARY_VIEW, "RMS-002", check)
        required_library = (
            '.accessibilityIdentifier("cipher.customize-share")',
            ".sheet(item: $shareBuilderSource)",
            "ShareBuilderView(source: source)",
            "shareBuilderSource = .cipherInvitation(",
        )
        for anchor in required_library:
            self.require(
                anchor in library,
                "RMS-002",
                check,
                CIPHER_LIBRARY_VIEW,
                f"cipher Share Builder entry is missing: {anchor}",
            )

    def check_security_summary(self) -> None:
        check = "fixed-security-summary"
        model = self.read(SHARE_BUILDER_MODEL, "RMS-003", check)
        summaries = (
            "Key included — this first delivery contains the shared cipher.",
            "Uses your shared key — this message does not resend the cipher.",
            "Contains shared cipher — anyone who imports this invitation receives "
            "the decoder for this cipher.",
        )
        self.require(
            "var securitySummary: String" in model
            and all(model.count(summary) == 1 for summary in summaries),
            "RMS-003",
            check,
            SHARE_BUILDER_MODEL,
            "all three fixed key and cipher summaries must remain exact",
        )
        view = self.read(SHARE_BUILDER_VIEW, "RMS-003", check)
        self.require(
            view.count("source.purpose.securitySummary") >= 2
            and "source.purpose.securityAccessibilityIdentifier" in view,
            "RMS-003",
            check,
            SHARE_BUILDER_VIEW,
            "visible and accessible security text must come from the fixed purpose summary",
        )

    def check_cancelled_progression(self) -> None:
        check = "cancelled-share-ineligible"
        contract = self.read(SHARE_COMPLETION, "RMS-004", check)
        eligible = re.search(
            r"public func isEligibleTerminal\(requiresKeyDelivery: Bool\) -> Bool \{"
            r"(.*?)\n\s*}\n\n\s*public init\(from decoder",
            contract,
            flags=re.DOTALL,
        )
        body = eligible.group(1) if eligible else ""
        self.require(
            eligible is not None
            and ".cancelled" not in body
            and "case (.shareSheet, .completedBySystem), (.airDrop, .completedBySystem):"
            in body
            and "default:\n            return false" in body,
            "RMS-004",
            check,
            SHARE_COMPLETION,
            "only confirmed Messages and completed system share routes may be eligible",
        )
        factory = self.read(PROGRESSION_FACTORY, "RMS-004", check)
        self.require(
            "guard report.isEligibleTerminal(requiresKeyDelivery: keyIncluded) else {"
            in factory
            and "case .presented, .cancelled, .failed, .completionUnavailable:\n"
            "            return nil" in factory,
            "RMS-004",
            check,
            PROGRESSION_FACTORY,
            "cancelled routes must not produce a progression fact",
        )

    def check_norse_source_resources(self) -> None:
        check = "norse-source-integrity"
        provenance_path = self.root / NORSE_PROVENANCE
        try:
            document = json.loads(provenance_path.read_text(encoding="utf-8"))
            resources = document["resources"]
            if not isinstance(resources, list) or len(resources) != 55:
                raise ValueError("provenance must contain 55 resources")
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            self.add("RMS-006", check, NORSE_PROVENANCE, f"invalid provenance: {error}")
            return

        for resource in resources:
            if not isinstance(resource, dict):
                self.add("RMS-006", check, NORSE_PROVENANCE, "resource record is invalid")
                continue
            relative_value = resource.get("normalizedProductionPath")
            if not isinstance(relative_value, str):
                self.add("RMS-006", check, NORSE_PROVENANCE, "resource path is invalid")
                continue
            relative = NORSE_RESOURCE_ROOT / relative_value
            path = self.root / relative
            required = resource.get("requiredForActiveContent") is True
            if not path.is_file() or path.is_symlink():
                code = "RMS-005" if required else "RMS-006"
                self.add(code, check, relative, "declared Norse resource is missing")
                continue
            expected_bytes = resource.get("byteCount")
            expected_hash = resource.get("sha256")
            if path.stat().st_size != expected_bytes or sha256_file(path) != expected_hash:
                self.add("RMS-006", check, relative, "Norse resource bytes or digest differ")

        validator = self.root / "scripts/check-norse-production-provenance.py"
        if validator.is_file():
            result = subprocess.run(
                [sys.executable, str(validator), "--root", str(self.root)],
                cwd=self.root,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            if result.returncode != 0:
                detail = result.stderr.strip().splitlines()
                self.add(
                    "RMS-006",
                    check,
                    NORSE_PROVENANCE,
                    detail[0] if detail else "production provenance checker failed",
                )

    def check_provider_neutral_ui(self) -> None:
        check = "provider-neutral-ui"
        source_root = (
            self.root
            / "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule"
        )
        if not source_root.is_dir():
            self.add(
                "RMS-007",
                check,
                source_root.relative_to(self.root),
                "UI module source is missing",
            )
            return

        provider = r"(?:norse|moonleaf|sunspire|wildwood|gloamthorn)"
        provider_value = (
            rf"(?:RuneScribeCodexIDs\.{provider}|\.\s*{provider}\b|"
            rf'\"(?:codex\.)?{provider}\")'
        )
        comparisons = (
            re.compile(
                rf"\b(?:if|guard)\b[^{{}}]{{0,400}}?"
                rf"(?:==|!=)[^{{}}]{{0,100}}?{provider_value}",
                flags=re.IGNORECASE | re.DOTALL,
            ),
            re.compile(
                rf"\b(?:if|guard)\b[^{{}}]{{0,400}}?{provider_value}"
                rf"[^{{}}]{{0,100}}?(?:==|!=)",
                flags=re.IGNORECASE | re.DOTALL,
            ),
            re.compile(
                rf"\bcase\s+{provider_value}",
                flags=re.IGNORECASE,
            ),
        )
        for path in sorted(source_root.rglob("*.swift")):
            relative = path.relative_to(self.root)
            try:
                source = without_swift_comments(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError) as error:
                self.add(
                    "RMS-007",
                    check,
                    relative,
                    f"UI source is unreadable: {error}",
                )
                continue
            if any(pattern.search(source) for pattern in comparisons):
                self.add(
                    "RMS-007",
                    check,
                    relative,
                    "UI control flow branches on a concrete Theme provider identity",
                )

    def check_root_background(self) -> None:
        check = "root-theme-background"
        root_view = without_swift_comments(self.read(ROOT_VIEW, "RMS-008", check))
        stack_start = root_view.find("        ZStack {")
        background_start = root_view.find("\n        .background {", stack_start)
        animation_start = root_view.find(
            "\n        .animation(.easeInOut(duration: 0.25)",
            background_start,
        )
        root_stack = (
            root_view[stack_start:background_start]
            if stack_start >= 0 and background_start > stack_start
            else ""
        )
        background = (
            root_view[background_start:animation_start]
            if background_start >= 0 and animation_start > background_start
            else ""
        )
        self.require(
            root_view.count("RuntimeMetalBackground()") == 1
            and "RuntimeMetalBackground()" not in root_stack
            and "RuntimeMetalBackground()" in background
            and ".ignoresSafeArea()" in background
            and ".clipped()" in background
            and ".accessibilityIdentifier(rootBackgroundAccessibilityIdentifier)"
            in background,
            "RMS-008",
            check,
            ROOT_VIEW,
            "the runtime Theme renderer must remain a single non-measuring root background",
        )

        theme = self.read(RUNE_THEME_VIEW, "RMS-008", check)
        self.require(
            "func runeSemanticPresentationSurface(" in theme
            and "Color.runeBackgroundSecondary.opacity(tintOpacity)" in theme
            and ".presentationBackground(.clear)" in theme,
            "RMS-008",
            check,
            RUNE_THEME_VIEW,
            "the shared presentation surface must remain semantic and translucent",
        )

        for relative in PRIMARY_SEMANTIC_PRESENTATIONS:
            presentation = without_swift_comments(
                self.read(relative, "RMS-008", check)
            )
            self.require(
                ".runeSemanticPresentationSurface()" in presentation,
                "RMS-008",
                check,
                relative,
                "the primary presentation must use the shared semantic surface",
            )
            self.require(
                ".background(Color.runeNavy)" not in presentation,
                "RMS-008",
                check,
                relative,
                "an opaque legacy background must not erase the root Theme",
            )

        lock_view = without_swift_comments(self.read(LOCK_VIEW, "RMS-008", check))
        self.require(
            ".runeSemanticPresentationSurface(.privacy)" in lock_view
            and "Color.runeNavy.ignoresSafeArea()" not in lock_view,
            "RMS-008",
            check,
            LOCK_VIEW,
            "the lock overlay must use the privacy semantic surface over the root Theme",
        )

    def production_swift_files(self) -> Iterable[Path]:
        roots = (
            self.root / "Packages/RuneScribeArchitecture/Sources",
            self.root / "RuneScrib",
            self.root / "RuneScribMacParityHost",
        )
        for source_root in roots:
            if not source_root.is_dir():
                continue
            for path in sorted(source_root.rglob("*.swift")):
                relative = path.relative_to(self.root)
                if "Resources" in relative.parts and "Source" in relative.parts:
                    continue
                yield path

    def check_runtime_settings_ownership(self) -> None:
        check = "runtime-owned-settings"
        pattern = re.compile(r"@(?:AppStorage|SceneStorage)\b|\b(?:UserDefaults|CFPreferences)\b")
        for path in self.production_swift_files():
            try:
                source = without_swift_comments(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError) as error:
                self.add(
                    "RMS-009",
                    check,
                    path.relative_to(self.root),
                    f"production source is unreadable: {error}",
                )
                continue
            if pattern.search(source):
                self.add(
                    "RMS-009",
                    check,
                    path.relative_to(self.root),
                    "production UI or module source owns durable settings storage",
                )

    def check_external_dependency_edges(self) -> None:
        check = "no-external-forsetti-dependency"
        candidates: set[Path] = set()
        for pattern in ("**/Package.swift", "**/Package.resolved", "**/project.pbxproj"):
            candidates.update(self.root.glob(pattern))
        for relative in (Path("project.yml"), Path(".gitmodules")):
            if (self.root / relative).is_file():
                candidates.add(self.root / relative)
        pattern = re.compile(r"forsetti", re.IGNORECASE)
        for path in sorted(candidates):
            try:
                source = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            if pattern.search(source):
                self.add(
                    "RMS-010",
                    check,
                    path.relative_to(self.root),
                    "dependency graph contains an external Forsetti edge",
                )

    def check_core_payload_reader(self) -> None:
        check = "core-payload-reader"
        codec = self.read(PACKAGE_CODEC, "RMS-013", check)
        anchors = (
            "var corePayload: Data {",
            "RuneScribePackageSectionType.corePayload.rawValue }?.data",
            "_ = try CipherSharePayload(decoding: sections.first {",
            "_ = try MessageSharePayload(decoding: sections.first {",
            "guard coreCount == 1 else { throw RuneScribePackageError.missingCorePayload }",
        )
        for anchor in anchors:
            self.require(
                anchor in codec,
                "RMS-013",
                check,
                PACKAGE_CODEC,
                f"typed package Core payload reader invariant is missing: {anchor}",
            )

    def check_cipher_presentation_separation(self) -> None:
        check = "cipher-presentation-separation"
        source = without_swift_comments(self.read(CIPHER, "RMS-014", check))
        forbidden = re.compile(
            r"\b(?:CodexID|ArtifactID|SharePresentationSelection|ThemeDescriptor|"
            r"RuntimeCodexArtifactSelection)\b"
        )
        if forbidden.search(source):
            self.add(
                "RMS-014",
                check,
                CIPHER,
                "Cipher key state contains presentation or Codex selection state",
            )
        self.require(
            "let keyMaterial: Data" in source
            and "let symbolPermutation: [Int]" in source
            and "let compatibility: CipherCompatibilityRecord" in source,
            "RMS-014",
            check,
            CIPHER,
            "Cipher must preserve only key, symbol-permutation, and compatibility domains",
        )

    def check_schema_version_types(self) -> None:
        check = "strict-numeric-schema-version"
        source = self.read(ARTIFACT_SELECTION, "RMS-016", check)
        self.require(
            source.count("let schemaVersion: Int") == 2
            and not re.search(r"schemaVersion.{0,160}as\? Bool", source, re.DOTALL),
            "RMS-016",
            check,
            ARTIFACT_SELECTION,
            "both selection codecs must decode schema versions as numeric integers only",
        )
        tests = self.read(SETTINGS_CONTRACT_TESTS, "RMS-016", check)
        self.require(
            tests.count('for schemaVersion in ["true", "false", "1.5"]') == 2,
            "RMS-016",
            check,
            SETTINGS_CONTRACT_TESTS,
            "both selection codecs must retain Boolean and fractional rejection tests",
        )


def validate_norse_product(repository_root: Path, product_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    provenance_path = repository_root / NORSE_PROVENANCE
    try:
        document = json.loads(provenance_path.read_text(encoding="utf-8"))
        resources = document["resources"]
        if not isinstance(resources, list) or len(resources) != 55:
            raise ValueError("provenance must contain 55 resources")
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        return [
            Finding(
                "RMS-006",
                "norse-product-integrity",
                NORSE_PROVENANCE.as_posix(),
                f"invalid source provenance: {error}",
            )
        ]

    expected: dict[str, tuple[int, str, bool]] = {}
    for resource in resources:
        path_value = resource.get("normalizedProductionPath")
        if not isinstance(path_value, str):
            continue
        name = Path(path_value).name
        if name in expected:
            findings.append(
                Finding(
                    "RMS-006",
                    "norse-product-integrity",
                    name,
                    "shipping basename collides",
                )
            )
            continue
        expected[name] = (
            resource.get("byteCount"),
            resource.get("sha256"),
            resource.get("requiredForActiveContent") is True,
        )

    fixed_paths = (
        NORSE_RESOURCE_ROOT / "module-manifest.json",
        NORSE_INTEGRITY,
        NORSE_PROVENANCE,
    )
    for relative in fixed_paths:
        path = repository_root / relative
        if not path.is_file():
            findings.append(
                Finding(
                    "RMS-005",
                    "norse-product-integrity",
                    relative.as_posix(),
                    "required shipping metadata is absent from source",
                )
            )
            continue
        expected[path.name] = (path.stat().st_size, sha256_file(path), True)

    actual = {
        path.name
        for path in product_root.iterdir()
        if path.is_file() and not path.is_symlink()
    } if product_root.is_dir() else set()
    for name, (byte_count, digest, required) in sorted(expected.items()):
        path = product_root / name
        if not path.is_file() or path.is_symlink():
            findings.append(
                Finding(
                    "RMS-005" if required else "RMS-006",
                    "norse-product-integrity",
                    name,
                    "declared shipping resource is missing",
                )
            )
            continue
        if path.stat().st_size != byte_count or sha256_file(path) != digest:
            findings.append(
                Finding(
                    "RMS-006",
                    "norse-product-integrity",
                    name,
                    "shipping resource bytes or digest differ",
                )
            )
    extra = sorted(actual - set(expected))
    if extra:
        findings.append(
            Finding(
                "RMS-006",
                "norse-product-integrity",
                product_root.as_posix(),
                "shipping resource inventory has undeclared files: " + ", ".join(extra),
            )
        )
    return sorted(findings, key=lambda item: (item.code, item.path, item.detail))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--norse-product-root", type=Path)
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args()

    root = arguments.root.resolve()
    if not root.is_dir():
        parser.error(f"root is not a directory: {root}")
    findings = Checker(root).run()
    if arguments.norse_product_root is not None:
        findings.extend(
            validate_norse_product(root, arguments.norse_product_root.resolve())
        )
        findings = sorted(
            set(findings),
            key=lambda item: (item.code, item.path, item.detail),
        )

    record = {
        "schemaVersion": "1.0",
        "result": "PASS" if not findings else "FAIL",
        "findingCount": len(findings),
        "findings": [asdict(finding) for finding in findings],
    }
    if arguments.json:
        print(json.dumps(record, indent=2, sort_keys=True))
    elif findings:
        for finding in findings:
            print(
                f"FAIL {finding.code}: {finding.path}: {finding.detail}",
                file=sys.stderr,
            )
    else:
        print("PASS: remediation source invariants")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
