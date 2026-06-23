# Rune Scribe — Phase 1: Real Encryption Core & New Cipher Model

**Status:** Draft for review
**Date:** 2026-06-23
**Phase:** 1 of 4

## Programme context

This is Phase 1 of a four-phase delivery of the "real encryption" scope:

1. **Encryption core + new cipher model** — this spec.
2. Cipher package + exchange (font transport, decorative-mapping packaging + rotation, richer integrity/versioning).
3. Contacts + per-contact ciphers.
4. Apple Messages integration.

Each phase runs spec → implementation plan → implementation → PR, reviewed at every step.

## Goal

Replace the rune-substitution mechanism with real Apple-native (CryptoKit) message
encryption, introduce the new symmetric-key cipher model, and update compose / read /
cipher-sharing to use it — while keeping every current user-facing workflow working.

Runes stop being the security and become a decorative representation of the encrypted
bytes. The user-facing term **cipher** stays.

## Non-goals (handled in later phases)

- The rune **font** travelling inside the shared cipher package (Phase 2).
- Decorative-mapping **rotation** (Phase 2) — Phase 1 uses a per-cipher *static* decorative mapping.
- Contacts and per-contact ciphers (Phase 3).
- Apple Messages compose/send integration (Phase 4).

## Crypto model (decided)

- **Symmetric shared secret.** A cipher = one 256-bit symmetric key
  (`SymmetricKey(size: .bits256)`). Whoever holds the cipher can both encrypt and
  decrypt. Matches the scope ("possess the matching cipher key"), the existing
  share-the-cipher UX, and needs no PKI, server, or network.
- **AEAD = AES-GCM** (CryptoKit `AES.GCM`) — the same primitive already used for
  at-rest storage. A fresh random 96-bit nonce per message. The GCM authentication
  tag guarantees that a wrong key or any tampering fails to open and never yields
  bogus plaintext.
- **Accepted property:** anyone holding a cipher can read all messages encrypted
  under it, and the sender is not cryptographically identified. (Asymmetric /
  sender-authentication is deferred; the message and cipher formats carry a version
  field so it could be added later without a breaking change.)

## The new cipher model

Replace `RuneKey` (permutation) + `NamedCipher` with a `Cipher` value type:

- `id: UUID` — library entry id.
- `label: String` — user-facing name.
- `origin: .generated | .imported`.
- `createdAt: Date`.
- `formatVersion: Int` — cipher schema version.
- `publicID: Data` (8 random bytes) — **non-secret** stable identifier for the cipher,
  used **only** in the share/import payload (dedup, and recognizing an updated cipher
  for a contact). It is **not** placed in messages. Never derived from the key.
- `keyMaterial: Data` (32 bytes) — the secret AES-256 key. Only ever serialized into
  the Keychain-encrypted library blob and the user-initiated share payload. Never
  logged, never exposed in any non-secret surface.
- `decorativeMapping` — the rune display mapping (a permutation over the rune
  alphabet), kept for the visual identity. **Static per cipher in Phase 1.**

`Cipher` is `Codable` (for the encrypted library) and `Equatable`.

## Message format

**Envelope (binary), produced on compose:**

- `version` (1 byte) — message format version.
- `sealed` (variable) — `AES.GCM.SealedBox.combined` (12-byte nonce ‖ ciphertext ‖
  16-byte tag) over the UTF-8 plaintext, using the cipher's key.

The message carries **no cipher identifier** — see "Receiver cipher selection" below.

**Decorative rune string (what the user sees / copies / sends):**

- `RuneCodec` renders the envelope bytes to runes using the cipher's
  `decorativeMapping`: an exact, reversible base-N encoding over a fixed rune alphabet,
  with the per-cipher permutation applied for visual variation. (Concretely, a
  base-32-style encoding over a 32-rune alphabet; the final alphabet size is an
  implementation-plan detail.)
- **Alphabet choice:** the decorative alphabet is drawn from runes with broad
  system-font coverage (core Elder Futhark) so a pasted message renders consistently
  wherever it lands — including the Messages app, which uses the **system** font, not
  Rune Scribe's bundled one. The cipher's own font (Phase 2) then guarantees fidelity
  *inside* Rune Scribe and covers any extended or custom glyphs.
- This layer is purely cosmetic — it carries no security. The security is the AES-GCM
  layer beneath it.

**Read / decrypt:**

1. `RuneCodec` maps the rune string back to envelope bytes.
2. **Receiver cipher selection:** identify the cipher by *trying the stored ciphers* —
   the AEAD tag authenticates exactly one (a wrong key fails to open; false-match
   probability ≈ 2⁻¹²⁸). This needs no in-message identifier and works even on a bare
   copy/paste with no sender identity. Later phases optimize the order by trying the
   message's contact's cipher first (Phase 3), but try-stored-ciphers stays the
   correctness fallback. If nothing opens it, surface "no matching cipher — import the
   sender's cipher first."
3. `AES.GCM.open(sealed, using: cipher.key)` → plaintext. Failure (wrong key or
   tampering) surfaces a clear "couldn't decrypt with this cipher" error and never
   produces bogus output.

## Cipher sharing (kept working; compact payload)

The existing QR / `runescribe://import` deep-link / file / clipboard import paths are
retained. Their payload changes from an 89-byte permutation to a compact
**`CipherSharePayload`**:

- `version`, `publicID` (8 bytes), `keyMaterial` (32 bytes), and the
  `decorativeMapping` permutation needed to render runes, plus an integrity check
  (checksum). Roughly 50–90 bytes — comfortably within QR and URL limits.
- One validated import funnel (as today) reconstructs a `Cipher` and adds it to the
  library; the import-confirmation sheet behaviour is unchanged.
- **Security note:** sharing a cipher transmits secret key material by the user's
  deliberate action — exactly as the permutation was the shared secret before. The
  transport (QR / deep-link) is the user's chosen channel; Rune Scribe adds no network.
- The rune **font bytes**, decorative-mapping packaging niceties, and rotation are
  Phase 2. Phase 1 ships the key + the static decorative mapping, so both sharing and
  rendering work end to end.

## At-rest storage & app-lock (unchanged mechanism)

- The cipher library (now holding `keyMaterial`) continues to be AES-GCM-encrypted
  under the Keychain-held symmetric key via `KeyManager` / `KeychainService`
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- App-lock PIN + failed-attempt throttling unchanged.
- Invariants: key material and plaintext are never written to logs; storage writes
  remain all-or-nothing.

## Obsolete code removed (beta; no back-compat, per scope §4/§16)

- `CipherEngine` substitution encode/decode → replaced by `MessageCryptor` + `RuneCodec`.
- `RuneKey` permutation-as-key and its reverse mapping → replaced by `Cipher`.
- `RuneKeyExport` verbose JSON format.
- `RuneCipherLink` permutation payload → replaced by `CipherSharePayload`.
- Legacy single-key / decoder Keychain migration in `KeyManager.load()`.
- `ImportedDecoder` permutation parsing.

The decorative rune **mapping concept**, the runic pool, and the bundled font are kept
and repurposed for display.

## Components (object-oriented, modular — one responsibility each)

- **`Cipher`** (Model) — id, label, origin, publicID, 256-bit key material, decorative
  mapping. Replaces `RuneKey` / `NamedCipher`.
- **`CipherLibrary`** (Model) — collection + active selection + pure mutations (kept;
  retyped to `Cipher`).
- **`MessageCryptor`** (Service) — `seal(plaintext, with: Cipher)` /
  `open(envelope, with: Cipher)`; owns AES-GCM. No UI, no storage.
- **`MessageEnvelope`** (Model) — versioned framing: build / parse
  `[version][sealed]`.
- **`RuneCodec`** (Service) — reversible bytes ↔ rune string via a cipher's decorative
  mapping. No crypto.
- **`CipherSharePayload`** (Model) — compact, validated share / import payload (replaces
  `RuneCipherLink`); encodes/decodes the QR / deep-link / file forms.
- **`KeyManager`** (Service, kept) — owns the library; create / import / rename /
  delete / select; persistence via Keychain; builds the share payload.
- **`KeychainService`** (Service, kept) — unchanged low-level Keychain.
- **`ImportCoordinator`** (Service, kept) — deep-link / QR / clipboard intake; updated
  to the new payload.
- **Views** (kept, rewired) — compose / read, library, import-confirm, QR display —
  now driving `MessageCryptor` / `RuneCodec` / the new payload. No security logic in
  views.

## Testing

- Encrypt → decrypt round-trip returns the original plaintext (including Unicode,
  emoji, newlines).
- Decrypting with the wrong cipher fails and yields no plaintext.
- A single flipped byte anywhere in the envelope is rejected by the AEAD tag.
- `RuneCodec` encode → decode is exact for arbitrary byte input.
- The receiver selects the correct cipher by trying its stored ciphers; an unrelated
  cipher never opens a message, and a message with no matching cipher fails cleanly.
- Share payload → import reconstructs an identical, working cipher (encrypt on one
  side, decrypt on the other).
- The library persists and reloads through the (encrypted) Keychain with the new model.
- No plaintext or key material appears in any log output.

## Exchange model (captured; mostly Phases 2–4)

The agreed contact-centric exchange flow is recorded here because it is why a message
needs no cipher-id hint:

- Ciphers are exchanged with **known contacts**. The **first** message to a new contact
  automatically sends the cipher (key) package alongside it; later messages to a known
  contact send **no** key.
- If the user **changes** a contact's cipher, the new key rides along with the next
  message and is imported by the receiver **before** decryption.
- A recipient **without** the app is guided to the App Store, then the message's **deep
  link auto-imports** the cipher into the Keychain-backed library.
- A recipient **with** the app taps the message and chooses **Copy** or **Open in Rune
  Scribe**.

Phase 1 keeps the deep-link / QR / file import working with the new key payload; the
auto-send-on-first-message and contact logic land in Phases 3–4.

## Risks / decisions

- **Beta break:** existing beta (permutation) ciphers will not decode old messages —
  explicitly authorized by the scope. No migration is shipped.
- **No message metadata:** messages carry no cipher identifier; the receiver identifies
  the cipher by trying its stored ciphers (AEAD-authenticated). Keeps *which* cipher
  private and works on plain copy/paste. Trade-off: a few microseconds of trial
  decryption — negligible.
- **Overhead:** AEAD adds ~28 bytes (nonce + tag) per message, so the rune output is a
  little longer than the old substitution output — acceptable.

## Acceptance (Phase 1 subset of scope §16)

Real CryptoKit encryption for messages; substitution is no longer the security; the
user concept stays "cipher"; create / select / share (QR + deep-link + file) / import
all work with the new model; AEAD integrity (no bogus plaintext on wrong key or
tampering); at-rest + app-lock intact; obsolete beta cipher and migration code removed;
implementation is object-oriented, modular, and Apple-native.
