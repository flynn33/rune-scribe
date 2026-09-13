# App Store submission — Rune Scribe

Ready-to-paste material for App Store Connect (iOS App Store and Mac App Store).
Keep this file in sync when shipping a new marketing version.

**Last prepared for:** 1.0.41 (build 41) — 2026-09-13

> **Publication boundary:** version 1.0.41 build 41 is the current UI/Xcode remediation
> candidate and is not shipped. Current-source qualification is recorded in
> [`verification/ui-xcode-remediation/QualificationSummary.md`](verification/ui-xcode-remediation/QualificationSummary.md).
> Distribution signing and archive-entitlement inspection require a matching profile
> and identity; archive, export, notarization, upload, and rollout remain external
> owner-operated publication actions.

---

## Version

| Field | Value |
|--------|--------|
| **Version** | `1.0.41` |
| **Build** | `41` |
| **Bundle ID** | `com.runescribe.app` |
| **Display name** | Rune Scribe |
| **Category** | Lifestyle (`public.app-category.lifestyle`) |
| **Platforms** | iOS 17+, macOS 15+ |
| **Team** | `9AQ2C2838M` |

Sources of truth in the repo:

- `project.yml` — `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`
- `RuneScrib.xcodeproj/project.pbxproj` — same values after XcodeGen / commit
- `CHANGELOG.md` — customer-facing history

---

## What’s New (customer-facing)

### Short

```
• Refreshes all five Codices with production theme resources
• Keeps long themed messages contained with complete, truthful paging
• Hardens themed sharing, safe receiving, and accessibility treatments
```

### Full

```
This update advances Rune Scribe's five Codices while preserving local encryption and offline use:

• Explore refreshed Norse, Moonleaf, Sunspire, Wildwood, and Gloamthorn presentation resources.
• Use responsive, scrollable compose and result layouts across iPhone, iPad, and Mac.
• Review every page of a long themed message in one canonical Artifact preview; rotation and Mac resizing preserve the selected page.
• Read complete, selectable received plaintext without false line counts or inactive disclosure controls.
• Keep editor and Settings content out of reach while App Lock is active.
• Choose owned Relics, optional Seals and Frames, and Full, Reduced, or Off effects policy in Share Builder.
• Share ciphers as typed themed .runescribe Artifacts; link, QR, and Export remain explicit fallbacks.
• Receive themed files safely even when their Codex is locked or unavailable.
• Continue using encode, decode, import, and messages under a visible emergency Base appearance when required appearance resources fail.
• Cipher keys, contacts, plaintext, and full messages stay out of iCloud and Game Center.
```

---

## App Review Notes

Paste into App Store Connect → App Review Information → Notes.

```
Rune Scribe is a local-first encrypted messaging utility. It has no proprietary account,
message relay, analytics backend, or advertising service. Optional private iCloud
progression sync and optional Game Center reporting use the signed-in Apple account;
both may be declined and are never required for first run or cipher/message utility.

HOW TO DEMO
1. Launch the app. You may see a short skippable intro (Skip or wait).
2. Optional: Settings → set a 4-digit App Lock PIN, then background and return to verify lock.
3. Cipher Library → New Cipher (or use the default).
4. On the main screen, set per-Codex appearance defaults, type a short message → Rune
   Scribe → Quick Share, Customize Share, or Send via iMessage (iOS).
5. In Customize Share, review the fixed security summary, choose available appearance
   options, and Share the freshly prepared typed package.
6. Cipher Library → Share sends a typed themed .runescribe invitation. Customize Share
   opens the same builder for that invitation.
7. Cipher Library → More retains Export File, Share Link, and Show QR as explicit
   fallbacks; Import… re-imports supported current and legacy formats.
8. Open Vault/Progress to review the local Journey, achievement progress, Encounters,
   and collected rewards. The app remains usable if Progression is unavailable.
9. Optional: Settings shows private-sync and Game Center state. Decline or remain
   offline to verify that all local cipher, message, and unlock behavior still works.

ENCRYPTION
• AES-256-GCM (CryptoKit) for messages and for the on-device cipher library.
• Keys stored in the Data Protection Keychain (This Device Only; no iCloud Keychain sync).
• Peer-to-peer key handoff only (link / QR / file). No end-to-end messaging network.

URL SCHEME
• runescribe:// — cipher import deep links (CFBundleURLTypes). Not Universal Links; no associated domains.

DOCUMENT TYPE
• .runescribe (UTI com.runescribe.runescribe) — typed or exact legacy cipher/message packages, distinguished by container magic or legacy version byte.

PERMISSIONS
• Camera (iOS only): scan cipher QR codes; frames processed on-device, not stored or uploaded.
• Contacts: optional organization of ciphers by person; contact data stays on device and is prohibited from private progression sync.

MAC
• App Sandbox + Hardened Runtime.
• Automatic import of cipher files from Messages is not claimed on Mac; use Import, open file, or paste runescribe:// link (see docs/platform-notes.md).
• First-delivery message keys require explicit confirmation before persistence or Reply on both platforms; wire sender labels never create or rebind Contacts.

NO DEMO ACCOUNT REQUIRED — local encryption, sharing, Journey, appearance, and Vault
features work without iCloud or Game Center. Live service checks require the review
device's Apple service configuration and are not mandatory for first run.
```

---

## Privacy nutrition label

| Question | Answer |
|----------|--------|
| **Developer data collection** | **No** (no analytics, ads, proprietary account, or developer backend) |
| **Linked to user** | N/A |
| **Used for tracking** | **No** |

Local-only surfaces (not uploaded):

- **Contacts** — optional; on-device organization of ciphers; never uploaded  
- **Camera** — iOS QR scan only; frames processed on-device, not saved or sent  

Optional Apple-service fields:

- **Private iCloud database** — progression identifiers, completion dates, owned
  content IDs, Encounter tokens, device-shard counters, selected Codex, pending Game
  Center reports, logical clocks, and bounded quarantine diagnostics only.
- **Game Center** — stable achievement identifiers and monotonic completion percentage
  only after user opt-in.

The cloud codec rejects plaintext, keys, Keychain material, full messages, package
bytes, contact identity, raw relationship identifiers, QR content, and private logs.
Confirm the final App Store privacy questionnaire against the enabled Apple services
before upload; this file does not submit those answers.

**Privacy policy source:** publish [PRIVACY.md](PRIVACY.md) unchanged at the dedicated
Raven Forge privacy URL before upload, then enter that live URL in App Store Connect.
The source policy is complete. Publication and App Store entry require external access
and are not performed by this work; their absence does not determine product
shippability.

---

## Export compliance (encryption)

Typical answers for this app (confirm against the current questionnaire wording):

| Topic | Answer |
|-------|--------|
| Uses encryption | **Yes** (CryptoKit AES-GCM, Keychain) |
| Proprietary / non-standard algorithms | **No** |
| Only standard OS / mass-market crypto | **Yes** |
| Exempt under US EAR for App Store | Usually **Yes** for standard crypto used for data protection |

Peer key handoff is manual (link / QR / file). There is no proprietary transport encryption stack beyond AES-GCM on-device.

---

## Custom EULA

Use the full text from [`EULA.md`](../EULA.md) as the App Store Connect custom license if not using Apple’s standard EULA.

The same text is shown in-app under **Settings → View License**
(`Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/ProductContent/AppLicense.swift`).

---

## Content rights / age rating

| Field | Suggested value |
|-------|-----------------|
| **Age rating** | 4+ (no UGC network, no violence, no gambling) |
| **Made for Kids** | No |
| **Advertising Identifier (IDFA)** | No |

---

## Entitlements & capabilities (sanity check)

### iOS (`Config/RuneScrib-iOS.entitlements`)

- Keychain access group: `$(AppIdentifierPrefix)com.runescribe.app`
- Game Center capability
- Private iCloud container: `iCloud.com.runescribe.app`
- CloudKit service and key-value store declarations
- No associated domains / Universal Links

### macOS (`Config/RuneScrib-macOS.entitlements`)

- `com.apple.security.app-sandbox`
- `com.apple.security.personal-information.addressbook` (Contacts)
- `com.apple.security.files.user-selected.read-write` (import/export)
- Game Center capability
- Private iCloud container: `iCloud.com.runescribe.app`
- CloudKit service and key-value store declarations

Info.plist highlights (`Config/RuneScrib-*-Info.plist` / `project.yml`):

- URL scheme: `runescribe`
- Document type / exported UTI: `com.runescribe.runescribe` (`.runescribe`)
- iOS: `NSCameraUsageDescription`, `NSContactsUsageDescription`
- macOS: `NSContactsUsageDescription`

---

## Archive & upload checklist

This is an external publication checklist for use when the required credentials and
services are available. No item in the archive, export, signing, notarization, upload,
record-creation, or rollout sequence is implied by product release qualification.

### iOS

1. Scheme: **RuneScrib-iOS**
2. Destination: Any iOS Device (arm64)
3. Product → **Archive** → Distribute App → **App Store Connect**
4. Use **App Store / Distribution** signing (not Development)

### macOS

1. Scheme: **RuneScrib-macOS**
2. Archive for **Mac App Store** distribution (sandbox required)
3. Confirm App Sandbox + Hardened Runtime in the archive’s entitlements
4. Upload via Organizer / Transporter / `xcrun altool` / `notarytool` path you use for MAS

### Before upload

- [ ] Version and build match App Store Connect (`1.0.41` / `41` for this packet)
- [x] Core user flows and clean automated tests pass against the final source
- [x] iOS Simulator and arm64-only unsigned macOS Release builds pass
- [x] Retained prior iPhone 17 Pro headless UI qualification passes on iOS 26.5
- [x] Retained prior iPad Pro 13-inch (M5) headless UI qualification passes on iOS 26.5
- [x] Deterministic accessibility and privacy checks, source validators, and negative
  mutation suites pass
- [x] Both final app bundles contain the exact reviewed `PrivacyInfo.xcprivacy`
  required-reason declarations
- [x] Local ad-hoc content, resource, privacy, signature, Hardened Runtime, and
  entitlement inspection passes 101/101 checks
- [ ] Distribution signing and archive entitlement inspection passes with a matching
  profile and identity
- [x] No known release-blocking defects remain
- [ ] Release notes pasted (What’s New)
- [ ] Review notes pasted
- [ ] Privacy answers set
- [ ] Export compliance answered
- [ ] Custom EULA attached if required
- [ ] Screenshots and description current for both platforms
- [x] Supported Simulator and hosted coverage verifies Share deep-link routing and
  intro cadence
- [x] Supported Simulator and hosted coverage verifies Vault/Progress, reveal
  accessibility, and feedback settings
- [x] Deterministic adapters verify private-sync merge/offline/account/corruption policy
- [x] Deterministic adapters verify Game Center mapping/opt-in/outbox/retry policy
- [ ] When credentials are available, configure the iCloud container and App Store records
- [ ] When services are available, create/group Game Center records and upload approved
  images/localizations

Manual hardware observations are superseded by repository-controlled Simulator, hosted,
and deterministic equivalents and are not a product-shippability requirement. Legacy
package audit and self-binding mechanics are noncontrolling verification history. The
source is repository-qualified. Retained prior headless UI results are not represented
as current-candidate source-bound evidence. Distribution signing, archive, export,
notarization, upload, and rollout remain external.

---

## Version 1.0.41 UI/Xcode remediation candidate

Internal release summary; this is **not a shipment claim**:

1. Optional on-device Progression with approved achievements, milestones, durable records, and privacy-safe existing-user migration
2. Vault/Progress, Collection, Archive, and accessible queued unlock reveals
3. Runtime-owned Theme coordination, required Norse Base, and four production Elven providers
4. Themed typed-package sharing/receiving, static preview, Encounter and provenance state
5. Local-first private progression synchronization and optional Game Center policy
6. Core, runtime, providers, Progression, Cloud, Game Center, and UI boundaries guarded
7. Final-source checks pass: 1,242/1,242 Swift tests, 255/255 Python tests, 60 Norse
   semantic rules, 25/25 Norse mutations, 18/18 legacy mutations, 28/28 shipping
   negative mutations, and 27/27 evidence-hardening tests
8. The iOS Release and arm64-only unsigned macOS Release builds pass; local ad-hoc
   built-product content, resource, privacy, signature, Hardened Runtime, and entitlement
   inspection passes 101/101 checks. Distribution identity and provisioning are unassessed
9. Retained prior evidence records the iPhone 17 Pro iOS 26.5 UI run with 7 passed, 1
   iPad-only skipped, and 0 failed, and the iPad Pro 13-inch (M5) iOS 26.5 UI run with 5
   passed, 3 phone-specific skipped by design, and 0 failed. These runs are not
   current-candidate source-bound evidence
10. The superseded v4.3 package audit is retained as noncontrolling verification history
11. Marketing version **1.0.41**, build **41** is not shipped;
    distribution signing, archive, export, notarization, upload, and rollout remain external

Platform-specific import notes: [`platform-notes.md`](platform-notes.md)

---

## Updating this doc for the next release

1. Bump Version table (and keep `project.yml` / Xcode / `CHANGELOG.md` aligned).
2. Rewrite **What’s New** for the new delta.
3. Adjust **App Review Notes** only if demo steps, permissions, or URL/document types change.
4. Re-check privacy and export compliance if data handling or crypto surface changes.
