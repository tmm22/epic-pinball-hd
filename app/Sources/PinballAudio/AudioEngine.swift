import AVFoundation
import Foundation
import PinballCore

/// Real-time classic audio for one table: `SFXn.PIN` effects and `SONGn.PSM`
/// music, mixed in an `AVAudioSourceNode` render callback.
///
/// Threading: call the control methods (`start`, `stop`, `submit`, `setMusic`,
/// `setMusicPaused`, `setVolumes`, `present`) from one thread at a time (the
/// game/main thread). They only enqueue commands; the audio thread drains the
/// queue at the start of each render block (so SFX start with block
/// granularity, typically 5-12 ms).
public final class AudioEngine: @unchecked Sendable {
    public let table: Int
    public let originalDir: URL
    public let bank: SfxBank
    public let sampleRate: Int
    /// Loaded music modules by song number (kept alive for the engine's lifetime).
    public private(set) var modules: [Int: MusicModule] = [:]

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let mixer: ClassicMixer
    private let queue = CommandQueue()
    public private(set) var isRunning = false

    /// Opens the table's bank and song from the user's `original/` directory.
    /// A missing song is not fatal (effects still play); a missing bank throws.
    public init(dataDir: URL, table: Int, options: AudioOptions = AudioOptions()) throws {
        self.table = table
        originalDir = dataDir
        bank = try SfxBank.load(originalDir: dataDir, bank: ClassicSoundMap.sfxBank(forTable: table))
        let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = hw > 0 ? Int(hw.rounded()) : 48000
        mixer = ClassicMixer(bank: bank, sampleRate: sampleRate, options: options)
        _ = try? loadSong(ClassicSoundMap.song(forTable: table))
    }

    deinit {
        stop()
    }

    /// Loads `SONG<song>.PSM` into its slot if needed (control thread).
    @discardableResult
    public func loadSong(_ song: Int) throws -> MusicModule {
        if let m = modules[song] { return m }
        guard (0..<ClassicMixer.maxSongs).contains(song) else {
            throw MusicModule.ModuleError.openFailed("song number \(song) out of range")
        }
        let m = try MusicModule.load(originalDir: originalDir, song: song)
        modules[song] = m
        mixer.install(module: m, song: song)
        return m
    }

    public func start() throws {
        if isRunning { return }
        attachSourceNode()
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Test hook: runs the same node graph in AVAudioEngine's offline manual
    /// rendering mode (no audio hardware). Returns interleaved-free L/R arrays.
    func renderManually(frames: Int) throws -> (left: [Float], right: [Float]) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2) else {
            throw NSError(domain: "PinballAudio", code: 1)
        }
        if !isRunning {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            attachSourceNode()
            engine.prepare()
            try engine.start()
            isRunning = true
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024) else {
            throw NSError(domain: "PinballAudio", code: 2)
        }
        var l: [Float] = [], r: [Float] = []
        var done = 0
        while done < frames {
            let n = AVAudioFrameCount(min(1024, frames - done))
            let status = try engine.renderOffline(n, to: buf)
            guard status == .success, let ch = buf.floatChannelData else { throw NSError(domain: "PinballAudio", code: 3) }
            let got = Int(buf.frameLength)
            l.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: got))
            r.append(contentsOf: UnsafeBufferPointer(start: ch[buf.format.channelCount > 1 ? 1 : 0], count: got))
            done += got
        }
        return (l, r)
    }

    private func attachSourceNode() {
        guard sourceNode == nil,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2) else { return }
        let node = AVAudioSourceNode(format: format, renderBlock: Self.makeRenderBlock(mixer: mixer, queue: queue))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
    }

    private static func makeRenderBlock(mixer: ClassicMixer, queue: CommandQueue) -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, audioBufferList -> OSStatus in
            queue.drain { mixer.apply($0) }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            // The node's format is standard (deinterleaved) stereo float: 2 buffers.
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            mixer.render(frames: frames, left: l, right: r)
            return noErr
        }
    }

    // MARK: control API

    /// Plays effects in order, centred (`SoundEvent` carries no pan yet).
    public func submit(events: [SoundEvent]) {
        for e in events { queue.push(.sfx(SfxCommand(e, pan: e.pan >= 0 ? e.pan : nil).raw)) }
    }

    /// Plays effects in order, with pan.
    public func submit(_ commands: [SfxCommand]) {
        for c in commands { queue.push(.sfx(c.raw)) }
    }

    /// Switches to `request.song` (loaded on demand) and jumps to `request.order`
    /// (row 0). `song < 0` stops the music; `order < 0` keeps the position.
    public func setMusic(_ request: MusicRequest) {
        if request.song >= 0 { _ = try? loadSong(request.song) }
        queue.push(.music(song: Int32(clamping: request.song), order: Int32(clamping: request.order)))
    }

    /// Music pause/resume: what the tables do on the M key (driver functions 9 / 0x0A).
    public func setMusicPaused(_ paused: Bool) {
        queue.push(.pauseMusic(paused))
    }

    /// Starts the table's own song from the beginning, as the launcher + table do
    /// (song started by PINBALL.EXE, resumed by the table after its fade-in).
    public func startTableMusic() {
        setMusic(MusicRequest(song: ClassicSoundMap.song(forTable: table), order: 0))
        setMusicPaused(false)
    }

    public func stopAllSounds() {
        queue.push(.stopSfx)
    }

    public func setVolumes(_ v: AudioVolumes) {
        queue.push(.volumes(master: v.master, sfx: v.sfx, music: v.music))
    }

    public func setVolumes(master: Float, sfx: Float, music: Float) {
        setVolumes(AudioVolumes(master: master, sfx: sfx, music: music))
    }

    /// Convenience for the integrator: forwards one frame's sound events and
    /// music request.
    public func present(_ state: PresentationState) {
        if !state.soundEvents.isEmpty { submit(events: state.soundEvents) }
        if let m = state.music { setMusic(m) }
    }

    /// Commands dropped because the queue was full (should stay 0).
    public var droppedCommands: Int { queue.dropped }
}
