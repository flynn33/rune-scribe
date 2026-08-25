import Foundation

public enum NorseArtifactCompatibilityKind: String, Codable, CaseIterable, Sendable {
    case relic
    case seal
    case frame
    case crest
}

public enum NorseArtifactCompatibilityError: Error, Equatable, Sendable {
    case kindMismatch(expected: NorseArtifactCompatibilityKind, identifier: String)
    case unsupportedNorseIdentifier(
        kind: NorseArtifactCompatibilityKind,
        identifier: String
    )
}

/// Frozen compatibility authority for the Norse v1-to-v2 artifact transition.
/// Legacy identifiers remain readable through these aliases, but only the
/// current sets are eligible to appear as current catalog content.
public enum NorseArtifactCompatibilityAuthority {
    public static let legacyCatalogVersion: UInt16 = 1
    public static let currentCatalogVersion: UInt16 = 2

    public enum Current {
        public static let runestoneTablet = RelicID(
            rawValue: "relic.norse.runestone-tablet"
        )!
        public static let dragonwoodPlaque = RelicID(
            rawValue: "relic.norse.dragonwood-plaque"
        )!
        public static let stormforgedStele = RelicID(
            rawValue: "relic.norse.stormforged-stele"
        )!

        public static let valknutSeal = SealID(rawValue: "seal.norse.valknut")!
        public static let ravenshieldSeal = SealID(rawValue: "seal.norse.ravenshield")!
        public static let mjolnirSeal = SealID(rawValue: "seal.norse.mjolnir")!
        public static let wolkinSeal = SealID(rawValue: "seal.norse.wolkin")!
        public static let yggdrasilSeal = SealID(rawValue: "seal.norse.yggdrasil")!
        public static let berserkSeal = SealID(rawValue: "seal.norse.berserk")!

        public static let carvedKnotworkFrame = FrameID(
            rawValue: "frame.norse.carved-knotwork"
        )!
        public static let ravenMasteryCrest = CrestID(
            rawValue: "crest.norse.raven-mastery"
        )!
    }

    public enum Legacy {
        public static let weatheredRunestone = RelicID(
            rawValue: "relic.norse.runestone.weathered"
        )!
        public static let ravenMedallion = RelicID(
            rawValue: "relic.norse.raven-medallion"
        )!
        public static let ironboundShield = RelicID(
            rawValue: "relic.norse.ironbound-shield"
        )!
        public static let sealedParchment = RelicID(
            rawValue: "relic.norse.sealed-parchment"
        )!
        public static let blackstoneRunestone = RelicID(
            rawValue: "relic.norse.runestone.blackstone"
        )!
        public static let frozenRunestone = RelicID(
            rawValue: "relic.norse.runestone.frozen"
        )!

        public static let knotworkSeal = SealID(rawValue: "seal.norse.knotwork")!
        public static let forgeFlameSeal = SealID(rawValue: "seal.norse.forge-flame")!
        public static let ravenSeal = SealID(rawValue: "seal.norse.raven")!
        public static let longshipSeal = SealID(rawValue: "seal.norse.longship")!
        public static let forgeHammerSeal = SealID(rawValue: "seal.norse.forge-hammer")!
        public static let echoRuneSeal = SealID(rawValue: "seal.norse.echo-rune")!

        public static let carvedKnotworkFrame = FrameID(
            rawValue: "frame.norse.carved-knotwork"
        )!
        public static let forgeMasterCrest = CrestID(
            rawValue: "crest.norse.forge-master"
        )!
    }

    public static let relicAliases: [RelicID: RelicID] = [
        Legacy.weatheredRunestone: Current.runestoneTablet,
        Legacy.ravenMedallion: Current.dragonwoodPlaque,
        Legacy.ironboundShield: Current.stormforgedStele,
        Legacy.sealedParchment: Current.dragonwoodPlaque,
        Legacy.blackstoneRunestone: Current.stormforgedStele,
        Legacy.frozenRunestone: Current.runestoneTablet,
    ]

    public static let sealAliases: [SealID: SealID] = [
        Legacy.knotworkSeal: Current.valknutSeal,
        Legacy.forgeFlameSeal: Current.ravenshieldSeal,
        Legacy.ravenSeal: Current.ravenshieldSeal,
        Legacy.longshipSeal: Current.wolkinSeal,
        Legacy.forgeHammerSeal: Current.mjolnirSeal,
        Legacy.echoRuneSeal: Current.yggdrasilSeal,
    ]

    public static let frameAliases: [FrameID: FrameID] = [
        Legacy.carvedKnotworkFrame: Current.carvedKnotworkFrame,
    ]

    public static let crestAliases: [CrestID: CrestID] = [
        Legacy.forgeMasterCrest: Current.ravenMasteryCrest,
    ]

    public static let currentRelicIDs: Set<RelicID> = [
        Current.runestoneTablet,
        Current.dragonwoodPlaque,
        Current.stormforgedStele,
    ]

    public static let currentSealIDs: Set<SealID> = [
        Current.valknutSeal,
        Current.ravenshieldSeal,
        Current.mjolnirSeal,
        Current.wolkinSeal,
        Current.yggdrasilSeal,
        Current.berserkSeal,
    ]

    public static let currentFrameIDs: Set<FrameID> = [
        Current.carvedKnotworkFrame,
    ]

    public static let currentCrestIDs: Set<CrestID> = [
        Current.ravenMasteryCrest,
    ]

    public static let currentSelectableRelicIDs = currentRelicIDs
    public static let currentSelectableSealIDs = currentSealIDs
    public static let currentSelectableFrameIDs = currentFrameIDs
    public static let currentSelectableCrestIDs: Set<CrestID> = []

    public static let defaultRelicID = Current.runestoneTablet
    public static let defaultSealID = Current.valknutSeal
    public static let defaultFrameID: FrameID? = nil
    public static let defaultCrestID: CrestID? = nil

    public static func canonicalRelicID(_ identifier: RelicID) throws -> RelicID {
        try canonicalize(
            identifier,
            kind: .relic,
            aliases: relicAliases,
            currentIDs: currentRelicIDs
        )
    }

    public static func canonicalSealID(_ identifier: SealID) throws -> SealID {
        try canonicalize(
            identifier,
            kind: .seal,
            aliases: sealAliases,
            currentIDs: currentSealIDs
        )
    }

    public static func canonicalFrameID(_ identifier: FrameID) throws -> FrameID {
        try canonicalize(
            identifier,
            kind: .frame,
            aliases: frameAliases,
            currentIDs: currentFrameIDs
        )
    }

    public static func canonicalCrestID(_ identifier: CrestID) throws -> CrestID {
        try canonicalize(
            identifier,
            kind: .crest,
            aliases: crestAliases,
            currentIDs: currentCrestIDs
        )
    }

    /// Canonicalizes a caller-typed artifact. A same-kind, non-Norse identifier
    /// passes through unchanged. An unknown identifier in the Norse namespace
    /// fails closed so callers can apply their surface-specific fallback policy.
    public static func canonicalArtifactID(
        _ identifier: ArtifactID,
        as kind: NorseArtifactCompatibilityKind
    ) throws -> ArtifactID {
        let rawValue: String = switch kind {
        case .relic:
            try canonicalRelicID(RelicID(rawValue: identifier.rawValue)!).rawValue
        case .seal:
            try canonicalSealID(SealID(rawValue: identifier.rawValue)!).rawValue
        case .frame:
            try canonicalFrameID(FrameID(rawValue: identifier.rawValue)!).rawValue
        case .crest:
            try canonicalCrestID(CrestID(rawValue: identifier.rawValue)!).rawValue
        }
        return ArtifactID(rawValue: rawValue)!
    }

    public static func currentArtifactIDs(
        for kind: NorseArtifactCompatibilityKind
    ) -> Set<ArtifactID> {
        switch kind {
        case .relic: Set(currentRelicIDs.map(artifactID))
        case .seal: Set(currentSealIDs.map(artifactID))
        case .frame: Set(currentFrameIDs.map(artifactID))
        case .crest: Set(currentCrestIDs.map(artifactID))
        }
    }

    public static func currentSelectableArtifactIDs(
        for kind: NorseArtifactCompatibilityKind
    ) -> Set<ArtifactID> {
        switch kind {
        case .relic: Set(currentSelectableRelicIDs.map(artifactID))
        case .seal: Set(currentSelectableSealIDs.map(artifactID))
        case .frame: Set(currentSelectableFrameIDs.map(artifactID))
        case .crest: Set(currentSelectableCrestIDs.map(artifactID))
        }
    }

    public static func defaultArtifactID(
        for kind: NorseArtifactCompatibilityKind
    ) -> ArtifactID? {
        switch kind {
        case .relic: artifactID(defaultRelicID)
        case .seal: artifactID(defaultSealID)
        case .frame: defaultFrameID.map(artifactID)
        case .crest: defaultCrestID.map(artifactID)
        }
    }

    private static func canonicalize<Domain>(
        _ identifier: RoadmapStringIdentifier<Domain>,
        kind: NorseArtifactCompatibilityKind,
        aliases: [
            RoadmapStringIdentifier<Domain>: RoadmapStringIdentifier<Domain>
        ],
        currentIDs: Set<RoadmapStringIdentifier<Domain>>
    ) throws -> RoadmapStringIdentifier<Domain> {
        guard identifier.rawValue.hasPrefix("\(kind.rawValue).") else {
            throw NorseArtifactCompatibilityError.kindMismatch(
                expected: kind,
                identifier: identifier.rawValue
            )
        }
        if let canonical = aliases[identifier] {
            return canonical
        }
        if currentIDs.contains(identifier) {
            return identifier
        }
        guard !identifier.rawValue.hasPrefix("\(kind.rawValue).norse.") else {
            throw NorseArtifactCompatibilityError.unsupportedNorseIdentifier(
                kind: kind,
                identifier: identifier.rawValue
            )
        }
        return identifier
    }

    private static func artifactID<Domain>(
        _ identifier: RoadmapStringIdentifier<Domain>
    ) -> ArtifactID {
        ArtifactID(rawValue: identifier.rawValue)!
    }
}

public enum NorseProgressionRewardSourceIdentifier: Equatable, Hashable, Sendable {
    case grantGroup(GrantGroupID)
    case achievement(AchievementID)
    case rule(RuleID)
}

public enum NorseProgressionRewardSource: String, Codable, CaseIterable, Hashable, Sendable {
    case baseIncluded = "grant-group.base.norse.included"
    case firstInscription = "achievement.first-inscription"
    case firstDispatch = "achievement.first-dispatch"
    case correspondent = "achievement.correspondent"
    case courierI = "achievement.courier-1"
    case courierII = "achievement.courier-2"
    case archivistI = "achievement.archivist-1"
    case archivistII = "achievement.archivist-2"
    case norseEcho = "rule.codex.norse.echo-five"
    case norseMastery = "rule.codex.norse.mastery"

    public var identifier: NorseProgressionRewardSourceIdentifier {
        switch self {
        case .baseIncluded:
            .grantGroup(GrantGroupID(rawValue: rawValue)!)
        case .firstInscription, .firstDispatch, .correspondent, .courierI,
             .courierII, .archivistI, .archivistII:
            .achievement(AchievementID(rawValue: rawValue)!)
        case .norseEcho, .norseMastery:
            .rule(RuleID(rawValue: rawValue)!)
        }
    }
}

public enum NorseProgressionRewardRouteRole: String, Codable, Sendable {
    case primary
    case idempotentSecondRoute = "idempotent-second-route"
}

public struct NorseProgressionRewardRoute: Equatable, Sendable {
    public let source: NorseProgressionRewardSource
    public let rewards: [ProgressionContentReference]
    public let role: NorseProgressionRewardRouteRole

    fileprivate init(
        source: NorseProgressionRewardSource,
        rewards: [ProgressionContentReference],
        role: NorseProgressionRewardRouteRole = .primary
    ) {
        self.source = source
        self.rewards = rewards
        self.role = role
    }
}

/// Source-based reward authority is intentionally separate from visual ID
/// aliases: a legacy selected artifact and its completed grant source can map
/// to different current content while both remain truthful. Stable entitlement
/// grants are not replacement rewards and remain outside this mapping.
public enum NorseProgressionRewardAuthority {
    public static let baseScriptID = ScriptID(rawValue: "script.base-runes")!
    public static let archivistTitleID = TitleID(rawValue: "title.archivist")!
    public static let masterOfRunesTitleID = TitleID(
        rawValue: "title.norse.master-of-runes"
    )!

    public static let routes: [NorseProgressionRewardRoute] = [
        NorseProgressionRewardRoute(
            source: .baseIncluded,
            rewards: [
                artifact(NorseArtifactCompatibilityAuthority.Current.runestoneTablet),
                artifact(NorseArtifactCompatibilityAuthority.Current.valknutSeal),
                artifact(NorseArtifactCompatibilityAuthority.Current.ravenshieldSeal),
                artifact(baseScriptID),
                .codex(RuneScribeCodexIDs.norse),
            ]
        ),
        NorseProgressionRewardRoute(
            source: .firstInscription,
            rewards: [
                artifact(NorseArtifactCompatibilityAuthority.Current.mjolnirSeal),
            ]
        ),
        NorseProgressionRewardRoute(
            source: .firstDispatch,
            rewards: [
                artifact(NorseArtifactCompatibilityAuthority.Current.dragonwoodPlaque),
            ]
        ),
        NorseProgressionRewardRoute(
            source: .correspondent,
            rewards: [
                artifact(NorseArtifactCompatibilityAuthority.Current.wolkinSeal),
            ]
        ),
        NorseProgressionRewardRoute(
            source: .courierI,
            rewards: [
                artifact(NorseArtifactCompatibilityAuthority.Current.yggdrasilSeal),
            ]
        ),
        NorseProgressionRewardRoute(
            source: .courierII,
            rewards: [
                artifact(NorseArtifactCompatibilityAuthority.Current.stormforgedStele),
            ]
        ),
        NorseProgressionRewardRoute(
            source: .archivistI,
            rewards: [
                artifact(NorseArtifactCompatibilityAuthority.Current.carvedKnotworkFrame),
            ]
        ),
        NorseProgressionRewardRoute(
            source: .archivistII,
            rewards: [
                .title(archivistTitleID),
                artifact(NorseArtifactCompatibilityAuthority.Current.berserkSeal),
            ]
        ),
        NorseProgressionRewardRoute(
            source: .norseEcho,
            rewards: [
                artifact(NorseArtifactCompatibilityAuthority.Current.yggdrasilSeal),
            ],
            role: .idempotentSecondRoute
        ),
        NorseProgressionRewardRoute(
            source: .norseMastery,
            rewards: [
                .crest(NorseArtifactCompatibilityAuthority.Current.ravenMasteryCrest),
                .title(masterOfRunesTitleID),
            ]
        ),
    ]

    public static func route(
        for source: NorseProgressionRewardSource
    ) -> NorseProgressionRewardRoute {
        routesBySource[source]!
    }

    private static let routesBySource = Dictionary(
        uniqueKeysWithValues: routes.map { ($0.source, $0) }
    )

    private static func artifact<Domain>(
        _ identifier: RoadmapStringIdentifier<Domain>
    ) -> ProgressionContentReference {
        .artifact(ArtifactID(rawValue: identifier.rawValue)!)
    }
}
