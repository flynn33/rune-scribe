# App Store submission — Rune Scribe

Ready-to-paste material for App Store Connect (iOS App Store and Mac App Store).
Keep this file in sync when shipping a new marketing version.

**Last prepared for:** 1.0.44 (build 44) — 2026-10-03

> **Publication boundary:** version 1.0.44 build 44 is the current source candidate and
> is not shipped. The
> [earlier UI/Xcode qualification](verification/ui-xcode-remediation/QualificationSummary.md)
> and signed Store exports cover the source measured at that time. They predate subsequently merged theme,
> Universal Link, tutorial, and workspace changes. Fresh current-source archive and
> export qualification is required before upload. Validation, upload, submission,
> release, and rollout remain owner-operated.

The packet remains aligned to version 1.0.44 build 44, but does not claim that the
current merged source is upload-ready before fresh qualification.

---

## Version

| Field | Value |
|--------|--------|
| **Version** | `1.0.44` |
| **Build** | `44` |
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
• Removes the extra fallback text from cipher invitations in Messages
• Keeps cipher keys out of regular message packages
• Fits rune lines within the tablet inscription area
```

### Full

```
This patch removes the extra fallback text from iOS Messages cipher invitations while
keeping the artwork, caption, and validated invitation URL. Regular message packages
carry the encrypted message without an embedded cipher; share a cipher explicitly from
Cipher Manager. The runes remain the regular Messages text. Longer rune inscriptions
are measured and paginated within the tablet's inscription area.
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
6. On iOS, Cipher Library → Share composes a themed Messages invitation. Customize Share
   opens the appearance builder before composing the same interactive route. The
   extension action is Continue to Rune Scribe; import confirmation stays in the app.
7. Cipher Library → More retains Export File, Share Link, and Show QR as explicit
   fallbacks; Import… re-imports supported current and legacy formats.
8. Open Vault/Progress to review the local Journey, achievement progress, Encounters,
   and collected rewards. The app remains usable if Progression is unavailable.
9. Optional: Settings shows private-sync and Game Center state. Decline or remain
   offline to verify that all local cipher, message, and unlock behavior still works.

ENCRYPTION
• AES-256-GCM (CryptoKit) for messages and for the on-device cipher library.
• Keys stored in the Data Protection Keychain (This Device Only; no iCloud Keychain sync).
• Peer-to-peer key handoff only (validated invitation / QR / file). No end-to-end messaging network.

URL SCHEME
• runescribe:// — compatible cipher import deep links (CFBundleURLTypes).

UNIVERSAL LINKS (iOS)
• https://ravenforgesoftware.com/rune-scribe/?runescribe=import… — cipher invitation links.
• The website association document authorizes Team 9AQ2C2838M and bundle com.runescribe.app.
• Without the app, the Rune Scribe product page provides the App Store fallback.

MESSAGES EXTENSION (iOS)
• Bundle com.runescribe.app.messages renders the selected themed artwork in an MSMessage.
• MSMessage.url carries the validated HTTPS invitation; the invitation composer body is empty.
• Continue to Rune Scribe hands off to the containing app; import confirmation and mutation remain there.
• The group.com.runescribe.app recovery envelope stores no key material.
• Physical-device transcript, artwork-tap, deleted-app fallback, and SMS behavior are not yet qualified.

DOCUMENT TYPE
• .runescribe (UTI com.runescribe.runescribe) — typed or exact legacy cipher/message packages, distinguished by container magic or legacy version byte.

PERMISSIONS
• Camera (iOS only): scan cipher QR codes; frames processed on-device, not stored or uploaded.
• Contacts: optional organization of ciphers by person; contact data stays on device and is prohibited from private progression sync.

MAC
• App Sandbox + Hardened Runtime.
• Automatic import of cipher files from Messages is not claimed on Mac; use Import, open file, or paste runescribe:// link (see docs/platform-notes.md).
• Regular messages carry no cipher key. Import and confirm a separately shared cipher before decoding or Reply; wire sender labels never create or rebind Contacts.

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
- App Group: `group.com.runescribe.app`
- Game Center capability
- Private iCloud container: `iCloud.com.runescribe.app`
- CloudKit service and key-value store declarations
- Associated domain: `applinks:ravenforgesoftware.com`

### Messages extension (`Config/RuneScribeMessagesExtension.entitlements`)

- Target: `RuneScribeMessagesExtension`
- Bundle ID: `com.runescribe.app.messages`
- App Group: `group.com.runescribe.app`
- Extension-safe build setting: `APPLICATION_EXTENSION_API_ONLY = YES`

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

The repository command below rebuilds, exports, and inspects both Store packages without
validating or uploading them:

```bash
scripts/qualify-app-store-archives.sh
```

It uses `Config/AppStoreExportOptions.plist` and requires access to the configured Apple
team. The remaining steps are owner-operated publication actions.

### iOS

1. Scheme: **RuneScrib-iOS**
2. Destination: Any iOS Device (arm64)
3. Product → **Archive** → Distribute App → **App Store Connect**
4. Use **App Store / Distribution** signing (not Development)

### macOS

1. Scheme: **RuneScrib-macOS**
2. Archive for **Mac App Store** distribution (sandbox required)
3. Confirm App Sandbox + Hardened Runtime in the archive’s entitlements
4. Upload the exported package through Organizer or Transporter

### Before upload

- [ ] Version and build match the configured App Store Connect record (`1.0.44` / `44` for this packet)
- [ ] Complete the full automated package regression against the final source
- [x] Focused Messages Shared, durable-fingerprint, handoff, and rendered-link tests pass
- [ ] Re-run iOS Simulator and arm64-only unsigned macOS Release qualification against the final source
- [x] Retained prior iPhone 17 Pro headless UI qualification passes on iOS 26.5
- [x] Retained prior iPad Pro 13-inch (M5) headless UI qualification passes on iOS 26.5
- [x] Deterministic accessibility and privacy checks, source validators, and negative
  mutation suites pass
- [x] Both final app bundles contain the exact reviewed `PrivacyInfo.xcprivacy`
  required-reason declarations
- [x] Local ad-hoc content, resource, privacy, signature, Hardened Runtime, and
  entitlement inspection passes 101/101 checks
- [ ] Produce fresh iOS and macOS Store exports from the current merged source and pass
  distribution identity, Store provisioning profile, architecture, production
  entitlement, privacy manifest, and package signature inspection
- [ ] Run sender iPhone → installed recipient with Rune Scribe cold and confirm exactly one import prompt
- [ ] Run sender iPhone → installed recipient with Rune Scribe already running and confirm exactly one import prompt
- [ ] Run sender iPhone → recipient with Rune Scribe deleted and observe the first artwork tap
- [ ] Confirm the body HTTPS URL remains visible and tappable in the recipient transcript
- [ ] Confirm a green-bubble/SMS send retains the HTTPS URL
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

Manual hardware observations remain superseded for the previously covered behavior by
repository-controlled Simulator, hosted, and deterministic equivalents. They do not
replace the five unrun Messages-extension rows above, which remain a qualification gate. Legacy
package audit and self-binding mechanics are noncontrolling verification history.
Earlier exported packages are retained historical evidence and are not qualified for
upload as the current source. Retained prior headless UI results are not represented as
current-candidate source-bound evidence. App Store Connect validation, upload,
submission, release, and rollout remain external.

---

## Version 1.0.44 current-source candidate

Internal release summary; this is **not a shipment claim**:

1. Optional on-device Progression with approved achievements, milestones, durable records, and privacy-safe existing-user migration
2. Vault/Progress, Collection, Archive, and accessible queued unlock reveals
3. Runtime-owned Theme coordination, required Norse Base, and four production Elven providers
4. Themed typed-package sharing/receiving, static preview, Encounter and provenance state
5. Local-first private progression synchronization and optional Game Center policy
6. Core, runtime, providers, Progression, Cloud, Game Center, and UI boundaries guarded
7. The earlier qualified source passed 1,242/1,242 Swift tests, 255/255 Python tests, 60 Norse
   semantic rules, 25/25 Norse mutations, 18/18 legacy mutations, 28/28 shipping
   negative mutations, and 27/27 evidence-hardening tests
8. The iOS Release and arm64-only unsigned macOS Release builds pass; local ad-hoc
   built-product content, resource, privacy, signature, Hardened Runtime, and entitlement
   inspection passed 101/101 checks for that source. Its iOS and macOS Store exports
   passed distribution identity, profile, production-entitlement, architecture, and
   package-signature checks; fresh current-source qualification remains required
9. Retained prior evidence records the iPhone 17 Pro iOS 26.5 UI run with 7 passed, 1
   iPad-only skipped, and 0 failed, and the iPad Pro 13-inch (M5) iOS 26.5 UI run with 5
   passed, 3 phone-specific skipped by design, and 0 failed. These runs are not
   current-candidate source-bound evidence
10. The superseded v4.3 package audit is retained as noncontrolling verification history
11. The Messages invitation keeps themed `MSMessage` artwork, caption, and the HTTPS
    URL in `MSMessage.url`, with an empty composer body. Regular message packages are
    key-free; Cipher Manager share carries the cipher. Rune lines fit the inscription rect
12. Physical-device Messages transcript, artwork-tap, deleted-app fallback, and
    green-bubble/SMS behavior remain unrun and unqualified
13. Marketing version **1.0.44**, build **44** is not shipped; earlier signed Store
    packages are retained evidence and must not be uploaded as the current source

Platform-specific import notes: [`platform-notes.md`](platform-notes.md)

---

## Updating this doc for the next release

1. Bump Version table (and keep `project.yml` / Xcode / `CHANGELOG.md` aligned).
2. Rewrite **What’s New** for the new delta.
3. Adjust **App Review Notes** only if demo steps, permissions, or URL/document types change.
4. Re-check privacy and export compliance if data handling or crypto surface changes.
