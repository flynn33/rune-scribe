# Rune Scribe Owner-Test Candidate Handoff

**Candidate status:** `RELEASE_CANDIDATE_READY`<br>
**Version/build:** `1.0.39 / 39`<br>
**Source manifest:** `47a1aa1c98ab120164223b53b4430a5dbd7d07f77a49fb57a25fa475a01a362d`<br>
**Source revision:** `5642f169a72eccd8615e284816db63a75a0a18c1`

## Report authority

The outer candidate ZIP is a deterministic envelope. Its internal schema-valid `CompletionReport.json` and `CompletionReport.md` truthfully bind the nested `Rune-Scribe-Owner-Test-Payload-v1.0.zip`. The adjacent external reports beside the outer ZIP truthfully bind the finalized outer-envelope SHA-256.

## Included products

- `RuneScrib-macOS-Release.app.zip`
- `RuneScrib-iPhoneSimulator-Release.app.zip`
- `RuneScrib-iPadSimulator-Qualification.json`
- `SOURCE-MANIFEST.json`
- `Screenshot-Index.md` and `Screenshots/`
- `TestSummaries/Test-Summary.json`

## Verify package contents

```bash
shasum -a 256 -c SHA256SUMS
```

## macOS launch

```bash
unzip RuneScrib-macOS-Release.app.zip -d macos-app
open macos-app/RuneScrib.app
```

No distribution signature or notarization is claimed.

## iPhone Simulator install and launch

Device: `iPhone 17 Pro` / `iOS 26.2` / `1563B47A-700D-4AEF-A8D5-89780C581F83`

```bash
xcrun simctl bootstatus 1563B47A-700D-4AEF-A8D5-89780C581F83 -b
unzip RuneScrib-iPhoneSimulator-Release.app.zip -d iphone-app
xcrun simctl install 1563B47A-700D-4AEF-A8D5-89780C581F83 iphone-app/RuneScrib.app
xcrun simctl launch 1563B47A-700D-4AEF-A8D5-89780C581F83 com.runescribe.app
```

## iPad Simulator install and launch

Device: `iPad Pro 13-inch (M5)` / `iOS 26.2` / `77D54A1F-0818-4761-B946-D7723490F6B3`

```bash
xcrun simctl bootstatus 77D54A1F-0818-4761-B946-D7723490F6B3 -b
unzip RuneScrib-iPhoneSimulator-Release.app.zip -d ipad-app
xcrun simctl install 77D54A1F-0818-4761-B946-D7723490F6B3 ipad-app/RuneScrib.app
xcrun simctl launch 77D54A1F-0818-4761-B946-D7723490F6B3 com.runescribe.app
```

## Reset commands

```bash
xcrun simctl uninstall 1563B47A-700D-4AEF-A8D5-89780C581F83 com.runescribe.app
xcrun simctl keychain 1563B47A-700D-4AEF-A8D5-89780C581F83 reset
xcrun simctl uninstall 77D54A1F-0818-4761-B946-D7723490F6B3 com.runescribe.app
xcrun simctl keychain 77D54A1F-0818-4761-B946-D7723490F6B3 reset
```

## Seed commands

```bash
xcrun simctl spawn 1563B47A-700D-4AEF-A8D5-89780C581F83 launchctl setenv RUNESCRIBE_QUALIFICATION_UNLOCK_CODEX moonleaf
xcrun simctl spawn 77D54A1F-0818-4761-B946-D7723490F6B3 launchctl setenv RUNESCRIBE_QUALIFICATION_UNLOCK_CODEX moonleaf
```

## Candidate review focus

- Norse and Elven-series visual presentation.
- Quick Share and Customize Share.
- Cipher Library themed invitation sharing.
- Appearance defaults, Vault, and Archive.
- Emergency Base Theme warning and decode fallback.
- Encode/decode and legacy import compatibility.

These are review suggestions, not unfinished engineering gates.

## External non-gating boundaries

- App Store Connect records.
- live CloudKit account/container.
- live Game Center sandbox.
- distribution signing and public upload.

No physical hardware, live account, public upload, release tag, notarization, TestFlight submission, App Store submission, or staged rollout was required or performed.
