# App Store submission — Rune Scribe

Ready-to-paste material for App Store Connect (iOS App Store and Mac App Store).
Keep this file in sync when shipping a new marketing version.

**Last prepared for:** 1.0.38 (build 38) — 2026-08-22

> **No-ship boundary:** this repository update prepares source-controlled copy only.
> It does not create or change App Store Connect records, archive/export either app,
> sign for distribution, notarize, upload, release, or begin rollout.

---

## Version

| Field | Value |
|--------|--------|
| **Version** | `1.0.38` |
| **Build** | `38` |
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
• Adds four unlockable Elven Codices and themed message Artifacts
• Adds optional private Journey sync across your Apple devices
• Adds optional Game Center achievement reporting
```

### Full

```
This update completes Rune Scribe's Codex journey while preserving local encryption and offline use:

• Unlock Moonleaf, Sunspire, Wildwood, and Gloamthorn Codices from the local Journey.
• Choose owned Relics, Seals, and Frames for a static themed message preview.
• Receive themed files safely even when their Codex is locked or unavailable.
• Optionally mirror progression through your private iCloud database.
• Optionally report the evergreen achievement catalog to Game Center.
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
4. On the main screen, choose available Relic/Seal/Frame appearance defaults, type a
   short message → Rune Scribe → Share or Send via iMessage (iOS).
5. Cipher Library → Share on a cipher: system share sheet offers a runescribe://import link. Opening that link on a device with Rune Scribe installed presents Import Cipher.
6. Cipher Library → Export produces a typed themed .runescribe file; Import… re-imports it.
7. QR: show QR for a cipher; Scan QR Code (iOS) or Camera to import.
8. Open Vault/Progress to review the local Journey, achievement progress, Encounters,
   and collected rewards. The app remains usable if Progression is unavailable.
9. Optional: Settings shows private-sync and Game Center state. Decline or remain
   offline to verify that all local cipher, message, and unlock behavior still works.

ENCRYPTION
• AES-256-GCM (CryptoKit) for messages and for the on-device cipher library.
• Keys stored in Keychain (This Device Only; no iCloud Keychain sync).
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
The source policy is complete; publication and App Store entry remain owner-only and
not performed by this work.

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

This is an owner-operated future checklist. No item in the archive, export, signing,
notarization, upload, record-creation, or rollout sequence was executed by the
roadmap-completion work.

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

- [ ] Version and build match App Store Connect (`1.0.38` / `38` for this packet)
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
- [ ] Owner configures the iCloud container and validates private-database account changes
- [ ] Owner creates/groups Game Center records, uploads approved images/localizations,
  and validates sandbox behavior on both platforms

Hardware-only observations are owner-operated optional validation outside Agent Coding
scope. They do not affect acceptance, completion, blocker status, residual work,
PASS/FAIL, upload readiness, or pull-request readiness.

---

## Source-complete 1.0.38 candidate

Internal source-complete summary; this is **not a shipment claim**:

1. Optional on-device Progression with approved achievements, milestones, durable records, and privacy-safe existing-user migration
2. Vault/Progress, Collection, Archive, and accessible queued unlock reveals
3. Runtime-owned Theme coordination, required Norse Base, and four production Elven providers
4. Themed typed-package sharing/receiving, static preview, Encounter and provenance state
5. Local-first private progression synchronization and optional Game Center policy
6. Core, runtime, providers, Progression, Cloud, Game Center, and UI boundaries guarded
7. Marketing version **1.0.38**, build **38**, with discretionary owner validation before distribution and no upload performed

Platform-specific import notes: [`platform-notes.md`](platform-notes.md)

---

## Updating this doc for the next release

1. Bump Version table (and keep `project.yml` / Xcode / `CHANGELOG.md` aligned).
2. Rewrite **What’s New** for the new delta.
3. Adjust **App Review Notes** only if demo steps, permissions, or URL/document types change.
4. Re-check privacy and export compliance if data handling or crypto surface changes.
