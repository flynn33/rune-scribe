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
