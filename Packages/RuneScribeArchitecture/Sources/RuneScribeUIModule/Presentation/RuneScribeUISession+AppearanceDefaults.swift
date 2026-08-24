import Foundation
import RuneScribeContracts

extension RuneScribeUISession {
    var appearanceEffectsPreference: RuntimeEffectsPreference {
        runtimeSettingsSnapshot?.effectsPreference ?? .full
    }

    func effectiveEffectsPreference(
        systemReduceMotion: Bool
    ) -> RuntimeEffectsPreference {
        appearanceEffectsPreference.effective(systemReduceMotion: systemReduceMotion)
    }

    var encounteredThemeArtifactIDs: Set<ArtifactID> {
        Set((progressionSnapshot?.ownership ?? []).compactMap { item in
            guard item.state == .encountered,
                  case .artifact(let artifactID) = item.reference
            else { return nil }
            return artifactID
        })
    }

    func makeShareBuilderCatalog(
        descriptor: ThemeDescriptor? = nil,
        provider: ThemeProviderSummaryDTO? = nil
    ) throws -> ShareBuilderCatalog {
        guard let resolvedDescriptor = descriptor ?? themeSnapshot?.effectiveTheme else {
            throw ShareArtifactRenderError.unavailableSelection
        }
        guard let resolvedProvider = provider ?? themeSnapshot?.providers.first(where: {
            $0.codexID == resolvedDescriptor.codex.id
        }) else { throw ShareArtifactRenderError.unavailableSelection }
        return try ShareBuilderCatalog(
            descriptor: resolvedDescriptor,
            provider: resolvedProvider,
            settings: runtimeSettingsSnapshot,
            ownedArtifactIDs: ownedThemeArtifactIDs,
            encounteredArtifactIDs: encounteredThemeArtifactIDs
        )
    }

    func saveShareBuilderDefaults(_ catalog: ShareBuilderCatalog) async throws {
        _ = try catalog.validatedSelection()
        guard let runtimeSettingsClientHandle else {
            throw ShareArtifactRenderError.unavailableSelection
        }
        let codexID = catalog.draft.codexID
        let snapshot = runtimeSettingsSnapshot
        let relics = try (snapshot?.artifactSelections(for: .relic)
            ?? RuneScribeRuntimeSettings.defaultArtifactSelections(for: .relic))
            .setting(catalog.draft.relicID, for: codexID)
        let seals = try (snapshot?.artifactSelections(for: .seal)
            ?? RuneScribeRuntimeSettings.defaultArtifactSelections(for: .seal))
            .setting(catalog.draft.sealID, for: codexID)
        let frames = try (snapshot?.artifactSelections(for: .frame)
            ?? RuneScribeRuntimeSettings.defaultArtifactSelections(for: .frame))
            .setting(catalog.draft.frameID, for: codexID)
        let expectedRevisions = Dictionary(uniqueKeysWithValues: [
            RuneScribeRuntimeSettings.selectedRelicByCodex,
            RuneScribeRuntimeSettings.selectedSealByCodex,
            RuneScribeRuntimeSettings.selectedFrameByCodex,
            RuneScribeRuntimeSettings.effectsPreference,
        ].map { settingID in
            (
                settingID,
                snapshot?.settings.first(where: { $0.settingID == settingID })?.revision ?? 0
            )
        })
        do {
            _ = try await runtimeSettingsClientHandle.setAppearanceDefaults(
                relics: relics,
                seals: seals,
                frames: frames,
                effects: catalog.draft.effects,
                expectedRevisions: expectedRevisions
            )
            settingsRailState = .available
            themeSelectionError = nil
        } catch {
            settingsRailState = .degraded
            themeSelectionError = "Those appearance defaults could not be saved."
            throw error
        }
    }

    func setEffectsPreference(_ preference: RuntimeEffectsPreference) async {
        guard let runtimeSettingsClientHandle else {
            settingsRailState = .unavailable
            return
        }
        let settingID = RuneScribeRuntimeSettings.effectsPreference
        let expectedRevision = runtimeSettingsSnapshot?.settings.first(where: {
            $0.settingID == settingID
        })?.revision
        do {
            _ = try await runtimeSettingsClientHandle.set(
                SetRuntimeSettingCommand(
                    settingID: settingID,
                    value: preference.settingValue,
                    expectedRevision: expectedRevision
                )
            )
            settingsRailState = .available
            themeSelectionError = nil
        } catch {
            settingsRailState = .degraded
            themeSelectionError = "The effects preference could not be saved."
        }
    }
}
