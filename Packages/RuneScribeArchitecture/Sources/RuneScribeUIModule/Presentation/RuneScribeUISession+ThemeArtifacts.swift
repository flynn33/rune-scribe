import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ThemeArtifactSelectionKind: Sendable {
    case relic
    case seal
    case frame

    var settingID: RuntimeSettingID {
        contractKind.settingID
    }

    var contractKind: RuntimeArtifactSelectionKind {
        switch self {
        case .relic: .relic
        case .seal: .seal
        case .frame: .frame
        }
    }
}

struct ThemeArtifactPickerItem: Identifiable, Equatable, Sendable {
    let id: ArtifactID
    let name: String
    let description: String
    let rarity: ThemeRarityToken
    let isOwned: Bool
    let isSelectable: Bool
    let isSelected: Bool
}

extension RuneScribeUISession {
    var themeRelicItems: [ThemeArtifactPickerItem] {
        guard let theme = themeSnapshot?.effectiveTheme else { return [] }
        let owned = ownedThemeArtifactIDs
        return theme.codex.relics.compactMap { relic in
            guard relic.metadata.availability != .reservedInactive else { return nil }
            return ThemeArtifactPickerItem(
                id: relic.metadata.id,
                name: relic.metadata.displayName.fallbackValue,
                description: relic.metadata.description.fallbackValue,
                rarity: relic.metadata.rarity,
                isOwned: relic.metadata.availability == .included || owned.contains(relic.metadata.id),
                isSelectable: relic.metadata.availability == .included || owned.contains(relic.metadata.id),
                isSelected: relic.metadata.id == selectedThemeRelicID
            )
        }
    }

    var themeSealItems: [ThemeArtifactPickerItem] {
        guard let theme = themeSnapshot?.effectiveTheme else { return [] }
        let owned = ownedThemeArtifactIDs
        return theme.codex.seals.map { seal in
            ThemeArtifactPickerItem(
                id: seal.metadata.id,
                name: seal.metadata.displayName.fallbackValue,
                description: seal.metadata.description.fallbackValue,
                rarity: seal.metadata.rarity,
                isOwned: seal.metadata.availability == .included || owned.contains(seal.metadata.id),
                isSelectable: seal.metadata.availability == .included || owned.contains(seal.metadata.id),
                isSelected: seal.metadata.id == selectedThemeSealID
            )
        }
    }

    var themeFrameItems: [ThemeArtifactPickerItem] {
        guard let theme = themeSnapshot?.effectiveTheme else { return [] }
        let owned = ownedThemeArtifactIDs
        return theme.codex.frames.compactMap { frame in
            guard frame.metadata.availability != .reservedInactive,
                  frame.allowsStaticShare
            else { return nil }
            return ThemeArtifactPickerItem(
                id: frame.metadata.id,
                name: frame.metadata.displayName.fallbackValue,
                description: frame.metadata.description.fallbackValue,
                rarity: frame.metadata.rarity,
                isOwned: frame.metadata.availability == .included
                    || owned.contains(frame.metadata.id),
                isSelectable: frame.metadata.availability == .included
                    || owned.contains(frame.metadata.id),
                isSelected: frame.metadata.id == selectedThemeFrameID
            )
        }
    }

    func selectThemeArtifact(_ artifactID: ArtifactID, kind: ThemeArtifactSelectionKind) async {
        let items: [ThemeArtifactPickerItem] = switch kind {
        case .relic: themeRelicItems
        case .seal: themeSealItems
        case .frame: themeFrameItems
        }
        guard items.contains(where: { $0.id == artifactID && $0.isSelectable }),
              let codexID = themeSnapshot?.effectiveCodexID,
              let runtimeSettingsClientHandle
        else {
            themeSelectionError = "That appearance is not available."
            return
        }
        let settingID = kind.settingID
        let current = runtimeSettingsSnapshot?.artifactSelections(for: kind.contractKind)
            ?? RuneScribeRuntimeSettings.defaultArtifactSelections(for: kind.contractKind)
        guard let selections = try? current.setting(artifactID, for: codexID) else {
            themeSelectionError = "That appearance could not be saved."
            return
        }
        let existingRevision = runtimeSettingsSnapshot?.settings.first(where: {
            $0.settingID == settingID
        })?.revision
        switch kind {
        case .relic: selectedThemeRelicID = artifactID
        case .seal: selectedThemeSealID = artifactID
        case .frame: selectedThemeFrameID = artifactID
        }
        do {
            _ = try await runtimeSettingsClientHandle.setArtifactSelections(
                selections,
                expectedRevision: existingRevision
            )
            themeSelectionError = nil
        } catch {
            reconcileThemeArtifactSelections()
            themeSelectionError = "That appearance could not be saved."
        }
    }

    func clearThemeFrame() async {
        guard let codexID = themeSnapshot?.effectiveCodexID,
              let runtimeSettingsClientHandle
        else {
            themeSelectionError = "That appearance is not available."
            return
        }
        let current = runtimeSettingsSnapshot?.artifactSelections(for: .frame)
            ?? RuneScribeRuntimeSettings.defaultArtifactSelections(for: .frame)
        guard let frameNone = ArtifactID(rawValue: "frame.none"),
              let selections = try? current.setting(frameNone, for: codexID)
        else {
            themeSelectionError = "That appearance could not be saved."
            return
        }
        let existingRevision = runtimeSettingsSnapshot?.settings.first(where: {
            $0.settingID == RuneScribeRuntimeSettings.selectedFrameByCodex
        })?.revision
        selectedThemeFrameID = nil
        do {
            _ = try await runtimeSettingsClientHandle.setArtifactSelections(
                selections,
                expectedRevision: existingRevision
            )
            themeSelectionError = nil
        } catch {
            reconcileThemeArtifactSelections()
            themeSelectionError = "That appearance could not be saved."
        }
    }

    var ownedThemeArtifactIDs: Set<ArtifactID> {
        Set((progressionSnapshot?.ownership ?? []).compactMap { item in
            guard item.state == .owned, case .artifact(let id) = item.reference else { return nil }
            return id
        })
    }
}
