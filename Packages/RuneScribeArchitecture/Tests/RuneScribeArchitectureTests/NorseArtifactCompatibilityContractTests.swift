import RuneScribeContracts
import XCTest

final class NorseArtifactCompatibilityContractTests: XCTestCase {
    private typealias Artifacts = NorseArtifactCompatibilityAuthority
    private typealias Rewards = NorseProgressionRewardAuthority

    func testLegacyAliasInventoryExactlyMatchesTheApprovedTransition() {
        XCTAssertEqual(rawMap(Artifacts.relicAliases), [
            "relic.norse.runestone.weathered": "relic.norse.runestone-tablet",
            "relic.norse.raven-medallion": "relic.norse.dragonwood-plaque",
            "relic.norse.ironbound-shield": "relic.norse.stormforged-stele",
            "relic.norse.sealed-parchment": "relic.norse.dragonwood-plaque",
            "relic.norse.runestone.blackstone": "relic.norse.stormforged-stele",
            "relic.norse.runestone.frozen": "relic.norse.runestone-tablet",
        ])
        XCTAssertEqual(rawMap(Artifacts.sealAliases), [
            "seal.norse.knotwork": "seal.norse.valknut",
            "seal.norse.forge-flame": "seal.norse.ravenshield",
            "seal.norse.raven": "seal.norse.ravenshield",
            "seal.norse.longship": "seal.norse.wolkin",
            "seal.norse.forge-hammer": "seal.norse.mjolnir",
            "seal.norse.echo-rune": "seal.norse.yggdrasil",
        ])
        XCTAssertEqual(rawMap(Artifacts.frameAliases), [
            "frame.norse.carved-knotwork": "frame.norse.carved-knotwork",
        ])
        XCTAssertEqual(rawMap(Artifacts.crestAliases), [
            "crest.norse.forge-master": "crest.norse.raven-mastery",
        ])
    }

    func testCurrentCatalogSelectableSetsAndDefaultsAreExact() {
        XCTAssertEqual(Artifacts.legacyCatalogVersion, 1)
        XCTAssertEqual(Artifacts.currentCatalogVersion, 2)
        XCTAssertEqual(rawValues(Artifacts.currentRelicIDs), [
            "relic.norse.runestone-tablet",
            "relic.norse.dragonwood-plaque",
            "relic.norse.stormforged-stele",
        ])
        XCTAssertEqual(rawValues(Artifacts.currentSealIDs), [
            "seal.norse.valknut",
            "seal.norse.ravenshield",
            "seal.norse.mjolnir",
            "seal.norse.wolkin",
            "seal.norse.yggdrasil",
            "seal.norse.berserk",
        ])
        XCTAssertEqual(rawValues(Artifacts.currentFrameIDs), [
            "frame.norse.carved-knotwork",
        ])
        XCTAssertEqual(rawValues(Artifacts.currentCrestIDs), [
            "crest.norse.raven-mastery",
        ])

        XCTAssertEqual(
            Artifacts.currentSelectableRelicIDs,
            Artifacts.currentRelicIDs
        )
        XCTAssertEqual(
            Artifacts.currentSelectableSealIDs,
            Artifacts.currentSealIDs
        )
        XCTAssertEqual(
            Artifacts.currentSelectableFrameIDs,
            Artifacts.currentFrameIDs
        )
        XCTAssertTrue(Artifacts.currentSelectableCrestIDs.isEmpty)

        XCTAssertEqual(
            Artifacts.defaultRelicID.rawValue,
            "relic.norse.runestone-tablet"
        )
        XCTAssertEqual(Artifacts.defaultSealID.rawValue, "seal.norse.valknut")
        XCTAssertNil(Artifacts.defaultFrameID)
        XCTAssertNil(Artifacts.defaultCrestID)
        XCTAssertEqual(
            Artifacts.defaultArtifactID(for: .relic)?.rawValue,
            "relic.norse.runestone-tablet"
        )
        XCTAssertEqual(
            Artifacts.defaultArtifactID(for: .seal)?.rawValue,
            "seal.norse.valknut"
        )
        XCTAssertNil(Artifacts.defaultArtifactID(for: .frame))
        XCTAssertNil(Artifacts.defaultArtifactID(for: .crest))

        XCTAssertTrue(Set(Artifacts.relicAliases.keys).isDisjoint(
            with: Artifacts.currentSelectableRelicIDs
        ))
        XCTAssertTrue(Set(Artifacts.sealAliases.keys).isDisjoint(
            with: Artifacts.currentSelectableSealIDs
        ))
        XCTAssertTrue(Set(Artifacts.crestAliases.keys).isDisjoint(
            with: Artifacts.currentCrestIDs
        ))
        XCTAssertEqual(
            Set(Artifacts.frameAliases.keys),
            Artifacts.currentSelectableFrameIDs
        )
    }

    func testLegacyAndCurrentIdentifiersCanonicalizeExactlyAndIdempotently() throws {
        for (legacy, current) in Artifacts.relicAliases {
            XCTAssertEqual(try Artifacts.canonicalRelicID(legacy), current)
        }
        for current in Artifacts.currentRelicIDs {
            XCTAssertEqual(try Artifacts.canonicalRelicID(current), current)
        }
        for (legacy, current) in Artifacts.sealAliases {
            XCTAssertEqual(try Artifacts.canonicalSealID(legacy), current)
        }
        for current in Artifacts.currentSealIDs {
            XCTAssertEqual(try Artifacts.canonicalSealID(current), current)
        }
        for (legacy, current) in Artifacts.frameAliases {
            XCTAssertEqual(try Artifacts.canonicalFrameID(legacy), current)
        }
        for current in Artifacts.currentFrameIDs {
            XCTAssertEqual(try Artifacts.canonicalFrameID(current), current)
        }
        for (legacy, current) in Artifacts.crestAliases {
            XCTAssertEqual(try Artifacts.canonicalCrestID(legacy), current)
        }
        for current in Artifacts.currentCrestIDs {
            XCTAssertEqual(try Artifacts.canonicalCrestID(current), current)
        }

        for kind in NorseArtifactCompatibilityKind.allCases {
            for identifier in Artifacts.currentArtifactIDs(for: kind) {
                XCTAssertEqual(
                    try Artifacts.canonicalArtifactID(identifier, as: kind),
                    identifier
                )
            }
        }
    }

    func testCanonicalizationPassesThroughNonNorseAndRejectsUnknownNorseOrWrongKind() throws {
        let nonNorse: [(NorseArtifactCompatibilityKind, String)] = [
            (.relic, "relic.moonleaf.tablet"),
            (.seal, "seal.sunspire.golden-lark"),
            (.frame, "frame.progression.collector"),
            (.crest, "crest.moonleaf.moonbloom"),
        ]
        for (kind, rawValue) in nonNorse {
            let identifier = try XCTUnwrap(ArtifactID(rawValue: rawValue))
            XCTAssertEqual(
                try Artifacts.canonicalArtifactID(identifier, as: kind),
                identifier
            )
        }

        let unknownNorse: [(NorseArtifactCompatibilityKind, String)] = [
            (.relic, "relic.norse.unapproved-relic"),
            (.seal, "seal.norse.unapproved-seal"),
            (.frame, "frame.norse.unapproved-frame"),
            (.crest, "crest.norse.unapproved-crest"),
        ]
        for (kind, rawValue) in unknownNorse {
            let identifier = try XCTUnwrap(ArtifactID(rawValue: rawValue))
            XCTAssertThrowsError(
                try Artifacts.canonicalArtifactID(identifier, as: kind)
            ) { error in
                XCTAssertEqual(
                    error as? NorseArtifactCompatibilityError,
                    .unsupportedNorseIdentifier(kind: kind, identifier: rawValue)
                )
            }
        }

        let sealAsRelic = try XCTUnwrap(ArtifactID(rawValue: "seal.norse.valknut"))
        XCTAssertThrowsError(
            try Artifacts.canonicalArtifactID(sealAsRelic, as: .relic)
        ) { error in
            XCTAssertEqual(
                error as? NorseArtifactCompatibilityError,
                .kindMismatch(expected: .relic, identifier: sealAsRelic.rawValue)
            )
        }
    }

    func testProgressionSourceRewardAuthorityExactlyMatchesCurrentRows() {
        let current = NorseArtifactCompatibilityAuthority.Current.self
        let expectedIdentifiers: [
            NorseProgressionRewardSource: NorseProgressionRewardSourceIdentifier
        ] = [
            .baseIncluded: .grantGroup(
                GrantGroupID(rawValue: "grant-group.base.norse.included")!
            ),
            .firstInscription: .achievement(
                AchievementID(rawValue: "achievement.first-inscription")!
            ),
            .firstDispatch: .achievement(
                AchievementID(rawValue: "achievement.first-dispatch")!
            ),
            .correspondent: .achievement(
                AchievementID(rawValue: "achievement.correspondent")!
            ),
            .courierI: .achievement(AchievementID(rawValue: "achievement.courier-1")!),
            .courierII: .achievement(AchievementID(rawValue: "achievement.courier-2")!),
            .archivistI: .achievement(
                AchievementID(rawValue: "achievement.archivist-1")!
            ),
            .archivistII: .achievement(
                AchievementID(rawValue: "achievement.archivist-2")!
            ),
            .norseEcho: .rule(RuleID(rawValue: "rule.codex.norse.echo-five")!),
            .norseMastery: .rule(RuleID(rawValue: "rule.codex.norse.mastery")!),
        ]
        let expectedRewards: [
            NorseProgressionRewardSource: [ProgressionContentReference]
        ] = [
            .baseIncluded: [
                artifact(current.runestoneTablet.rawValue),
                artifact(current.valknutSeal.rawValue),
                artifact(current.ravenshieldSeal.rawValue),
                artifact(Rewards.baseScriptID.rawValue),
                .codex(RuneScribeCodexIDs.norse),
            ],
            .firstInscription: [artifact(current.mjolnirSeal.rawValue)],
            .firstDispatch: [artifact(current.dragonwoodPlaque.rawValue)],
            .correspondent: [artifact(current.wolkinSeal.rawValue)],
            .courierI: [artifact(current.yggdrasilSeal.rawValue)],
            .courierII: [artifact(current.stormforgedStele.rawValue)],
            .archivistI: [artifact(current.carvedKnotworkFrame.rawValue)],
            .archivistII: [
                .title(Rewards.archivistTitleID),
                artifact(current.berserkSeal.rawValue),
            ],
            .norseEcho: [artifact(current.yggdrasilSeal.rawValue)],
            .norseMastery: [
                .crest(current.ravenMasteryCrest),
                .title(Rewards.masterOfRunesTitleID),
            ],
        ]

        XCTAssertEqual(
            Set(Rewards.routes.map(\.source)),
            Set(NorseProgressionRewardSource.allCases)
        )
        XCTAssertEqual(Rewards.routes.count, NorseProgressionRewardSource.allCases.count)
        for source in NorseProgressionRewardSource.allCases {
            let route = Rewards.route(for: source)
            XCTAssertEqual(source.identifier, expectedIdentifiers[source])
            XCTAssertEqual(route.rewards, expectedRewards[source])
            XCTAssertEqual(
                route.role,
                source == .norseEcho ? .idempotentSecondRoute : .primary
            )
        }

        XCTAssertEqual(
            Rewards.route(for: .courierI).rewards,
            Rewards.route(for: .norseEcho).rewards
        )
        XCTAssertEqual(
            Rewards.route(for: .archivistII).rewards.first,
            .title(Rewards.archivistTitleID)
        )
    }

    func testVisualAliasesRemainSeparateFromProgressionSourceRewards() throws {
        XCTAssertEqual(
            try Artifacts.canonicalSealID(Artifacts.Legacy.ravenSeal),
            Artifacts.Current.ravenshieldSeal
        )
        XCTAssertEqual(
            Rewards.route(for: .firstInscription).rewards,
            [artifact(Artifacts.Current.mjolnirSeal.rawValue)]
        )

        XCTAssertEqual(
            try Artifacts.canonicalSealID(Artifacts.Legacy.forgeHammerSeal),
            Artifacts.Current.mjolnirSeal
        )
        XCTAssertEqual(
            Rewards.route(for: .courierI).rewards,
            [artifact(Artifacts.Current.yggdrasilSeal.rawValue)]
        )

        XCTAssertEqual(
            try Artifacts.canonicalRelicID(Artifacts.Legacy.sealedParchment),
            Artifacts.Current.dragonwoodPlaque
        )
        XCTAssertTrue(Rewards.route(for: .archivistII).rewards.contains(
            artifact(Artifacts.Current.berserkSeal.rawValue)
        ))

        XCTAssertEqual(
            try Artifacts.canonicalRelicID(Artifacts.Legacy.blackstoneRunestone),
            Artifacts.Current.stormforgedStele
        )
        XCTAssertEqual(Rewards.route(for: .norseMastery).rewards, [
            .crest(Artifacts.Current.ravenMasteryCrest),
            .title(Rewards.masterOfRunesTitleID),
        ])
    }

    func testInboundNorseAliasesResolveCurrentInventoryAndPreserveRequestedSelection()
        throws
    {
        let requested = try norseSelection(
            relic: Artifacts.Legacy.weatheredRunestone.rawValue,
            seal: Artifacts.Legacy.knotworkSeal.rawValue,
            frame: Artifacts.Legacy.carvedKnotworkFrame.rawValue
        )
        let expected = try norseSelection(
            relic: Artifacts.Current.runestoneTablet.rawValue,
            seal: Artifacts.Current.valknutSeal.rawValue,
            frame: Artifacts.Current.carvedKnotworkFrame.rawValue
        )
        let inventory = try currentNorseInventory()

        XCTAssertEqual(
            SharePresentationProviderCompatibilityResolver.resolve(
                selection: requested,
                resources: [],
                providerAvailability: .available,
                inventories: [inventory]
            ),
            .available
        )
        XCTAssertEqual(
            SharePresentationProviderCompatibilityResolver.effectiveSelection(
                for: requested
            ),
            expected
        )

        let presentation = try ReceivedSharePresentation(
            requestedSelection: requested,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            providerAvailability: .available,
            renderMode: .requestedCodex,
            safePreviewStatus: .absent,
            provenanceStatus: .unavailable
        )
        XCTAssertEqual(presentation.requestedSelection, requested)
        XCTAssertEqual(presentation.effectiveSelection, expected)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(presentation)
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "effectiveSelection")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder().decode(
            ReceivedSharePresentation.self,
            from: legacyData
        )
        XCTAssertEqual(decodedLegacy.requestedSelection, requested)
        XCTAssertEqual(decodedLegacy.effectiveSelection, expected)

        XCTAssertThrowsError(try ReceivedSharePresentation(
            requestedSelection: requested,
            effectiveSelection: requested,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            providerAvailability: .available,
            renderMode: .requestedCodex,
            safePreviewStatus: .absent,
            provenanceStatus: .unavailable
        )) { error in
            XCTAssertEqual(
                error as? SharePresentationContractError,
                .invalidObservation
            )
        }
    }

    func testInboundUnknownNorseIDsFailClosedAndAliasesDoNotBypassResourceIntegrity()
        throws
    {
        let unknown = try norseSelection(
            relic: "relic.norse.future-relic",
            seal: Artifacts.Current.valknutSeal.rawValue
        )
        let inventory = try currentNorseInventory()
        XCTAssertNil(
            SharePresentationProviderCompatibilityResolver.effectiveSelection(
                for: unknown
            )
        )
        XCTAssertEqual(
            SharePresentationProviderCompatibilityResolver.resolve(
                selection: unknown,
                resources: [],
                providerAvailability: .available,
                inventories: [inventory]
            ),
            .incompatible
        )
        XCTAssertThrowsError(try ReceivedSharePresentation(
            requestedSelection: unknown,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            providerAvailability: .available,
            renderMode: .requestedCodex,
            safePreviewStatus: .absent,
            provenanceStatus: .unavailable
        ))

        let requested = try norseSelection(
            relic: Artifacts.Legacy.weatheredRunestone.rawValue,
            seal: Artifacts.Legacy.knotworkSeal.rawValue
        )
        let declaredResource = try resourceMetadata(digestCharacter: "b")
        let installedResource = try resourceMetadata(digestCharacter: "a")
        let resourceInventory = try currentNorseInventory(resources: [
            SharePresentationProviderResourceInventory(metadata: installedResource),
        ])
        XCTAssertEqual(
            SharePresentationProviderCompatibilityResolver.resolve(
                selection: requested,
                resources: [declaredResource],
                providerAvailability: .available,
                inventories: [resourceInventory]
            ),
            .corrupt
        )
        XCTAssertEqual(
            SharePresentationProviderCompatibilityResolver.resolve(
                selection: requested,
                resources: [declaredResource],
                providerAvailability: .available,
                inventories: [inventory]
            ),
            .incompatible
        )
    }

    func testOutboundShareContractRejectsLegacyAndUnknownNorseSelections() throws {
        let current = try norseSelection(
            relic: Artifacts.Current.runestoneTablet.rawValue,
            seal: Artifacts.Current.valknutSeal.rawValue
        )
        XCTAssertNoThrow(try OutboundSharePresentationDTO(
            metadata: shareMetadata(selection: current)
        ))

        for selection in [
            try norseSelection(
                relic: Artifacts.Legacy.weatheredRunestone.rawValue,
                seal: Artifacts.Current.valknutSeal.rawValue
            ),
            try norseSelection(
                relic: Artifacts.Current.runestoneTablet.rawValue,
                seal: "seal.norse.future-seal"
            ),
        ] {
            XCTAssertThrowsError(try OutboundSharePresentationDTO(
                metadata: shareMetadata(selection: selection)
            )) { error in
                XCTAssertEqual(
                    error as? SharePresentationContractError,
                    .invalidArtifactIdentifier
                )
            }
        }

        let nonNorse = try SharePresentationSelection(
            codexID: CodexID(rawValue: "codex.moonleaf")!,
            scriptID: ScriptID(rawValue: "script.moonleaf")!,
            relicID: ArtifactID(rawValue: "relic.moonleaf.silver-leaf")!,
            sealID: ArtifactID(rawValue: "seal.moonleaf.firefly")!,
            frameID: nil
        )
        XCTAssertNoThrow(try OutboundSharePresentationDTO(
            metadata: shareMetadata(selection: nonNorse)
        ))
    }

    private func rawMap<Domain>(
        _ values: [
            RoadmapStringIdentifier<Domain>: RoadmapStringIdentifier<Domain>
        ]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map {
            ($0.key.rawValue, $0.value.rawValue)
        })
    }

    private func rawValues<Domain>(
        _ values: Set<RoadmapStringIdentifier<Domain>>
    ) -> Set<String> {
        Set(values.map(\.rawValue))
    }

    private func artifact(_ rawValue: String) -> ProgressionContentReference {
        .artifact(ArtifactID(rawValue: rawValue)!)
    }

    private func norseSelection(
        relic: String,
        seal: String? = nil,
        frame: String? = nil
    ) throws -> SharePresentationSelection {
        try SharePresentationSelection(
            codexID: RuneScribeCodexIDs.norse,
            scriptID: Rewards.baseScriptID,
            relicID: ArtifactID(rawValue: relic)!,
            sealID: seal.map { ArtifactID(rawValue: $0)! },
            frameID: frame.map { ArtifactID(rawValue: $0)! }
        )
    }

    private func currentNorseInventory(
        resources: [SharePresentationProviderResourceInventory] = []
    ) throws -> SharePresentationProviderInventory {
        try SharePresentationProviderInventory(
            codexID: RuneScribeCodexIDs.norse,
            scriptIDs: [Rewards.baseScriptID],
            relicIDs: Artifacts.currentRelicIDs.map {
                ArtifactID(rawValue: $0.rawValue)!
            },
            sealIDs: Artifacts.currentSealIDs.map {
                ArtifactID(rawValue: $0.rawValue)!
            },
            frameIDs: Artifacts.currentFrameIDs.map {
                ArtifactID(rawValue: $0.rawValue)!
            },
            resources: resources
        )
    }

    private func shareMetadata(
        selection: SharePresentationSelection
    ) throws -> SharePresentationMetadata {
        try SharePresentationMetadata(
            selection: selection,
            compatibility: .norseInteractiveFallback
        )
    }

    private func resourceMetadata(
        digestCharacter: Character
    ) throws -> SharePresentationResourceMetadata {
        try SharePresentationResourceMetadata(
            resourceID: ThemeResourceID(rawValue: "resource.norse.share-background")!,
            role: ThemeResourceRoles.backgroundStaticBase,
            mediaType: .pdf,
            byteLength: 512,
            sha256: ThemeSHA256Digest(
                rawValue: String(repeating: digestCharacter, count: 64)
            )!
        )
    }
}
