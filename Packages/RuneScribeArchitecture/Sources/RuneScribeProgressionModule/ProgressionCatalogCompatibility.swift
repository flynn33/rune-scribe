import Foundation
import RuneScribeContracts

enum ProgressionCatalogCompatibility {
    typealias Fingerprint = CatalogMigrationRecord.CompatibilityFingerprint

    static func fingerprints(
        for bundle: ValidatedProgressionCatalogBundle
    ) throws -> [Fingerprint] {
        let catalog = bundle.catalog
        var values: [Fingerprint] = []

        for content in catalog.content {
            values.append(fingerprint(
                key: "content:\(content.contentID.rawValue)",
                fields: [
                    content.kind.rawValue,
                    String(content.countsAsArtifact),
                    content.availability.rawValue,
                    content.rarity.rawValue,
                    content.codexID?.rawValue ?? "-",
                ]
            ))
        }
        for statistic in catalog.statistics {
            values.append(fingerprint(
                key: "statistic:\(statistic.statisticID.rawValue)",
                fields: [
                    statistic.storage.rawValue,
                    statistic.bucket?.rawValue ?? "-",
                    statistic.dimension.rawValue,
                    list(statistic.sourceEvents.sorted()),
                    statistic.filter ?? "-",
                ]
            ))
        }
        for achievement in catalog.achievements {
            values.append(fingerprint(
                key: "achievement:\(achievement.achievementID.rawValue)",
                fields: [
                    achievement.path.rawValue,
                    String(achievement.evergreen),
                    achievement.visibility.rawValue,
                    String(achievement.localPointWeight),
                    String(achievement.gameCenter.eligible),
                    achievement.gameCenter.status.rawValue,
                    achievement.gameCenter.permanentIdentifier ?? "-",
                    String(achievement.gameCenter.points),
                    ruleMaterial(achievement.rule),
                    achievement.progress.statisticID.rawValue,
                    String(achievement.progress.target),
                    list((achievement.progress.excludeAchievementIDs ?? []).map(\.rawValue).sorted()),
                    achievement.rewardGrantGroupID.rawValue,
                ]
            ))
        }
        for milestone in catalog.milestones {
            values.append(fingerprint(
                key: "milestone:\(milestone.ruleID.rawValue)",
                fields: [
                    milestone.visibility.rawValue,
                    milestone.category.rawValue,
                    ruleMaterial(milestone.rule),
                    milestone.grantGroupID.rawValue,
                    milestone.revealTier.rawValue,
                    list(milestone.progressComponents.map(progressMaterial).sorted()),
                ]
            ))
        }
        for group in catalog.grantGroups {
            values.append(fingerprint(
                key: "grant-group:\(group.grantGroupID.rawValue)",
                fields: [group.revealTier.rawValue, group.primaryContentID.rawValue]
            ))
            for item in group.items {
                values.append(fingerprint(
                    key: "grant-item:\(group.grantGroupID.rawValue):\(item.contentID.rawValue)",
                    fields: [item.grantKind.rawValue]
                ))
            }
        }
        for node in catalog.journeyGraph.nodes {
            values.append(fingerprint(
                key: "journey-node:\(node.nodeID.rawValue)",
                fields: [
                    node.contentID.rawValue,
                    node.state.rawValue,
                    node.gateRuleID?.rawValue ?? "-",
                    String(node.order),
                ]
            ))
        }
        for edge in catalog.journeyGraph.edges {
            values.append(fingerprint(
                key: "journey-edge:\(edge.from.rawValue):\(edge.to.rawValue)",
                fields: [edge.from.rawValue, edge.to.rawValue]
            ))
        }
        values.append(fingerprint(
            key: "migration-baseline",
            fields: [
                catalog.migration.startingGrantGroupID.rawValue,
                String(catalog.migration.seedSafelyDerivableCipherStatistics),
                String(catalog.migration.evaluateArchivistAchievementsAfterSafeSeed),
                String(catalog.migration.backfillPastShares),
                String(catalog.migration.backfillPastDecodes),
                String(catalog.migration.backfillDistinctRelationshipsFromDeliveredFlags),
                catalog.migration.includedGrantReveal.rawValue,
                catalog.migration.derivedMigrationRewardsReveal.rawValue,
            ]
        ))

        for event in bundle.eventCatalog.events {
            values.append(fingerprint(
                key: "event:\(event.eventType.rawValue)",
                fields: [
                    event.producer,
                    event.emissionPoint,
                    list(event.requiredPayload.map(\.rawValue).sorted()),
                    list((event.optionalPayload ?? []).map(\.rawValue).sorted()),
                    event.requiredValues?.origin?.rawValue ?? "-",
                    event.requiredValues?.keyIncluded.map(String.init) ?? "-",
                    event.requiredValues?.linkedRelationship.map(String.init) ?? "-",
                    list(event.semanticDedupe.map(\.rawValue).sorted()),
                    list(event.updates.map(\.rawValue).sorted()),
                ]
            ))
        }
        for policy in bundle.eventCatalog.shareRoutePolicy {
            values.append(fingerprint(
                key: "share-route:\(policy.routeClass.rawValue):\(policy.terminalResult.rawValue)",
                fields: [
                    policy.requiresAttachmentAcceptedWhenKeyDelivery.map(String.init) ?? "-",
                    String(policy.progressionEligible),
                    String(policy.firstDeliveryEligible),
                ]
            ))
        }
        for reason in bundle.eventCatalog.eligibilityReasonIDs {
            values.append(fingerprint(
                key: "eligibility-reason:\(reason.rawValue)",
                fields: [reason.rawValue]
            ))
        }
        for binding in bundle.futureThemeBindings.bindings {
            values.append(fingerprint(
                key: "theme-binding:\(binding.codexID.rawValue)",
                fields: [
                    binding.moduleID.rawValue,
                    binding.entitlementID.rawValue,
                    binding.gate?.rawValue ?? "-",
                    binding.gateRuleID?.rawValue ?? "-",
                    binding.criticality.rawValue,
                    binding.fallback.map(String.init) ?? "-",
                    binding.fallbackCodexID?.rawValue ?? "-",
                ]
            ))
        }

        let ordered = values.sorted { $0.stableKey < $1.stableKey }
        guard ordered.count <= CatalogMigrationRecord.maximumCompatibilityFingerprints,
              Set(ordered.map(\.stableKey)).count == ordered.count
        else { throw ProgressionDomainError.invalidRecord("catalog-fingerprint-set") }
        for value in ordered { try value.validate() }
        return ordered
    }

    static func validateAddOnlyUpgrade(
        from stored: [Fingerprint],
        to current: [Fingerprint]
    ) throws {
        let indexed = Dictionary(uniqueKeysWithValues: current.map { ($0.stableKey, $0) })
        for prior in stored {
            guard indexed[prior.stableKey] == prior else {
                throw ProgressionDomainError.invalidRecord(
                    "catalog-stable-id-reinterpreted"
                )
            }
        }
    }

    static func validateUpgrade(
        from stored: [Fingerprint],
        to current: [Fingerprint],
        fromVersion: ProgressionCatalogVersion,
        toVersion: ProgressionCatalogVersion
    ) throws {
        if fromVersion.rawValue == 1, toVersion.rawValue >= 2 {
            return try validateNorseV1Upgrade(
                from: stored,
                to: current,
                toVersion: toVersion
            )
        }
        try validateAddOnlyUpgrade(from: stored, to: current)
    }

    private static func validateNorseV1Upgrade(
        from stored: [Fingerprint],
        to current: [Fingerprint],
        toVersion: ProgressionCatalogVersion
    ) throws {
        let minimumCurrentCount = toVersion.rawValue >= 3 ? 318 : 310
        let currentCountIsValid = toVersion.rawValue == 2
            ? current.count == minimumCurrentCount
            : current.count >= minimumCurrentCount
        guard stored.count == 312, currentCountIsValid else {
            throw ProgressionDomainError.invalidRecord("catalog-v1-v2-fingerprint-count")
        }
        let prior = Dictionary(uniqueKeysWithValues: stored.map { ($0.stableKey, $0) })
        let next = Dictionary(uniqueKeysWithValues: current.map { ($0.stableKey, $0) })
        let removed = norseV1RemovedFingerprintDigests
        let added = norseV2AddedFingerprintDigests
        let changedPrior = norseV1ChangedFingerprintDigests
        let changedNext = norseV2ChangedFingerprintDigests
        let elvenMasteryAdded = elvenMasteryV3AddedFingerprintDigests
        let baseKeys = Set(prior.keys).subtracting(removed.keys).union(added.keys)
        let expectedKeys = toVersion.rawValue >= 3
            ? baseKeys.union(elvenMasteryAdded.keys)
            : baseKeys
        let keySetIsValid = toVersion.rawValue <= 3
            ? Set(next.keys) == expectedKeys
            : expectedKeys.isSubset(of: Set(next.keys))

        guard Set(removed.keys).isSubset(of: Set(prior.keys)),
              Set(added.keys).isSubset(of: Set(next.keys)),
              Set(changedPrior.keys) == Set(changedNext.keys),
              Set(changedPrior.keys).isSubset(of: Set(prior.keys)),
              Set(changedNext.keys).isSubset(of: Set(next.keys)),
              keySetIsValid
        else {
            throw ProgressionDomainError.invalidRecord("catalog-v1-v2-key-set")
        }
        for (key, digest) in removed {
            guard prior[key]?.semanticDigest == digest, next[key] == nil else {
                throw ProgressionDomainError.invalidRecord("catalog-v1-v2-removed-key")
            }
        }
        for (key, digest) in added {
            guard next[key]?.semanticDigest == digest, prior[key] == nil else {
                throw ProgressionDomainError.invalidRecord("catalog-v1-v2-added-key")
            }
        }
        for (key, digest) in changedPrior {
            guard prior[key]?.semanticDigest == digest,
                  next[key]?.semanticDigest == changedNext[key]
            else {
                throw ProgressionDomainError.invalidRecord("catalog-v1-v2-changed-key")
            }
        }
        if toVersion.rawValue >= 3 {
            for (key, digest) in elvenMasteryAdded {
                guard next[key]?.semanticDigest == digest, prior[key] == nil else {
                    throw ProgressionDomainError.invalidRecord(
                        "catalog-v3-elven-mastery-added-key"
                    )
                }
            }
        }
        for value in stored where removed[value.stableKey] == nil &&
            changedPrior[value.stableKey] == nil
        {
            guard next[value.stableKey] == value else {
                throw ProgressionDomainError.invalidRecord(
                    "catalog-stable-id-reinterpreted"
                )
            }
        }
    }

    private static let elvenMasteryV3AddedFingerprintDigests: [String: String] = [
        "content:title.gloamthorn.mastery": "7dd81dfcee4195faf62b30906f200b8c",
        "content:title.moonleaf.mastery": "4f06f1c85fe23bdf16175c5ca30c8087",
        "content:title.sunspire.mastery": "648d15c70634ad1165e76f3104dbc65f",
        "content:title.wildwood.mastery": "c4d5e77a6aa2d51895b477c0b388f4f6",
        "grant-item:grant-group.codex.gloamthorn.mastery:title.gloamthorn.mastery":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.moonleaf.mastery:title.moonleaf.mastery":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.sunspire.mastery:title.sunspire.mastery":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.wildwood.mastery:title.wildwood.mastery":
            "9663671f40fe6ca1de092681f7ab10a7",
    ]

    private static let norseV1RemovedFingerprintDigests: [String: String] = [
        "content:crest.norse.forge-master": "860280c20229d45f0cfd1981fb4d3a60",
        "content:relic.norse.ironbound-shield": "e3c9f36a9e915877eb307454d9deef5a",
        "content:relic.norse.raven-medallion": "83a63bbfe3b5faa8ffeefcb072671843",
        "content:relic.norse.runestone.blackstone": "d94c101847e808819dbb4ce78b60da35",
        "content:relic.norse.runestone.frozen": "f1b03a003984da3e2959fd74ce129da7",
        "content:relic.norse.runestone.weathered": "ba46c12898c455728ede1d1b865923e4",
        "content:relic.norse.sealed-parchment": "83a63bbfe3b5faa8ffeefcb072671843",
        "content:seal.norse.echo-rune": "e55962c13036516dcb54eefd002d97c4",
        "content:seal.norse.forge-flame": "ce848d1c7b800253aa10b5927a988885",
        "content:seal.norse.forge-hammer": "d9df98e682d99b6c378f9a39ffbd0882",
        "content:seal.norse.knotwork": "ce848d1c7b800253aa10b5927a988885",
        "content:seal.norse.longship": "d9df98e682d99b6c378f9a39ffbd0882",
        "content:seal.norse.raven": "d9df98e682d99b6c378f9a39ffbd0882",
        "grant-item:grant-group.archivist-2:relic.norse.sealed-parchment":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.base.norse.included:relic.norse.runestone.weathered":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.base.norse.included:seal.norse.forge-flame":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.base.norse.included:seal.norse.knotwork":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.norse.echo-five:seal.norse.echo-rune":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.norse.mastery:crest.norse.forge-master":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.norse.mastery:relic.norse.runestone.blackstone":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.correspondent:seal.norse.longship":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.courier-1:seal.norse.forge-hammer":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.courier-2:relic.norse.ironbound-shield":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.first-dispatch:relic.norse.raven-medallion":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.first-inscription:seal.norse.raven":
            "9663671f40fe6ca1de092681f7ab10a7",
    ]

    private static let norseV2AddedFingerprintDigests: [String: String] = [
        "content:crest.norse.raven-mastery": "860280c20229d45f0cfd1981fb4d3a60",
        "content:relic.norse.dragonwood-plaque": "83a63bbfe3b5faa8ffeefcb072671843",
        "content:relic.norse.runestone-tablet": "18e3f0c8cee0b8b6676d1f02b527aaa8",
        "content:relic.norse.stormforged-stele": "e3c9f36a9e915877eb307454d9deef5a",
        "content:seal.norse.berserk": "d9df98e682d99b6c378f9a39ffbd0882",
        "content:seal.norse.mjolnir": "d9df98e682d99b6c378f9a39ffbd0882",
        "content:seal.norse.ravenshield": "ce848d1c7b800253aa10b5927a988885",
        "content:seal.norse.valknut": "ce848d1c7b800253aa10b5927a988885",
        "content:seal.norse.wolkin": "d9df98e682d99b6c378f9a39ffbd0882",
        "content:seal.norse.yggdrasil": "d9df98e682d99b6c378f9a39ffbd0882",
        "content:title.norse.master-of-runes": "9cc8777cccb85ca01ced2acc71ffe25c",
        "grant-item:grant-group.archivist-2:seal.norse.berserk":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.base.norse.included:relic.norse.runestone-tablet":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.base.norse.included:seal.norse.ravenshield":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.base.norse.included:seal.norse.valknut":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.norse.echo-five:seal.norse.yggdrasil":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.norse.mastery:crest.norse.raven-mastery":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.codex.norse.mastery:title.norse.master-of-runes":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.correspondent:seal.norse.wolkin":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.courier-1:seal.norse.yggdrasil":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.courier-2:relic.norse.stormforged-stele":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.first-dispatch:relic.norse.dragonwood-plaque":
            "9663671f40fe6ca1de092681f7ab10a7",
        "grant-item:grant-group.first-inscription:seal.norse.mjolnir":
            "9663671f40fe6ca1de092681f7ab10a7",
    ]

    private static let norseV1ChangedFingerprintDigests: [String: String] = [
        "grant-group:grant-group.codex.norse.echo-five":
            "c1f0590ec5a0381f35cbb5295752084b",
        "grant-group:grant-group.codex.norse.mastery":
            "029940f6e963e66da813c490b521e8d4",
        "grant-group:grant-group.correspondent": "fea4bacedc87bfff2d28c70f7ad2587e",
        "grant-group:grant-group.courier-1": "7398c4c982b72803e7b1eda861b97fa9",
        "grant-group:grant-group.courier-2": "e77f0affebf4e7e5fc10c257cb0bfd5b",
        "grant-group:grant-group.first-dispatch": "57325dcf3ae8595d0b5dc248a304d541",
        "grant-group:grant-group.first-inscription":
            "856721b6ae5b883579909c1c4d6ae424",
        "milestone:rule.codex.norse.mastery": "0358a43e9e9df21f2f99350f391676f4",
    ]

    private static let norseV2ChangedFingerprintDigests: [String: String] = [
        "grant-group:grant-group.codex.norse.echo-five":
            "d4d6441fa6b8e45c1f5fc8d9d3058ae7",
        "grant-group:grant-group.codex.norse.mastery":
            "4162927c4bd2953363d7cbc7f1ae3744",
        "grant-group:grant-group.correspondent": "837d61606c3822b790563ed6741e2b0d",
        "grant-group:grant-group.courier-1": "d4d6441fa6b8e45c1f5fc8d9d3058ae7",
        "grant-group:grant-group.courier-2": "c4d33bb49ecd16efb483866b2081e53e",
        "grant-group:grant-group.first-dispatch": "49523b45a04ff7437bc2cd16ee7d010b",
        "grant-group:grant-group.first-inscription":
            "50f0006d7c36b1032f880f6d0959605e",
        "milestone:rule.codex.norse.mastery": "95e2b61f0a20e8f524596f5680761032",
    ]

    private static func fingerprint(key: String, fields: [String]) -> Fingerprint {
        let material = list(fields)
        return Fingerprint(
            stableKey: key,
            semanticMaterial: material,
            semanticDigest: ProgressionDeterminism.digest128(material)
        )
    }

    private static func ruleMaterial(_ rule: ProgressionRule) -> String {
        switch rule {
        case let .distinctCountAtLeast(statisticID, threshold, bucketID):
            return list([
                "distinctCountAtLeast", statisticID.rawValue, String(threshold),
                bucketID?.rawValue ?? "-",
            ])
        case let .contentOwned(contentID):
            return list(["contentOwned", contentID.rawValue])
        case let .achievementCompleted(achievementID):
            return list(["achievementCompleted", achievementID.rawValue])
        case let .completedAchievementCountAtLeast(threshold, excluding):
            return list([
                "completedAchievementCountAtLeast", String(threshold),
                list(excluding.map(\.rawValue).sorted()),
            ])
        case let .all(children):
            return list(["all", list(children.map(ruleMaterial).sorted())])
        case let .any(children):
            return list(["any", list(children.map(ruleMaterial).sorted())])
        case let .bucketCountAtLeast(statisticID, minimumBuckets, minimumValuePerBucket):
            return list([
                "bucketCountAtLeast", statisticID.rawValue, String(minimumBuckets),
                String(minimumValuePerBucket),
            ])
        case let .allListedContentUsed(statisticID, bucketID, contentIDs):
            return list([
                "allListedContentUsed", statisticID.rawValue, bucketID.rawValue,
                list(contentIDs.map(\.rawValue).sorted()),
            ])
        }
    }

    private static func progressMaterial(_ value: ProgressionProgressComponent) -> String {
        list([
            value.type.rawValue,
            value.statisticID?.rawValue ?? "-",
            value.target.map(String.init) ?? "-",
            value.bucketID?.rawValue ?? "-",
            list((value.contentIDs ?? []).map(\.rawValue).sorted()),
            value.minimumBuckets.map(String.init) ?? "-",
            value.minimumValuePerBucket.map(String.init) ?? "-",
            value.achievementID?.rawValue ?? "-",
            value.contentID?.rawValue ?? "-",
        ])
    }

    private static func list(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
