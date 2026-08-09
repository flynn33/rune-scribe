# ADR-RS-009: Privacy-Safe Relationship Token

**Status:** Accepted in part; cross-device token reconciliation blocked
**Date:** 2026-08-09

## Decision

Core creates a random 256-bit per-relationship seed and derives the opaque token as
`HMAC-SHA256(deviceRelationshipSecret, "runescribe.relationship.v1" || seed)`. The
device relationship secret is random Keychain-held material; the seed is persisted
encrypted with the relationship. Neither input is a name, telephone number, email
address, Contacts identifier, cipher key, public cipher ID, or any other user identity.
Without the device secret the token is not reversible or reproducible from repository
metadata.

Core receives the secret through a narrow injected secure-value contract. Deterministic
tests use a fixed in-memory secret and never read the operator's login Keychain.

Only this token may cross into progression events. It is not displayed, logged, placed
in a share package, sent to Game Center, or exposed to a Theme Module. Retaining and
relinking the same relationship retains the token; creating a genuinely new cipher
relationship creates a new token.

Tokens from one local device namespace are safe for local set membership and event
deduplication. The locked specification and ADR-RS-008 require set-union merge for
relationship-token records, but a token keyed only by a device-held secret will not be
stable for the same relationship on another device. The derivation and qualification
rule that makes those requirements compatible is therefore unresolved.

This record does not prohibit the required set union, redefine the locked cloud merge
policy, or freeze a device-only threshold. Cross-device relationship qualification is
blocked until a successor decision demonstrates an identity-free stable namespace or
another privacy-preserving rule that remains deterministic under set union. The
successor must cover device replacement, restore, relinking, collision resistance,
unlink/recreate behavior, migration, and duplicate suppression before cloud sync or a
cross-device distinct-relationship Achievement is enabled.

## Consequences

- Progression can count eligible relationships without learning contact identity.
- A cloud record cannot be used as a contact directory.
- Local qualification can be tested without selecting an unsafe cross-device identity
  mechanism.
- Cross-device distinct-relationship qualification and token merge remain blocked; the
  specification's set-union rule remains authoritative.
