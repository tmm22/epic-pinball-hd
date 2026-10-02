import COpenMPT
import Foundation

/// How samples are resampled to the output rate.
public enum AudioInterpolation: String, Sendable, CaseIterable {
    /// Nearest neighbour with a 16.16 step truncated like the MASI SB driver
    /// (MDRV004R file 0xB03) and nearest-neighbour libopenmpt music. Default.
    case original
    /// Linear interpolation for SFX, libopenmpt's default filter for music.
    case smooth
}

public struct AudioOptions: Sendable {
    public var interpolation: AudioInterpolation
    public var volumes: AudioVolumes
    /// Largest block rendered in one go; bigger requests are split. Sizes the
    /// preallocated music scratch buffers.
    public var maxBlockFrames: Int
    public init(interpolation: AudioInterpolation = .original,
                volumes: AudioVolumes = AudioVolumes(), maxBlockFrames: Int = 4096) {
        self.interpolation = interpolation; self.volumes = volumes
        self.maxBlockFrames = max(64, maxBlockFrames)
    }
}

/// The classic sound mixer: 4 round-robin SFX channels with the original's
/// pitch semantics plus one libopenmpt music module. Used by both the real-time
/// engine (from the audio thread) and the offline renderer.
///
/// Real-time rules for `apply(_:)` and `render(...)`: no allocation, no locks,
/// no Swift arrays/classes touched (all state is in raw pointers).
final class ClassicMixer: @unchecked Sendable {
    struct Voice {
        var active = false
        var sample: Int32 = -1
        var start = 0          // offset into pcm
        var length = 0         // samples
        var pos: UInt64 = 0    // 16.16 position within the sample
        var step: UInt64 = 0   // 16.16 increment per output frame
        var rateHz: Int32 = 0
        var sweepPerFrame: Int32 = 0
        var sweepFramesLeft: Int32 = 0
        var gainL: Float = 1
        var gainR: Float = 1
    }

    static let maxSongs = 32

    let sampleRate: Int
    /// Render-thread state: changed by `.interpolation` commands (`AudioEngine.setInterpolation`).
    private(set) var interpolation: AudioInterpolation
    let maxBlock: Int

    // SFX bank, immutable after init.
    private let pcm: UnsafeMutablePointer<Float>
    private let pcmCount: Int
    private let sampleStart: UnsafeMutablePointer<Int>
    private let sampleLength: UnsafeMutablePointer<Int>
    let sampleCount: Int

    // Voices = logical channels (sfx_channel_rr / sfx_channel_handle[]).
    let voices: UnsafeMutablePointer<Voice>
    private(set) var roundRobin = 0

    // Game-frame clock for sweeps.
    private(set) var sampleClock: Int64 = 0
    private(set) var frameIndex: Int64 = 0
    private var nextTick: Int64 = 0

    // Music: song slots hold libopenmpt handles owned by a MusicModule elsewhere.
    let songSlots: UnsafeMutablePointer<OpaquePointer?>
    private(set) var currentSong: Int32 = -1
    private var current: OpaquePointer? = nil
    private(set) var musicPaused = false
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>

    // Gains.
    private var master: Float
    private var sfxGain: Float
    private var musicGain: Float

    init(bank: SfxBank?, sampleRate: Int, options: AudioOptions) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
        interpolation = options.interpolation
        maxBlock = options.maxBlockFrames
        let samples = bank?.samples ?? []
        sampleCount = samples.count
        let total = samples.reduce(0) { $0 + $1.count }
        pcmCount = total
        pcm = .allocate(capacity: max(1, total))
        sampleStart = .allocate(capacity: max(1, samples.count))
        sampleLength = .allocate(capacity: max(1, samples.count))
        var o = 0
        for (i, s) in samples.enumerated() {
            sampleStart[i] = o
            sampleLength[i] = s.count
            for (j, b) in s.enumerated() { pcm[o + j] = Float(b) / 128 }
            o += s.count
        }
        voices = .allocate(capacity: ClassicSoundMap.channels)
        voices.initialize(repeating: Voice(), count: ClassicSoundMap.channels)
        songSlots = .allocate(capacity: Self.maxSongs)
        songSlots.initialize(repeating: nil, count: Self.maxSongs)
        scratchL = .allocate(capacity: options.maxBlockFrames)
        scratchR = .allocate(capacity: options.maxBlockFrames)
        master = options.volumes.master
        sfxGain = options.volumes.sfx
        musicGain = options.volumes.music
        nextTick = tickSample(1)
    }

    deinit {
        pcm.deallocate()
        sampleStart.deallocate()
        sampleLength.deallocate()
        voices.deinitialize(count: ClassicSoundMap.channels)
        voices.deallocate()
        songSlots.deinitialize(count: Self.maxSongs)
        songSlots.deallocate()
        scratchL.deallocate()
        scratchR.deallocate()
    }

    // MARK: control-thread setup (before the command that uses the slot is queued)

    /// Makes a module available as song `song`. Call from the control thread
    /// before queueing a `.music` command for that slot; slots are write-once
    /// while the audio thread may be running.
    /// `interpolation`: the control thread's current choice (default: the mixer's own, for a
    /// mixer that is not rendering yet). The module is not visible to the audio thread until the
    /// slot is written, so setting its filter here does not race.
    func install(module: MusicModule, song: Int, interpolation i: AudioInterpolation? = nil) {
        precondition((0..<Self.maxSongs).contains(song))
        module.setInterpolation(filterLength: Self.filterLength(i ?? interpolation))
        songSlots[song] = module.handle
    }

    /// libopenmpt's interpolation filter length: 1 = nearest neighbour, 0 = its default.
    static func filterLength(_ i: AudioInterpolation) -> Int32 { i == .original ? 1 : 0 }

    func hasSong(_ song: Int) -> Bool {
        (0..<Self.maxSongs).contains(song) && songSlots[song] != nil
    }

    // MARK: render-thread API

    @inline(__always)
    private func tickSample(_ frame: Int64) -> Int64 {
        Int64((Double(frame) * Double(sampleRate) / ClassicSoundMap.frameRateHz).rounded(.down))
    }

    @inline(__always)
    private func step(forRate rate: Int32) -> UInt64 {
        // Driver: step = rate / mix_rate as 16.16 (integer part and remainder
        // divided separately; the result equals floor(rate * 65536 / mix_rate)).
        (UInt64(max(rate, 0)) << 16) / UInt64(sampleRate)
    }

    func apply(_ command: AudioCommand) {
        switch command {
        case let .sfx(raw): play(raw)
        case .stopSfx:
            for i in 0..<ClassicSoundMap.channels { voices[i].active = false }
        case let .music(song, order):
            if song < 0 || Int(song) >= Self.maxSongs || songSlots[Int(song)] == nil {
                current = nil
                currentSong = -1
            } else {
                current = songSlots[Int(song)]
                currentSong = song
                if order >= 0, let h = current {
                    _ = openmpt_module_set_position_order_row(h, order, 0)
                }
            }
        case let .pauseMusic(p): musicPaused = p
        case let .volumes(m, s, mu):
            master = m; sfxGain = s; musicGain = mu
        case let .interpolation(smooth):
            // Takes effect from this block on (playing voices keep their position). Setting a
            // render parameter is a plain store in libopenmpt, no allocation.
            let i: AudioInterpolation = smooth ? .smooth : .original
            guard i != interpolation else { return }
            interpolation = i
            for k in 0..<Self.maxSongs { if let h = songSlots[k] { _ = openmpt_module_set_render_param(h, Int32(OPENMPT_MODULE_RENDER_INTERPOLATIONFILTER_LENGTH), Self.filterLength(i)) } }
        }
    }

    /// `sfx_play` (EP1 cs:014A): advance the round-robin channel, stop that
    /// channel's previous voice, start the sample at the current rate, then pan.
    private func play(_ c: SfxCommand.Raw) {
        let idx = Int(c.sample)
        guard idx >= 0, idx < sampleCount, sampleLength[idx] > 0, c.rateHz > 0 else { return }
        roundRobin += 1
        if roundRobin >= ClassicSoundMap.channels { roundRobin = 0 }
        var v = Voice()
        v.active = true
        v.sample = c.sample
        v.start = sampleStart[idx]
        v.length = sampleLength[idx]
        v.rateHz = c.rateHz
        v.step = step(forRate: c.rateHz)
        v.sweepPerFrame = c.sweepPerFrame
        v.sweepFramesLeft = max(0, c.sweepFrames)
        // Pan 0...15 (sent to MASI as p*16-128). Balance law, centre = both full. [L]
        if c.pan >= 0 {
            let x = Float(c.pan) / 15
            v.gainL = min(1, 2 * (1 - x))
            v.gainR = min(1, 2 * x)
        }
        voices[roundRobin] = v
    }

    /// Per game frame: apply pitch sweeps to playing voices.
    private func frameTick() {
        for i in 0..<ClassicSoundMap.channels where voices[i].active && voices[i].sweepFramesLeft > 0 {
            var r = Int64(voices[i].rateHz) + Int64(voices[i].sweepPerFrame)
            r = max(1, min(r, Int64(Int32.max)))
            voices[i].rateHz = Int32(r)
            voices[i].step = step(forRate: voices[i].rateHz)
            voices[i].sweepFramesLeft -= 1
        }
    }

    /// Renders `frames` stereo frames, overwriting `left`/`right`.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < frames {
            var n = min(frames - done, maxBlock)
            let untilTick = Int(nextTick - sampleClock)
            if untilTick > 0 { n = min(n, untilTick) }
            renderSegment(n, left + done, right + done)
            done += n
            sampleClock += Int64(n)
            while sampleClock >= nextTick {
                frameIndex += 1
                nextTick = tickSample(frameIndex + 1)
                frameTick()
            }
        }
    }

    private func renderSegment(_ n: Int, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>) {
        l.update(repeating: 0, count: n)
        r.update(repeating: 0, count: n)
        // SFX
        let linear = interpolation == .smooth
        for vi in 0..<ClassicSoundMap.channels where voices[vi].active {
            var v = voices[vi]
            let end = UInt64(v.length) << 16
            let base = pcm + v.start
            let gl = v.gainL * sfxGain, gr = v.gainR * sfxGain
            var p = v.pos
            var i = 0
            while i < n {
                if p >= end { v.active = false; break }
                let k = Int(p >> 16)
                var s = base[k]
                if linear, k + 1 < v.length {
                    let f = Float(p & 0xFFFF) * (1.0 / 65536)
                    s += (base[k + 1] - s) * f
                }
                l[i] += s * gl
                r[i] += s * gr
                p &+= v.step
                i += 1
            }
            v.pos = p
            voices[vi] = v
        }
        // Music
        if let h = current, !musicPaused {
            let got = openmpt_module_read_float_stereo(h, Int32(sampleRate), n, scratchL, scratchR)
            let g = musicGain
            for i in 0..<min(got, n) {
                l[i] += scratchL[i] * g
                r[i] += scratchR[i] * g
            }
        }
        // Master + hard clip.
        let m = master
        for i in 0..<n {
            l[i] = max(-1, min(1, l[i] * m))
            r[i] = max(-1, min(1, r[i] * m))
        }
    }

    // MARK: inspection (tests / diagnostics; not for the audio thread)

    func voiceSnapshot() -> [Voice] {
        (0..<ClassicSoundMap.channels).map { voices[$0] }
    }
}
