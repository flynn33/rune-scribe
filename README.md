# Rune-Scrib

A Norse runic substitution-cipher app for **macOS** and **iOS**. Type a message,
press **Rune Scrib**, and every character is mapped to a unique Unicode Runic
glyph. Copy the runes and paste them anywhere; share the key with a correspondent
(or an AI model) so they can decode it.

The cipher is a random bijection over an 89-character set onto the Unicode Runic
block (U+16A0–U+16F8). The mapping is generated on first launch, encrypted with
AES-256-GCM, and stored in the system Keychain. It can be exported (to pre-share
for decoding) or rotated on demand.

## Features

- **Encode / decode** a 89-character set (A–Z, a–z, 0–9, space, common punctuation)
  to runes; everything else (newlines, emoji, accents) passes through unchanged.
- **Key in the Keychain** — the mapping is AES-256-GCM encrypted; the symmetric key
  never leaves the device and never rotates (only the mapping does).
- **Export** the decoder as a single `.json` file — import it into RuneScrib to
  decode, or share it with an AI model (Claude, ChatGPT, Grok) to read the table.
- **Import** a decoder file (Key Management → Import Decoder), then switch to the
  **Decode** tab and paste runes to turn them back into text.
- **Rotate** the mapping (with a warning — old messages become undecodable).
- **Universal UI** — one SwiftUI codebase, native on Mac and iPhone/iPad, with an
  animated Metal header and a consistent design system.

## Requirements

- Xcode 16+ (built with Xcode 26)
- macOS 15.0+ / iOS 17.0+
- Swift 6.0
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — only to regenerate the project from `project.yml`

No third-party runtime dependencies; the app uses Apple frameworks only
(SwiftUI, AppKit/UIKit, CryptoKit, Security, Metal, MetalKit, CoreText).

## Build

The Xcode project is committed, so you can open `RuneScrib.xcodeproj` directly.
To regenerate it from `project.yml`:

```sh
xcodegen generate
```

Then build either platform:

```sh
# macOS
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' build

# iOS Simulator
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Unit tests (cipher + key management, hosted in the macOS app)
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' test
```

For local runs the app is signed ad-hoc ("Sign to Run Locally"); set your own team
in Xcode to run on a physical device.

## Project layout

```
RuneScrib/
├── App/         RuneScribApp (@main), AppDelegate (per-platform)
├── Models/      RuneKey, RuneKeyExport, RuneCharacterSet (the 89-char pools)
├── Services/    KeychainService, CipherEngine, KeyManager, Clipboard, FontRegistration
├── Views/       ContentView, ResultPopupView, KeyManagementView + Components/ (design system)
├── Metal/       RuneMetalView, MetalRenderer, Shaders.metal (animated header)
└── Resources/   Assets.xcassets, Fonts/ (Noto Sans Runic)
RuneScribTests/  Cipher, key-generation, and round-trip tests
```

Platform differences (delegate adaptor, MTKView host, pasteboard, export
mechanism, sizing) are isolated behind `#if os(macOS)` / `#if os(iOS)` and a small
set of cross-platform wrappers, so the views and cipher logic are shared.

## Credits

Bundled font: **Noto Sans Runic** by the Noto Project, licensed under the SIL Open
Font License 1.1 (see `RuneScrib/Resources/Fonts/OFL.txt`).
