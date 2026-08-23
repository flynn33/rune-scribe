# Norse Visual Presentation Remediation Diagnosis

## Baseline

The remediation began from fetched `origin/main` at `dde22989d2c5180485c6737670afb6c3f5556eb0` in the isolated `fix/norse-visual-presentation` worktree. The original dirty worktree was not used for implementation.

A deterministic fresh-install iPhone 17 Pro Simulator test established that the effective presentation was the valid required Base provider:

- Theme: `theme.norse.base`
- Codex: `codex.norse`
- Emergency presentation: false
- Relic: `relic.norse.runestone.weathered` (Weathered Rune Stone)
- Seal: `seal.norse.knotwork` (Knotwork Mark)
- Frame: none
- Norse resource validation: pass

The same test captured the workspace, Settings Appearance, and Vault without manual interaction and proved the corresponding production visual identifiers were absent.

## Root cause

The Norse provider, descriptor, metadata, progression bindings, and accepted artwork are present and hash-valid. The defect is downstream of provider activation:

1. `ThemePresentationResourcePlan` plans the theme script, font, background, headings, renderer parameters, and unlock cues, but not Codex cards or artifact imagery.
2. `RuneScribeUISession` resolves and publishes only those semantic resources. It exposes artifact identifiers and text metadata, but no runtime-owned image references or atomically revisioned visual presentation.
3. The workspace artifact controls are text menus, and the settled Encode surface is a semantic rounded rectangle with inscription text.
4. Settings uses provider icons and text instead of descriptor-declared Codex cards.
5. Vault maps descriptor metadata into text-only cards.
6. The only complete Relic, Seal, and Frame composition geometry is private to the static share renderer, so interactive presentation cannot reuse it.

This is a generic presentation-layer integration gap. It is not a missing-provider, invalid-resource, entitlement, or activation defect.

## Required remediation boundary

The implementation must keep production UI provider-neutral. Visual resource identities come from the effective `ThemeDescriptor`; bytes cross only the coordinator/runtime boundary; UI holds bounded opaque image references; selected visual state commits atomically by revision; and interactive Encode and static sharing use the same composition plan and geometry.

The accepted Norse artwork must not be changed. Locked and encountered presentation remains truthful, and preview permission must not grant selection or ownership.

## Historical owner-test language

Prior roadmap-completion documents truthfully record an earlier release handoff that included owner and physical-device evaluation. Those documents remain historical evidence and are noncontrolling for this remediation. Physical hardware and operator input are not required for implementation, verification, PR readiness, or a PASS result. Any later owner validation is discretionary before distribution, and no distribution is authorized by this package.

## Baseline evidence

- `Baseline.json`
- `baseline-screenshots/iphone-workspace-before.png`
- `baseline-screenshots/iphone-settings-before.png`
- `baseline-screenshots/iphone-vault-before.png`
