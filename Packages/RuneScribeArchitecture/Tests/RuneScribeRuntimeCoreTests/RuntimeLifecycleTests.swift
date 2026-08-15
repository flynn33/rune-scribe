import Foundation
import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import XCTest

final class RuntimeLifecycleTests: XCTestCase {
    func testDuplicateModuleIDIsRejectedWithTypedError() async throws {
        let module = descriptor(
            id: "com.runescribe.module.duplicate-id",
            kind: .ui,
            entryPoint: "DuplicateIDModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let counter = FactoryCounter()
        let moduleFactory = factory(for: module, counter: counter)
        let runtime = makeRuntime()

        try await runtime.register(
            manifest: manifest(for: module),
            factory: moduleFactory
        )
        do {
            try await runtime.register(
                manifest: manifest(for: module),
                factory: moduleFactory
            )
            XCTFail("Expected duplicate module registration to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .duplicateModuleID(module.moduleID)
            )
        }
        XCTAssertEqual(counter.value, 0)
    }

    func testDistinctProviderRolesSharePolicyClassWithoutWeakeningRoleUniqueness()
        async throws
    {
        let capability = RuneScribeCapabilities.publishEvents
        let sharedPolicyClass = RuneScribePolicyClasses.themeProvider
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(knownCapabilities: [capability]),
            capabilities: CapabilityPolicy(allowedPolicyClassesByCapability: [
                capability: [sharedPolicyClass],
            ]),
            services: ServiceAccessPolicy(rules: [])
        )
        let first = descriptor(
            id: "com.runescribe.module.provider-first",
            kind: .service,
            criticality: .optional,
            entryPoint: "FirstProviderModule",
            role: "runescribe.provider.first",
            policyClass: sharedPolicyClass,
            capabilities: [capability]
        )
        let second = descriptor(
            id: "com.runescribe.module.provider-second",
            kind: .service,
            criticality: .optional,
            entryPoint: "SecondProviderModule",
            role: "runescribe.provider.second",
            policyClass: sharedPolicyClass,
            capabilities: [capability]
        )
        let duplicateRole = descriptor(
            id: "com.runescribe.module.provider-duplicate-role",
            kind: .service,
            criticality: .optional,
            entryPoint: "DuplicateRoleProviderModule",
            role: first.role,
            policyClass: sharedPolicyClass,
            capabilities: [capability]
        )
        let runtime = makeRuntime(policy: policy)

        try await runtime.register(
            manifest: manifest(for: first, policyClass: sharedPolicyClass),
            factory: factory(for: first)
        )
        try await runtime.register(
            manifest: manifest(for: second, policyClass: sharedPolicyClass),
            factory: factory(for: second)
        )

        do {
            try await runtime.register(
                manifest: manifest(
                    for: duplicateRole,
                    policyClass: sharedPolicyClass
                ),
                factory: factory(for: duplicateRole)
            )
            XCTFail("A shared policy class must not relax routable role uniqueness")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .duplicateRole(first.role)
            )
        }
    }

    func testCoreAndUIModulesCannotDeclareOptionalCriticality() async {
        let optionalUI = descriptor(
            id: "com.runescribe.module.optional-ui",
            kind: .ui,
            criticality: .optional,
            entryPoint: "OptionalUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let optionalCore = descriptor(
            id: RuneScribeModuleIDs.core,
            kind: .service,
            criticality: .optional,
            entryPoint: "OptionalCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )

        for item in [optionalUI, optionalCore] {
            let runtime = makeRuntime()
            do {
                try await runtime.register(
                    manifest: manifest(for: item),
                    factory: factory(for: item)
                )
                XCTFail("Core and the sole UI module must be required.")
            } catch {
                XCTAssertEqual(
                    error as? RuneScribeRuntimeError,
                    .invalidModuleCriticality(
                        moduleID: item.moduleID,
                        expected: .required,
                        actual: .optional
                    )
                )
            }
        }
    }

    func testManifestDescriptorMismatchRejectsRegistrationBeforeFactoryUse() async {
        let compiledDescriptor = descriptor(
            id: "com.runescribe.module.manifest-mismatch",
            kind: .ui,
            entryPoint: "ManifestMismatchModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let manifestDescriptor = descriptor(
            id: compiledDescriptor.moduleID,
            kind: compiledDescriptor.kind,
            entryPoint: compiledDescriptor.entryPoint,
            role: compiledDescriptor.role,
            capabilities: compiledDescriptor.requestedCapabilities,
            moduleVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(34)
            )
        )
        let counter = FactoryCounter()
        let runtime = makeRuntime()

        do {
            try await runtime.register(
                manifest: manifest(for: manifestDescriptor),
                factory: factory(for: compiledDescriptor, counter: counter)
            )
            XCTFail("Expected manifest and descriptor mismatch to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .manifestDescriptorMismatch(
                    moduleID: compiledDescriptor.moduleID,
                    field: "moduleVersion"
                )
            )
        }
        XCTAssertEqual(counter.value, 0)
    }

    func testFactoryProducedDescriptorMismatchFailsBeforeModuleStart() async throws {
        let registeredDescriptor = descriptor(
            id: "com.runescribe.module.factory-mismatch",
            kind: .ui,
            entryPoint: "FactoryMismatchModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let producedDescriptor = descriptor(
            id: registeredDescriptor.moduleID,
            kind: registeredDescriptor.kind,
            entryPoint: registeredDescriptor.entryPoint,
            role: registeredDescriptor.role,
            capabilities: registeredDescriptor.requestedCapabilities,
            moduleVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(34)
            )
        )
        let counter = FactoryCounter()
        let recorder = RuntimeRecorder()
        let runtime = makeRuntime()
        let mismatchedFactory = AnyModuleFactory(descriptor: registeredDescriptor) {
            counter.increment()
            return ProbeModule(
                descriptor: producedDescriptor,
                startAction: { _ in await recorder.append("start") },
                stopAction: { await recorder.append("stop") }
            )
        }

        try await runtime.register(
            manifest: manifest(for: registeredDescriptor),
            factory: mismatchedFactory
        )
        do {
            try await runtime.start()
            XCTFail("Expected the factory descriptor mismatch to fail activation.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .factoryDescriptorMismatch(registeredDescriptor.moduleID)
            )
        }

        let entries = await recorder.values()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertEqual(
            snapshot.moduleStates[registeredDescriptor.moduleID],
            .failed
        )
    }

    func testOptionalManifestDecodeFailureIsRecordedWithoutBlockingRequiredModules() async throws {
        let optional = descriptor(
            id: "com.runescribe.module.invalid-optional-manifest",
            kind: .service,
            criticality: .optional,
            entryPoint: "InvalidOptionalManifestModule",
            role: "runescribe.service.invalid-manifest",
            capabilities: []
        )
        let core = descriptor(
            id: "com.runescribe.module.invalid-manifest-core",
            kind: .service,
            entryPoint: "InvalidManifestCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let ui = descriptor(
            id: "com.runescribe.module.invalid-manifest-ui",
            kind: .ui,
            entryPoint: "InvalidManifestUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI],
            requiredRoles: [RuneScribeRoles.core]
        )
        let optionalCounter = FactoryCounter()
        let runtime = makeRuntime()

        try await runtime.register(
            manifestData: Data("{".utf8),
            factory: factory(for: optional, counter: optionalCounter)
        )
        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core)
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui)
        )

        try await runtime.start()
        let snapshot = await runtime.snapshot()

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.moduleStates[optional.moduleID], .failed)
        XCTAssertEqual(snapshot.moduleStates[core.moduleID], .active)
        XCTAssertEqual(snapshot.moduleStates[ui.moduleID], .active)
        XCTAssertEqual(optionalCounter.value, 0)
        await runtime.stop()
    }

    func testOptionalConstructionCatalogAndEndpointFailuresDoNotRollbackCoreOrUI() async throws {
        let recorder = RuntimeRecorder()
        let core = descriptor(
            id: "com.runescribe.module.optional-failure-core",
            kind: .service,
            entryPoint: "OptionalFailureCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let construction = descriptor(
            id: "com.runescribe.module.optional-construction-failure",
            kind: .service,
            criticality: .optional,
            entryPoint: "OptionalConstructionFailureModule",
            role: "runescribe.service.optional-construction",
            capabilities: []
        )
        let catalog = descriptor(
            id: "com.runescribe.module.optional-catalog-failure",
            kind: .service,
            criticality: .optional,
            entryPoint: "OptionalCatalogFailureModule",
            role: "runescribe.service.optional-catalog",
            capabilities: []
        )
        let missingEndpointID: RuntimeEndpointIdentifier = "optional.endpoint.missing"
        let endpoint = descriptor(
            id: "com.runescribe.module.optional-endpoint-failure",
            kind: .service,
            criticality: .optional,
            entryPoint: "OptionalEndpointFailureModule",
            role: "runescribe.service.optional-endpoint",
            capabilities: [],
            publishedEndpoints: [missingEndpointID]
        )
        let ui = descriptor(
            id: "com.runescribe.module.optional-failure-ui",
            kind: .ui,
            entryPoint: "OptionalFailureUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = makeRuntime()
        let constructionFactory = AnyModuleFactory(descriptor: construction) {
            throw ProbeFailure.injected
        }

        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, label: "core", recorder: recorder)
        )
        try await runtime.register(
            manifest: manifest(for: construction),
            factory: constructionFactory
        )
        try await runtime.register(
            manifest: manifest(for: catalog),
            factory: factory(for: catalog, start: { _ in throw ProbeFailure.injected })
        )
        try await runtime.register(
            manifest: manifest(for: endpoint),
            factory: factory(for: endpoint)
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, label: "ui", recorder: recorder)
        )

        try await runtime.start()
        let snapshot = await runtime.snapshot()
        let entries = await recorder.values()

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.activationOrder, [core.moduleID, ui.moduleID])
        XCTAssertEqual(snapshot.moduleStates[construction.moduleID], .failed)
        XCTAssertEqual(snapshot.moduleStates[catalog.moduleID], .failed)
        XCTAssertEqual(snapshot.moduleStates[endpoint.moduleID], .failed)
        XCTAssertEqual(snapshot.moduleStates[core.moduleID], .active)
        XCTAssertEqual(snapshot.moduleStates[ui.moduleID], .active)
        XCTAssertEqual(entries, ["start:core", "start:ui"])
        await runtime.stop()
    }

    func testEarnedEntitlementActivatesOptionalModuleLiveAndGrantsAreMonotonic() async throws {
        let recorder = RuntimeRecorder()
        let core = descriptor(
            id: "com.runescribe.module.live-entitlement-core",
            kind: .service,
            entryPoint: "LiveEntitlementCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let theme = descriptor(
            id: "com.runescribe.module.theme.synthetic",
            kind: .service,
            criticality: .optional,
            entryPoint: "SyntheticThemeModule",
            role: "runescribe.theme.synthetic",
            capabilities: [],
            requiredRoles: [RuneScribeRoles.core]
        )
        let ui = descriptor(
            id: "com.runescribe.module.live-entitlement-ui",
            kind: .ui,
            entryPoint: "LiveEntitlementUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI],
            requiredRoles: [RuneScribeRoles.core]
        )
        let moonleaf = try XCTUnwrap(UnlockID(rawValue: "unlock.codex.moonleaf"))
        let runtime = makeRuntime()

        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, label: "core", recorder: recorder)
        )
        try await runtime.register(
            manifest: manifest(
                for: theme,
                entitlementRequirement: EntitlementRequirement(
                    kind: .earned,
                    identifier: moonleaf
                )
            ),
            factory: factory(for: theme, label: "theme", recorder: recorder)
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, label: "ui", recorder: recorder)
        )

        try await runtime.start()
        let initial = await runtime.snapshot()
        XCTAssertEqual(initial.activationOrder, [core.moduleID, ui.moduleID])
        XCTAssertEqual(initial.moduleStates[theme.moduleID], .validated)
        XCTAssertEqual(
            initial.entitlementSnapshot.includedUnlockIDs,
            [RuneScribeUnlockIDs.norseCodex]
        )
        XCTAssertTrue(initial.entitlementSnapshot.earnedUnlockIDs.isEmpty)

        let earned = try ProgressionEntitlementSnapshotDTO(
            revision: 1,
            capturedAt: Date(timeIntervalSince1970: 10),
            includedUnlockIDs: [],
            earnedUnlockIDs: [moonleaf]
        )
        try await runtime.reconcileEntitlements(earned)
        let activated = await runtime.snapshot()
        XCTAssertEqual(
            activated.activationOrder,
            [core.moduleID, ui.moduleID, theme.moduleID]
        )
        XCTAssertEqual(activated.moduleStates[theme.moduleID], .active)
        XCTAssertEqual(
            activated.entitlementSnapshot.includedUnlockIDs,
            [RuneScribeUnlockIDs.norseCodex]
        )
        XCTAssertEqual(activated.entitlementSnapshot.earnedUnlockIDs, [moonleaf])

        let emptyLaterSnapshot = try ProgressionEntitlementSnapshotDTO(
            revision: 2,
            capturedAt: Date(timeIntervalSince1970: 20),
            includedUnlockIDs: [],
            earnedUnlockIDs: []
        )
        try await runtime.reconcileEntitlements(emptyLaterSnapshot)
        let semanticReplayAtDifferentTime = try ProgressionEntitlementSnapshotDTO(
            revision: 2,
            capturedAt: Date(timeIntervalSince1970: 21),
            includedUnlockIDs: [],
            earnedUnlockIDs: []
        )
        try await runtime.reconcileEntitlements(semanticReplayAtDifferentTime)
        let divergentSameRevision = try ProgressionEntitlementSnapshotDTO(
            revision: 2,
            capturedAt: Date(timeIntervalSince1970: 22),
            includedUnlockIDs: [],
            earnedUnlockIDs: [
                try XCTUnwrap(UnlockID(rawValue: "unlock.codex.sunspire")),
            ]
        )
        do {
            try await runtime.reconcileEntitlements(divergentSameRevision)
            XCTFail("Expected divergent equal-revision entitlement replay to fail")
        } catch RuneScribeRuntimeError.entitlementRevisionConflict(2) {}
        let monotonic = await runtime.snapshot()
        let values = await recorder.values()
        XCTAssertEqual(monotonic.entitlementSnapshot.earnedUnlockIDs, [moonleaf])
        XCTAssertEqual(values, ["start:core", "start:ui", "start:theme"])
        await runtime.stop()
    }

    func testProgressionEntitlementEndpointActivatesEarnedOptionalModuleLive() async throws {
        let recorder = RuntimeRecorder()
        let core = descriptor(
            id: "com.runescribe.module.endpoint-entitlement-core",
            kind: .service,
            entryPoint: "EndpointEntitlementCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let progression = descriptor(
            id: RuneScribeModuleIDs.progression,
            kind: .service,
            criticality: .optional,
            entryPoint: "SyntheticProgressionModule",
            role: RuneScribeRoles.progression,
            capabilities: [],
            publishedEndpoints: RuntimeProgressionEndpointCatalog.publishedEndpointIDs
        )
        let theme = descriptor(
            id: "com.runescribe.module.theme.endpoint-synthetic",
            kind: .service,
            criticality: .optional,
            entryPoint: "EndpointSyntheticThemeModule",
            role: "runescribe.theme.endpoint-synthetic",
            capabilities: [],
            requiredRoles: [RuneScribeRoles.core]
        )
        let ui = descriptor(
            id: "com.runescribe.module.endpoint-entitlement-ui",
            kind: .ui,
            entryPoint: "EndpointEntitlementUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI],
            requiredRoles: [RuneScribeRoles.core]
        )
        let moonleaf = try XCTUnwrap(UnlockID(rawValue: "unlock.codex.moonleaf"))
        let progressionService = SyntheticProgressionService()
        let runtime = makeRuntime()

        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, label: "core", recorder: recorder)
        )
        try await runtime.register(
            manifest: manifest(for: progression),
            factory: factory(for: progression, start: { context in
                try await context.registerProgressionEndpoints(progressionService)
            })
        )
        try await runtime.register(
            manifest: manifest(
                for: theme,
                entitlementRequirement: EntitlementRequirement(
                    kind: .earned,
                    identifier: moonleaf
                )
            ),
            factory: factory(for: theme, label: "theme", recorder: recorder)
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, label: "ui", recorder: recorder)
        )

        try await runtime.start()
        progressionService.publish(
            try ProgressionEntitlementSnapshotDTO(
                revision: 0,
                capturedAt: Date(timeIntervalSince1970: 29),
                includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
                earnedUnlockIDs: []
            )
        )
        progressionService.publish(
            try ProgressionEntitlementSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 30),
                includedUnlockIDs: [],
                earnedUnlockIDs: [moonleaf]
            )
        )

        for _ in 0 ..< 1_000 {
            let current = await runtime.snapshot()
            if current.moduleStates[theme.moduleID] == .active {
                break
            }
            await Task.yield()
        }
        let snapshot = await runtime.snapshot()
        let values = await recorder.values()

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.moduleStates[progression.moduleID], .active)
        XCTAssertEqual(snapshot.moduleStates[theme.moduleID], .active)
        XCTAssertEqual(snapshot.entitlementSnapshot.earnedUnlockIDs, [moonleaf])
        XCTAssertTrue(snapshot.entitlementSnapshot.includedUnlockIDs.contains(
            RuneScribeUnlockIDs.norseCodex
        ))
        XCTAssertEqual(values, ["start:core", "start:ui", "start:theme"])
        await runtime.stop()
    }

    func testTwoNonUIModulesCoexistAndStartAndStopExactlyOnce() async throws {
        let recorder = RuntimeRecorder()
        let firstCounter = FactoryCounter()
        let secondCounter = FactoryCounter()
        let uiCounter = FactoryCounter()
        let first = descriptor(
            id: "com.runescribe.module.coexist-alpha",
            kind: .service,
            entryPoint: "CoexistAlphaModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let secondRole: ModuleRole = "runescribe.service.secondary"
        let second = descriptor(
            id: "com.runescribe.module.coexist-beta",
            kind: .service,
            entryPoint: "CoexistBetaModule",
            role: secondRole,
            capabilities: []
        )
        let ui = descriptor(
            id: "com.runescribe.module.coexist-ui",
            kind: .ui,
            entryPoint: "CoexistUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let runtime = makeRuntime()

        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(
                for: ui,
                label: "ui",
                recorder: recorder,
                counter: uiCounter
            )
        )
        try await runtime.register(
            manifest: manifest(for: second),
            factory: factory(
                for: second,
                label: "beta",
                recorder: recorder,
                counter: secondCounter
            )
        )
        try await runtime.register(
            manifest: manifest(for: first),
            factory: factory(
                for: first,
                label: "alpha",
                recorder: recorder,
                counter: firstCounter
            )
        )

        try await runtime.start()
        try await runtime.start()
        let runningSnapshot = await runtime.snapshot()
        await runtime.stop()
        await runtime.stop()
        let entries = await recorder.values()

        XCTAssertEqual(
            runningSnapshot.activationOrder,
            [first.moduleID, second.moduleID, ui.moduleID]
        )
        XCTAssertEqual(firstCounter.value, 1)
        XCTAssertEqual(secondCounter.value, 1)
        XCTAssertEqual(uiCounter.value, 1)
        XCTAssertEqual(
            entries,
            [
                "start:alpha",
                "start:beta",
                "start:ui",
                "stop:ui",
                "stop:beta",
                "stop:alpha",
            ]
        )
    }

    func testMutableEligibilityReconcilesDeterministicallyAcrossRestart() async throws {
        let recorder = RuntimeRecorder()
        let coreCounter = FactoryCounter()
        let optionalCounter = FactoryCounter()
        let uiCounter = FactoryCounter()
        let core = descriptor(
            id: "com.runescribe.module.eligibility-core",
            kind: .service,
            entryPoint: "EligibilityCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let optionalRole: ModuleRole = "runescribe.service.optional"
        let optional = descriptor(
            id: "com.runescribe.module.eligibility-optional",
            kind: .service,
            criticality: .optional,
            entryPoint: "EligibilityOptionalModule",
            role: optionalRole,
            capabilities: []
        )
        let ui = descriptor(
            id: "com.runescribe.module.eligibility-ui",
            kind: .ui,
            entryPoint: "EligibilityUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let eligibility = MutableEligibilityProvider(
            eligibleModuleIDs: [core.moduleID, optional.moduleID, ui.moduleID]
        )
        let runtime = makeRuntime(eligibility: eligibility)

        try await runtime.register(
            manifest: manifest(for: optional),
            factory: factory(
                for: optional,
                label: "optional",
                recorder: recorder,
                counter: optionalCounter
            )
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(
                for: ui,
                label: "ui",
                recorder: recorder,
                counter: uiCounter
            )
        )
        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(
                for: core,
                label: "core",
                recorder: recorder,
                counter: coreCounter
            )
        )

        try await runtime.start()
        let firstSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            firstSnapshot.activationOrder,
            [core.moduleID, optional.moduleID, ui.moduleID]
        )
        await runtime.stop()

        await eligibility.setEligible(false, moduleID: optional.moduleID)
        try await runtime.start()
        let secondSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            secondSnapshot.activationOrder,
            [core.moduleID, ui.moduleID]
        )
        XCTAssertEqual(secondSnapshot.moduleStates[optional.moduleID], .validated)
        await runtime.stop()

        await eligibility.setEligible(true, moduleID: optional.moduleID)
        try await runtime.start()
        let thirdSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            thirdSnapshot.activationOrder,
            [core.moduleID, optional.moduleID, ui.moduleID]
        )
        await runtime.stop()

        let entries = await recorder.values()
        XCTAssertEqual(coreCounter.value, 3)
        XCTAssertEqual(optionalCounter.value, 2)
        XCTAssertEqual(uiCounter.value, 3)
        XCTAssertEqual(
            entries,
            [
                "start:core", "start:optional", "start:ui",
                "stop:ui", "stop:optional", "stop:core",
                "start:core", "start:ui",
                "stop:ui", "stop:core",
                "start:core", "start:optional", "start:ui",
                "stop:ui", "stop:optional", "stop:core",
            ]
        )
    }

    func testFactoriesAreLazyAndServiceActivatesBeforeUI() async throws {
        let recorder = RuntimeRecorder()
        let coreCounter = FactoryCounter()
        let uiCounter = FactoryCounter()
        let core = descriptor(
            id: "com.runescribe.module.test-core",
            kind: .service,
            entryPoint: "TestCoreModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.publishEvents]
        )
        let ui = descriptor(
            id: "com.runescribe.module.test-ui",
            kind: .ui,
            entryPoint: "TestUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.subscribeEvents,
                RuneScribeCapabilities.rootUI,
            ],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = makeRuntime()

        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, label: "ui", recorder: recorder, counter: uiCounter)
        )
        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, label: "core", recorder: recorder, counter: coreCounter)
        )

        XCTAssertEqual(coreCounter.value, 0)
        XCTAssertEqual(uiCounter.value, 0)

        try await runtime.start()
        try await runtime.start()

        XCTAssertEqual(coreCounter.value, 1)
        XCTAssertEqual(uiCounter.value, 1)
        let startedValues = await recorder.values()
        let runningSnapshot = await runtime.snapshot()
        XCTAssertEqual(startedValues, ["start:core", "start:ui"])
        XCTAssertEqual(
            runningSnapshot.activationOrder,
            [core.moduleID, ui.moduleID]
        )

        await runtime.stop()
        await runtime.stop()
        let stoppedValues = await recorder.values()
        XCTAssertEqual(
            stoppedValues,
            ["start:core", "start:ui", "stop:ui", "stop:core"]
        )
    }

    func testExactlyOneEligibleUIIsRequired() async throws {
        let core = descriptor(
            id: "com.runescribe.module.test-core",
            kind: .service,
            entryPoint: "TestCoreModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.publishEvents]
        )
        let noUIRuntime = makeRuntime()
        try await noUIRuntime.register(
            manifest: manifest(for: core),
            factory: factory(for: core)
        )

        do {
            try await noUIRuntime.start()
            XCTFail("Expected the no-UI invariant to fail.")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .noEligibleUIModule)
        }

        let secondaryRole: ModuleRole = "runescribe.ui.secondary"
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(knownCapabilities: RuneScribeCapabilities.all),
            capabilities: CapabilityPolicy(allowedRolesByCapability: [
                RuneScribeCapabilities.publishEvents: [RuneScribeRoles.core],
                RuneScribeCapabilities.rootUI: [RuneScribeRoles.primaryUI, secondaryRole],
            ]),
            services: ServiceAccessPolicy(rules: [])
        )
        let firstUI = descriptor(
            id: "com.runescribe.module.first-ui",
            kind: .ui,
            entryPoint: "FirstUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let secondUI = descriptor(
            id: "com.runescribe.module.second-ui",
            kind: .ui,
            entryPoint: "SecondUIModule",
            role: secondaryRole,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let multipleUIRuntime = makeRuntime(policy: policy)
        for item in [core, firstUI, secondUI] {
            try await multipleUIRuntime.register(
                manifest: manifest(for: item),
                factory: factory(for: item)
            )
        }

        do {
            try await multipleUIRuntime.start()
            XCTFail("Expected the multiple-UI invariant to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .multipleEligibleUIModules([firstUI.moduleID, secondUI.moduleID])
            )
        }
    }

    func testDeclaredEndpointDispatchesThroughPolicy() async throws {
        let endpointID: RuntimeEndpointIdentifier = "test.value.query"
        let endpoint = RuntimeEndpointDescriptor<RuntimeEmptyPayload, TestValue>(
            endpointID: endpointID,
            kind: .query,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .internalData,
            maximumRequestBytes: 1,
            maximumResponseBytes: 16
        ).key
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(knownCapabilities: RuneScribeCapabilities.all),
            capabilities: CapabilityPolicy(allowedRolesByCapability: [
                RuneScribeCapabilities.applicationCommands: [RuneScribeRoles.primaryUI],
                RuneScribeCapabilities.rootUI: [RuneScribeRoles.primaryUI],
            ]),
            services: ServiceAccessPolicy(rules: [])
        )
        let core = descriptor(
            id: "com.runescribe.module.service-provider",
            kind: .service,
            entryPoint: "ServiceProviderModule",
            role: RuneScribeRoles.core,
            capabilities: [],
            publishedEndpoints: [endpointID]
        )
        let ui = descriptor(
            id: "com.runescribe.module.service-consumer",
            kind: .ui,
            entryPoint: "ServiceConsumerModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.applicationCommands,
                RuneScribeCapabilities.rootUI,
            ],
            requiredRoles: [RuneScribeRoles.core],
            consumedEndpoints: [endpointID]
        )
        let recorder = RuntimeRecorder()
        let clientCapture = RuntimeQueryClientCapture()
        let runtime = makeRuntime(policy: policy)

        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, start: { context in
                try await context.registerEndpoint(
                    endpoint,
                    handler: { _, _ in TestValue(value: 42) }
                )
            })
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, start: { context in
                let client = try await context.queryClient(to: .role(RuneScribeRoles.core))
                await clientCapture.store(client)
            })
        )

        try await runtime.start()
        let capturedClient = await clientCapture.value()
        let client = try XCTUnwrap(capturedClient)
        let value = try await client.fetch(RuntimeEmptyPayload(), from: endpoint)
        await recorder.record(number: value.value)
        let resolvedNumber = await recorder.number()
        XCTAssertEqual(resolvedNumber, 42)
        await runtime.stop()
    }

    func testRuntimeActivationRejectsMissingDeclaredPublishedEndpoint() async throws {
        let missingEndpointID: RuntimeEndpointIdentifier = "test.declared-but-unregistered"
        let core = descriptor(
            id: "com.runescribe.module.incomplete-provider",
            kind: .service,
            entryPoint: "IncompleteProviderModule",
            role: RuneScribeRoles.core,
            capabilities: [],
            publishedEndpoints: [missingEndpointID]
        )
        let ui = descriptor(
            id: "com.runescribe.module.incomplete-provider-ui",
            kind: .ui,
            entryPoint: "IncompleteProviderUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = makeRuntime()
        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core)
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui)
        )

        do {
            try await runtime.start()
            XCTFail("A module must register every endpoint it declares before activation")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .activationFailed(core.moduleID)
            )
        }

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.moduleStates[core.moduleID], .failed)
    }

    func testUnmappedServiceAndUnknownCapabilityAreDeniedAtRegistration() async throws {
        let serviceID: ServiceIdentifier = "UnmappedService"
        let serviceDescriptor = descriptor(
            id: "com.runescribe.module.unmapped",
            kind: .service,
            entryPoint: "UnmappedModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.publishService],
            publishedServices: [serviceID]
        )
        let runtime = makeRuntime()
        do {
            try await runtime.register(
                manifest: manifest(for: serviceDescriptor),
                factory: factory(for: serviceDescriptor)
            )
            XCTFail("Expected unmapped service registration to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .serviceMappingMissing(moduleID: serviceDescriptor.moduleID, service: serviceID)
            )
        }

        let unknown: CapabilityIdentifier = "runtime.unknown"
        let unknownDescriptor = descriptor(
            id: "com.runescribe.module.unknown-capability",
            kind: .service,
            entryPoint: "UnknownCapabilityModule",
            role: RuneScribeRoles.core,
            capabilities: [unknown]
        )
        do {
            try await runtime.register(
                manifest: manifest(for: unknownDescriptor),
                factory: factory(for: unknownDescriptor)
            )
            XCTFail("Expected unknown capability registration to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .unknownCapability(moduleID: unknownDescriptor.moduleID, capability: unknown)
            )
        }
    }

    func testClipboardCapabilityPolicyDeniesCoreWriteAndUIRead() async throws {
        let coreWriter = descriptor(
            id: "com.runescribe.module.clipboard-core-writer",
            kind: .service,
            entryPoint: "ClipboardCoreWriterModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clipboardWrite],
            requiredServices: [RuneScribeServiceIDs.clipboardWrite]
        )
        let coreRuntime = makeRuntime()

        do {
            try await coreRuntime.register(
                manifest: manifest(for: coreWriter),
                factory: factory(for: coreWriter)
            )
            XCTFail("Expected Core clipboard-write access to be denied.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: coreWriter.moduleID,
                    capability: RuneScribeCapabilities.clipboardWrite
                )
            )
        }

        let uiReader = descriptor(
            id: "com.runescribe.module.clipboard-ui-reader",
            kind: .ui,
            entryPoint: "ClipboardUIReaderModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.clipboardRead,
                RuneScribeCapabilities.rootUI,
            ],
            requiredServices: [RuneScribeServiceIDs.clipboardRead]
        )
        let uiRuntime = makeRuntime()

        do {
            try await uiRuntime.register(
                manifest: manifest(for: uiReader),
                factory: factory(for: uiReader)
            )
            XCTFail("Expected UI clipboard-read access to be denied.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: uiReader.moduleID,
                    capability: RuneScribeCapabilities.clipboardRead
                )
            )
        }

    }

    func testClipboardRoleSpecificServicesResolveAllowedOperations() async throws {
        let clipboard = ClipboardRuntimeProbe(string: "seed", changeCount: 3)
        let reader: any ClipboardReading = clipboard
        let writer: any ClipboardWriting = clipboard
        let recorder = RuntimeRecorder()
        let core = descriptor(
            id: "com.runescribe.module.clipboard-reader",
            kind: .service,
            entryPoint: "ClipboardReaderModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clipboardRead],
            requiredServices: [RuneScribeServiceIDs.clipboardRead]
        )
        let ui = descriptor(
            id: "com.runescribe.module.clipboard-writer",
            kind: .ui,
            entryPoint: "ClipboardWriterModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.clipboardWrite,
                RuneScribeCapabilities.rootUI,
            ],
            requiredServices: [RuneScribeServiceIDs.clipboardWrite],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = makeRuntime()

        try await runtime.installPlatformAdapter(reader, for: RuneScribeServiceKeys.clipboardRead)
        try await runtime.installPlatformAdapter(writer, for: RuneScribeServiceKeys.clipboardWrite)
        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, start: { context in
                let client = try await context.runtimeIOClient()
                let snapshot = try await client.clipboardSnapshot()
                await recorder.append("read:\(snapshot.string ?? "nil")")
                await recorder.record(number: snapshot.changeCount)
            })
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, start: { context in
                let client = try await context.runtimeIOClient()
                try await client.setClipboardString("updated")
            })
        )

        try await runtime.start()

        let recordedValues = await recorder.values()
        let recordedNumber = await recorder.number()
        let finalString = await clipboard.string()
        let finalChangeCount = await clipboard.changeCount()
        XCTAssertEqual(recordedValues, ["read:seed"])
        XCTAssertEqual(recordedNumber, 3)
        XCTAssertEqual(finalString, "updated")
        XCTAssertEqual(finalChangeCount, 4)
        await runtime.stop()
    }

    func testClockAndUUIDServicesRequireTheirOwnCapabilities() async throws {
        let clockUsingInboundCapability = descriptor(
            id: "com.runescribe.module.clock-with-inbound",
            kind: .service,
            entryPoint: "ClockWithInboundModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.inboundInput],
            requiredServices: [RuneScribeServiceIDs.clock]
        )
        let clockRuntime = makeRuntime()

        do {
            try await clockRuntime.register(
                manifest: manifest(for: clockUsingInboundCapability),
                factory: factory(for: clockUsingInboundCapability)
            )
            XCTFail("Expected the unrelated inbound-input capability to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .serviceCapabilityMissing(
                    moduleID: clockUsingInboundCapability.moduleID,
                    service: RuneScribeServiceIDs.clock
                )
            )
        }

        let uuidUsingClockCapability = descriptor(
            id: "com.runescribe.module.uuid-with-clock",
            kind: .service,
            entryPoint: "UUIDWithClockModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clockRead],
            requiredServices: [RuneScribeServiceIDs.uuid]
        )
        let uuidRuntime = makeRuntime()

        do {
            try await uuidRuntime.register(
                manifest: manifest(for: uuidUsingClockCapability),
                factory: factory(for: uuidUsingClockCapability)
            )
            XCTFail("Expected the clock capability not to authorize UUID generation.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .serviceCapabilityMissing(
                    moduleID: uuidUsingClockCapability.moduleID,
                    service: RuneScribeServiceIDs.uuid
                )
            )
        }
    }

    func testShareArtifactStorageRequiresItsOwnCapability() async throws {
        let deniedDescriptor = descriptor(
            id: "com.runescribe.module.share-with-protected-files",
            kind: .service,
            entryPoint: "ShareWithProtectedFilesModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.protectedFileStorage],
            requiredServices: [RuneScribeServiceIDs.shareArtifactStore]
        )
        let runtime = makeRuntime()

        do {
            try await runtime.register(
                manifest: manifest(for: deniedDescriptor),
                factory: factory(for: deniedDescriptor)
            )
            XCTFail("Protected-file access must not authorize temporary share artifacts.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .serviceCapabilityMissing(
                    moduleID: deniedDescriptor.moduleID,
                    service: RuneScribeServiceIDs.shareArtifactStore
                )
            )
        }

        let allowedDescriptor = descriptor(
            id: "com.runescribe.module.share-with-scoped-capability",
            kind: .service,
            entryPoint: "ShareWithScopedCapabilityModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.shareArtifactStorage],
            requiredServices: [RuneScribeServiceIDs.shareArtifactStore]
        )
        let allowedRuntime = makeRuntime()
        try await allowedRuntime.register(
            manifest: manifest(for: allowedDescriptor),
            factory: factory(for: allowedDescriptor)
        )
    }

    func testRuntimeStampsEventsAndDirectedMessages() async throws {
        let date = Date(timeIntervalSince1970: 123)
        let eventUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let messageUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let uuidSequence = UUIDSequence([eventUUID, messageUUID])
        let environment = RuntimeEnvironment(
            now: { date },
            nextUUID: { uuidSequence.next() }
        )
        let recorder = RuntimeRecorder()
        let core = descriptor(
            id: "com.runescribe.module.runtime-source",
            kind: .service,
            entryPoint: "RuntimeSourceModule",
            role: RuneScribeRoles.core,
            capabilities: [
                RuneScribeCapabilities.publishEvents,
                RuneScribeCapabilities.receiveMessages,
            ]
        )
        let ui = descriptor(
            id: "com.runescribe.module.runtime-sender",
            kind: .ui,
            entryPoint: "RuntimeSenderModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.sendMessages,
                RuneScribeCapabilities.rootUI,
            ],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = makeRuntime(environment: environment)

        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, start: { context in
                let event = try await context.publishEvent(
                    "test.ready",
                    payload: TestValue(value: 7)
                )
                await recorder.record(event: event)
                try await context.registerMessageHandler { message in
                    await recorder.record(message: message)
                }
            })
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, start: { context in
                try await context.sendMessage(
                    "test.command",
                    to: RuneScribeRoles.core,
                    payload: TestValue(value: 9)
                )
            })
        )

        try await runtime.start()
        let recordedEvent = await recorder.event()
        let recordedMessage = await recorder.message()
        let event = try XCTUnwrap(recordedEvent)
        let message = try XCTUnwrap(recordedMessage)
        XCTAssertEqual(event.eventID, eventUUID)
        XCTAssertEqual(event.sourceModuleID, core.moduleID)
        XCTAssertEqual(event.timestamp, date)
        XCTAssertEqual(try event.decodePayload(as: TestValue.self), TestValue(value: 7))
        XCTAssertEqual(message.messageID, messageUUID)
        XCTAssertEqual(message.sourceModuleID, ui.moduleID)
        XCTAssertEqual(message.destinationRole, RuneScribeRoles.core)
        XCTAssertEqual(try message.decodePayload(as: TestValue.self), TestValue(value: 9))
        await runtime.stop()
    }

    func testRetainedContextRejectsServiceEventAndMessageAccessAfterStop() async throws {
        let endpointID: RuntimeEndpointIdentifier = "test.retained-context.query"
        let endpoint = RuntimeEndpointDescriptor<RuntimeEmptyPayload, TestValue>(
            endpointID: endpointID,
            kind: .query,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .internalData,
            maximumRequestBytes: 1,
            maximumResponseBytes: 16
        ).key
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(knownCapabilities: RuneScribeCapabilities.all),
            capabilities: CapabilityPolicy(allowedRolesByCapability: [
                RuneScribeCapabilities.applicationCommands: [RuneScribeRoles.primaryUI],
                RuneScribeCapabilities.subscribeEvents: [RuneScribeRoles.primaryUI],
                RuneScribeCapabilities.sendMessages: [RuneScribeRoles.primaryUI],
                RuneScribeCapabilities.rootUI: [RuneScribeRoles.primaryUI],
            ]),
            services: ServiceAccessPolicy(rules: [])
        )
        let core = descriptor(
            id: "com.runescribe.module.retained-context-core",
            kind: .service,
            entryPoint: "RetainedContextCoreModule",
            role: RuneScribeRoles.core,
            capabilities: [],
            publishedEndpoints: [endpointID]
        )
        let ui = descriptor(
            id: "com.runescribe.module.retained-context-ui",
            kind: .ui,
            entryPoint: "RetainedContextUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.applicationCommands,
                RuneScribeCapabilities.subscribeEvents,
                RuneScribeCapabilities.sendMessages,
                RuneScribeCapabilities.rootUI,
            ],
            requiredRoles: [RuneScribeRoles.core],
            consumedEndpoints: [endpointID]
        )
        let capture = ModuleContextCapture()
        let runtime = makeRuntime(policy: policy)

        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, start: { context in
                try await context.registerEndpoint(
                    endpoint,
                    handler: { _, _ in TestValue(value: 42) }
                )
            })
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, start: { context in
                _ = try await context.queryClient(to: .role(RuneScribeRoles.core))
                await capture.store(context)
            })
        )

        try await runtime.start()
        await runtime.stop()
        let capturedContext = await capture.value()
        let retainedContext = try XCTUnwrap(capturedContext)
        let expectedError = RuneScribeRuntimeError.contextInactive(ui.moduleID)

        let serviceError = await runtimeError(from: {
            _ = try await retainedContext.queryClient(to: .role(RuneScribeRoles.core))
        })
        let eventError = await runtimeError(from: {
            _ = try await retainedContext.eventStream()
        })
        let messageError = await runtimeError(from: {
            try await retainedContext.sendMessage(
                "test.after-stop",
                to: RuneScribeRoles.core,
                payload: TestValue(value: 7)
            )
        })

        XCTAssertEqual(serviceError, expectedError)
        XCTAssertEqual(eventError, expectedError)
        XCTAssertEqual(messageError, expectedError)
    }

    private func runtimeError(
        from operation: () async throws -> Void
    ) async -> RuneScribeRuntimeError? {
        do {
            try await operation()
            return nil
        } catch {
            return error as? RuneScribeRuntimeError
        }
    }
}

private struct TestValue: Codable, Equatable, Sendable {
    let value: Int
}

private enum ProbeFailure: Error {
    case injected
}

private final class SyntheticProgressionService: RuneScribeProgressionService, @unchecked Sendable {
    private let entitlements: AsyncStream<ProgressionEntitlementSnapshotDTO>
    private let entitlementContinuation: AsyncStream<
        ProgressionEntitlementSnapshotDTO
    >.Continuation

    init() {
        var continuation: AsyncStream<ProgressionEntitlementSnapshotDTO>.Continuation!
        entitlements = AsyncStream(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        entitlementContinuation = continuation
    }

    func publish(_ snapshot: ProgressionEntitlementSnapshotDTO) {
        entitlementContinuation.yield(snapshot)
    }

    func applyEvent(
        _ envelope: DomainEventEnvelope,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionEventApplyResult {
        .ignoredIneligible
    }

    func stateStream(metadata _: RuntimeOperationMetadata) -> AsyncStream<ProgressionSnapshotDTO> {
        AsyncStream { $0.finish() }
    }

    func entitlementStream(
        metadata _: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionEntitlementSnapshotDTO> {
        entitlements
    }

    func acknowledgeReveal(
        _ command: AcknowledgeProgressionRevealCommand,
        metadata _: RuntimeOperationMetadata
    ) async throws {}

    func selectTitle(
        _ command: SelectProgressionTitleCommand,
        metadata _: RuntimeOperationMetadata
    ) async throws {}

    func diagnosticsSummary(
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionDiagnosticsSummaryDTO {
        try ProgressionDiagnosticsSummaryDTO(
            capturedAt: Date(timeIntervalSince1970: 0),
            availability: .available,
            storeHealth: .loaded,
            catalogID: ProgressionCatalogID(rawValue: "runescribe.progression.catalog"),
            catalogVersion: ProgressionCatalogVersion(rawValue: 1),
            stateNamespaceSchemaVersion: 1,
            logicalRecordSchemaVersion: 1,
            pendingOutboxCount: 0
        )
    }

    func rebuild(
        _ request: ProgressionRecoveryRequest,
        metadata _: RuntimeOperationMetadata
    ) async throws
        -> ProgressionRecoveryResult
    {
        try ProgressionRecoveryResult(
            rebuiltAt: Date(timeIntervalSince1970: 0),
            revision: 1
        )
    }
}

private actor ClipboardRuntimeProbe: ClipboardReading, ClipboardWriting {
    private var storedString: String?
    private var counter: Int

    init(string: String?, changeCount: Int) {
        storedString = string
        counter = changeCount
    }

    func changeCount() async -> Int {
        counter
    }

    func string() async -> String? {
        storedString
    }

    func setString(_ value: String) async throws {
        storedString = value
        counter += 1
    }
}

private actor RuntimeRecorder {
    private var entries: [String] = []
    private var recordedNumber: Int?
    private var recordedEvent: RuntimeEvent?
    private var recordedMessage: DirectedMessage?

    func append(_ value: String) {
        entries.append(value)
    }

    func values() -> [String] {
        entries
    }

    func record(number: Int) {
        recordedNumber = number
    }

    func number() -> Int? {
        recordedNumber
    }

    func record(event: RuntimeEvent) {
        recordedEvent = event
    }

    func event() -> RuntimeEvent? {
        recordedEvent
    }

    func record(message: DirectedMessage) {
        recordedMessage = message
    }

    func message() -> DirectedMessage? {
        recordedMessage
    }
}

private actor MutableEligibilityProvider: ModuleEligibilityProviding {
    private var eligibleModuleIDs: Set<ModuleIdentifier>

    init(eligibleModuleIDs: Set<ModuleIdentifier>) {
        self.eligibleModuleIDs = eligibleModuleIDs
    }

    func isEligible(_ manifest: ModuleManifest) async -> Bool {
        eligibleModuleIDs.contains(manifest.moduleID)
    }

    func setEligible(_ isEligible: Bool, moduleID: ModuleIdentifier) {
        if isEligible {
            eligibleModuleIDs.insert(moduleID)
        } else {
            eligibleModuleIDs.remove(moduleID)
        }
    }
}

private actor ModuleContextCapture {
    private var context: ModuleContext?

    func store(_ context: ModuleContext) {
        self.context = context
    }

    func value() -> ModuleContext? {
        context
    }
}

private actor RuntimeQueryClientCapture {
    private var client: RuntimeQueryClient?

    func store(_ client: RuntimeQueryClient) {
        self.client = client
    }

    func value() -> RuntimeQueryClient? {
        client
    }
}

private final class FactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!values.isEmpty)
            return values.removeFirst()
        }
    }
}

private struct ProbeModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void
    let stopAction: @Sendable () async -> Void

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {
        await stopAction()
    }
}

private func descriptor(
    id: ModuleIdentifier,
    kind: ModuleKind,
    criticality: ModuleCriticality = .required,
    entryPoint: String,
    role: ModuleRole,
    policyClass: ModulePolicyClass? = nil,
    capabilities: Set<CapabilityIdentifier>,
    requiredServices: Set<ServiceIdentifier> = [],
    publishedServices: Set<ServiceIdentifier> = [],
    requiredRoles: Set<ModuleRole> = [],
    consumedEndpoints: Set<RuntimeEndpointIdentifier> = [],
    publishedEndpoints: Set<RuntimeEndpointIdentifier> = [],
    moduleVersion: SemanticVersion = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(33)
    )
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: id,
        moduleVersion: moduleVersion,
        kind: kind,
        criticality: criticality,
        entryPoint: entryPoint,
        role: role,
        policyClass: policyClass,
        requestedCapabilities: capabilities,
        requiredServices: requiredServices,
        publishedServices: publishedServices,
        requiredModuleRoles: requiredRoles,
        consumedEndpoints: consumedEndpoints,
        publishedEndpoints: publishedEndpoints
    )
}

private func manifest(
    for descriptor: ModuleDescriptor,
    entitlementRequirement: EntitlementRequirement? = nil,
    policyClass: ModulePolicyClass? = nil
) -> ModuleManifest {
    ModuleManifest(
        runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        moduleID: descriptor.moduleID,
        displayName: descriptor.entryPoint,
        moduleVersion: descriptor.moduleVersion,
        moduleType: descriptor.kind,
        criticality: descriptor.criticality,
        supportedPlatforms: [.macOS],
        minimumOS: MinimumOSVersions(macOS: "15.0"),
        capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: descriptor.requiredServices.sorted(),
            requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
        ),
        defaultRole: descriptor.role,
        policyClass: policyClass,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted(),
        entitlementRequirement: entitlementRequirement
    )
}

private func factory(
    for descriptor: ModuleDescriptor,
    label: String? = nil,
    recorder: RuntimeRecorder? = nil,
    counter: FactoryCounter? = nil,
    start: @escaping @Sendable (ModuleContext) async throws -> Void = { _ in }
) -> AnyModuleFactory {
    AnyModuleFactory(descriptor: descriptor) {
        counter?.increment()
        return ProbeModule(
            descriptor: descriptor,
            startAction: { context in
                if let label, let recorder {
                    await recorder.append("start:\(label)")
                }
                try await start(context)
            },
            stopAction: {
                if let label, let recorder {
                    await recorder.append("stop:\(label)")
                }
            }
        )
    }
}

private func makeRuntime(
    policy: RuntimePolicy = .patternBFoundation,
    environment: RuntimeEnvironment = .live,
    eligibility: any ModuleEligibilityProviding = AlwaysEligibleProvider()
) -> RuneScribeRuntime {
    RuneScribeRuntime(
        runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        platform: .macOS,
        policy: policy,
        eligibility: eligibility,
        environment: environment
    )
}
