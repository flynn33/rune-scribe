import AudioToolbox
import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribePlatform
import XCTest

@MainActor
final class AppleUnlockFeedbackTests: XCTestCase {
    func testFallbackAssetsMatchDeterministicHashesAndAudioLimits() throws {
        let expectedMaximumDuration: [UnlockFeedbackFallbackResourceID: Double] = [
            .micro: 0.7,
            .artifact: 1.0,
            .codex: 2.0,
            .mastery: 2.3,
        ]
        var combinedBytes = 0

        for descriptor in UnlockFeedbackFallbackResourceDescriptor.all {
            let url = try XCTUnwrap(
                AppleUnlockFeedbackService.bundledResourceURL(descriptor: descriptor)
            )
            let data = try Data(contentsOf: url)
            combinedBytes += data.count
            let wave = try PCM16Wave(data: data)
            let digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()

            XCTAssertEqual(digest, descriptor.sha256, descriptor.filename)
            XCTAssertEqual(wave.channels, 1, descriptor.filename)
            XCTAssertEqual(wave.sampleRate, 22_050, descriptor.filename)
            XCTAssertEqual(wave.bitsPerSample, 16, descriptor.filename)
            XCTAssertEqual(
                wave.durationSeconds,
                descriptor.durationSeconds,
                accuracy: 1.0 / Double(wave.sampleRate),
                descriptor.filename
            )
            XCTAssertLessThanOrEqual(
                wave.durationSeconds,
                try XCTUnwrap(expectedMaximumDuration[descriptor.resourceID]),
                descriptor.filename
            )
            XCTAssertGreaterThan(wave.peakMagnitude, 0, descriptor.filename)
            XCTAssertLessThan(wave.peakMagnitude, Int32(Int16.max), descriptor.filename)
        }

        XCTAssertEqual(UnlockFeedbackFallbackResourceDescriptor.all.count, 4)
        XCTAssertEqual(
            Set(UnlockFeedbackFallbackResourceDescriptor.all.map(\.resourceID)),
            Set(UnlockFeedbackFallbackResourceID.allCases)
        )
        XCTAssertLessThan(combinedBytes, 1_048_576)
    }

    func testFallbackPlaybackCannotOverlapTheNextAutomaticReveal() throws {
        let presentationSequenceDuration: [UnlockFeedbackFallbackResourceID: Double] = [
            .micro: 0.75,
            .artifact: 1.25,
            .codex: 2.30,
            .mastery: 2.40,
        ]

        for descriptor in UnlockFeedbackFallbackResourceDescriptor.all {
            XCTAssertLessThan(
                descriptor.durationSeconds,
                try XCTUnwrap(presentationSequenceDuration[descriptor.resourceID]),
                "The fallback must finish before the FIFO reveal can advance"
            )
        }
    }

    func testIndependentSettingsUseOnlyRequestedFeedbackAndOneHaptic() async {
        let recorder = FeedbackOperationsRecorder()
        let service = AppleUnlockFeedbackService(
            operations: recorder.operations
        )

        await service.perform(UnlockFeedbackRequestDTO(
            tier: .micro,
            soundEnabled: false,
            hapticEnabled: false
        ))
        XCTAssertTrue(recorder.playedSounds.isEmpty)
        XCTAssertEqual(recorder.hapticCount, 0)

        await service.perform(UnlockFeedbackRequestDTO(
            tier: .artifact,
            soundEnabled: true,
            hapticEnabled: false
        ))
        XCTAssertEqual(recorder.playedSounds.count, 1)
        XCTAssertEqual(recorder.hapticCount, 0)

        await service.perform(UnlockFeedbackRequestDTO(
            tier: .mastery,
            soundEnabled: false,
            hapticEnabled: true
        ))
        XCTAssertEqual(
            recorder.playedSounds.count,
            1,
            "Haptic-only feedback must not play a fallback sound"
        )
        XCTAssertEqual(recorder.hapticCount, 1)
        XCTAssertEqual(Set(recorder.loadedFilenames).count, 4)
    }

    func testPlaybackBoundaryDoesNotUseAudioSessionOrUIPlaybackFrameworks() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let platformSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/RuneScribePlatform/Feedback/AppleUnlockFeedbackService.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(platformSource.contains("AVFoundation"))
        XCTAssertFalse(platformSource.contains("AVAudioSession"))
        XCTAssertFalse(platformSource.contains("setActive"))

        let uiRoot = packageRoot.appendingPathComponent("Sources/RuneScribeUIModule")
        let uiFiles = try FileManager.default.subpathsOfDirectory(atPath: uiRoot.path)
            .filter { $0.hasSuffix(".swift") }
        for relativePath in uiFiles {
            let source = try String(
                contentsOf: uiRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("import AVFoundation"), relativePath)
            XCTAssertFalse(source.contains("import AudioToolbox"), relativePath)
            if [
                "Presentation/RuneScribeUISession+Progression.swift",
                "Views/RootView.swift",
                "Views/SettingsView.swift",
                "Views/UnlockRevealView.swift",
                "Views/VaultProgressView.swift",
            ].contains(relativePath) {
                XCTAssertFalse(source.contains("import UIKit"), relativePath)
                XCTAssertFalse(source.contains("import AppKit"), relativePath)
            }
        }
    }

    func testGenerationSourceIsOfflineAndDocumentsEveryDigest() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot
            .appendingPathComponent("Sources/RuneScribePlatform/Feedback/Resources/Source")
        let generator = try String(
            contentsOf: sourceRoot.appendingPathComponent("make_fallback_sounds.swift"),
            encoding: .utf8
        )
        let notes = try String(
            contentsOf: sourceRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        for forbidden in ["URLSession", "http://", "https://", "sample file"] {
            XCTAssertFalse(generator.contains(forbidden))
        }
        for descriptor in UnlockFeedbackFallbackResourceDescriptor.all {
            XCTAssertTrue(notes.contains(descriptor.sha256), descriptor.filename)
            XCTAssertTrue(notes.contains(descriptor.filename), descriptor.filename)
        }
    }
}

private struct PCM16Wave {
    let channels: UInt16
    let sampleRate: UInt32
    let bitsPerSample: UInt16
    let durationSeconds: Double
    let peakMagnitude: Int32

    init(data: Data) throws {
        guard data.count >= 44,
              String(data: data[0 ..< 4], encoding: .ascii) == "RIFF",
              String(data: data[8 ..< 12], encoding: .ascii) == "WAVE",
              String(data: data[12 ..< 16], encoding: .ascii) == "fmt ",
              String(data: data[36 ..< 40], encoding: .ascii) == "data"
        else { throw WaveError.invalidHeader }
        let format = data.uint16LE(at: 20)
        channels = data.uint16LE(at: 22)
        sampleRate = data.uint32LE(at: 24)
        bitsPerSample = data.uint16LE(at: 34)
        let payloadByteCount = Int(data.uint32LE(at: 40))
        guard format == 1,
              channels > 0,
              sampleRate > 0,
              bitsPerSample == 16,
              payloadByteCount == data.count - 44,
              payloadByteCount.isMultiple(of: 2)
        else { throw WaveError.invalidFormat }

        durationSeconds = Double(payloadByteCount)
            / Double(Int(sampleRate) * Int(channels) * 2)
        var peak: Int32 = 0
        var offset = 44
        while offset < data.count {
            let sample = Int16(bitPattern: data.uint16LE(at: offset))
            peak = max(peak, abs(Int32(sample)))
            offset += 2
        }
        peakMagnitude = peak
    }

    private enum WaveError: Error {
        case invalidHeader
        case invalidFormat
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

private final class FeedbackOperationsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSoundID: SystemSoundID = 1
    private var _loadedFilenames: [String] = []
    private var _playedSounds: [SystemSoundID] = []
    private var _hapticCount = 0

    lazy var operations = AppleUnlockFeedbackOperations(
        makeSound: { [self] url in
            lock.withLock {
                _loadedFilenames.append(url.lastPathComponent)
                defer { nextSoundID += 1 }
                return nextSoundID
            }
        },
        playSound: { [self] soundID in
            lock.withLock { _playedSounds.append(soundID) }
        },
        disposeSound: { _ in },
        performHaptic: { [self] in
            lock.withLock { _hapticCount += 1 }
        }
    )

    var loadedFilenames: [String] {
        lock.withLock { _loadedFilenames }
    }

    var playedSounds: [SystemSoundID] {
        lock.withLock { _playedSounds }
    }

    var hapticCount: Int {
        lock.withLock { _hapticCount }
    }
}
