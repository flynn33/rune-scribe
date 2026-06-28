# Changelog

All notable changes to Rune Scribe are recorded here. New entries are added
automatically when a pull request is merged into `main` (see
`.github/workflows/version-bump.yml`). The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

<!-- NEW ENTRIES BELOW -->
## [1.0.26] - 2026-06-28

- Fix Share-to-Messages, add macOS/iOS Messages send, copy carries cipher key, add Clear (#26) by @flynn33

## [1.0.25] - 2026-06-28

- Selective contacts import; fix Share, first-message key, and remove-contacts (#25) by @flynn33

## [1.0.24] - 2026-06-28

- Fix Info.plist version and match build number to version (#24) by @flynn33

## [1.0.23] - 2026-06-27

- feat: file-based, server-free cipher and message sharing (#23) by @flynn33

## [1.0.21] - 2026-06-26

- Messages: inbound/outbound flow, Swift 6 fixes, updated splash (#22) by @flynn33

## [1.0.20] - 2026-06-26

- Phase 4: Apple Messages send + cipher key auto-exchange (#21) by @flynn33

## [1.0.19] - 2026-06-25

- Replace the cold-launch splash video with v2 (#20) by @flynn33

## [1.0.18] - 2026-06-24

- Phase 3: Contacts & per-contact ciphers (#19) by @flynn33

## [1.0.17] - 2026-06-24

- Phase 2: font travels with the cipher + https Universal-Link sharing (#18) by @flynn33

## [1.0.16] - 2026-06-23

- Phase 1: real message encryption (replace substitution cipher) (#17) by @flynn33

## [1.0.15] - 2026-06-21

- Refresh the README for v1.0.14 — cipher sharing & cold-launch splash (#16) by @flynn33

## [1.0.14] - 2026-06-21

- Video splash screen on cold launch (#15) by @flynn33

## [1.0.13] - 2026-06-20

- Share ciphers via iMessage, QR code, and deep-link auto-import (#14) by @flynn33

## [1.0.12] - 2026-06-20

- Rebrand to "Rune Scribe" and refresh the README + docs (#12) by @flynn33

## [1.0.11] - 2026-06-20

- Add cross-person decoder round-trip tests (#11) by @flynn33

## [1.0.10] - 2026-06-20

- Lock the text frame height during the transformation (#10) by @flynn33

## [1.0.9] - 2026-06-20

- Keep runes norse and the text frame fixed; remove info chips (#9) by @flynn33

## [1.0.8] - 2026-06-20

- Make rune transformation fast and sharp; remove the glow (#8) by @flynn33

## [1.0.7] - 2026-06-20

- Animate text-to-rune conversion in place (rune-by-rune inscription) (#7) by @flynn33

## [1.0.6] - 2026-06-20

- PIN app lock, multi-cipher library, settings, and rune glow (#6) by @flynn33

## [1.0.5] - 2026-06-19

- Enable App Sandbox for the macOS app (Mac App Store) (#5) by @flynn33

## [1.0.4] - 2026-06-19

- Rebrand identifiers to com.runescribe (#4) by @flynn33

## [1.0.3] - 2026-06-19

- Fix Xcode warnings: iPad orientations and MTKView main-actor isolation (#3) by @flynn33

## [1.0.2] - 2026-06-19

- Add app icon and developer-team signing for iOS (#2) by @flynn33

## [1.0.1] - 2026-06-19

- Single-file decoder export, plus decoder import and a Decode tab (#1) by @flynn33


## [1.0.0] - 2026-06-19

- Initial release: universal macOS + iOS runic substitution cipher.
