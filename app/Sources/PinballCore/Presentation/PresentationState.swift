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
    /// Raw lamp state byte per slot (0 off, 1/2 draw a/b once, 3/4 blinking, 5/6 steady a/b;
    /// sprites.md 3.1). `lamps[i]` is whether sprite "a" is currently drawn.
    public var lampStates: [UInt8] = []
    /// Number of players in the game (1...4); `scores` has one entry per player.
    public var playerCount: Int = 1
    /// Score-strip text drawn this frame (draw_text calls), in order.
    public var texts: [TextRef] = []
    /// The game has ended (the original enters its game-over menu here).
    public var gameOver: Bool = false
    /// Per lamp slot, which overlay record lamp_update blitted last: 0 = none since boot (the
    /// playfield shows through), 1 = record "a", 2 = record "b" (`RulesRuntime.lampDrawn`).
    public var lampSprites: [UInt8] = []

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
    /// Offset of the string in the table's data segment (-1 if unknown).
    public var dsOffset: Int = -1
    /// The full mode word the rules passed (AX: AH = font/centring, AL = effect = `mode`).
    public var modeWord: UInt16 = 0
    /// Display position word (DI) the rules passed.
    public var position: Int = 0
    /// The live string bytes (up to the terminating 0) at the time of the frame; rules patch
    /// digits into their strings, so this can differ from the bytes at `exeOffset`.
    public var bytes: [UInt8] = []
    /// EP9-13 dot colour index for this message (set from a DS byte before the call); -1 = unknown,
    /// the renderer uses the table's default.
    public var colour: Int = -1
    public init(exeOffset: Int, mode: UInt8, framesRemaining: Int) {
        self.exeOffset = exeOffset; self.mode = mode; self.framesRemaining = framesRemaining
    }
}

/// A text line drawn by rule code: string by EXE/DS offset plus its live bytes, position word (DI)
/// and the drawing routine (cs offset in the table's code segment). draw_text (EP1 cs:59AC, font5)
/// and draw_text_hi (cs:5926, font8) append the line to the active dot message (they check and
/// advance its line pointer [0x50C]); they are not score-strip text.
public struct TextRef: Sendable, Equatable {
    public var exeOffset: Int
    public var dsOffset: Int
    public var position: Int
    public var routine: Int
    public var bytes: [UInt8]
    /// EP9-13 dot colour index (-1 = unknown), as `MessageRef.colour`.
    public var colour: Int = -1
    public init(exeOffset: Int, dsOffset: Int, position: Int, routine: Int, bytes: [UInt8]) {
        self.exeOffset = exeOffset; self.dsOffset = dsOffset; self.position = position
        self.routine = routine; self.bytes = bytes
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
