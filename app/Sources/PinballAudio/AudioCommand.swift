import COpenMPT
import Foundation
import PinballCore

/// A sound-effect trigger as the mixer sees it: `SoundEvent` plus a pan.
public struct SfxCommand: Sendable, Equatable {
    public var sample: Int
    public var rateHz: Int
    public var sweepPerFrame: Int
    public var sweepFrames: Int
    /// 0 (left) ... 15 (right); nil = centre. The original takes it from the
    /// sound id's pan nibble or from the ball x (`ClassicSoundMap.pan(forBallX:)`).
    public var pan: Int?

    public init(sample: Int, rateHz: Int = ClassicSoundMap.baseRateHz,
                sweepPerFrame: Int = 0, sweepFrames: Int = 0, pan: Int? = nil) {
        self.sample = sample; self.rateHz = rateHz
        self.sweepPerFrame = sweepPerFrame; self.sweepFrames = sweepFrames
        self.pan = pan
    }

    public init(_ e: SoundEvent, pan: Int? = nil) {
        self.init(sample: e.sample, rateHz: e.rateHz, sweepPerFrame: e.sweepPerFrame,
                  sweepFrames: e.sweepFrames, pan: pan)
    }
}

/// Linear gains (1 = unity: an SFX sample at full 8-bit scale reaches 1.0, music
/// as libopenmpt renders it). The launcher has music and SFX levels 0...7
/// (0 = off, default 4 each, sent to the driver as level << 5).
/// Defaults: SFX at 0.5 so effects sit about 5 dB above the music (measured RMS)
/// and rarely clip; the original's relative balance is not known. [L]
public struct AudioVolumes: Sendable, Equatable {
    public var master: Float
    public var sfx: Float
    public var music: Float
    public init(master: Float = 0.9, sfx: Float = 0.5, music: Float = 1.0) {
        self.master = master; self.sfx = sfx; self.music = music
    }
    /// Gain for a launcher volume level 0...7 (linear; the driver's curve is unknown).
    public static func gain(forLauncherLevel level: Int) -> Float {
        Float(max(0, min(level, 7))) / 7
    }
}

/// Everything the audio thread can be told. Trivial payloads only, so a value
/// can be copied through the lock-free ring without reference counting.
enum AudioCommand: Sendable {
    case sfx(SfxCommand.Raw)
    case stopSfx
    /// Switch to preloaded song slot `song` (or silence if < 0) at `order`, row 0.
    case music(song: Int32, order: Int32)
    case pauseMusic(Bool)
    case volumes(master: Float, sfx: Float, music: Float)
    /// Resampling: nearest neighbour (false, the original) or smooth.
    case interpolation(smooth: Bool)
}

extension SfxCommand {
    /// POD form of the command (pan -1 = centre).
    struct Raw: Sendable {
        var sample: Int32, rateHz: Int32, sweepPerFrame: Int32, sweepFrames: Int32, pan: Int32
    }
    var raw: Raw {
        Raw(sample: Int32(clamping: sample), rateHz: Int32(clamping: rateHz),
            sweepPerFrame: Int32(clamping: sweepPerFrame), sweepFrames: Int32(clamping: sweepFrames),
            pan: Int32(clamping: pan.map { max(0, min($0, 15)) } ?? -1))
    }
}

/// Single-consumer ring of `AudioCommand`. Producers are serialised by a lock
/// (never taken by the audio thread); the consumer (audio thread) only does
/// acquire/release loads and stores, no locks and no allocation.
final class CommandQueue: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let slots: UnsafeMutablePointer<AudioCommand>
    /// [0] = head (next write, producer-owned), [1] = tail (next read, consumer-owned).
    private let indices: UnsafeMutablePointer<Int>
    private let producerLock = NSLock()
    private(set) var dropped = 0

    init(capacityPowerOfTwo: Int = 1024) {
        precondition(capacityPowerOfTwo > 1 && capacityPowerOfTwo & (capacityPowerOfTwo - 1) == 0)
        capacity = capacityPowerOfTwo
        mask = capacityPowerOfTwo - 1
        slots = .allocate(capacity: capacityPowerOfTwo)
        slots.initialize(repeating: .stopSfx, count: capacityPowerOfTwo)
        indices = .allocate(capacity: 2)
        indices.initialize(repeating: 0, count: 2)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
        indices.deallocate()
    }

    /// Returns false (and counts a drop) when the ring is full.
    @discardableResult
    func push(_ c: AudioCommand) -> Bool {
        producerLock.lock(); defer { producerLock.unlock() }
        let head = indices[0]
        let tail = ep_atomic_load_acquire(indices + 1)
        if head - tail >= capacity { dropped += 1; return false }
        slots[head & mask] = c
        ep_atomic_store_release(indices, head + 1)
        return true
    }

    /// Consumer side (audio thread). Calls `body` for each pending command, in order.
    @inline(__always)
    func drain(_ body: (AudioCommand) -> Void) {
        let head = ep_atomic_load_acquire(indices)
        var tail = indices[1]
        while tail != head {
            body(slots[tail & mask])
            tail += 1
        }
        ep_atomic_store_release(indices + 1, tail)
    }
}
