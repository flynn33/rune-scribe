import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ThemeArtifactSelectionKind: Sendable {
    case relic
    case seal

    var settingID: RuntimeSettingID {
        switch self {
        case .relic: RuneScribeRuntimeSettings.selectedRelicByCodex
        case .seal: RuneScribeRuntimeSettings.selectedSealByCodex
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

    func selectThemeArtifact(_ artifactID: ArtifactID, kind: ThemeArtifactSelectionKind) async {
        let items = kind == .relic ? themeRelicItems : themeSealItems
        guard items.contains(where: { $0.id == artifactID && $0.isSelectable }),
              let codexID = themeSnapshot?.effectiveCodexID,
              let runtimeSettingsClientHandle
        else {
            themeSelectionError = "That appearance is not available."
            return
        }
        let settingID = kind.settingID
        var selections = Self.themeSelectionMap(
            runtimeSettingsSnapshot?[settingID]?.textValue?.rawValue
        )
        selections[codexID.rawValue] = artifactID.rawValue
        let encoded = selections.keys.sorted().map { key in
            "\(key)=\(selections[key]!)"
        }.joined(separator: ";")
        guard let text = RuntimeSettingText(rawValue: encoded) else {
            themeSelectionError = "That appearance could not be saved."
            return
        }
        let existingRevision = runtimeSettingsSnapshot?.settings.first(where: {
            $0.settingID == settingID
        })?.revision
        if kind == .relic { selectedThemeRelicID = artifactID }
        else { selectedThemeSealID = artifactID }
        do {
            _ = try await runtimeSettingsClientHandle.set(
                SetRuntimeSettingCommand(
                    settingID: settingID,
                    value: .text(text),
                    expectedRevision: existingRevision
                )
            )
            themeSelectionError = nil
        } catch {
            reconcileThemeArtifactSelections()
            themeSelectionError = "That appearance could not be saved."
        }
    }

    private var ownedThemeArtifactIDs: Set<ArtifactID> {
        Set((progressionSnapshot?.ownership ?? []).compactMap { item in
            guard item.state == .owned, case .artifact(let id) = item.reference else { return nil }
            return id
        })
    }
}
