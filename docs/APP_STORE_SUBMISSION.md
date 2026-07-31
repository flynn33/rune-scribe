# App Store submission — Rune Scribe

Ready-to-paste material for App Store Connect (iOS App Store and Mac App Store).
Keep this file in sync when shipping a new marketing version.

**Last prepared for:** 1.0.33 (build 33) — 2026-07-31

---

## Version

| Field | Value |
|--------|--------|
| **Version** | `1.0.33` |
| **Build** | `33` |
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
• Intro video at most once every 30 days
• Cipher Library Share now sends a tap-to-open import link
• Export still shares full .runescribe files
```

### Full

```
This update improves day-to-day use and cipher sharing:

• The Raven Forge intro video plays on first launch, then at most once every 30 days (still skippable).
• Sharing a cipher from Cipher Library now sends a runescribe:// import link. Recipients with the app can tap the link in Messages, Mail, or Notes to open Rune Scribe and import the cipher.
• Export still creates a full .runescribe decoder file when you need a file instead of a link.
• QR codes for cipher sharing work as before.
```

---

## App Review Notes

Paste into App Store Connect → App Review Information → Notes.

```
Rune Scribe is a fully offline encrypted messaging utility. No accounts, no servers, no network API calls.

HOW TO DEMO
1. Launch the app. You may see a short skippable intro (Skip or wait).
2. Optional: Settings → set a 4-digit App Lock PIN, then background and return to verify lock.
3. Cipher Library → New Cipher (or use the default).
4. On the main screen: type a short message → Rune Scribe → Share or Send via iMessage (iOS).
5. Cipher Library → Share on a cipher: system share sheet offers a runescribe://import link. Opening that link on a device with Rune Scribe installed presents Import Cipher.
6. Cipher Library → Export produces a .runescribe file; Import… re-imports it.
7. QR: show QR for a cipher; Scan QR Code (iOS) or Camera to import.

ENCRYPTION
• AES-256-GCM (CryptoKit) for messages and for the on-device cipher library.
• Keys stored in Keychain (This Device Only; no iCloud Keychain sync).
• Peer-to-peer key handoff only (link / QR / file). No end-to-end messaging network.

URL SCHEME
• runescribe:// — cipher import deep links (CFBundleURLTypes). Not Universal Links; no associated domains.

DOCUMENT TYPE
• .runescribe (UTI com.runescribe.runescribe) — cipher packages and message attachments, distinguished by version byte.

PERMISSIONS
• Camera (iOS only): scan cipher QR codes; frames processed on-device, not stored or uploaded.
• Contacts: optional organization of ciphers by person; data stays on device, never uploaded.

MAC
• App Sandbox + Hardened Runtime.
• Automatic import of cipher files from Messages is not claimed on Mac; use Import, open file, or paste runescribe:// link (see docs/platform-notes.md).

NO DEMO ACCOUNT REQUIRED — all features work offline after install.
```

---

## Privacy nutrition label

| Question | Answer |
|----------|--------|
| **Data collection** | **No** (no analytics, ads, or backend) |
| **Linked to user** | N/A |
| **Used for tracking** | **No** |

Local-only surfaces (not uploaded):

- **Contacts** — optional; on-device organization of ciphers; never uploaded  
- **Camera** — iOS QR scan only; frames processed on-device, not saved or sent  

**Privacy policy URL:** use the live Raven Forge privacy page if published; otherwise the company site (`https://ravenforgesoftware.com/`) until a dedicated policy URL exists.

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

The same text is shown in-app under **Settings → View License** (`RuneScrib/Models/AppLicense.swift`).

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
- No associated domains / Universal Links

### macOS (`Config/RuneScrib-macOS.entitlements`)

- `com.apple.security.app-sandbox`
- `com.apple.security.personal-information.addressbook` (Contacts)
- `com.apple.security.files.user-selected.read-write` (import/export)

Info.plist highlights (`Config/RuneScrib-*-Info.plist` / `project.yml`):

- URL scheme: `runescribe`
- Document type / exported UTI: `com.runescribe.runescribe` (`.runescribe`)
- iOS: `NSCameraUsageDescription`, `NSContactsUsageDescription`
- macOS: `NSContactsUsageDescription`

---

## Archive & upload checklist

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

- [ ] Version and build match App Store Connect (`1.0.33` / `33` for this packet)
- [ ] Release notes pasted (What’s New)
- [ ] Review notes pasted
- [ ] Privacy answers set
- [ ] Export compliance answered
- [ ] Custom EULA attached if required
- [ ] Screenshots and description current for both platforms
- [ ] Smoke-test Share deep link and intro cadence on device

---

## What shipped in 1.0.33

Internal summary for this submission:

1. Cold-launch intro plays at most once every **30 days**
2. Cipher Library **Share** sends a `runescribe://import` deep link (tap-to-import); **Export** still provides `.runescribe` files
3. Marketing version **1.0.33**, build **33**

Related PR: https://github.com/flynn33/rune-scribe/pull/33

Platform-specific import notes: [`platform-notes.md`](platform-notes.md)

---

## Updating this doc for the next release

1. Bump Version table (and keep `project.yml` / Xcode / `CHANGELOG.md` aligned).
2. Rewrite **What’s New** for the new delta.
3. Adjust **App Review Notes** only if demo steps, permissions, or URL/document types change.
4. Re-check privacy and export compliance if data handling or crypto surface changes.
