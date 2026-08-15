import AudioToolbox
import Foundation
import RuneScribeContracts

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct UnlockFeedbackFallbackResourceDescriptor: Equatable, Sendable {
    let resourceID: UnlockFeedbackFallbackResourceID
    let filename: String
    let sha256: String
    let durationSeconds: Double

    static let all: [Self] = [
        Self(
            resourceID: .micro,
            filename: "unlock_micro",
            sha256: "49c4cfb544be9dc7d42d31cc6f1da82fcc96e02fd78ee7ca60f165d1a0eaa8c5",
            durationSeconds: 0.55
        ),
        Self(
            resourceID: .artifact,
            filename: "unlock_artifact",
            sha256: "3e0aad842b786515a43e3942d0b0ec8519396efccdb2d2b738ccf07984d9da7d",
            durationSeconds: 1.00
        ),
        Self(
            resourceID: .codex,
            filename: "unlock_codex",
            sha256: "fa23a17ee1af6e845b77f9079b49d4b26921bdeb7cf3d30f45db5510df99719b",
            durationSeconds: 1.75
        ),
        Self(
            resourceID: .mastery,
            filename: "unlock_mastery",
            sha256: "1e23ca022369024eb2339f7d7738841011041095d62bc9a285583be37325af31",
            durationSeconds: 2.20
        ),
    ]

    static func descriptor(
        for resourceID: UnlockFeedbackFallbackResourceID
    ) -> Self? {
        all.first { $0.resourceID == resourceID }
    }
}

struct AppleUnlockFeedbackOperations: @unchecked Sendable {
    let makeSound: @Sendable (URL) -> SystemSoundID?
    let playSound: @Sendable (SystemSoundID) -> Void
    let disposeSound: @Sendable (SystemSoundID) -> Void
    let performHaptic: @MainActor @Sendable () -> Void

    static let system = Self(
        makeSound: { url in
            var soundID = SystemSoundID()
            guard AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == kAudioServicesNoError
            else { return nil }
            return soundID
        },
        playSound: { soundID in
            AudioServicesPlaySystemSound(soundID)
        },
        disposeSound: { soundID in
            AudioServicesDisposeSystemSoundID(soundID)
        },
        performHaptic: {
            #if os(iOS)
            let feedback = UIImpactFeedbackGenerator(style: .soft)
            feedback.prepare()
            feedback.impactOccurred(intensity: 0.55)
            #elseif os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
            #endif
        }
    )
}

/// Plays generic fallback effects through System Sound Services. It never
/// activates or reconfigures an audio session, so iOS retains silent-mode and
/// system-volume behavior and existing audio is not taken over.
@MainActor
public final class AppleUnlockFeedbackService: UnlockFeedbackProviding {
    private let operations: AppleUnlockFeedbackOperations
    private var sounds: [UnlockFeedbackFallbackResourceID: SystemSoundID] = [:]

    public convenience init() {
        self.init(bundle: .module, operations: .system)
    }

    convenience init(operations: AppleUnlockFeedbackOperations) {
        self.init(bundle: .module, operations: operations)
    }

    init(
        bundle: Bundle,
        operations: AppleUnlockFeedbackOperations
    ) {
        self.operations = operations
        for descriptor in UnlockFeedbackFallbackResourceDescriptor.all {
            guard let url = Self.resourceURL(
                descriptor: descriptor,
                bundle: bundle
            ), let soundID = operations.makeSound(url) else { continue }
            sounds[descriptor.resourceID] = soundID
        }
    }

    public func perform(_ request: UnlockFeedbackRequestDTO) async {
        if request.soundEnabled,
           let soundID = sounds[request.fallbackResourceID] {
            operations.playSound(soundID)
        }
        if request.hapticEnabled {
            operations.performHaptic()
        }
    }

    deinit {
        for soundID in sounds.values {
            operations.disposeSound(soundID)
        }
    }

    static func resourceURL(
        descriptor: UnlockFeedbackFallbackResourceDescriptor,
        bundle: Bundle
    ) -> URL? {
        bundle.url(forResource: descriptor.filename, withExtension: "wav")
            ?? bundle.url(
                forResource: descriptor.filename,
                withExtension: "wav",
                subdirectory: "Feedback/Resources"
            )
    }

    static func bundledResourceURL(
        descriptor: UnlockFeedbackFallbackResourceDescriptor
    ) -> URL? {
        resourceURL(descriptor: descriptor, bundle: .module)
    }
}
