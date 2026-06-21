<div align="center">

# ᚱᚢᚾᛖ ᛋᚲᚱᛁᛒᛖ &nbsp;·&nbsp; Rune Scribe

**Turn your words into Norse runes — and back again.**

A private, on-device substitution-cipher app for **macOS** and **iOS**. Type a
message, watch each character inscribe itself into a unique Unicode rune, and
share the result anywhere. Send a friend the cipher — by QR, iMessage, link, or
file — and they can read it; without it, the runes are just runes.

![Platform](https://img.shields.io/badge/platform-macOS%2015%20%7C%20iOS%2017-3A7FD5?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6.0-D4971A?style=flat-square)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20Metal-3A7FD5?style=flat-square)
![Tests](https://img.shields.io/badge/tests-72%20passing-2ea043?style=flat-square)
![License](https://img.shields.io/badge/license-Proprietary-A0A8B8?style=flat-square)

A product of **Raven Forge Software**.

</div>

---

## ✨ Features

- **🔤 Encode & decode** — map an 89-character set (A–Z, a–z, 0–9, space, common
  punctuation) onto the Unicode Runic block (U+16A0–U+16F8). Anything else
  (newlines, emoji, accents, other scripts) passes through untouched.
- **📚 Cipher library** — keep **multiple labelled cipher/decipher pairs**. Each
  one both encodes and decodes; pick the active pair and switch any time. Create,
  rename, export, import, and delete them.
- **🤝 Share a cipher, any way** — send a cipher by **QR code**, by
  **iMessage / share sheet**, or as a tap-to-import **`runescribe://` link**; your
  friend taps once to import and can read your runes. The portable **`.json`
  decoder file** remains the universal fallback. Every channel carries the same
  mapping, isn't tied to your device, and works across installs.
- **🔒 App lock** — an optional **4-digit PIN** gates the app on launch and when
  it returns from the background. The PIN is never stored: a salted
  **PBKDF2-HMAC-SHA256** hash lives in the Keychain, and repeated wrong guesses
  trigger an escalating lockout.
- **🪄 Living transformation** — pressing **Rune Scribe** inscribes the text in
  place, rune by rune, each glyph flaring as it lands. No popups, no spinners —
  the text frame itself transforms.
- **🎨 Crafted interface** — a Metal-rendered Norse background, a bundled
  **Noto Sans Runic** font so every rune renders sharply, and one cohesive design
  system across both platforms.
- **🎬 Cold-launch intro** — a short, skippable Raven Forge splash video plays on
  first open (tap anywhere or **Skip**), and is bypassed automatically if the
  video asset isn't bundled.

---

## 🔮 How the cipher works

The cipher is a **random bijection** (a one-to-one pairing) from the 89 input
characters onto 89 runes. The pairing — the *key* — is generated on first launch
with a cryptographically secure shuffle, encrypted with **AES-256-GCM**, and
stored in the system **Keychain**. Encoding looks up each character; decoding uses
the exact inverse.

```mermaid
flowchart LR
    subgraph Encode["🔤  Encode"]
        direction TB
        A["Plain text<br/>“Meet at dawn”"] --> B{Char in the<br/>89-set?}
        B -->|yes| C["Map to its rune"]
        B -->|no| D["Pass through<br/>(emoji, newline…)"]
        C --> E["Runes<br/>ᛗᛖᛖᛏ ᚨᛏ ᛞᚨᚹᚾ"]
        D --> E
    end
    subgraph Decode["🔓  Decode"]
        direction TB
        F["Runes"] --> G{Char in the<br/>reverse map?}
        G -->|yes| H["Map back to<br/>the character"]
        G -->|no| I["Pass through"]
        H --> J["Plain text"]
        I --> J
    end
    Encode -.the same key.-> Decode

    classDef plain fill:#1A1E30,stroke:#3A7FD5,color:#FFFFFF
    classDef rune fill:#D4971A,stroke:#EEBE45,color:#080A1E
    classDef gate fill:#0E1226,stroke:#A0A8B8,color:#A0A8B8
    class A,J plain
    class E,F rune
    class B,G gate
```

Because the cipher's *output* alphabet is the runic block, the only text that
won't survive a round trip is a message that *itself* contains literal rune
characters — which no real message does. Everything people actually type (Latin
text, numbers, punctuation, emoji, accents, other scripts) round-trips exactly.

---

## 🤝 Sharing & decoding

A cipher is the shared secret: whoever has it can read — and write — your runes.
Rune Scribe gives three ways to hand one to a friend, easiest first.

- **QR code or `runescribe://` link.** A cipher is encoded as a compact
  **89-byte permutation** (one runic index per input character) inside a
  `runescribe://import?v=1&p=…&n=…` URL — small enough to become a QR code or a
  tappable link you send over **iMessage, Mail, or AirDrop**. Your friend taps the
  link (or scans the QR with their Camera or the in-app scanner) and Rune Scribe
  offers a **one-tap import**. `keyId`/`createdAt` aren't sent — the receiver mints
  a fresh identity, exactly like a file import.
- **Decoder file (`.json`).** The portable fallback: a plain-JSON `RuneKeyExport`
  of the mapping (and its inverse), imported from **Cipher Library → Import**. Not
  tied to your device, so it works across installs.

Every channel — link, QR, clipboard, file — funnels through the **same validated
import path** (`KeyManager.importCipher`): the payload must be exactly 89 bytes and
a true permutation, or the import is rejected with a friendly message. The in-app
**QR scanner is iOS-only**; on macOS you import via a tapped link, a pasted link,
or the file.

```mermaid
sequenceDiagram
    autonumber
    actor Alice
    participant App1 as Rune Scribe (Alice)
    participant Ch as iMessage · QR · AirDrop
    participant App2 as Rune Scribe (Bob)
    actor Bob

    Alice->>App1: Type “Meet at dawn”, press Rune Scribe
    App1-->>Alice: Runes  ᛗᛖᛖᛏ ᚨᛏ ᛞᚨᚹᚾ
    Alice->>App1: Share cipher → QR / runescribe:// link
    App1-->>Ch: 89-byte permutation in a runescribe:// URL
    Alice->>Bob: Send the runes + the link/QR
    Bob->>App2: Tap link / scan QR
    App2-->>Bob: “Import this cipher?” → one tap
    Bob->>App2: Paste the runes, press Decode
    App2-->>Bob: “Meet at dawn”
```

> The compact link/QR format is covered by `RuneCipherLinkTests` (encode, decode,
> round-trip, malformed URLs); the file path is locked down by
> `FriendDecodeRoundTripTests` — 700+ random key/message round trips, plus emoji,
> accents, other scripts, multi-line text, and the full character set.

> **Guard the cipher.** A shared QR image or `runescribe://` link carries the
> exact same mapping as the decoder file — anyone who has it can read your runes,
> so don't post it publicly.

---

## 🏛 Architecture

Rune Scribe is SwiftUI + Metal, organised into clear layers. All cryptography and
storage happen on-device; nothing is sent anywhere.

```mermaid
flowchart TD
    subgraph UI["🖼  Views (SwiftUI)"]
        RV[RootView<br/>splash · lock gate] --> CV[ContentView<br/>encode / decode]
        RV --> VSP[VideoSplashView]
        RV --> LV[LockView]
        RV --> ICV[ImportConfirmView]
        CV --> CLV[CipherLibraryView]
        CV --> SV[SettingsView]
        SV --> LIC[LicenseView]
        CLV --> QRD[QRDisplaySheet]
        CLV --> QRS[QRScannerView<br/>iOS only]
        RIT[RuneInscriptionText<br/>inscription animation]
        CV --> RIT
    end

    subgraph SVC["⚙️  Services"]
        KM[KeyManager<br/>cipher library]
        AL[AppLock<br/>PIN]
        CE[CipherEngine<br/>encode / decode]
        KC[KeychainService]
        IC[ImportCoordinator<br/>deep-link intake]
        QRG[QRCodeGenerator]
    end

    subgraph MOD["📦  Models"]
        RK[RuneKey]
        NC[NamedCipher]
        CL[CipherLibrary]
        RCS[RuneCharacterSet]
        RKE[RuneKeyExport]
        RCL[RuneCipherLink<br/>89-byte link / QR]
        ID[ImportedDecoder]
    end

    subgraph MTL["🌌  Metal"]
        RMV[RuneMetalView] --> MR[MetalRenderer] --> SH[(Shaders.metal)]
    end

    subgraph SYS["🔐  Apple frameworks"]
        CK[(CryptoKit<br/>AES-GCM · PBKDF2)]
        KCH[(Keychain)]
        MTK[(Metal / MetalKit)]
        AVF[(AVFoundation<br/>splash · QR scan)]
        CIM[(CoreImage<br/>QR generate)]
    end

    URL{{runescribe:// link}} --> IC
    IC --> ICV
    ICV --> KM
    CV --> KM
    RV --> AL
    CLV --> KM
    CV --> CE
    KM --> CE
    KM --> KC
    AL --> KC
    KM --> CL --> NC --> RK
    RK --> RCS
    KM --> RKE
    KM --> RCL
    KM --> ID
    QRD --> QRG --> CIM
    QRS --> AVF
    VSP --> AVF
    KC --> KCH
    KM --> CK
    AL --> CK
    MR --> MTK

    classDef ui fill:#1A1E30,stroke:#3A7FD5,color:#FFFFFF
    classDef svc fill:#0E1226,stroke:#D4971A,color:#EEBE45
    classDef mod fill:#11152a,stroke:#A0A8B8,color:#D6DAE6
    classDef mtl fill:#0E1226,stroke:#3A7FD5,color:#9FC0EE
    classDef sys fill:#080A1E,stroke:#A0A8B8,color:#A0A8B8
    class RV,CV,CLV,SV,LV,LIC,RIT,VSP,ICV,QRD,QRS ui
    class KM,AL,CE,KC,IC,QRG svc
    class RK,NC,CL,RCS,RKE,RCL,ID mod
    class RMV,MR,SH mtl
    class CK,KCH,MTK,AVF,CIM sys
```

---

## 🔐 Security & privacy

- **On-device only.** Encoding, decoding, and key storage all happen locally.
  Rune Scribe has no servers, no accounts, and no network calls.
- **Local sharing surfaces.** Sending a cipher hands a link, QR, or file to the OS
  share sheet — the app itself still makes no network calls. Inbound
  `runescribe://` links and scanned QR codes are validated entirely on-device
  (correct format, exactly 89 bytes, a true permutation) and never import without
  your one-tap confirmation — and your PIN first, if App Lock is on. iOS QR
  scanning uses the camera only to read the code; frames are processed on-device
  and never saved or sent.
- **Keys at rest.** Each cipher mapping is **AES-256-GCM** encrypted with a
  symmetric key that lives in the Keychain and never leaves the device.
- **The PIN is never stored.** Only a random salt and a **PBKDF2-HMAC-SHA256**
  derivation are kept (in the Keychain), compared in constant time. A persistent,
  escalating lockout blunts brute-force attempts.
- **Honest scope.** Rune Scribe is a personal-privacy and obfuscation tool with a
  fun Norse aesthetic — not a guaranteed-secure messenger. A shared cipher — a
  `.json` decoder file, a QR image, or a `runescribe://` link — is plaintext by
  design (so friends can read it); guard it like a key and don't post it publicly.

---

## 🧱 Project structure

```
RuneScrib/
├── App/          RuneScribApp (entry · runescribe:// links), AppDelegate
├── Models/       RuneKey, NamedCipher, CipherLibrary, RuneCharacterSet,
│                 RuneKeyExport, ImportedDecoder, RuneCipherLink, AppLicense
├── Services/     KeyManager, AppLock, KeychainService, CipherEngine,
│                 ImportCoordinator, QRCodeGenerator, Clipboard, FontRegistration
├── Views/        RootView, ContentView, CipherLibraryView, SettingsView,
│                 LockView, PINFlowView, LicenseView, ImportConfirmView,
│                 QRDisplaySheet
│   └── Components/  RuneTheme, RuneInscriptionText, PINPadView, QRScannerView,
│                    VideoSplashView, RuneScribButtonStyle, DecoderDocument
├── Metal/        RuneMetalView, MetalRenderer, Shaders.metal
└── Resources/    Assets, Noto Sans Runic font, raven-forge-spp-splash.mp4
RuneScribTests/   72 unit tests (cipher, library, PIN, decoder import,
                  friend round-trip, link/QR)
```

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonsm/XcodeGen) — `project.yml` is the source of
truth; regenerate with `xcodegen generate`.

---

## 🛠 Building

Requires Xcode 26+ on macOS.

```bash
# Regenerate the Xcode project from project.yml
xcodegen generate

# Build & test (macOS)
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS \
  -destination 'platform=macOS' test

# Build (iOS simulator)
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-iOS \
  -destination 'generic/platform=iOS Simulator' build
```

Two app targets — **RuneScrib-macOS** and **RuneScrib-iOS** — share one source
tree behind `#if os(macOS)` / `#if os(iOS)` splits. The macOS target ships with
App Sandbox + Hardened Runtime enabled for Mac App Store distribution.

Both targets register the **`runescribe://`** URL scheme (for tap-to-import
links), and the iOS target declares a camera-usage string for in-app QR scanning.
Those Info.plist keys — and the bundled splash video — are configured in
`project.yml`, the source of truth.

---

## ✅ Testing

**72 unit tests**, including a dedicated cross-person suite that proves the most
important promise — that a friend can decode your message on a different device:

| Suite | What it covers |
|---|---|
| `RuneScribTests` | character set, key generation, the cipher engine, exports |
| `CipherLibraryTests` | the cipher library model, mutations, legacy migration |
| `AppLockTests` | PIN format validation |
| `DecoderImportTests` | export → import → decode round trips |
| `FriendDecodeRoundTripTests` | full Alice → file → Bob flow, 700+ combinations |
| `RuneCipherLinkTests` | the compact link/QR permutation — encode, decode, round-trip, bad URLs |

---

## 📜 License

Rune Scribe is **proprietary** software, licensed (not sold) under the
[End-User License Agreement](EULA.md). The bundled *Noto Sans Runic* font is used
under the SIL Open Font License. © Raven Forge Software. All rights reserved.

---

## 📖 Documentation

Detailed guides, architecture deep-dives, and diagrams live in the
**[project wiki](https://github.com/flynn33/rune-scribe/wiki)**.

<div align="center">

**ᚱᚨᚹᛖᚾ ᚠᛟᚱᚷᛖ ᛋᛟᚠᛏᚹᚨᚱᛖ** · [ravenforgesoftware.com](https://ravenforgesoftware.com)

</div>
