# Rune Scribe Controlling Forsetti Policy

This document is the single repository authority for Rune Scribe's Forsetti architecture. It records the operator-defined application model and supersedes any conflicting audit conclusion, roadmap gate, architecture decision, migration plan, or historical compliance claim.

## Authority and source precedence

When sources conflict, apply them in this order:

1. Active operator instructions.
2. The active implementation package and its machine-readable controls.
3. Current repository behavior, compatibility identifiers, data formats, source paths, tests, and build configuration.
4. Factual findings from the Rune Scribe Forsetti Compliance Audit v2.0.
5. Locked product decisions that do not conflict with later operator clarification.
6. Nonconflicting factual observations from third-party audits.
7. General conventions.

Documentation alone cannot close a compliance finding. Closure requires applicable source, runtime behavior, guard behavior, tests, shipping-artifact evidence, and external-exhaustion evidence.

## 1. Framework role

Forsetti is the application operating environment and control plane. It owns:

- module discovery, validation, registration, activation, suspension, replacement, deactivation, and failure isolation;
- all cross-module commands, queries, state updates, events, and responses;
- capability authorization and per-operation lifecycle checks;
- operational I/O and platform side effects;
- persistent Settings registration, validation, storage, migration, synchronization hooks, and observation;
- module-scoped state storage and migration execution;
- operational timestamps, operation IDs, correlation IDs, session IDs, and revocable handles;
- resource loading, validation, caching, and invalidation;
- runtime-composed Theme catalog, unlock/selectability state, selected Theme Setting, and fallback;
- ingress from application/scene callbacks;
- presentation sessions for system facilities such as sharing, Messages, camera, Contacts, file pickers, external URLs, and audio.

## 2. UI Module role

Exactly one UI Module exists. It owns:

- the user-facing SwiftUI view tree;
- visual layout, navigation presentation, controls, typography, accessibility labels, animations, and local ephemeral presentation state;
- rendering of runtime-provided snapshots, results, errors, resources, and Theme tokens;
- collection of user intent and submission of typed actions to Forsetti.

The UI Module does **not** own:

- domain operations;
- peer-module objects;
- persistent Settings values or storage;
- platform permission decisions or sessions;
- Contacts, clipboard, Keychain, file, camera, share, Messages, audio, network, or external-URL operations;
- runtime IDs or timestamps;
- module activation or unlock truth.

A passive platform-view shell may remain in the UI Module only when it receives an opaque runtime presentation-session handle and cannot start, stop, configure, authorize, inspect, or extract data from the underlying platform facility.

## 3. Module role

A module is a replaceable room. It provides conforming:

- identity and compatibility metadata;
- domain functions;
- command and query handlers;
- state schema, defaults, reducers, validation, and migration descriptions;
- contribution catalogs;
- resource declarations;
- Settings declarations;
- progression gates or rule data where appropriate;
- health and diagnostics;
- lifecycle behavior.

A module does not:

- import or call another module implementation;
- read another module's persistence;
- retain a peer-module service object;
- retain a raw platform adapter;
- create persistent Settings outside Forsetti;
- activate itself;
- coordinate another module;
- discover another module's bundle;
- expose its implementation object through a service registry.

## 4. Runtime mediation test

A cross-module operation is compliant only if the runtime remains in the path for **every call**:

```text
consumer module or UI view
→ runtime-owned client/dispatcher
→ source lifecycle and capability check
→ destination lookup and generation check
→ runtime operation ledger
→ destination standard port invocation
→ normalized runtime result/state channel
→ consumer
```

A client may be retained if it contains only a runtime endpoint identity and revocable runtime reference. It may not contain, close over, or return the provider implementation.

## 5. I/O test

A module request for I/O is compliant only if:

```text
module
→ typed runtime I/O request
→ runtime validates module, capability, namespace, bounds, and lifecycle
→ runtime invokes its platform adapter
→ runtime normalizes/redacts result
→ module receives only permitted data or an opaque handle
```

## 6. Settings test

A Setting is compliant only if:

- its descriptor is registered with Forsetti;
- Forsetti owns the persisted value and migration;
- the UI renders a framework snapshot and submits a mutation;
- no module uses `@AppStorage`, `UserDefaults.standard`, or direct preference files.

## 7. Theme test

A Theme Module:

- is non-UI;
- uses a unique module ID and shared `theme-provider` policy class;
- exposes a discovery descriptor, Theme contribution, Script/resource descriptors, semantic tokens, and Artifact catalog;
- owns no unlock rules, Settings screen, navigation, system I/O, or direct rendering;
- is discovered and validated by Forsetti;
- becomes selectable only when the runtime reads a completed gate from Progression;
- is activated/deactivated by the runtime according to selection and lifecycle policy;
- cannot take down Core/UI when optional and invalid;
- is rendered by the sole UI Module through the common scaffold.

## 8. Permanent dependency prohibition

The repository must reject all of the following:

- Swift Package dependency on a Forsetti repository;
- git submodule or subtree containing Forsetti;
- vendored Forsetti source;
- binary framework or XCFramework named Forsetti;
- build script that clones/downloads Forsetti;
- Swift import of external Forsetti products;
- developer-machine path dependency to Forsetti.

App-owned Rune Scribe code may use the word Forsetti to name its architecture and policy, but it must not ship external Forsetti code.
