import Foundation
import PinballCore

/// One scripted action at a game frame (59.94 Hz frames from t = 0).
public struct ScriptedAudioEvent: Sendable {
    public enum Action: Sendable {
        case sfx(SfxCommand)
        case music(MusicRequest)
        case pauseMusic(Bool)
        case stopSfx
        case volumes(AudioVolumes)
    }
    public var frame: Int
    public var action: Action
    public init(frame: Int, _ action: Action) { self.frame = frame; self.action = action }

    public static func sound(_ e: SoundEvent, atFrame f: Int, pan: Int? = nil) -> ScriptedAudioEvent {
        ScriptedAudioEvent(frame: f, .sfx(SfxCommand(e, pan: pan)))
    }
}

/// Rendered stereo float audio.
public struct RenderedAudio: Sendable {
    public var sampleRate: Int
    public var left: [Float]
    public var right: [Float]
    public var frameCount: Int { left.count }

    /// 16-bit PCM stereo WAV.
    public func wavData() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(frameCount * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(2); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.reserveCapacity(d.count + Int(dataBytes))
        for i in 0..<frameCount {
            for s in [left[i], right[i]] {
                let v = Int16(max(-32768, min(32767, (s * 32767).rounded())))
                u16(UInt16(bitPattern: v))
            }
        }
        return d
    }

    public func writeWAV(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try wavData().write(to: url)
    }
}

/// Headless renderer: same mixer as the real-time engine, driven by a script.
/// Events at frame f are applied at output sample floor(f * rate / 59.94), the
/// same instants at which the mixer's frame clock applies sweeps.
public final class OfflineAudioRenderer {
    public let sampleRate: Int
    public let bank: SfxBank?
    public private(set) var modules: [Int: MusicModule] = [:]
    private let options: AudioOptions

    public init(bank: SfxBank?, modules: [Int: MusicModule] = [:], sampleRate: Int = 48000,
                options: AudioOptions = AudioOptions()) {
        self.bank = bank
        self.modules = modules
        self.sampleRate = sampleRate
        self.options = options
    }

    /// Table n's bank and song from the user's original directory.
    public convenience init(dataDir: URL, table: Int, sampleRate: Int = 48000,
                            options: AudioOptions = AudioOptions()) throws {
        let bank = try SfxBank.load(originalDir: dataDir, bank: ClassicSoundMap.sfxBank(forTable: table))
        let song = ClassicSoundMap.song(forTable: table)
        let m = try MusicModule.load(originalDir: dataDir, song: song)
        self.init(bank: bank, modules: [song: m], sampleRate: sampleRate, options: options)
    }

    /// Renders `seconds` of audio. A fresh mixer is used per call, so each
    /// render starts from silence (module positions are reset by the script's
    /// `.music` requests).
    public func render(script: [ScriptedAudioEvent], seconds: Double) -> RenderedAudio {
        let mixer = ClassicMixer(bank: bank, sampleRate: sampleRate, options: options)
        for (song, m) in modules where (0..<ClassicMixer.maxSongs).contains(song) {
            mixer.install(module: m, song: song)
        }
        let total = max(0, Int((seconds * Double(sampleRate)).rounded()))
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        let events = script.enumerated().sorted {
            $0.element.frame != $1.element.frame ? $0.element.frame < $1.element.frame : $0.offset < $1.offset
        }.map(\.element)
        func sampleAt(frame: Int) -> Int {
            Int((Double(frame) * Double(sampleRate) / ClassicSoundMap.frameRateHz).rounded(.down))
        }
        var pos = 0
        var ei = 0
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                while pos < total {
                    while ei < events.count, sampleAt(frame: events[ei].frame) <= pos {
                        mixer.apply(Self.command(events[ei].action))
                        ei += 1
                    }
                    var end = total
                    if ei < events.count { end = min(end, max(pos + 1, sampleAt(frame: events[ei].frame))) }
                    mixer.render(frames: end - pos, left: lb.baseAddress! + pos, right: rb.baseAddress! + pos)
                    pos = end
                }
            }
        }
        return RenderedAudio(sampleRate: sampleRate, left: left, right: right)
    }

    static func command(_ a: ScriptedAudioEvent.Action) -> AudioCommand {
        switch a {
        case let .sfx(c): return .sfx(c.raw)
        case let .music(r): return .music(song: Int32(clamping: r.song), order: Int32(clamping: r.order))
        case let .pauseMusic(p): return .pauseMusic(p)
        case .stopSfx: return .stopSfx
        case let .volumes(v): return .volumes(master: v.master, sfx: v.sfx, music: v.music)
        }
    }

    /// Mixer factory for tests that need to inspect voice state.
    func makeMixer() -> ClassicMixer {
        let mixer = ClassicMixer(bank: bank, sampleRate: sampleRate, options: options)
        for (song, m) in modules where (0..<ClassicMixer.maxSongs).contains(song) {
            mixer.install(module: m, song: song)
        }
        return mixer
    }
}
