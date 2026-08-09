# Forsetti Migration Baseline

## Purpose

This record freezes the compatibility-sensitive Rune Scribe behavior observed before the architecture migration. The fixtures use deterministic synthetic values and contain no user data. Later phases must continue to read these bytes and preserve the identifiers and behaviors below.

## Repository snapshot

| Item | Audited value |
|---|---|
| Repository | `/Users/jimdaley/GitHub/Rune-Scribe` |
| Package source baseline | `793f275b86ef16aa3d2606318cccd9714b7af95e` |
| Preflight branch | `docs/app-store-submission` |
| Preflight HEAD | `2d3d371e51d95ff4c8d9b6dd9e55465176f986d6` |
| Application version | `1.0.33` (`33`) |
| Swift mode | Swift 6 |
| Targets | `RuneScrib-macOS`, `RuneScrib-iOS`, `RuneScribTests` |
| Deployment targets | macOS 15.0, iOS 17.0 |
| Bundle identifier | `com.runescribe.app` |
| Package dependencies | None |

Every one of the 72 source/test hashes in the instruction-package inventory matched the tree at `793f275b86ef16aa3d2606318cccd9714b7af95e`. This makes that revision the byte-exact comparison point for the uploaded `1.0.29` (`29`) baseline.

At preflight, the branch was one commit ahead of its remote and contained four pre-existing configuration edits: the macOS entitlements, the Xcode project, and both shared schemes. Those paths were preserved while the authoritative configuration discrepancy was investigated.

## Audited local delta

No application source, test, configuration, or resource was removed or renamed relative to the package baseline.

| Area | Package baseline | Local pre-migration source | Delta |
|---|---:|---:|---:|
| Application Swift | 51 files / 6,285 lines | 51 files / 6,588 lines | 9 files changed, +303 lines |
| XCTest source | 21 files / 1,524 lines / 126 tests | 22 files / 1,802 lines / 148 tests | 1 file added, 2 changed, +22 tests |
| Resource files | 16 plus one Metal shader | unchanged | no path or byte changes |

Changed application files:

- `RuneScrib/App/AppDelegate.swift`
- `RuneScrib/App/RuneScribApp.swift`
- `RuneScrib/Services/FileRouter.swift`
- `RuneScrib/Services/MessageSend.swift`
- `RuneScrib/Views/CipherLibraryView.swift`
- `RuneScrib/Views/Components/MessageComposeView.swift`
- `RuneScrib/Views/Components/VideoSplashView.swift`
- `RuneScrib/Views/ContentView.swift`
- `RuneScrib/Views/RootView.swift`

Changed or added tests:

- `RuneScribTests/FileRouterTests.swift`: 6 to 18 tests
- `RuneScribTests/MessageSendTests.swift`: 5 to 11 tests
- `RuneScribTests/SplashAssetScheduleTests.swift`: 4 new tests

Newer behavior that is part of the migration contract:

- all macOS, iOS application-delegate, iOS scene-delegate, SwiftUI URL, and browsing-user-activity inputs funnel through one inbound-open route;
- iOS scene callbacks retain cold-launch and warm `.runescribe` document intake;
- unreadable and unrecognized files produce visible typed outcomes instead of disappearing silently;
- a first-delivery Messages send preflights attachment support, supplies a real temporary `.runescribe` file, checks acceptance, cleans it up, and consumes delivery only after the required attachment was accepted and the message was sent;
- the Cipher Library share control sends the tappable `runescribe://import` link, while explicit Export continues to produce a file;
- the intro video is offered at most once per 30 days using `rf.splash.lastShownAt`.

Repository configuration also gained issue, pull-request, and funding templates. The version workflow stopped creating and publishing release tags. These files must not be discarded as part of source movement.

## Toolchain and baseline build evidence

| Item | Evidence |
|---|---|
| Xcode | 26.2, build 17C52 |
| Swift | 6.2.3; swift-driver 1.127.14.1; `arm64-apple-macosx26.0` |
| XcodeGen | 2.45.4 |
| Available iOS runtimes | 18.6, 26.0, 26.2 |
| Project generation | Isolated XcodeGen run completed successfully |
| Targets/schemes | Both application targets, the test target, and both shared schemes were listed successfully |

The canonical macOS command was:

```sh
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -resultBundlePath /tmp/RuneScribe-Forsetti-Run.bd3t1W/Baseline-macOS.xcresult test
```

It built successfully but the test bundle could not load because the application used Apple Development team `9AQ2C2838M` while the tests were ad-hoc signed. This was a pre-existing signing/configuration defect, not an assertion failure. The isolated ad-hoc retry passed all 144 tests discovered by that project:

```sh
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM='' CODE_SIGN_STYLE=Manual -resultBundlePath /tmp/RuneScribe-Forsetti-Run.bd3t1W/Baseline-macOS-adhoc.xcresult test
```

Four source-defined splash tests were absent from that result because the committed project had not incorporated the newer test file. Project membership is a baseline generated-project defect and must be rechecked after project regeneration. `CompatibilityBaselineTests` was added after this historical run and is likewise not represented by the 144-test result.

After project regeneration added both missing suites, the focused compatibility command passed all 9 characterization tests:

```sh
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -derivedDataPath /tmp/RuneScribe-Forsetti-Run.bd3t1W/DerivedData-compatibility CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM='' CODE_SIGN_STYLE=Manual test -only-testing:RuneScribTests/CompatibilityBaselineTests
```

The result bundle is `/tmp/RuneScribe-Forsetti-Run.bd3t1W/DerivedData-compatibility/Logs/Test/Test-RuneScrib-macOS-2026.08.08_09-37-11--0500.xcresult`.

The authoritative XcodeGen reconciliation then restored all test membership,
preserved the three macOS capabilities in both the entitlement plist and Xcode
26 build settings, and made Debug host/test signing consistent. A first full
signed-host run exposed a separate baseline hazard: singleton-backed tests could
block while reading the operator's real Keychain. `KeychainService` now selects
an in-memory, lock-protected account store only when XCTest supplies
`XCTestConfigurationFilePath`; normal application launches continue to use the
unchanged production service and account identifiers.

With that isolation seam, the canonical regenerated-project test passed all 157
tests with no command-line signing override:

```sh
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -derivedDataPath /tmp/RuneScribe-Forsetti-Run.bd3t1W/DerivedData-p0-final -resultBundlePath /tmp/RuneScribe-Forsetti-Run.bd3t1W/P0-final-macOS.xcresult test
```

The regenerated generic iOS Simulator build also passed:

```sh
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/RuneScribe-Forsetti-Run.bd3t1W/DerivedData-p0-final-iOS -resultBundlePath /tmp/RuneScribe-Forsetti-Run.bd3t1W/P0-final-iOS.xcresult CODE_SIGNING_ALLOWED=NO build
```

Two consecutive generations produced identical project, scheme, plist, and
entitlement hashes. The signed macOS test host contained the sandbox, Contacts,
and user-selected read/write entitlements.

The first generic iOS Simulator build failed because the installed Metal toolchain was not yet available to Xcode. After the mounted toolchain became active, this unsigned retry passed:

```sh
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The successful retry used `/tmp/RuneScribe-Forsetti-Run.bd3t1W/DerivedData-baseline-iOS-retry`.

## Frozen wire fixtures

### Cipher payload v3

The accepted compact fixture is 129 bytes:

```text
AwABAgMEBQYHEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8fHh0cGxoZGBcWFRQTEhEQDw4NDAsKCQgHBgUEAwIBAG5vdG8tc2Fucy1ydW5pYwAAAAABYVtsEWaoxRgW3BU2eErL9IZUfjvtA9v91wkQ4QBmeTsMHGhN
```

It freezes version 3, public ID bytes `00...07`, key bytes `10...2f`, the reverse `31...0` decorative mapping, bundled font ID `noto-sans-runic`, font version 1, and the bundled-font digest below. Decoding and re-encoding must reproduce all 129 bytes exactly.

The same payload must parse from both:

- `runescribe://import?v=3&p=<base64url>`
- `https://[www.]ravenforgesoftware.com/rune-scribe/import?v=3&p=<base64url>`

Checksum corruption and byte truncation must fail closed.

### Message payload v1

The accepted fixture is 151 bytes:

```text
AQEIQmFzZWxpbmUABQGqu8zdAwABAgMEBQYHEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8fHh0cGxoZGBcWFRQTEhEQDw4NDAsKCQgHBgUEAwIBAG5vdG8tc2Fucy1ydW5pYwAAAAABYVtsEWaoxRgW3BU2eErL9IZUfjvtA9v91wkQ4QBmeTsMHGhNp8lXWg==
```

It freezes version 1, sender `Baseline`, envelope bytes `01 aa bb cc dd`, and the embedded v3 cipher above. Decoding and re-encoding must reproduce all 151 bytes exactly. Checksum corruption and truncation must fail closed.

### Encrypted contact store

The frozen AES-GCM combined fixture is:

```text
oKGio6SlpqeoqaqrnToKSDe4a9AMR73iK1ijsR7YOHPmxGBWx3UE7xuJTyPiRnfPnxJjDXKsNPg5V7PJdytreFLgKlNxbjtulEC1gISMtV4SicaEnZGPdO63gtugbome54P4CYsZV/TUuGG2/+xExWbdraHF+S1hsL3YGRZjVZvoArlhA+27ydU8nj7nK+tdsSPzclswkO5SL+m35anBDpCzleHfkJHX3KhBWaV9PYuUByF492tHAEPw1ZMSR4n9ZifaHLiyC2Qhu77yzdD6MSN+2D5mOc60vQ==
```

It uses AES-256 key bytes `00...1f` and nonce bytes `a0...ab`. The plaintext is contact-book version 1 with one manual contact:

- ID `00000000-0000-0000-0000-000000000001`
- display name `Baseline`
- phone `+15551234567`
- email `baseline@example.com`
- creation date `Date(timeIntervalSinceReferenceDate: 0)`

The file must continue to load from an injected `contacts.enc` location through `ContactStore`.

## Resource anchor

`NotoSansRunic-Regular.ttf` has the fixed SHA-256 digest:

```text
615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b
```

The bundled `FontRef` remains `noto-sans-runic`, version 1, with this digest.

## Persistence and PIN anchors

| Area | Frozen behavior |
|---|---|
| Keychain service | `com.runescribe.keystore` |
| Keychain accounts | `symmetricKey`, `cipherLibrary`, `appPin`, `pinThrottle` |
| Keychain accessibility | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Cipher library | Schema version 1; ISO-8601 JSON encrypted as AES-GCM combined data under `cipherLibrary`; AES-256 key bytes under `symmetricKey` |
| Contacts | `RuneScribContacts/contacts.enc`; JSON with deferred `Date` encoding; AES-GCM combined data using the same symmetric key; atomic writes and complete file protection on iOS |
| Imported fonts | `RuneScribFonts`; content-addressed filename `<sha256>.ttf` |
| PIN | Exactly four ASCII digits; record version 1; 16-byte random salt; PBKDF2-HMAC-SHA256; 120,000 iterations; 32-byte derived hash |
| PIN throttle | Persisted under `pinThrottle`; lockout begins at attempt 5 with 15, 30, 60, 120, then 300 seconds |
| Splash preference | `rf.splash.lastShownAt`; 30-day replay interval |

The fixed PIN derivation vector is:

```text
PIN:        1234
salt:       000102030405060708090a0b0c0d0e0f
iterations: 120000
derived:    5070321ca34dbdafe9b25371d1c0f83bcafe073fbae1f2274f00a6d6c68e9899
```

## Document and routing anchors

| Anchor | Value |
|---|---|
| URL scheme | `runescribe` |
| Cipher custom-link host | `import` |
| Legacy web host/path | `ravenforgesoftware.com/rune-scribe/import` |
| Document UTI | `com.runescribe.runescribe` |
| Extension | `.runescribe` |
| Cipher payload | version 3, 129-byte compact form |
| Message payload | version 1 |

These values and fixture bytes are migration gates. Changes require an explicit compatibility decision and replacement evidence rather than silent regeneration.
