import Foundation

private let sampleRate: UInt32 = 22_050
private let maximumAmplitude: Int64 = 32_767

private struct Note {
    let start: Double
    let end: Double
    let frequencyMilliHertz: UInt64
    let amplitude: Int64
    let attack: Double
    let release: Double
}

private struct SoundPlan {
    let filename: String
    let duration: Double
    let notes: [Note]
}

private let plans = [
    SoundPlan(
        filename: "unlock_micro.wav",
        duration: 0.55,
        notes: [
            Note(
                start: 0.00,
                end: 0.52,
                frequencyMilliHertz: 523_251,
                amplitude: 7_200,
                attack: 0.025,
                release: 0.30
            ),
            Note(
                start: 0.00,
                end: 0.38,
                frequencyMilliHertz: 1_046_502,
                amplitude: 1_300,
                attack: 0.018,
                release: 0.24
            ),
        ]
    ),
    SoundPlan(
        filename: "unlock_artifact.wav",
        duration: 1.00,
        notes: [
            Note(
                start: 0.00,
                end: 0.62,
                frequencyMilliHertz: 391_995,
                amplitude: 5_800,
                attack: 0.030,
                release: 0.34
            ),
            Note(
                start: 0.24,
                end: 0.96,
                frequencyMilliHertz: 523_251,
                amplitude: 6_400,
                attack: 0.035,
                release: 0.42
            ),
        ]
    ),
    SoundPlan(
        filename: "unlock_codex.wav",
        duration: 1.75,
        notes: [
            Note(
                start: 0.00,
                end: 0.92,
                frequencyMilliHertz: 329_628,
                amplitude: 4_500,
                attack: 0.040,
                release: 0.48
            ),
            Note(
                start: 0.30,
                end: 1.28,
                frequencyMilliHertz: 440_000,
                amplitude: 4_800,
                attack: 0.040,
                release: 0.52
            ),
            Note(
                start: 0.64,
                end: 1.70,
                frequencyMilliHertz: 659_255,
                amplitude: 5_000,
                attack: 0.045,
                release: 0.62
            ),
        ]
    ),
    SoundPlan(
        filename: "unlock_mastery.wav",
        duration: 2.20,
        notes: [
            Note(
                start: 0.00,
                end: 1.12,
                frequencyMilliHertz: 261_626,
                amplitude: 4_000,
                attack: 0.045,
                release: 0.58
            ),
            Note(
                start: 0.25,
                end: 1.52,
                frequencyMilliHertz: 391_995,
                amplitude: 4_200,
                attack: 0.045,
                release: 0.64
            ),
            Note(
                start: 0.58,
                end: 2.10,
                frequencyMilliHertz: 523_251,
                amplitude: 4_600,
                attack: 0.050,
                release: 0.78
            ),
            Note(
                start: 0.92,
                end: 2.16,
                frequencyMilliHertz: 783_991,
                amplitude: 2_300,
                attack: 0.055,
                release: 0.82
            ),
        ]
    ),
]

private func sampleIndex(_ seconds: Double) -> Int {
    Int((seconds * Double(sampleRate)).rounded(.toNearestOrAwayFromZero))
}

/// Integer-only parabolic sine approximation. Fixed-point phase and envelopes
/// make every PCM sample reproducible without external synthesis libraries.
private func oscillator(phase: UInt32) -> Int64 {
    let signedPhase = Int64(Int32(bitPattern: phase))
    let x = signedPhase >> 16
    return 4 * x * (32_768 - abs(x)) / 32_768
}

private func envelope(note: Note, localSample: Int, noteSampleCount: Int) -> Int64 {
    let attackSamples = max(1, sampleIndex(note.attack))
    let releaseSamples = max(1, sampleIndex(note.release))
    let attackValue = min(maximumAmplitude, Int64(localSample) * maximumAmplitude / Int64(attackSamples))
    let remaining = max(0, noteSampleCount - localSample)
    let releaseValue = min(maximumAmplitude, Int64(remaining) * maximumAmplitude / Int64(releaseSamples))
    return min(attackValue, releaseValue)
}

private func render(_ plan: SoundPlan) -> [Int16] {
    let count = sampleIndex(plan.duration)
    return (0 ..< count).map { index in
        var mixed: Int64 = 0
        for note in plan.notes {
            let start = sampleIndex(note.start)
            let end = sampleIndex(note.end)
            guard index >= start, index < end else { continue }
            let local = index - start
            let phaseStep = UInt32(
                (note.frequencyMilliHertz << 32)
                    / (UInt64(sampleRate) * 1_000)
            )
            let phase = UInt32(truncatingIfNeeded: UInt64(local) * UInt64(phaseStep))
            let voice = oscillator(phase: phase)
            let shaped = voice * envelope(
                note: note,
                localSample: local,
                noteSampleCount: end - start
            ) / maximumAmplitude
            mixed += shaped * note.amplitude / maximumAmplitude
        }
        return Int16(clamping: mixed)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

private func waveData(samples: [Int16]) -> Data {
    let dataByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
    var data = Data()
    data.append(contentsOf: Data("RIFF".utf8))
    data.appendLittleEndian(UInt32(36) + dataByteCount)
    data.append(contentsOf: Data("WAVE".utf8))
    data.append(contentsOf: Data("fmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(sampleRate)
    data.appendLittleEndian(sampleRate * UInt32(MemoryLayout<Int16>.size))
    data.appendLittleEndian(UInt16(MemoryLayout<Int16>.size))
    data.appendLittleEndian(UInt16(16))
    data.append(contentsOf: Data("data".utf8))
    data.appendLittleEndian(dataByteCount)
    for sample in samples {
        data.appendLittleEndian(sample)
    }
    return data
}

let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outputDirectory = sourceDirectory.deletingLastPathComponent()
for plan in plans {
    let output = outputDirectory.appendingPathComponent(plan.filename)
    try waveData(samples: render(plan)).write(to: output, options: .atomic)
    print("Wrote \(output.path)")
}
