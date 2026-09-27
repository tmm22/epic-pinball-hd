import Foundation
import PinballCore
import XCTest
@testable import PinballAudio

/// Repo root, derived from this file's path (app/Tests/PinballAudioTests/...).
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let scratchAudio = repoRoot.appendingPathComponent("scratch/audio", isDirectory: true)

private func originalDirOrSkip() throws -> URL {
    guard let dir = OriginalDataLocator.resolve() else {
        throw XCTSkip("no original/ game files (SFX1.PIN) found; tried \(OriginalDataLocator.candidates().map(\.path))")
    }
    return dir
}

// MARK: synthetic data (no game data in the repository)

/// Builds an SFX bank image in the launcher's layout from raw sample bodies.
/// Each body is stored after 16 skipped bytes, with 24 trailing bytes, so the
/// header len = body + 40.
private func makeBank(_ bodies: [[Int8]], extraEntryAfterGap: Bool = false) -> Data {
    var bytes = [UInt8](repeating: 0, count: 0x70) // header + pad, sample 0 at para 7
    var header: [(Int, Int)] = []
    for body in bodies {
        while bytes.count % 16 != 0 { bytes.append(0) }
        let paras = bytes.count / 16
        header.append((body.count + 40, paras))
        bytes += [UInt8](repeating: 0x55, count: 16)          // skipped head
        bytes += body.map { UInt8(bitPattern: $0) }
        bytes += [UInt8](repeating: 0x66, count: 24)          // trimmed tail
    }
    for (i, (len, paras)) in header.enumerated() {
        bytes[i * 4] = UInt8(len & 0xFF); bytes[i * 4 + 1] = UInt8(len >> 8)
        bytes[i * 4 + 2] = UInt8(paras & 0xFF); bytes[i * 4 + 3] = UInt8(paras >> 8)
    }
    if extraEntryAfterGap {
        // Entry after a zero-paragraph entry: the launcher never loads it.
        let i = header.count + 1
        bytes[i * 4] = 100; bytes[i * 4 + 2] = 7
    }
    return Data(bytes)
}

/// Sine with no exact zeros (phase offset half a step): `cycles` cycles over n samples.
private func sine(n: Int, cycles: Int, amplitude: Double = 100) -> [Int8] {
    (0..<n).map { k in
        Int8((amplitude * sin(2 * Double.pi * Double(cycles) * (Double(k) + 0.5) / Double(n))).rounded())
    }
}

private func lastNonZero(_ a: [Float]) -> Int {
    (a.lastIndex { $0 != 0 } ?? -1) + 1
}

private let unity = AudioOptions(volumes: AudioVolumes(master: 1, sfx: 1, music: 1))

final class SfxBankTests: XCTestCase {
    func testSyntheticBankUsesLauncherTrim() throws {
        let a: [Int8] = (0..<60).map { Int8($0 - 30) }
        let b: [Int8] = (0..<17).map { Int8(-$0) }
        let bank = try SfxBank(data: makeBank([a, b], extraEntryAfterGap: true))
        XCTAssertEqual(bank.count, 2, "loading stops at the first entry with paras == 0")
        XCTAssertEqual(bank.samples[0], a)
        XCTAssertEqual(bank.samples[1], b)
        XCTAssertEqual(bank.entries[0].playOffset, (bank.entries[0].paragraphs + 1) * 16)
        XCTAssertEqual(bank.entries[1].playLength, bank.entries[1].headerLength - 40)
    }

    func testShortBankThrows() {
        XCTAssertThrowsError(try SfxBank(data: Data(count: 10)))
    }

    func testUserBanksParse() throws {
        let dir = try originalDirOrSkip()
        for n in 0...13 {
            let url = ClassicSoundMap.sfxURL(originalDir: dir, bank: n)
            let bank = try SfxBank(contentsOf: url)
            let raw = try Data(contentsOf: url)
            XCTAssertGreaterThan(bank.count, 0, "SFX\(n)")
            XCTAssertLessThanOrEqual(bank.count, SfxBank.headerEntries)
            for e in bank.entries {
                XCTAssertEqual(e.playOffset, (e.paragraphs + 1) * 16)
                XCTAssertEqual(e.playLength, e.headerLength - 40, "SFX\(n) #\(e.index) fits in the file")
                XCTAssertLessThanOrEqual(e.playOffset + e.playLength, raw.count)
                XCTAssertEqual(bank.samples[e.index].count, e.playLength)
            }
        }
    }
}

final class CommandQueueTests: XCTestCase {
    func testOrderAndOverflow() {
        let q = CommandQueue(capacityPowerOfTwo: 4)
        for i in 0..<5 { q.push(.sfx(SfxCommand(sample: i).raw)) }
        XCTAssertEqual(q.dropped, 1)
        var got: [Int32] = []
        q.drain { if case let .sfx(r) = $0 { got.append(r.sample) } }
        XCTAssertEqual(got, [0, 1, 2, 3])
        q.push(.sfx(SfxCommand(sample: 9).raw))
        got = []
        q.drain { if case let .sfx(r) = $0 { got.append(r.sample) } }
        XCTAssertEqual(got, [9])
    }
}

final class MixerTests: XCTestCase {
    let rate = 48000

    /// Frames until the voice ends with the driver's truncated 16.16 step.
    func expectedLength(samples n: Int, rateHz: Int) -> Int {
        let step = (UInt64(rateHz) << 16) / UInt64(rate)
        let end = UInt64(n) << 16
        return Int((end + step - 1) / step)
    }

    func testResampledLengthAndPitch() throws {
        let n = 1100, cycles = 100 // 1000 Hz at the 11000 Hz base rate
        let bank = try SfxBank(data: makeBank([sine(n: n, cycles: cycles)]))
        let r = OfflineAudioRenderer(bank: bank, sampleRate: rate, options: unity)
        for hz in [5500, 11000, 22000, 3000, 24000] {
            let out = r.render(script: [ScriptedAudioEvent(frame: 0, .sfx(SfxCommand(sample: 0, rateHz: hz)))],
                               seconds: 0.5)
            let len = lastNonZero(out.left)
            XCTAssertEqual(len, expectedLength(samples: n, rateHz: hz), "length at \(hz) Hz")
            // Duration n/hz seconds, pitch 1000 * hz / 11000.
            XCTAssertEqual(Double(len) / Double(rate), Double(n) / Double(hz), accuracy: 2.0 / Double(rate))
            let measuredHz = Double(cycles) / (Double(len) / Double(rate))
            XCTAssertEqual(measuredHz, 1000 * Double(hz) / 11000, accuracy: 1000 * Double(hz) / 11000 * 0.005)
            // Zero-crossing count is rate independent (every cycle is rendered).
            var crossings = 0
            for i in 1..<len where (out.left[i - 1] < 0) != (out.left[i] < 0) { crossings += 1 }
            XCTAssertEqual(Double(crossings), Double(2 * cycles), accuracy: 2)
        }
    }

    func testSweepChangesRateEachFrame() throws {
        let n = 11000
        let body = [Int8](repeating: 50, count: n)
        let bank = try SfxBank(data: makeBank([body]))
        let r = OfflineAudioRenderer(bank: bank, sampleRate: rate, options: unity)
        let out = r.render(script: [ScriptedAudioEvent(frame: 0, .sfx(SfxCommand(sample: 0, rateHz: 11000,
                                                                                    sweepPerFrame: 1000, sweepFrames: 10)))],
                           seconds: 1.5)
        // Reference: the rate steps up by 1000 Hz at each frame tick, 10 times.
        var pos: UInt64 = 0, frame: Int64 = 0, hz = 11000, i = 0
        var nextTick = Int64((Double(1) * Double(rate) / ClassicSoundMap.frameRateHz).rounded(.down))
        while pos < UInt64(n) << 16 {
            pos += (UInt64(hz) << 16) / UInt64(rate)
            i += 1
            if Int64(i) >= nextTick {
                frame += 1
                nextTick = Int64((Double(frame + 1) * Double(rate) / ClassicSoundMap.frameRateHz).rounded(.down))
                if frame <= 10 { hz += 1000 }
            }
        }
        XCTAssertEqual(lastNonZero(out.left), i)
        XCTAssertLessThan(i, expectedLength(samples: n, rateHz: 11000))
    }

    func testRoundRobinFourChannels() throws {
        let bank = try SfxBank(data: makeBank((0..<6).map { _ in [Int8](repeating: 10, count: 5000) }))
        let r = OfflineAudioRenderer(bank: bank, sampleRate: rate, options: unity)
        let mixer = r.makeMixer()
        for s in 0..<5 { mixer.apply(.sfx(SfxCommand(sample: s).raw)) }
        // sfx_play increments the channel before use: plays go to 1,2,3,0,1.
        XCTAssertEqual(mixer.voiceSnapshot().map(\.sample), [3, 4, 1, 2])
        XCTAssertEqual(mixer.voiceSnapshot().filter(\.active).count, 4)
        mixer.apply(.stopSfx)
        XCTAssertEqual(mixer.voiceSnapshot().filter(\.active).count, 0)
        // Invalid sample ids and rates are ignored (no channel consumed).
        mixer.apply(.sfx(SfxCommand(sample: 99).raw))
        mixer.apply(.sfx(SfxCommand(sample: 0, rateHz: 0).raw))
        XCTAssertEqual(mixer.roundRobin, 1)
    }

    func testPan() throws {
        let bank = try SfxBank(data: makeBank([[Int8](repeating: 64, count: 500)]))
        let r = OfflineAudioRenderer(bank: bank, sampleRate: rate, options: unity)
        let hardLeft = r.render(script: [ScriptedAudioEvent(frame: 0, .sfx(SfxCommand(sample: 0, pan: 0)))], seconds: 0.1)
        XCTAssertGreaterThan(lastNonZero(hardLeft.left), 0)
        XCTAssertEqual(lastNonZero(hardLeft.right), 0)
        let hardRight = r.render(script: [ScriptedAudioEvent(frame: 0, .sfx(SfxCommand(sample: 0, pan: 15)))], seconds: 0.1)
        XCTAssertEqual(lastNonZero(hardRight.left), 0)
        let centre = r.render(script: [ScriptedAudioEvent(frame: 0, .sfx(SfxCommand(sample: 0)))], seconds: 0.1)
        XCTAssertEqual(centre.left[10], 0.5, accuracy: 1e-6)
        XCTAssertEqual(centre.right[10], 0.5, accuracy: 1e-6)
    }

    func testEventTimingFollowsFrames() throws {
        let bank = try SfxBank(data: makeBank([[Int8](repeating: 64, count: 100)]))
        let r = OfflineAudioRenderer(bank: bank, sampleRate: rate, options: unity)
        let out = r.render(script: [ScriptedAudioEvent(frame: 30, .sfx(SfxCommand(sample: 0)))], seconds: 1)
        let first = out.left.firstIndex { $0 != 0 }
        XCTAssertEqual(first, Int((30 * Double(rate) / ClassicSoundMap.frameRateHz).rounded(.down)))
    }

    func testWAVHeader() {
        let a = RenderedAudio(sampleRate: 48000, left: [0, 0.5, -1], right: [0, -0.5, 1])
        let d = a.wavData()
        XCTAssertEqual(d.count, 44 + 12)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
    }
}

final class MusicTests: XCTestCase {
    func testLoadSong1AndJump() throws {
        let dir = try originalDirOrSkip()
        let m = try MusicModule.load(originalDir: dir, song: 1)
        XCTAssertEqual(m.metadata("type"), "psm")
        XCTAssertEqual(m.channelCount, 4)
        XCTAssertEqual(m.subsongCount, 1)
        XCTAssertGreaterThan(m.orderCount, 2)
        XCTAssertGreaterThan(m.durationSeconds, 10)

        let r = OfflineAudioRenderer(bank: nil, modules: [1: m], sampleRate: 48000, options: unity)
        let mixer = r.makeMixer()
        mixer.apply(.music(song: 1, order: 2))
        XCTAssertEqual(m.currentOrder, 2)
        var l = [Float](repeating: 0, count: 4800), rr = l
        l.withUnsafeMutableBufferPointer { lb in
            rr.withUnsafeMutableBufferPointer { rb in mixer.render(frames: 4800, left: lb.baseAddress!, right: rb.baseAddress!) }
        }
        XCTAssertEqual(m.currentOrder, 2)
        mixer.apply(.music(song: -1, order: 0))
        XCTAssertEqual(mixer.currentSong, -1)
    }

    func testMusicRendersAndPauses() throws {
        let dir = try originalDirOrSkip()
        let m = try MusicModule.load(originalDir: dir, song: 1)
        let r = OfflineAudioRenderer(bank: nil, modules: [1: m], sampleRate: 48000, options: unity)
        let out = r.render(script: [
            ScriptedAudioEvent(frame: 0, .music(MusicRequest(song: 1, order: 0))),
            ScriptedAudioEvent(frame: 120, .pauseMusic(true)),
        ], seconds: 3)
        let pauseAt = Int((120 * 48000 / ClassicSoundMap.frameRateHz).rounded(.down))
        let rms = sqrt(out.left[0..<pauseAt].reduce(0) { $0 + Double($1 * $1) } / Double(pauseAt))
        XCTAssertGreaterThan(rms, 0.005, "music is audible")
        XCTAssertTrue(out.left[pauseAt...].allSatisfy { $0 == 0 }, "paused music is silent")
    }
}

final class RenderToWAVTests: XCTestCase {
    /// Renders a scripted mix of table 1 (music + effects at several rates and a
    /// sweep) to scratch/audio/ for listening.
    func testTable1DemoWAV() throws {
        let dir = try originalDirOrSkip()
        let r = try OfflineAudioRenderer(dataDir: dir, table: 1)
        let bank = try XCTUnwrap(r.bank)
        var script: [ScriptedAudioEvent] = [.init(frame: 0, .music(MusicRequest(song: 1, order: 0)))]
        for i in 0..<bank.count {
            script.append(.sound(SoundEvent(sample: i, rateHz: 11000), atFrame: 30 + i * 30, pan: (i * 5) % 16))
        }
        let t = 30 + bank.count * 30
        script.append(.sound(SoundEvent(sample: 3, rateHz: 5500), atFrame: t))
        script.append(.sound(SoundEvent(sample: 3, rateHz: 22000), atFrame: t + 40))
        script.append(.sound(SoundEvent(sample: 3, rateHz: 3000, sweepPerFrame: 400, sweepFrames: 50), atFrame: t + 80))
        let seconds = Double(t + 160) / ClassicSoundMap.frameRateHz
        let out = r.render(script: script, seconds: seconds)
        let url = scratchAudio.appendingPathComponent("ep1_demo.wav")
        try out.writeWAV(to: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(size, 44 + out.frameCount * 4)

        // SFX only, each effect at the base rate, for A/B against DOSBox-X.
        let sfxOnly = OfflineAudioRenderer(bank: bank, sampleRate: 48000)
        let s = sfxOnly.render(script: (0..<bank.count).map { .sound(SoundEvent(sample: $0, rateHz: 11000), atFrame: $0 * 45) },
                               seconds: Double(bank.count * 45 + 60) / ClassicSoundMap.frameRateHz)
        try s.writeWAV(to: scratchAudio.appendingPathComponent("sfx1_all_11000.wav"))
    }

    /// Same graph as the live app (AVAudioSourceNode + command queue) in
    /// AVAudioEngine's offline manual-rendering mode.
    func testRealtimeGraphRendersOffline() throws {
        let dir = try originalDirOrSkip()
        let engine = try AudioEngine(dataDir: dir, table: 1)
        XCTAssertNotNil(engine.modules[1])
        engine.setVolumes(master: 1, sfx: 1, music: 0)
        engine.submit(events: [SoundEvent(sample: 0, rateHz: 11000)])
        let out = try engine.renderManually(frames: 4096)
        XCTAssertGreaterThan(out.left.map { abs($0) }.max() ?? 0, 0.001, "effect reaches the output")
        engine.startTableMusic()
        engine.setVolumes(master: 1, sfx: 0, music: 1)
        let music = try engine.renderManually(frames: 48000)
        XCTAssertGreaterThan(music.left.map { abs($0) }.max() ?? 0, 0.01, "music reaches the output")
        XCTAssertEqual(engine.droppedCommands, 0)
        engine.stop()
    }
}

final class LiveOutputTests: XCTestCase {
    /// Plays through the real output device for ~1.5 s. Opt-in: EP_AUDIO_LIVE=1.
    func testLivePlayback() throws {
        guard ProcessInfo.processInfo.environment["EP_AUDIO_LIVE"] != nil else { throw XCTSkip("set EP_AUDIO_LIVE=1 to play through the speakers") }
        let dir = try originalDirOrSkip()
        let engine = try AudioEngine(dataDir: dir, table: 1)
        try engine.start()
        XCTAssertTrue(engine.isRunning)
        engine.startTableMusic()
        for i in 0..<6 {
            engine.submit(events: [SoundEvent(sample: i, rateHz: 11000)])
            Thread.sleep(forTimeInterval: 0.25)
        }
        engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.droppedCommands, 0)
    }
}
