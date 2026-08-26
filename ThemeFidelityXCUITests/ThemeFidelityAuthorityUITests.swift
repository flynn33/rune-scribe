import CryptoKit
import Foundation
import XCTest

@MainActor
final class ThemeFidelityAuthorityUITests: XCTestCase {
    private static let qualificationDestinationKey =
        "RUNESCRIBE_QUALIFICATION_DESTINATION"
    private static let entryFilterKey = "RUNESCRIBE_XCUI_ENTRY_FILTER"
    private static let uiTestTargetKind =
        "com.apple.product-type.bundle.ui-testing"
    private static let testIdentifier =
        "ThemeFidelityAuthorityUITests/testCaptureThemeFidelityAuthority()"
    private static let captureOperation = "xcui-element-screenshot"
    private static let lockedProbeID =
        "probe.norse.vault.locked-element-count"
    private static let lockedQueryPredicate =
        "identifier CONTAINS[c] 'codex.norse' AND identifier CONTAINS[c] 'locked'"

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    func testCaptureThemeFidelityAuthority() throws {
        let catalogs = try loadCatalogs()
        try validateCatalogs(catalogs)

        var destinations = try activeDestinations()
        let filter = ProcessInfo.processInfo.environment[Self.entryFilterKey]
            .flatMap { value in value.isEmpty ? nil : value }
        if let filter {
            guard let filteredEntry = catalogs.authority.entries.first(
                where: {
                    $0.id == filter
                        && (!$0.candidateIDs.isEmpty
                            || !$0.xcuiProbeIDs(using: catalogs.probesByID).isEmpty)
                }
            ), destinations.contains(filteredEntry.destination) else {
                throw CaptureFailure(
                    "Entry filter \(filter) does not identify one affected entry for this test destination"
                )
            }
            destinations = [filteredEntry.destination]
        }
        var emitted = CaptureInventory()

        for destination in destinations {
            var entries = catalogs.authority.entries.filter { entry in
                entry.destination == destination
                    && (!entry.candidateIDs.isEmpty
                        || !entry.xcuiProbeIDs(using: catalogs.probesByID).isEmpty)
            }
            entries.sort { $0.id < $1.id }

            if let filter {
                entries = entries.filter { $0.id == filter }
                guard entries.count == 1 else {
                    throw CaptureFailure(
                        "Entry filter \(filter) does not identify one affected \(destination) entry"
                    )
                }
            } else {
                try require(
                    entries.count == 95,
                    "Expected 95 affected entries for \(destination), found \(entries.count)"
                )
                try require(
                    entries.reduce(0) { $0 + $1.candidateIDs.count } == 168,
                    "Expected 168 candidate captures for \(destination)"
                )
                try require(
                    entries.reduce(0) {
                        $0 + $1.xcuiProbeIDs(using: catalogs.probesByID)
                            .filter { $0 == Self.lockedProbeID }.count
                    } == 1,
                    "Expected one locked query capture for \(destination)"
                )
            }

            for entry in entries {
                guard let seed = catalogs.seedsByID[entry.seedID] else {
                    throw CaptureFailure("Missing seed \(entry.seedID)")
                }
                try XCTContext.runActivity(named: entry.id) { _ in
                    emitted += try capture(
                        entry: entry,
                        seed: seed,
                        probesByID: catalogs.probesByID,
                        candidatesByID: catalogs.candidatesByID
                    )
                }
            }
        }

        if filter == nil {
            let multiplier = destinations.count
            XCTAssertEqual(emitted.sidecars, 95 * multiplier)
            XCTAssertEqual(emitted.candidates, 168 * multiplier)
            XCTAssertEqual(emitted.queries, multiplier)
        } else {
            XCTAssertEqual(emitted.sidecars, 1)
        }
    }

    private func capture(
        entry: AuthorityEntry,
        seed: DeterministicSeed,
        probesByID: [String: RuntimeProbe],
        candidatesByID: [String: CandidateCatalogEntry]
    ) throws -> CaptureInventory {
        let app = XCUIApplication()
        var launchEnvironment = seed.launchEnvironment
        launchEnvironment[Self.qualificationDestinationKey] = entry.destination
        try validateLaunchEnvironment(
            launchEnvironment,
            seed: seed,
            destination: entry.destination
        )
        app.launchEnvironment = launchEnvironment
        app.launch()
        defer { app.terminate() }

        try require(
            app.wait(for: .runningForeground, timeout: 20),
            "Application did not enter the foreground for \(entry.id)"
        )
        let window = app.windows.firstMatch
        try require(
            window.waitForExistence(timeout: 20),
            "Application window did not appear for \(entry.id)"
        )
        try waitForQualificationReadiness(
            entry: entry,
            seed: seed,
            app: app
        )

        let candidateIDs = entry.candidateIDs
        if let firstCandidateID = candidateIDs.first {
            _ = try exactElement(
                identifiedBy: firstCandidateID,
                in: app,
                timeout: 20
            )
        } else {
            let witness = try exactElement(
                identifiedBy: "screen.vault-progress",
                in: app,
                timeout: 20
            )
            try require(
                witness.queryCount == 1,
                "Norse locked readiness witness is ambiguous for \(entry.id)"
            )
            settle(for: 0.4)
        }

        let containerFrame = try evidenceRect(
            window.frame,
            label: "\(entry.id) container"
        )
        var capturedByID: [String: CapturedElement] = [:]
        var candidateEvidence: [CandidateCaptureEvidence] = []

        for candidateID in candidateIDs {
            let resolved = try exactElement(
                identifiedBy: candidateID,
                in: app,
                timeout: 20
            )
            try revealIfNeeded(
                resolved.element,
                in: app,
                container: window.frame
            )
            let postReveal = try exactElement(
                identifiedBy: candidateID,
                in: app,
                timeout: 5
            )
            let elementFrame = try evidenceRect(
                postReveal.element.frame,
                label: "\(entry.id) candidate \(candidateID)"
            )
            try require(
                postReveal.queryCount == 1,
                "Exact candidate cardinality changed for \(entry.id): \(candidateID)"
            )

            let attachmentName = candidateAttachmentName(
                for: entry,
                candidateID: candidateID
            )
            let image = try capturedImage(
                postReveal.element.screenshot().pngRepresentation,
                attachmentName: attachmentName
            )
            attach(image.data, named: attachmentName, type: "public.png")

            let evidence = CandidateCaptureEvidence(
                candidateID: candidateID,
                elementIdentifier: postReveal.element.identifier,
                attachmentName: attachmentName,
                declaredOperation: Self.captureOperation,
                actualOperation: Self.captureOperation,
                sha256: image.sha256,
                byteCount: image.data.count,
                pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight,
                queryPredicate: "identifier == '\(candidateID)'",
                matchCount: postReveal.queryCount,
                coordinateOrigin: "top-left",
                coordinateUnits: "points",
                elementFrame: elementFrame,
                windowFrame: containerFrame,
                label: postReveal.element.label,
                value: accessibilityValue(of: postReveal.element) ?? "",
                isEnabled: postReveal.element.isEnabled,
                isHittable: postReveal.element.isHittable
            )
            candidateEvidence.append(evidence)
            capturedByID[candidateID] = CapturedElement(
                evidence: evidence,
                frame: elementFrame,
                matchCount: postReveal.queryCount,
                image: image
            )
        }

        let xcuiProbeIDs = entry.xcuiProbeIDs(using: probesByID)
        var probeEvidence: [ProbeEvidence] = []
        var queryCount = 0

        for probeID in xcuiProbeIDs {
            guard let probe = probesByID[probeID] else {
                throw CaptureFailure("Unknown probe \(probeID)")
            }
            if probeID == Self.lockedProbeID {
                let predicate = NSPredicate(format: Self.lockedQueryPredicate)
                let query = app.descendants(matching: .any).matching(predicate)
                let matchCount = query.count
                try require(
                    matchCount == 0,
                    "Production exposed \(matchCount) Norse locked elements for \(entry.id)"
                )
                let attachmentName = queryAttachmentName(for: entry)
                let image = try capturedImage(
                    app.screenshot().pngRepresentation,
                    attachmentName: attachmentName
                )
                attach(image.data, named: attachmentName, type: "public.png")
                queryCount += 1
                probeEvidence.append(
                    ProbeEvidence(
                        probeID: probe.id,
                        source: probe.source,
                        operatorName: probe.operatorName,
                        expected: probe.expected,
                        observed: .integer(matchCount),
                        queryPredicate: Self.lockedQueryPredicate,
                        matchCount: matchCount,
                        candidateID: nil,
                        attachmentName: attachmentName,
                        attachmentSHA256: image.sha256,
                        pixelWidth: image.pixelWidth,
                        pixelHeight: image.pixelHeight,
                        coordinateOrigin: "top-left",
                        coordinateUnits: "points",
                        elementFrame: nil,
                        containerFrame: containerFrame
                    )
                )
                continue
            }

            let previewIDs = candidateIDs.filter {
                $0.hasPrefix("theme.artifact-preview.")
            }
            try require(
                previewIDs.count == 1,
                "XCUI preview probe lacks one exact preview candidate for \(entry.id)"
            )
            let candidateID = previewIDs[0]
            guard let captured = capturedByID[candidateID] else {
                throw CaptureFailure(
                    "XCUI preview evidence was not captured for \(entry.id)"
                )
            }
            let observed = try observedPreviewValue(
                probeID: probeID,
                matchCount: captured.matchCount,
                elementFrame: captured.frame,
                containerFrame: containerFrame
            )
            try require(
                probe.expected == .boolean(observed),
                "XCUI observation differs from expected for \(probeID)"
            )
            probeEvidence.append(
                ProbeEvidence(
                    probeID: probe.id,
                    source: probe.source,
                    operatorName: probe.operatorName,
                    expected: probe.expected,
                    observed: .boolean(observed),
                    queryPredicate: "identifier == '\(candidateID)'",
                    matchCount: captured.matchCount,
                    candidateID: candidateID,
                    attachmentName: captured.evidence.attachmentName,
                    attachmentSHA256: captured.image.sha256,
                    pixelWidth: captured.image.pixelWidth,
                    pixelHeight: captured.image.pixelHeight,
                    coordinateOrigin: "top-left",
                    coordinateUnits: "points",
                    elementFrame: captured.frame,
                    containerFrame: containerFrame
                )
            )
        }

        let structuralWitnesses = try captureStructuralWitnesses(
            entry: entry,
            candidatesByID: candidatesByID,
            app: app,
            window: window
        )

        let sidecar = AuthoritySidecar(
            schemaVersion: "1.0",
            entryID: entry.id,
            theme: entry.theme,
            surface: entry.surface,
            destination: entry.destination,
            deterministicSeed: seed,
            primaryCaptureAttachmentName: "\(entry.stem).png",
            captureRecordAttachmentName: "\(entry.stem).capture.json",
            sourceTest: SourceTestEvidence(
                targetName: sourceTargetName,
                targetKind: Self.uiTestTargetKind,
                testIdentifier: Self.testIdentifier,
                bundleRole: bundleRole(for: entry.destination)
            ),
            candidateElementCaptures: candidateEvidence,
            structuralWitnesses: structuralWitnesses,
            xcuiProbeEvidence: probeEvidence
        )
        try validate(
            sidecar: sidecar,
            entry: entry,
            seed: seed,
            probesByID: probesByID,
            candidatesByID: candidatesByID,
            capturedByID: capturedByID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sidecarData = try encoder.encode(sidecar)
        attach(
            sidecarData,
            named: "\(entry.stem).xcui.json",
            type: "public.json"
        )

        return CaptureInventory(
            sidecars: 1,
            candidates: candidateEvidence.count,
            queries: queryCount
        )
    }

    private func captureStructuralWitnesses(
        entry: AuthorityEntry,
        candidatesByID: [String: CandidateCatalogEntry],
        app: XCUIApplication,
        window: XCUIElement
    ) throws -> [StructuralWitnessEvidence] {
        let specifications = try structuralWitnessSpecifications(
            entry: entry,
            candidatesByID: candidatesByID
        )
        var evidence: [StructuralWitnessEvidence] = []
        for specification in specifications {
            let windowFrame = try evidenceRect(
                window.frame,
                label: "\(entry.id) witness window"
            )
            switch specification.query {
            case let .exact(identifier):
                let resolved = try exactElement(
                    identifiedBy: identifier,
                    in: app,
                    timeout: 20
                )
                try revealIfNeeded(
                    resolved.element,
                    in: app,
                    container: window.frame
                )
                let postReveal = try exactElement(
                    identifiedBy: identifier,
                    in: app,
                    timeout: 5
                )
                if identifier == "theme-fidelity.diagnostic.dynamic-type" {
                    try require(
                        accessibilityValue(of: postReveal.element) == "accessibility5",
                        "Live large-text witness is not accessibility5 for \(entry.id)"
                    )
                }
                try require(
                    postReveal.queryCount == specification.expectedMatchCount,
                    "Structural witness query count differs for \(identifier)"
                )
                evidence.append(StructuralWitnessEvidence(
                    witnessID: specification.witnessID,
                    queryPredicate: specification.query.predicate,
                    matchCount: postReveal.queryCount,
                    elementIdentifier: postReveal.element.identifier,
                    coordinateOrigin: "top-left",
                    coordinateUnits: "points",
                    elementFrame: try evidenceRect(
                        postReveal.element.frame,
                        label: "\(entry.id) witness \(identifier)"
                    ),
                    windowFrame: windowFrame,
                    label: postReveal.element.label,
                    value: accessibilityValue(of: postReveal.element),
                    isEnabled: postReveal.element.isEnabled,
                    isHittable: postReveal.element.isHittable
                ))
            case let .beginsWith(prefix):
                let predicate = NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    prefix
                )
                let query = app.descendants(matching: .any).matching(predicate)
                let count = query.count
                try require(
                    count == specification.expectedMatchCount,
                    "Structural zero-fallback query count differs for \(specification.witnessID): \(count)"
                )
                evidence.append(StructuralWitnessEvidence(
                    witnessID: specification.witnessID,
                    queryPredicate: specification.query.predicate,
                    matchCount: count,
                    elementIdentifier: nil,
                    coordinateOrigin: "top-left",
                    coordinateUnits: "points",
                    elementFrame: nil,
                    windowFrame: windowFrame,
                    label: nil,
                    value: nil,
                    isEnabled: nil,
                    isHittable: nil
                ))
            }
        }
        return evidence
    }

    private func structuralWitnessSpecifications(
        entry: AuthorityEntry,
        candidatesByID: [String: CandidateCatalogEntry]
    ) throws -> [StructuralWitnessSpecification] {
        var byID: [String: StructuralWitnessSpecification] = [:]
        func add(_ specification: StructuralWitnessSpecification) throws {
            if let existing = byID[specification.witnessID] {
                try require(
                    existing == specification,
                    "Conflicting structural witness \(specification.witnessID)"
                )
            } else {
                byID[specification.witnessID] = specification
            }
        }
        func addExact(_ identifier: String) throws {
            try add(StructuralWitnessSpecification(
                witnessID: "element:\(identifier)",
                query: .exact(identifier),
                expectedMatchCount: 1
            ))
        }

        try addExact("theme-fidelity.diagnostic.state")

        let assertions = entry.structuralAssertionIDs
        if assertions.contains("assert.mobile-hit-targets") {
            let controls: [String] = switch entry.surface {
            case "workspace-empty": [
                "workspace.artifact-control.relic",
                "workspace.artifact-control.seal",
                "workspace.artifact-control.frame",
            ]
            case "share-builder": [
                "share-builder.reset-defaults",
                "share-builder.save-defaults",
                "share-builder.share",
            ]
            default: []
            }
            try require(!controls.isEmpty, "Missing mobile hit-target witness route")
            for identifier in controls { try addExact(identifier) }
        }

        if assertions.contains("assert.no-placeholder-art") {
            try addExact("theme-fidelity.diagnostic.resources")
            try add(StructuralWitnessSpecification(
                witnessID: "query:missing-resource",
                query: .beginsWith("theme-fidelity.missing-resource."),
                expectedMatchCount: 0
            ))
        }
        if assertions.contains("assert.no-system-symbol-artifact") {
            try addExact("theme-fidelity.diagnostic.resources")
            try add(StructuralWitnessSpecification(
                witnessID: "query:missing-picker-artwork",
                query: .beginsWith("theme-fidelity.missing-picker-artwork."),
                expectedMatchCount: 0
            ))
        }
        if assertions.contains("assert.safe-region-no-overlap") {
            try addExact("theme-fidelity.diagnostic.plan.interactive")
        }
        if assertions.contains("assert.interactive-static-plan-parity") {
            try addExact("theme-fidelity.diagnostic.plan.interactive")
            try addExact("theme-fidelity.diagnostic.plan.static")
        }
        if assertions.contains("assert.state-text-shape-truthful") {
            try addExact("theme-fidelity.diagnostic.state")
            if entry.surface == "high-contrast" {
                try addExact("theme-fidelity.diagnostic.plan.interactive")
            } else if entry.surface == "received-cipher" {
                try addExact("received.safe-preview")
            } else if [
                "vault-locked", "vault-encountered", "vault-owned", "vault-selected",
            ].contains(entry.surface) {
                try addExact("theme.vault.\(entry.codexID).provider-state")
                try addExact("theme.vault.\(entry.codexID).ownership-state")
                let state = entry.surface.replacingOccurrences(of: "vault-", with: "")
                if entry.codexID == "codex.norse", state == "encountered" {
                    try addExact("theme.vault.codex.norse.selected")
                    try addExact("theme.vault-artifact.relic.norse.dragonwood-plaque")
                } else if entry.codexID != "codex.norse" || state != "locked" {
                    try addExact("theme.vault.\(entry.codexID).\(state)")
                }
            } else if entry.surface == "vault-progress" {
                if entry.codexID == "codex.norse" {
                    try addExact("theme.vault.codex.norse.owned")
                } else {
                    try addExact("progression.journey.\(entry.codexID).progress")
                }
                try addExact("progression.journey.\(entry.codexID).requirement-count")
            }
        }

        let themeComponent = entry.codexID.replacingOccurrences(of: "codex.", with: "")
        if assertions.contains("assert.all-three-relics-present") {
            let prefix = "theme.artifact-picker.relic.\(themeComponent)."
            let identifiers = candidatesByID.keys.filter { $0.hasPrefix(prefix) }.sorted()
            try require(identifiers.count == 3, "Candidate catalog relic set differs")
            for identifier in identifiers { try addExact(identifier) }
            try add(StructuralWitnessSpecification(
                witnessID: "query:relic-picker-set",
                query: .beginsWith(prefix),
                expectedMatchCount: identifiers.count
            ))
        }
        if assertions.contains("assert.all-six-seals-present") {
            let prefix = "theme.artifact-picker.seal.\(themeComponent)."
            let identifiers = candidatesByID.keys.filter { $0.hasPrefix(prefix) }.sorted()
            try require(identifiers.count == 6, "Candidate catalog seal set differs")
            for identifier in identifiers { try addExact(identifier) }
            try add(StructuralWitnessSpecification(
                witnessID: "query:seal-picker-set",
                query: .beginsWith(prefix),
                expectedMatchCount: identifiers.count
            ))
        }
        if assertions.contains("assert.mastery-frame-crest-title-present") {
            let prefixes = [
                "theme.mastery.frame.frame.\(themeComponent).",
                "theme.mastery.crest.crest.\(themeComponent).",
            ]
            for prefix in prefixes {
                let identifiers = candidatesByID.keys.filter { $0.hasPrefix(prefix) }.sorted()
                try require(identifiers.count == 1, "Candidate catalog mastery set differs")
                try addExact(identifiers[0])
            }
            try add(StructuralWitnessSpecification(
                witnessID: "query:mastery-frame-set",
                query: .beginsWith("theme.mastery.frame."),
                expectedMatchCount: 1
            ))
            try add(StructuralWitnessSpecification(
                witnessID: "query:mastery-crest-set",
                query: .beginsWith("theme.mastery.crest."),
                expectedMatchCount: 1
            ))
            let titleID = entry.codexID == "codex.norse"
                ? "title.norse.master-of-runes" : "title.master-scribe"
            try addExact("theme.mastery.title.\(titleID)")
            try add(StructuralWitnessSpecification(
                witnessID: "query:mastery-title-set",
                query: .beginsWith("theme.mastery.title."),
                expectedMatchCount: 1
            ))
        }
        if assertions.contains("assert.large-text-required-controls-visible") {
            try addExact("theme-fidelity.diagnostic.state")
            try addExact("theme-fidelity.diagnostic.dynamic-type")
            var controls = [
                "workspace.result.edit",
                "workspace.result.copy",
                "message.quick-share",
                "message.customize-share",
                "workspace.result.clear",
            ]
            #if os(iOS)
            controls.append("message.imessage-share")
            #endif
            for identifier in controls { try addExact(identifier) }
        }

        return byID.values.sorted { $0.witnessID < $1.witnessID }
    }

    private func accessibilityValue(of element: XCUIElement) -> String? {
        guard let raw = element.value else { return nil }
        if let string = raw as? String { return string }
        return String(describing: raw)
    }

    private func waitForQualificationReadiness(
        entry: AuthorityEntry,
        seed: DeterministicSeed,
        app: XCUIApplication
    ) throws {
        let identifier = "theme-fidelity.diagnostic.state"
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        let element = query.firstMatch
        try require(
            element.waitForExistence(timeout: 20),
            "Settled qualification readiness witness did not appear for \(entry.id)"
        )
        try require(
            query.count == 1,
            "Settled qualification readiness witness was ambiguous for \(entry.id)"
        )
        guard let value = accessibilityValue(of: element),
              let data = value.data(using: .utf8),
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CaptureFailure(
                "Settled qualification readiness witness was invalid for \(entry.id)"
            )
        }
        let environment = seed.launchEnvironment
        let expectedStrings = [
            "schemaVersion": "1.0",
            "themeID": entry.themeID,
            "codexID": entry.codexID,
            "surface": entry.surface,
            "destination": entry.destination,
            "appearance": environment["RUNESCRIBE_QUALIFICATION_APPEARANCE"],
            "messageProfile": environment["RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE"],
            "activeThemeID": entry.themeID,
            "effectiveCodexID": entry.codexID,
        ]
        for (key, expected) in expectedStrings {
            try require(
                expected != nil && document[key] as? String == expected,
                "Settled qualification readiness \(key) differed for \(entry.id)"
            )
        }
        if let expectedVaultState = environment["RUNESCRIBE_QUALIFICATION_VAULT_STATE"] {
            try require(
                document["vaultState"] as? String == expectedVaultState,
                "Settled qualification vault state differed for \(entry.id)"
            )
        } else {
            try require(
                document["vaultState"] is NSNull,
                "Settled qualification vault state was not null for \(entry.id)"
            )
        }
    }

    private func exactElement(
        identifiedBy identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> ResolvedElement {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        let element = query.firstMatch
        if !element.waitForExistence(timeout: min(timeout, 4)) {
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                for _ in 0..<8 { scrollView.swipeDown() }
                let deadline = Date().addingTimeInterval(max(0, timeout - 4))
                while Date() < deadline, !element.exists {
                    scrollView.swipeUp()
                    settle(for: 0.15)
                }
            }
        }
        try require(
            element.exists,
            "Exact candidate did not exist: \(identifier)"
        )
        let count = query.count
        try require(
            count == 1,
            "Exact candidate cardinality for \(identifier) was \(count), expected 1"
        )
        return ResolvedElement(element: element, queryCount: count)
    }

    private func revealIfNeeded(
        _ element: XCUIElement,
        in app: XCUIApplication,
        container: CGRect
    ) throws {
        let permittedContainer = container.insetBy(dx: -0.5, dy: -0.5)
        guard !permittedContainer.contains(element.frame) else { return }
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else {
            throw CaptureFailure(
                "Exact element is outside its container and no scroll view exists: \(element.identifier)"
            )
        }
        for _ in 0..<16 {
            let frame = element.frame
            if permittedContainer.contains(frame) { return }
            if frame.minY < permittedContainer.minY {
                scrollView.swipeDown()
            } else {
                scrollView.swipeUp()
            }
            settle(for: 0.15)
        }
        try require(
            permittedContainer.contains(element.frame),
            "Exact element remained partially outside its container: \(element.identifier)"
        )
    }

    private func observedPreviewValue(
        probeID: String,
        matchCount: Int,
        elementFrame: EvidenceRect,
        containerFrame: EvidenceRect
    ) throws -> Bool {
        if probeID.hasPrefix("probe.motion.preview-exists.") {
            return matchCount == 1
        }
        if probeID.hasPrefix("probe.motion.preview-visible.") {
            return matchCount == 1
                && elementFrame.intersects(containerFrame)
        }
        if probeID.hasPrefix("probe.motion.preview-contained.") {
            return matchCount == 1
                && containerFrame.contains(elementFrame)
        }
        throw CaptureFailure("Unsupported XCUI probe \(probeID)")
    }

    private func validate(
        sidecar: AuthoritySidecar,
        entry: AuthorityEntry,
        seed: DeterministicSeed,
        probesByID: [String: RuntimeProbe],
        candidatesByID: [String: CandidateCatalogEntry],
        capturedByID: [String: CapturedElement]
    ) throws {
        try require(sidecar.schemaVersion == "1.0", "Invalid XCUI schema version")
        try require(sidecar.entryID == entry.id, "Sidecar entry binding differs")
        try require(sidecar.theme == entry.theme, "Sidecar Theme binding differs")
        try require(sidecar.surface == entry.surface, "Sidecar surface binding differs")
        try require(
            sidecar.destination == entry.destination,
            "Sidecar destination binding differs"
        )
        try require(
            sidecar.deterministicSeed == seed
                && sidecar.deterministicSeed.id == entry.seedID
                && sidecar.deterministicSeed.theme == entry.theme
                && sidecar.deterministicSeed.surface == entry.surface
                && sidecar.deterministicSeed.operatorInputRequired == false,
            "Sidecar deterministic seed binding differs"
        )
        try require(
            sidecar.sourceTest.targetKind == Self.uiTestTargetKind,
            "Sidecar target kind differs"
        )
        try require(
            sidecar.sourceTest.testIdentifier == Self.testIdentifier,
            "Sidecar test identifier differs"
        )
        try require(
            sidecar.sourceTest.bundleRole == bundleRole(for: entry.destination),
            "Sidecar bundle role differs"
        )

        let candidateIDs = sidecar.candidateElementCaptures.map(\.candidateID)
        try require(
            candidateIDs == entry.candidateIDs,
            "Sidecar candidate set or order differs for \(entry.id)"
        )
        for item in sidecar.candidateElementCaptures {
            guard let captured = capturedByID[item.candidateID] else {
                throw CaptureFailure("Missing in-memory candidate \(item.candidateID)")
            }
            try require(
                item.declaredOperation == Self.captureOperation
                    && item.actualOperation == Self.captureOperation,
                "Candidate operation differs for \(item.candidateID)"
            )
            try require(
                item.attachmentName == candidateAttachmentName(
                    for: entry,
                    candidateID: item.candidateID
                ),
                "Candidate attachment name differs for \(item.candidateID)"
            )
            try require(
                item.sha256 == captured.image.sha256
                    && item.byteCount == captured.image.data.count
                    && item.pixelWidth == captured.image.pixelWidth
                    && item.pixelHeight == captured.image.pixelHeight,
                "Candidate image binding differs for \(item.candidateID)"
            )
            try require(
                item.elementIdentifier == item.candidateID
                    && item.queryPredicate == "identifier == '\(item.candidateID)'"
                    && item.matchCount == 1
                    && item.coordinateOrigin == "top-left"
                    && item.coordinateUnits == "points"
                    && item.elementFrame == captured.frame,
                "Candidate raw XCUI query binding differs for \(item.candidateID)"
            )
        }

        let expectedWitnesses = try structuralWitnessSpecifications(
            entry: entry,
            candidatesByID: candidatesByID
        )
        try require(
            sidecar.structuralWitnesses.map(\.witnessID)
                == expectedWitnesses.map(\.witnessID),
            "Sidecar structural witness set or order differs for \(entry.id)"
        )
        for (item, specification) in zip(
            sidecar.structuralWitnesses,
            expectedWitnesses
        ) {
            try require(
                item.queryPredicate == specification.query.predicate
                    && item.matchCount == specification.expectedMatchCount
                    && item.coordinateOrigin == "top-left"
                    && item.coordinateUnits == "points",
                "Sidecar structural witness query differs for \(item.witnessID)"
            )
            switch specification.query {
            case let .exact(identifier):
                try require(
                    item.elementIdentifier == identifier
                        && item.elementFrame != nil
                        && item.label != nil
                        && item.isEnabled != nil
                        && item.isHittable != nil,
                    "Sidecar exact structural witness is incomplete for \(identifier)"
                )
            case .beginsWith:
                try require(
                    item.elementIdentifier == nil
                        && item.elementFrame == nil
                        && item.label == nil
                        && item.value == nil
                        && item.isEnabled == nil
                        && item.isHittable == nil,
                    "Sidecar zero-result structural witness contains an element"
                )
            }
        }

        let expectedProbeIDs = entry.xcuiProbeIDs(using: probesByID)
        try require(
            sidecar.xcuiProbeEvidence.map(\.probeID) == expectedProbeIDs,
            "Sidecar probe set or order differs for \(entry.id)"
        )
        for item in sidecar.xcuiProbeEvidence {
            guard let catalog = probesByID[item.probeID] else {
                throw CaptureFailure("Unknown sidecar probe \(item.probeID)")
            }
            try require(
                item.source == catalog.source
                    && item.operatorName == catalog.operatorName
                    && item.expected == catalog.expected,
                "Probe catalog binding differs for \(item.probeID)"
            )
            try require(
                item.coordinateOrigin == "top-left"
                    && item.coordinateUnits == "points",
                "Probe coordinate contract differs for \(item.probeID)"
            )
            if item.probeID == Self.lockedProbeID {
                try require(
                    item.candidateID == nil
                        && item.elementFrame == nil
                        && item.queryPredicate == Self.lockedQueryPredicate
                        && item.matchCount == 0
                        && item.observed == .integer(0),
                    "Locked query evidence differs for \(entry.id)"
                )
            } else {
                guard let candidateID = item.candidateID,
                      let frame = item.elementFrame
                else {
                    throw CaptureFailure("Preview probe binding is absent")
                }
                let recomputed = try observedPreviewValue(
                    probeID: item.probeID,
                    matchCount: item.matchCount,
                    elementFrame: frame,
                    containerFrame: item.containerFrame
                )
                try require(
                    item.observed == .boolean(recomputed),
                    "Preview probe observation is not geometry-derived"
                )
                try require(
                    item.queryPredicate == "identifier == '\(candidateID)'",
                    "Preview probe predicate differs"
                )
            }
        }
    }

    private func loadCatalogs() throws -> Catalogs {
        let decoder = JSONDecoder()
        let authority: ComparisonAuthority = try decodeResource(
            named: "Comparison-Authority-v1.2",
            using: decoder
        )
        let seeds: SeedCatalog = try decodeResource(
            named: "Deterministic-Seed-Catalog-v1.2",
            using: decoder
        )
        let probes: RuntimeProbeCatalog = try decodeResource(
            named: "Runtime-Probe-Catalog-v1.2",
            using: decoder
        )
        let candidates: CandidateCatalog = try decodeResource(
            named: "Candidate-Capture-Catalog-v1.2",
            using: decoder
        )
        return Catalogs(
            authority: authority,
            seeds: seeds,
            probes: probes,
            candidates: candidates
        )
    }

    private func decodeResource<T: Decodable>(
        named name: String,
        using decoder: JSONDecoder
    ) throws -> T {
        guard let url = Bundle(for: Self.self).url(
            forResource: name,
            withExtension: "json"
        ) else {
            throw CaptureFailure("Missing bundled authority resource \(name).json")
        }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func validateCatalogs(_ catalogs: Catalogs) throws {
        try require(
            catalogs.authority.schemaVersion == "1.2"
                && catalogs.authority.expectedEntryCount == 400
                && catalogs.authority.entries.count == 400,
            "Comparison authority must contain exactly 400 v1.2 entries"
        )
        try require(
            Set(catalogs.authority.entries.map(\.id)).count == 400,
            "Comparison authority entry IDs are not unique"
        )
        try require(
            catalogs.seeds.schemaVersion == "1.2"
                && catalogs.seeds.seedCount == 100
                && catalogs.seeds.seeds.count == 100
                && catalogs.seedsByID.count == 100,
            "Seed catalog must contain exactly 100 unique v1.2 seeds"
        )
        try require(
            catalogs.probes.schemaVersion == "1.2"
                && catalogs.probes.probeCount == 50
                && catalogs.probes.probes.count == 50
                && catalogs.probesByID.count == 50,
            "Runtime probe catalog must contain exactly 50 unique v1.2 probes"
        )
        try require(
            catalogs.candidates.schemaVersion == "1.2"
                && catalogs.candidates.candidateCount == 188
                && catalogs.candidates.candidates.count == 188
                && catalogs.candidatesByID.count == 188,
            "Candidate capture catalog must contain exactly 188 unique v1.2 candidates"
        )

        let destinations = [
            "iphone-portrait",
            "ipad-portrait",
            "macos-standard",
            "macos-resized",
        ]
        var total = CaptureInventory()
        for destination in destinations {
            let entries = catalogs.authority.entries.filter { entry in
                entry.destination == destination
                    && (!entry.candidateIDs.isEmpty
                        || !entry.xcuiProbeIDs(using: catalogs.probesByID).isEmpty)
            }
            let inventory = CaptureInventory(
                sidecars: entries.count,
                candidates: entries.reduce(0) { $0 + $1.candidateIDs.count },
                queries: entries.reduce(0) {
                    $0 + $1.xcuiProbeIDs(using: catalogs.probesByID)
                        .filter { $0 == Self.lockedProbeID }.count
                }
            )
            try require(
                inventory == CaptureInventory(sidecars: 95, candidates: 168, queries: 1),
                "Authority inventory differs for \(destination)"
            )
            total += inventory
        }
        try require(
            total == CaptureInventory(sidecars: 380, candidates: 672, queries: 4),
            "Full XCUI inventory must be 380 sidecars, 672 candidates, and 4 queries"
        )

        for entry in catalogs.authority.entries {
            guard let seed = catalogs.seedsByID[entry.seedID] else {
                throw CaptureFailure("Entry references missing seed \(entry.seedID)")
            }
            try require(
                seed.theme == entry.theme && seed.surface == entry.surface,
                "Entry seed binding differs for \(entry.id)"
            )
            for probeID in entry.runtimeProbeIDs {
                try require(
                    catalogs.probesByID[probeID] != nil,
                    "Entry references missing probe \(probeID)"
                )
            }
            for mapping in entry.referenceMappings
            where mapping.candidateElementID != nil {
                try require(
                    mapping.candidateCaptureOperation == Self.captureOperation,
                    "Entry declares an unsupported candidate capture operation for \(entry.id)"
                )
            }
        }
    }

    private func validateLaunchEnvironment(
        _ environment: [String: String],
        seed: DeterministicSeed,
        destination: String
    ) throws {
        let expectedKeys = Set(seed.launchEnvironment.keys).union([
            Self.qualificationDestinationKey,
        ])
        try require(
            Set(environment.keys) == expectedKeys,
            "Qualification launch tuple has unexpected keys for \(seed.id)"
        )
        try require(
            environment["RUNESCRIBE_QUALIFICATION"] == "theme-fidelity-v4.2"
                && environment["RUNESCRIBE_QUALIFICATION_RESET_STATE"] == "1"
                && environment[Self.qualificationDestinationKey] == destination,
            "Qualification launch tuple differs for \(seed.id)"
        )
        try require(
            seed.operatorInputRequired == false,
            "Qualification seed unexpectedly requires operator input: \(seed.id)"
        )
    }

    private func activeDestinations() throws -> [String] {
        #if os(iOS)
        let environment = ProcessInfo.processInfo.environment
        let identity = [
            environment["SIMULATOR_DEVICE_NAME"],
            environment["SIMULATOR_MODEL_IDENTIFIER"],
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if identity.contains("ipad") { return ["ipad-portrait"] }
        if identity.contains("iphone") { return ["iphone-portrait"] }
        throw CaptureFailure(
            "Unable to derive iOS qualification destination from Simulator identity: \(identity)"
        )
        #elseif os(macOS)
        return ["macos-standard", "macos-resized"]
        #endif
    }

    private var sourceTargetName: String {
        #if os(iOS)
        "RuneScribIOSUITests"
        #elseif os(macOS)
        "RuneScribMacParityUITests"
        #endif
    }

    private func bundleRole(for destination: String) -> String {
        switch destination {
        case "iphone-portrait": "iphone-xcui"
        case "ipad-portrait": "ipad-xcui"
        case "macos-standard", "macos-resized": "macos-xcui"
        default: ""
        }
    }

    private func candidateAttachmentName(
        for entry: AuthorityEntry,
        candidateID: String
    ) -> String {
        "\(entry.stem)--candidate-element--\(candidateID).png"
    }

    private func queryAttachmentName(for entry: AuthorityEntry) -> String {
        "\(entry.stem)--xcui-query.png"
    }

    private func capturedImage(
        _ data: Data,
        attachmentName: String
    ) throws -> CapturedImage {
        let dimensions = try pngDimensions(data, label: attachmentName)
        return CapturedImage(
            data: data,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height
        )
    }

    private func pngDimensions(
        _ data: Data,
        label: String
    ) throws -> (width: Int, height: Int) {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        try require(
            data.count >= 24 && Array(data.prefix(8)) == signature,
            "Attachment is not a valid PNG: \(label)"
        )
        func uint32(at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
        }
        let width = Int(uint32(at: 16))
        let height = Int(uint32(at: 20))
        try require(width > 0 && height > 0, "PNG dimensions are empty: \(label)")
        return (width, height)
    }

    private func evidenceRect(
        _ rect: CGRect,
        label: String
    ) throws -> EvidenceRect {
        let evidence = EvidenceRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
        try require(
            evidence.isValid,
            "XCUI frame is invalid for \(label): \(rect)"
        )
        return evidence
    }

    private func attach(_ data: Data, named name: String, type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String
    ) throws {
        guard condition() else { throw CaptureFailure(message()) }
    }
}

private struct Catalogs {
    let authority: ComparisonAuthority
    let seeds: SeedCatalog
    let probes: RuntimeProbeCatalog
    let candidates: CandidateCatalog

    var seedsByID: [String: DeterministicSeed] {
        seeds.seeds.reduce(into: [:]) { result, seed in
            result[seed.id] = seed
        }
    }

    var probesByID: [String: RuntimeProbe] {
        probes.probes.reduce(into: [:]) { result, probe in
            result[probe.id] = probe
        }
    }

    var candidatesByID: [String: CandidateCatalogEntry] {
        candidates.candidates.reduce(into: [:]) { result, candidate in
            result[candidate.id] = candidate
        }
    }
}

private struct ComparisonAuthority: Decodable {
    let schemaVersion: String
    let expectedEntryCount: Int
    let entries: [AuthorityEntry]
}

private struct AuthorityEntry: Decodable {
    let id: String
    let theme: String
    let themeID: String
    let codexID: String
    let surface: String
    let destination: String
    let seedID: String
    let referenceMappings: [ReferenceMapping]
    let entryStructuralAssertionIDs: [String]
    let runtimeProbeIDs: [String]

    var stem: String {
        "\(theme.lowercased())--\(surface)--\(destination)"
    }

    var candidateIDs: [String] {
        Array(Set(referenceMappings.compactMap(\.candidateElementID))).sorted()
    }

    func xcuiProbeIDs(using probesByID: [String: RuntimeProbe]) -> [String] {
        runtimeProbeIDs.filter { probeID in
            probesByID[probeID]?.source.hasPrefix("xcui-") == true
        }
    }

    var structuralAssertionIDs: Set<String> {
        Set(entryStructuralAssertionIDs).union(
            referenceMappings.flatMap(\.structuralAssertionIDs)
        )
    }
}

private struct ReferenceMapping: Decodable {
    let candidateElementID: String?
    let candidateCaptureOperation: String
    let structuralAssertionIDs: [String]
}

private struct SeedCatalog: Decodable {
    let schemaVersion: String
    let seedCount: Int
    let seeds: [DeterministicSeed]
}

private struct DeterministicSeed: Codable, Equatable {
    let id: String
    let theme: String
    let surface: String
    let launchEnvironment: [String: String]
    let operatorInputRequired: Bool
}

private struct RuntimeProbeCatalog: Decodable {
    let schemaVersion: String
    let probeCount: Int
    let probes: [RuntimeProbe]
}

private struct CandidateCatalog: Decodable {
    let schemaVersion: String
    let candidateCount: Int
    let candidates: [CandidateCatalogEntry]
}

private struct CandidateCatalogEntry: Decodable {
    let id: String
}

private struct RuntimeProbe: Decodable {
    let id: String
    let source: String
    let operatorName: String
    let expected: JSONValue

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case operatorName = "operator"
        case expected
    }
}

private enum JSONValue: Codable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .boolean(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

private struct AuthoritySidecar: Encodable {
    let schemaVersion: String
    let entryID: String
    let theme: String
    let surface: String
    let destination: String
    let deterministicSeed: DeterministicSeed
    let primaryCaptureAttachmentName: String
    let captureRecordAttachmentName: String
    let sourceTest: SourceTestEvidence
    let candidateElementCaptures: [CandidateCaptureEvidence]
    let structuralWitnesses: [StructuralWitnessEvidence]
    let xcuiProbeEvidence: [ProbeEvidence]
}

private struct SourceTestEvidence: Encodable {
    let targetName: String
    let targetKind: String
    let testIdentifier: String
    let bundleRole: String
}

private struct CandidateCaptureEvidence: Encodable {
    let candidateID: String
    let elementIdentifier: String
    let attachmentName: String
    let declaredOperation: String
    let actualOperation: String
    let sha256: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let queryPredicate: String
    let matchCount: Int
    let coordinateOrigin: String
    let coordinateUnits: String
    let elementFrame: EvidenceRect
    let windowFrame: EvidenceRect
    let label: String
    let value: String
    let isEnabled: Bool
    let isHittable: Bool
}

private struct StructuralWitnessEvidence: Encodable {
    let witnessID: String
    let queryPredicate: String
    let matchCount: Int
    let elementIdentifier: String?
    let coordinateOrigin: String
    let coordinateUnits: String
    let elementFrame: EvidenceRect?
    let windowFrame: EvidenceRect
    let label: String?
    let value: String?
    let isEnabled: Bool?
    let isHittable: Bool?

    private enum CodingKeys: String, CodingKey {
        case witnessID
        case queryPredicate
        case matchCount
        case elementIdentifier
        case coordinateOrigin
        case coordinateUnits
        case elementFrame
        case windowFrame
        case label
        case value
        case isEnabled
        case isHittable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(witnessID, forKey: .witnessID)
        try container.encode(queryPredicate, forKey: .queryPredicate)
        try container.encode(matchCount, forKey: .matchCount)
        try container.encode(elementIdentifier, forKey: .elementIdentifier)
        try container.encode(coordinateOrigin, forKey: .coordinateOrigin)
        try container.encode(coordinateUnits, forKey: .coordinateUnits)
        try container.encode(elementFrame, forKey: .elementFrame)
        try container.encode(windowFrame, forKey: .windowFrame)
        try container.encode(label, forKey: .label)
        try container.encode(value, forKey: .value)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isHittable, forKey: .isHittable)
    }
}

private struct StructuralWitnessSpecification: Equatable {
    let witnessID: String
    let query: StructuralWitnessQuery
    let expectedMatchCount: Int
}

private enum StructuralWitnessQuery: Equatable {
    case exact(String)
    case beginsWith(String)

    var predicate: String {
        switch self {
        case let .exact(identifier):
            "identifier == '\(identifier)'"
        case let .beginsWith(prefix):
            "identifier BEGINSWITH '\(prefix)'"
        }
    }
}

private struct ProbeEvidence: Encodable {
    let probeID: String
    let source: String
    let operatorName: String
    let expected: JSONValue
    let observed: JSONValue
    let queryPredicate: String
    let matchCount: Int
    let candidateID: String?
    let attachmentName: String
    let attachmentSHA256: String
    let pixelWidth: Int
    let pixelHeight: Int
    let coordinateOrigin: String
    let coordinateUnits: String
    let elementFrame: EvidenceRect?
    let containerFrame: EvidenceRect

    private enum CodingKeys: String, CodingKey {
        case probeID
        case source
        case operatorName = "operator"
        case expected
        case observed
        case queryPredicate
        case matchCount
        case candidateID
        case attachmentName
        case attachmentSHA256
        case pixelWidth
        case pixelHeight
        case coordinateOrigin
        case coordinateUnits
        case elementFrame
        case containerFrame
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(probeID, forKey: .probeID)
        try container.encode(source, forKey: .source)
        try container.encode(operatorName, forKey: .operatorName)
        try container.encode(expected, forKey: .expected)
        try container.encode(observed, forKey: .observed)
        try container.encode(queryPredicate, forKey: .queryPredicate)
        try container.encode(matchCount, forKey: .matchCount)
        if let candidateID {
            try container.encode(candidateID, forKey: .candidateID)
        } else {
            try container.encodeNil(forKey: .candidateID)
        }
        try container.encode(attachmentName, forKey: .attachmentName)
        try container.encode(attachmentSHA256, forKey: .attachmentSHA256)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(coordinateOrigin, forKey: .coordinateOrigin)
        try container.encode(coordinateUnits, forKey: .coordinateUnits)
        if let elementFrame {
            try container.encode(elementFrame, forKey: .elementFrame)
        } else {
            try container.encodeNil(forKey: .elementFrame)
        }
        try container.encode(containerFrame, forKey: .containerFrame)
    }
}

private struct EvidenceRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }

    func intersects(_ other: Self) -> Bool {
        x < other.x + other.width
            && x + width > other.x
            && y < other.y + other.height
            && y + height > other.y
    }

    func contains(_ other: Self) -> Bool {
        other.x >= x
            && other.y >= y
            && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }
}

private struct CapturedImage {
    let data: Data
    let sha256: String
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct CapturedElement {
    let evidence: CandidateCaptureEvidence
    let frame: EvidenceRect
    let matchCount: Int
    let image: CapturedImage
}

private struct ResolvedElement {
    let element: XCUIElement
    let queryCount: Int
}

private struct CaptureInventory: Equatable {
    var sidecars = 0
    var candidates = 0
    var queries = 0

    static func += (left: inout Self, right: Self) {
        left.sidecars += right.sidecars
        left.candidates += right.candidates
        left.queries += right.queries
    }
}

private struct CaptureFailure: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}
