> Historical M1 discovery snapshot, captured 2026-10-21 against source d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54. Permissions and unexecuted-check statements below describe that completed run. The subsequent owner instruction authorizes documentation publication, Xcode documentation references and unsigned build verification only. Application implementation, Store changes and release remain outside this publication. See [publication scope and portability](README.md).

# M1 content reconciliation evidence

Inspected checkout: `d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54`. These are static source/file observations, with hashes and exact JSON pointers in `02-CONTENT-INVENTORY.json`. No application code, product script or test was executed.

| Content | Norse | Each Elven Codex | Total |
|---|---:|---:|---:|
| Scripts | 1 | 1 | 5 |
| Relics | 3 | 3 | 15 |
| Seals | 6 | 6 | 30 |
| Frames | 1 | 1 | 5 |
| Crests | 1 | 1 | 5 |
| Background | 1 | 1 | 5 |
| Vault presentation | 1 | 1 | 5 |

The report accounts for all 84 historical Progression content IDs, adds descriptor-only and resource-only items, and contains 156 item rows. Separate resource inventory records 315 physical production entries and four embedded Elven localization literals. Norse has 70 production resources; Moonleaf has 65; Sunspire, Wildwood and Gloamthorn have 60 each. Every physical entry's byte length and SHA-256 matches its manifest and frozen Swift pin; four integrity-manifest hashes and the Norse integrity-manifest hash also match their pins. Twelve additional support/metadata files are listed outside the descriptor resource inventory. No font or artwork bytes were copied into reports.

Observed scope details:

- All providers remain separate service targets in [Package.swift](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Package.swift#L123), with native app dependency declarations in [project.yml](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/project.yml#L59) and runtime registration in [RuneScribeRuntimeComposition.swift](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/RuneScrib/AppHost/RuneScribeRuntimeComposition.swift#L197). These are source declarations, not a build result.
- Elven mastery frames/crests and encountered echo seals are existing descriptor content, not excluded extras. APPROVAL-PIVOT-001 includes them with series ownership, as well as all Norse content without an achievement gate.
- Five shared visual IDs (`frame.progression.collector`, `frame.progression.mastery`, `relic.progression.collector`, `seal.progression.echo`, `seal.progression.relic-bearer`) explicitly defer artwork in the [Progression catalog](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/Resources/Rune-Scribe-Progression-Catalog-v1.0.json). They have no visual descriptor/resources among the five inspected providers. Preserve existing grant records inertly; do not promise new artwork by treating these as shipped provider visuals.
- Nine catalog titles are shipped text/state even though they have no provider artwork. [VaultProgressView](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VaultProgressView.swift#L772) displays owned titles and selected-title choices. Preserve meaningful selection/state and review their future presentation when removing the progression UI.
- Four Norse reveal-effect and four sound resources are explicitly inventoried. Active achievement/reward scheduling retires; later reuse of these resources needs reviewed presentation rules. No separate Elven effect/audio resource was declared in its current descriptor/resource catalogs. The catalog's old global `deferred` list is stale for production theme artwork, given current resource files and descriptors; its labels alone do not establish absence.
- Sunspire, Wildwood and Gloamthorn each bundle five resources whose optional direct seed-descriptor fields are absent: wide background, crest thumbnail, standard/high-contrast script specimens, unavailable vault state. The inventory preserves those resources and records these declaration differences. No runtime rendering consequence was tested or inferred.
- [NorseArtifactCompatibilityAuthority](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/NorseArtifactCompatibilityContracts.swift#L87) defines 14 alias rows: six relic, six seal, one identity frame and one crest. Preserve these compatibility readers independently of reward evaluation. Its current selectable crest set is empty even though the Raven Mastery Crest is bundled; future contracts must describe its intended presentation without silently excluding it from existing content.
- [FontCatalog](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Fonts/FontCatalog.swift#L42) owns custom-font validation, content-addressed persistence and rollback. Preserve this free retained functionality; custom user fonts are not a finite shipped-content catalog and were not read.

Named test sections were read, including provider identity/resource integrity, deferred corruption isolation, source-layer import guards, Norse resource identity/binding assertions, and alias-vs-reward separation. Their names and hashes are in the inventory. The old progression-gate assertions are affected contracts to replace deliberately; resource integrity, canonical symbol mapping, legacy aliases and safe failure guarantees remain necessary.

Focused history metadata was inspected for the descriptors and catalog, including `d965f58` (2026-09-15 visual/script refresh), `bd28940` and `a17ebf2` (v4.3 qualification/remediation), `8d65050` (Norse v2 resources), and `8010eb5` (roadmap rails). This establishes relevant change history pointers, not historical independent approval.

`content-inventory-static.py` records initial literal extraction and file/pin checks. The final JSON additionally includes reviewed test/history metadata, explicit optional-field differences and exact label/membership annotations added after extraction. Its write mode refuses to replace an existing report. Application rendering, build membership/copy output, entitlement changes, StoreKit purchases/restoration and live availability remain unverified because M1 prohibits those executions.
