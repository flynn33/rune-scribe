# Rune Scribe Contracts and Capabilities

## Boundary model

[`RuneScribeContracts`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts) is the only product-semantic surface shared by Core, UI, Platform, and hosts. It is Foundation-first and contains values and protocols, not implementations or orchestration.

This report records committed cleanup snapshot `01e2fcf655a3139a856787fc96f17a58db3f3ad0`.

The boundary follows four rules:

1. Module implementations never import or cast to another module implementation.
2. A module receives only its `ModuleContext`, declared neutral services, and composition-time UI dependencies that do not expose Core or Platform implementations.
3. Service access is declared twice: statically in the manifest/compiled descriptor and centrally in runtime policy. Both declarations must authorize the operation.
4. Sensitive values are minimized. Keys and persistence entities never enter UI contracts; PIN values are non-serializable and closure-scoped; plaintext results that UI must render are non-`Codable`; safe events contain only counts, IDs, phases, timestamps, and failure categories.

The full physical dependency direction is in [`ModuleGraph.md`](ModuleGraph.md).

## Stable vocabulary

[`Identifiers.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/Identifiers.swift) defines typed identifiers for modules, roles, capabilities, services, events, and directed messages. [`DomainIdentifiers.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/DomainIdentifiers.swift) defines typed cipher, contact, message, import, share-artifact, inbound-input, and font identities.

The current module identities are:

| Purpose | Identifier |
|---|---|
| Core module | `com.runescribe.module.core` |
| Primary UI module | `com.runescribe.module.ui` |
| Core role | `runescribe.core` |
| Primary UI role | `runescribe.ui.primary` |
| Host role | `application.host` |

Capabilities are closed over [`RuneScribeCapabilities.all`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimePolicyVocabulary.swift). Unknown names are rejected rather than ignored. There is no umbrella capability.

## Shipping module declarations

| Module | Requested capabilities | Required services | Required roles |
|---|---|---|---|
| Core | `runtime.service.publish`, `runtime.events.publish`, `storage.keychain`, `storage.protected-files`, `files.inbound.read`, `storage.share-artifacts`, `resources.read`, `fonts.register`, `contacts.read`, `clipboard.read`, `clock.read`, `uuid.generate`, `application.inbound-input` | secure values, protected files, bounded inbound file reader, share artifact store, app resources, font registrar, Contacts access, clipboard read, clock, UUID | none |
| UI | `runtime.service.resolve`, `application.commands`, `application.state.read`, `ui.root`, `resources.read`, `clipboard.write`, `ui.share`, `ui.messages` | application facade, app resources, clipboard write | `runescribe.core` |

The JSON manifests are [`Core`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Resources/module-manifest.json) and [`UI`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Resources/module-manifest.json). Their compiled descriptors are in [`CoreModule.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreModule.swift) and [`UIModule.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/UIModule.swift).

The runtime checks equality for module identity, version, kind, entry point, role, requested capabilities, required services, and required roles. Published services are compiled descriptor declarations: Core declares `RuneScribeApplicationService` and `RuneScribeInboundInputService`. Runtime activation verifies both were actually published before marking Core active.

Both current manifests have no entitlement requirement, and the runtime uses [`AlwaysEligibleProvider`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Module.swift). `ModuleEligibilityProviding` remains the single injected eligibility seam; there is no duplicate entitlement API and no purchase, achievement, unlock, or progression implementation.

## Service policy

[`RuntimePolicy.patternBFoundation`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Policy.swift) contains the complete current service map.

| Service ID | Required capability | Publisher role | Consumer role | Shipping implementation or publisher |
|---|---|---|---|---|
| `RuneScribeApplicationService` | `runtime.service.resolve` | Core | primary UI | Core application-service actor |
| `RuneScribeInboundInputService` | `application.inbound-input` | Core | host | Core application-service actor |
| `SecureValueStore` | `storage.keychain` | host | Core | `AppleKeychainStore` |
| `ProtectedFileStore` | `storage.protected-files` | host | Core | `AppleProtectedFileStore` |
| `InboundFileReader` | `files.inbound.read` | host | Core | `AppleInboundFileReader` |
| `ShareArtifactStore` | `storage.share-artifacts` | host | Core | `AppleShareArtifactStore` |
| `ApplicationResourceLocator` | `resources.read` | host | Core, primary UI | `BundleApplicationResourceLocator` |
| `SystemFontRegistrar` | `fonts.register` | host | Core | `CoreTextFontRegistrar` |
| `ContactAccessService` | `contacts.read` | host | Core | `SystemContactAccessService` |
| `ClipboardService` | `clipboard.read` | host | Core | `SystemClipboardService` |
| `ClipboardWriteService` | `clipboard.write` | host | primary UI | `SystemClipboardService` |
| `ClockService` | `clock.read` | host | Core | `SystemClock` |
| `UUIDService` | `uuid.generate` | host | Core | `SystemUUIDProvider` |

Clipboard read and write intentionally use different protocols, service IDs, and capabilities even though one system adapter implements both. Core can inspect the clipboard only for the existing import behavior; UI can copy user-selected output but cannot resolve the read side.

The application facade is mapped through `runtime.service.resolve`; the UI's additional `application.commands` and `application.state.read` declarations record its product authority and are independently role-validated. UI presentation capabilities (`ui.root`, `ui.share`, and `ui.messages`) likewise describe its narrow role without granting a generic platform-service escape hatch.

## Default-deny resolution

To register a module, the runtime requires every requested capability to be in the vocabulary and allowed for the module role. For every required service, it also requires:

1. a service-access rule exists;
2. the descriptor requests that rule's capability;
3. the capability is allowed for the module role;
4. the rule lists the role as a consumer.

For a published service, the descriptor must request `runtime.service.publish`, the service must have a policy rule, and the role must be an allowed publisher.

At use time, [`ModuleContext`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Services.swift) repeats the relevant declaration, capability, and role checks. `resolveService` then performs a typed lookup. `publishService` records the owning module. An invalidated lifecycle lease denies later service, event, or message use. Module-owned services are removed during invalidation.

The host has two narrow runtime APIs:

- `registerHostService` accepts only services whose policy lists `application.host` as publisher;
- `resolveHostService` works only while the runtime is running and only for a service whose policy lists the host as consumer. The current sole host-resolved module service is `RuneScribeInboundInputService`.

There is no public unscoped registry accessor and no singleton service locator.

## Application facade

[`RuneScribeApplicationService`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/ApplicationContracts.swift) is the coherent UI-to-Core boundary. Its operations are grouped as follows:

| Area | Contract operations |
|---|---|
| State and menus | application snapshot stream; menu-command stream |
| Messages | encode and decode |
| Ciphers | create, rename, delete, activate, assign or clear contact |
| Contacts | create, update, delete, delete imported, import selected system contacts, request system contacts |
| Sharing | prepare cipher/message artifacts; complete or release an artifact |
| Import | import file/URL; confirm/cancel cipher import; dismiss received message |
| App lock | lock, verify, unlock, set/change/disable PIN |

[`RuneScribeCoreApplicationService`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Application/RuneScribeCoreApplicationService.swift) is an actor. It serializes complete use cases across suspension points so an older result cannot overwrite newer state. It publishes snapshots through `AsyncStream` with a newest-two buffer. The UI wraps the facade in the `@MainActor` [`RuneScribeUISession`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession.swift), which owns observable presentation state and cancellation.

Core returns typed `RuneScribeFailureDTO` categories instead of implementation errors or private payloads. UI-required decoded plaintext is transient and non-`Codable`; `PINInput` stores its value privately and exposes it only to a supplied closure; share DTOs carry a scoped file URL or opaque lease ID rather than artifact bytes. A key-bearing cipher link remains inside `AppleShareArtifactStore` until an authorized UI presentation resolves the opaque ID.

## Platform contracts

[`PlatformContracts.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/PlatformContracts.swift) narrows privileged operations rather than mirroring Apple APIs:

- `SecureValueStore` addresses generic values by stable service/account strings;
- `ProtectedFileStore` accepts validated relative `ProtectedPath` values and rejects absolute paths, traversal, empty components, backslashes, and nulls;
- `InboundFileReader` reads one external file with explicit security-scope and byte-limit inputs;
- `ShareArtifactStore` owns generated temporary files and opaque key-bearing links;
- `ContactAccessService` returns value-only `SystemContactDTO`, never `CNContact`;
- clipboard read and write are separate protocols;
- `SystemFontRegistrar` accepts bytes and returns only a PostScript-name value;
- `ApplicationResourceLocator` resolves stable resource handles from a host-supplied bundle;
- clock and UUID protocols provide deterministic test seams.

Core owns encryption, schema, validation, policy, and orchestration. Platform owns Apple API calls, safe paths, atomic/protected I/O, and adapter cleanup. UI never imports the Platform target.

Deterministic adapters live in the separate [`RuneScribeTestSupport`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeTestSupport) product, which depends only on Contracts. Package and hosted test targets may import it; shipping applications may not link it. This keeps in-memory stores and fixed clock/UUID/resource seams reusable without making them part of the production Platform surface. `AppleKeychainStore` exposes only the async `SecureValueStore` contract; exact Security behavior is tested through that same production API.

## State, events, and directed messages

Current Core/UI behavior uses synchronous/async facade calls when a result is needed and typed snapshot/menu streams for state. This is the shortest neutral route and avoids duplicating product state onto an event bus.

[`RuntimeEventBus`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Events.swift) remains available when a fact legitimately has zero or more consumers:

- the runtime supplies event UUID, source module ID, timestamp, and monotonic sequence;
- payloads are typed `Encodable & Sendable` values encoded to an immutable `Data` value;
- each active subscriber observes future publications in actor order; there is no replay contract;
- subscriptions are owned by a module and finished at context invalidation.

[`SafeEvents.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/SafeEvents.swift) defines safe application-snapshot, cipher-count, contact-count, import-phase, message-phase, and lock-state facts. It excludes keys, PIN material, plaintext, contact details, file contents, and full deep links. Core currently does not publish domain traffic on this bus, so no module requests an event-subscription capability.

[`DirectedMessageRouter`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Messages.swift) is reserved for a command that must target a neutral role without identifying an implementation:

- one live destination may register per role;
- the runtime stamps message ID, source module ID, destination role, and timestamp;
- send fails when no destination exists;
- destinations are removed when their owner stops.

Neither shipping module currently requests send/receive message capabilities. A product command with an expected result belongs on the application facade unless a future design proves that a role-directed message is necessary.

`NotificationCenter` is not a cross-module path. The sole retained use is an adapter-local `AVPlayerItem` completion observer in the splash view, with paired registration/removal.

## Lifecycle and input contracts

`ModuleContext` access is legal only during the module's active lifetime. The runtime activation plan starts all eligible service modules before the sole UI module and respects explicit role dependencies. Stop and failed-start rollback invalidate contexts and remove everything the module published or registered.

[`RuneScribeInboundInput`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/InboundInputs.swift) has four typed cases: file, URL, lifecycle, and menu. Metadata carries a generated input ID, receipt time, delivery source, and cold-start flag. Wire constants retain the `runescribe` scheme, import host, legacy web route, `com.runescribe.runescribe` UTI, `.runescribe` extension, cipher version 3, and message version 1.

The host submits inputs synchronously to [`SerialInboundInputForwarder`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/SerialInboundInputForwarder.swift), which:

- keeps FIFO order across awaited delivery;
- retains inputs before the Core service attaches;
- permits exactly one attached service and requires an awaited detach before replacement;
- caps retained input at 512, reserves 16 control positions and two security-lifecycle positions, and coalesces repeated queued background/termination controls;
- bounds URL and content-type metadata;
- reports rejected input and failed delivery instead of silently dropping it.

Core performs a second bounded admission and deduplication step. Data inputs pause while the app is locked or an import/message presentation is active, while background lock and other controls retain a dedicated lane. One malformed input cannot permanently block later queued inputs.

## Resource contracts

`ApplicationResource` defines stable handles for the bundled rune font, splash video, and default Metal library. The host supplies `Bundle.main` to [`BundleApplicationResourceLocator`](../../Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/Resources/BundleApplicationResourceLocator.swift). Core uses the font handle; UI uses video and Metal handles. Neither assumes `Bundle.main` from package code.

The asset catalog, font/license, splash video, and Metal source remain in the application targets. Core and UI manifests are their package targets' `Bundle.module` resources. This split preserves shipping lookup and target membership while keeping manifest ownership local to each module.

## Extension procedure

The architecture supports extension without prebuilding future product behavior.

### Add a service module

1. Define the minimum neutral IDs, immutable DTOs, and protocol in `RuneScribeContracts`. Keep the target Foundation-first and exclude implementation or secret-bearing types.
2. Add a narrow capability to `RuneScribeCapabilities.all` only if an existing capability does not express the privilege.
3. Add an explicit `ServiceAccessRule` naming the required capability and exact publisher/consumer roles. Default denial must remain the fallback.
4. Add one app-owned package product/target. Depend only on Contracts and Runtime Core plus narrowly required standard frameworks; do not import Core, UI, or Platform implementations.
5. Add a strict `module-manifest.json` and compiled descriptor with a unique module ID, role, and entry point. Declare required services/roles in both. Declare published services in the descriptor.
6. Register a lazy factory at the host composition root. Register any new privileged adapter through a neutral Platform contract and host service rule.
7. Make start/stop idempotent, ensure partial activation cleans up, and do not retain a usable context after stop.
8. Add manifest, default-deny, coexistence, activation-order, rollback, context-revocation, import-edge, contract-safety, platform, and parity tests. Update the architecture ratchet and regenerate the project twice from `project.yml`.

### Add or replace a UI contribution

Pattern B permits exactly one eligible user-facing UI module. A new UI contribution must therefore replace the current eligible UI or be mutually exclusive through an explicit eligibility policy; it may not activate alongside `com.runescribe.module.ui`.

1. Keep product UI in a UI-module target. During `start(context:)`, create one `RootViewContribution` and present it through the injected `RootViewPresentationStore`; do not add a second root-contribution API.
2. Resolve neutral services from the scoped context; never import service-module or Platform implementation targets.
3. Request only the UI capabilities used by the contribution and declare its required service-module roles.
4. Prove zero/one/two eligible-UI behavior, root selection, boot recovery, stop cleanup, accessibility, platform presentation, and feature parity.
5. Update manifests, descriptors, `project.yml`, architecture scans, resource membership, and documentation together.

For either path, do not add a remote Forsetti package, copied framework source, a runtime plugin downloader, a global registry, a cross-module notification, or product-facing module administration UI.

## Verification entry points

The primary checks are:

```sh
scripts/check-architecture.sh
swift test --package-path Packages/RuneScribeArchitecture
```

The package suites exercise manifest strictness, capability and role denial, typed service resolution, event/message stamping, lifecycle rollback, stopped-context denial, input ordering/bounds, contract safety, and integrated Core-before-UI activation. The standalone Xcode architecture target invokes the repository guard. At the recorded snapshot, all 283 package tests and all 17 architecture ratchets passed; evidence is retained at `/tmp/RuneScribe-P8-final-package.yGz7qs`. The current Release inspection passed 50 of 50 checks at `/tmp/RuneScribe-P8-release-final.XsJS4P`, including proof that both applications link all six shipping products and exclude `RuneScribeTestSupport`. Negative dependency mutations at `/tmp/RuneScribe-P8-guard-audit.4gkAfP` prove that the architecture and shipping guards reject Test Support as either a shipping application dependency or a shipping package-target dependency. Exact test identifiers are in [`p7-test-matrix.json`](../verification/p7-test-matrix.json), especially `T-001` through `T-014`, `T-024`, `T-027`, and `T-029`.
