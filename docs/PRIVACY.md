# Rune Scribe Privacy Policy

**Effective date:** August 31, 2026
**Applies to:** Rune Scribe 1.0.40 (build 40) for iOS and macOS

Rune Scribe is a local-first encryption and sharing app from Raven Forge Software. It
does not require a Raven Forge account and does not use advertising, tracking,
analytics, or a developer-operated message service.

## Data that stays on the device

Cipher keys, plaintext, full messages, encrypted package bytes, App Lock data, and the
authoritative local Vault remain on the device. Cipher-library keys use this-device-only
Data Protection Keychain storage. On macOS, legacy migration reads only the classic
default keychain and never deletes its file-based source, including when an imported or
restored keychain is the current default. The replacement bytes and accessibility class
are verified, and explicit deletion records a this-device-only blocker that prevents
legacy remigration. Optional Contacts access is used only to organize ciphers locally;
contact names, addresses, system identifiers, and relationship identifiers are not sent
to iCloud or Game Center. On iOS, camera access is used only to scan a QR code; camera
frames are processed on-device and are not retained or uploaded.

Sharing uses Apple-provided share, file, clipboard, Messages, AirDrop, print, and camera
surfaces selected by the user. Rune Scribe does not operate a relay for those transfers.
The destination app or service is governed by its own privacy terms after the user
chooses to share.

Share Builder UI receives opaque operation handles and validated appearance snapshots,
not cipher keys or raw package bytes. Cipher invitation Artifacts necessarily contain
the shared cipher material; the fixed security notice identifies that fact before Share.

## Platform privacy declarations

Both the iOS and macOS products bundle the same `PrivacyInfo.xcprivacy` manifest. It
declares that Rune Scribe does not track users or send developer-collected data, and it
lists only the file-timestamp required-reason API category. The declared reasons cover
metadata for Rune Scribe's protected app-container files and files the user explicitly
selects or imports. Built-product checks reject a missing manifest, an altered reason,
tracking, collected-data declarations, or a platform mismatch.

## Optional Apple services

Private iCloud progression sync is optional and local-first. When available, it stores a
bounded progression replica in the signed-in user's private CloudKit database. Allowed
records include achievement and milestone progress, owned-content and unlock IDs,
privacy-safe Encounter and distinct-statistic tokens, per-device counter shards,
selected appearance and title IDs, pending Game Center percentages, logical clocks,
provenance references, and quarantine diagnostics.

The private-sync codec rejects plaintext, cipher keys, Keychain material, full messages,
encrypted package bytes, contact identity, raw relationship identifiers, QR content,
and private logs. Invalid remote data is quarantined without deleting valid local
progress. An iCloud account change pauses sync until the user explicitly rebinds; local
Vault data remains usable.

Game Center achievement reporting is also optional. Rune Scribe sends only stable
achievement identifiers and monotonic completion percentages after the user opts in.
The user can stop Rune Scribe's Game Center mirroring in Settings. Game Center and
iCloud are never authority to grant or revoke local content.

Apple processes iCloud and Game Center data under Apple's terms. Raven Forge Software
does not receive that private database or Game Center account data through a separate
backend.

## Retention and control

Local data remains until the user removes it through the app or operating system.
Private iCloud and Game Center retention is controlled through the user's Apple account
and Apple service settings. Stopping an optional service does not delete the local Vault.
Rune Scribe does not implement a cross-device progression reset in this release.

## Children, changes, and contact

Rune Scribe is not designed to collect personal information from children. Because no
developer account or backend is provided, Raven Forge Software does not knowingly
collect child account data through the app.

Material changes to this policy will be published with an updated effective date. For
privacy or support questions, use the contact channel published at
[Raven Forge Software](https://ravenforgesoftware.com/).
