> Historical M1 discovery snapshot, captured 2026-10-21 against source d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54. Permissions and unexecuted-check statements below describe that completed run. The subsequent owner instruction authorizes documentation publication, Xcode documentation references and unsigned build verification only. Application implementation, Store changes and release remain outside this publication. See [publication scope and portability](README.md).

# RS-PIVOT-M1 — environment and authority

Date: 2026-10-21 (America/Chicago). Read-only discovery. This report is evidence for review, not a Project Record or implementation approval.

## Measured checkout and host

| Observation | Result | Evidence / limit |
|---|---|---|
| Physical product root | `<product-checkout>` | pwd -P and git rev-parse --show-toplevel agree |
| Canonical origin identity | flynn33/rune-scribe | Probe validates SSH/HTTPS identity without persisting raw credential-bearing URLs |
| Actual HEAD / branch | d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54 / main | Locally queried, not inferred from package |
| Local tracking comparison | HEAD...refs/remotes/origin/main = 0 / 0 | Existing local tracking ref; no fetch |
| Live remote comparison | Connected GitHub main resolves to the same full commit | authority-retrieval.json; no remote write |
| Initial staged, unstaged, untracked state | Empty porcelain; empty diff --stat | Optional locks, fsmonitor and untracked cache disabled; no stash/reset/checkout |
| Content baseline | 1,784 tracked path records with SHA-256 and modes | source-baseline-start.json; taken after initial metadata/navigation and before report drafting |
| Host | Darwin arm64, macOS 27.0.1 (26A434) | sw_vers, platform metadata |
| Xcode | 27.0 (27A266a), /Applications/Xcode.app/Contents/Developer | xcode-select -p; xcodebuild -version |
| SDKs relevant to product | macOS 27.0, iOS 27.0 and iOS Simulator 27.0 | xcodebuild -showsdks; tool presence is not build success |
| Tools present | Git 2.54.0 (Apple Git-157), Python, Swift, xcrun, xcodebuild, xcodegen, gh | Presence only; no tooling installed |
| Python actually used | 3.9.6 | Package recommends 3.10+; its inspected one-shot helpers nevertheless completed successfully here. No compatibility modification or product Python execution |
| Output write/read | Succeeded under physical external package/output/m1-20261021-discovery | Probe creates exclusively; reports read back |
| Package integrity | PASS, 20 manifest payload files plus manifest | verify_package.py; report outputs excluded by design. This is package integrity only |

All eight available destinations were Shutdown at capture:

| Runtime | Device names |
|---|---|
| iOS 26.5 | Rune Scribe App Store iPhone 17 Pro; Rune Scribe App Store iPhone 17 Pro Max; Rune Scribe Beta Fixes iPhone; Rune Scribe App Store iPad Pro 13; Rune Scribe Beta Fixes iPad |
| iOS 27.0 | Rune Scribe App Store iPhone 17 Pro iOS 27; Rune Scribe App Store iPhone-Pro-Max iOS 27; Rune Scribe App Store iPad iOS 27 |

These are available metadata destinations, not proven working launches, StoreKit environments, screenshots or accepted devices. The supported iOS 17/macOS 15 minimums in Package.swift and project.yml were not executed on corresponding minimum OS hosts. No additional physical hardware is an M1 or agent implementation prerequisite.

## Output boundary and effective permissions

The package, external root and product root physically resolve to the requested paths. The inspected OutputBoundary.validate rejects output inside the product, symlink escapes into a product, any ancestor containing .git, an existing run directory and output outside package/output. The successful probe wrote new paired environment.json/environment.md files; no permissions changed.

| Operation | Task authority | Observed access / action |
|---|---|---|
| Read product, source-defined configuration/tests/history | Granted | Succeeded; source inspected without execution |
| Read relevant external instructions and records | Granted | Succeeded in known workspace; no whole-home search |
| Query host/tool/simulator metadata | Granted | Succeeded; may touch ordinary tool caches/start system service |
| New M1 report/evidence files | Granted only inside package output | Succeeded at named external run root |
| Product source/tests/dependencies/native project/schema/capabilities | No writes | No edits authorized or made |
| Read actual app-data, receipts, keychain or secrets | Not granted | Not attempted |
| App code/tests/product scripts/build/launch | Not granted | Not run |
| Git mutations, worktree/branch creation | Not granted | Not run |
| Commit/push/PR/merge/sign/upload/store settings/release | Not granted | Not attempted; tool availability grants none of these |
| Start implementation after M1 | Not granted | Separate future assignment required |

The session filesystem tool has broad technical access and approval policy never. Those tool settings do not widen the task's empty product write allowlist. No need to probe product writability, Keychain, developer identities or store credentials to confirm this distinction.

## Authority actually retrieved

The owner's current instruction and APPROVAL-PIVOT-001 settle: free Norse and all retained tools; one one-time $1.99 complete first Elven Series covering Moonleaf, Sunspire, Wildwood and Gloamthorn with all included content unlocked; full first-series inclusion for original paid-app owners; remove achievements/Game Center; preserve separate modules, data and free receiving/decoding.

The package record is planning draft 0.4 with SHA-256 49c823e7ab12593f05614dfc2ddd5104c0483c7bcf87029e348d57fc91e66dff. Its header explicitly says prepared but not saved to authoritative project location. It names draft 0.3 as predecessor, not as a newly verified accepted implementation contract.

Bounded retrieval covered file metadata and relevant Markdown/JSON in `<external-instructions-workspace>` (including historical instruction folders), repository docs/.github/README and the package. No on-disk AGENTS.md was found at checked user/GitHub/project ancestors or inside checkout; the user-supplied accuracy agreements apply. Historic instruction archives were searched for record metadata; no superseded implementation package was run.

A connected Pages query for Rune Scribe Project Record returned only unrelated Page metadata. Those contents were not opened. Two project chats titled “Create Codex Package” were retrieved read-only. The latest contains the owner's approval and package request and explicitly records the unresolved historical binding, missing reviewed contracts and unsaved authoritative record. The older chat holds the superseded individual-theme proposal. These observations corroborate the scope and its history; neither creates a saving route or authority. See authority-retrieval.json for exact chat/turn IDs and bounded search limits.

Raven Forge Development 0.7.4 at d3d40076e1bc21201e23628058b3907dc4443e51 remains an inspected method reference. Its execution block and diagnostics policy were fetched at that immutable commit. The intake's full 19-document coverage is inherited, not repeated or upgraded. No prior adopted product pin or current authoritative record location was located. No reviewed pivot System Realization Contract/profile set was located. Non-matches in bounded searches are not proof none exists.

Repository controlling policy remains current source authority subordinate to active owner instructions. Its completed-Progression-gate clause conflicts with the approved target outcome and needs a deliberate later amendment; all runtime authorization/lifecycle, one-UI-module and permanent external-Forsetti exclusion boundaries remain. Exact authority hashes and readiness dispositions are in 04-CONTRACTS-AND-VERIFICATION-PLAN.md.

## Verification limits and closeout route

Only package integrity, metadata queries, source/history reads, static inventory processing and new report read-back run in M1. No application check or implementation conformance result is implied. No user app store, live product, sale price history, signed receipt, entitlement recovery, signing authority, provisioned service or release was inspected.

Closeout uses a fresh environment-end directory and source-boundary-closeout.json to compare HEAD, branch, status, tracked bytes/modes and report saves. A clean status alone cannot prove every ignored file, filesystem metadata value, background process or tool cache was unchanged. No pre-existing/concurrent edits will be reverted to manufacture a clean result. No authoritative Project Record was overwritten.
