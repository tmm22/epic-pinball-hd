// Shared contract between simulation/rules (producer) and the renderer and
// audio (consumers). Extend additively; do not rename or remove fields
// without updating every consumer.

/// Snapshot of everything the front end needs to present one frame.
public struct PresentationState: Sendable {
    /// Per lamp slot (index = slot in sprites.json lamp table): true = lit
    /// ("a" overlay record), false = unlit ("b" record).
    public var lamps: [Bool] = []
    /// Palette entries overridden this frame (lamp colours / cycling in 200-254),
    /// as (index, r, g, b) with 8-bit components.
    public var paletteOverrides: [PaletteOverride] = []
    /// Score per player, current player (0-based), ball number, credits etc.
    public var scores: [UInt32] = [0]
    public var currentPlayer: Int = 0
    public var ballNumber: Int = 1
    public var tilted: Bool = false
    /// Active display-strip message, referenced by file offset of the string in
    /// the user's EPn.EXE (never stored verbatim), plus a display mode byte.
    public var message: MessageRef? = nil
    /// Sound events emitted since the previous frame, in order.
    public var soundEvents: [SoundEvent] = []
    /// Music request (song index into SONGn.PSM + order/position), if changed.
    public var music: MusicRequest? = nil

    public init() {}
}

public struct PaletteOverride: Sendable, Equatable {
    public var index: UInt8, r: UInt8, g: UInt8, b: UInt8
    public init(index: UInt8, r: UInt8, g: UInt8, b: UInt8) {
        self.index = index; self.r = r; self.g = g; self.b = b
    }
}

public struct MessageRef: Sendable, Equatable {
    public var exeOffset: Int
    public var mode: UInt8
    public var framesRemaining: Int
    public init(exeOffset: Int, mode: UInt8, framesRemaining: Int) {
        self.exeOffset = exeOffset; self.mode = mode; self.framesRemaining = framesRemaining
    }
}

public struct SoundEvent: Sendable, Equatable {
    /// Sample index within the table's SFX bank.
    public var sample: Int
    /// Playback rate in Hz (the original's live pitch variable, base 11000).
    public var rateHz: Int
    /// Optional pitch sweep: rate delta per frame and number of frames.
    public var sweepPerFrame: Int = 0
    public var sweepFrames: Int = 0
    /// Stereo position 0...15 as sfx_play computes it (sound id high nibble if
    /// non-zero, else min(ball_x / 20, 15)); -1 = let the audio side decide.
    public var pan: Int = -1
    public init(sample: Int, rateHz: Int, sweepPerFrame: Int = 0, sweepFrames: Int = 0, pan: Int = -1) {
        self.sample = sample; self.rateHz = rateHz
        self.sweepPerFrame = sweepPerFrame; self.sweepFrames = sweepFrames
        self.pan = pan
    }
}

public struct MusicRequest: Sendable, Equatable {
    public var song: Int
    public var order: Int
    public init(song: Int, order: Int) { self.song = song; self.order = order }
}
