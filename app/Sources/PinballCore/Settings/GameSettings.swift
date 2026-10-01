// User-facing settings shared by the front end (owner), renderer, physics and
// audio. Codable so the app can persist it. Extend additively; do not rename
// or remove fields without updating every consumer.
public struct GameSettings: Codable, Sendable, Equatable {
    public enum PhysicsMode: String, Codable, Sendable, CaseIterable {
        /// Bit-exact port of the original integer engine (59.94 Hz, 3 steps/frame).
        case classic
        /// Sub-stepped floating-point engine with the classic feel; rules/timers
        /// still advance on the original 59.94 Hz frame cadence.
        case enhanced
    }
    public enum UpscaleFilter: String, Codable, Sendable, CaseIterable {
        case nearest, smooth, xbrz, crt
    }
    /// How strong `dynamicLighting` is when it is on (the Bool stays the on/off switch, so a
    /// settings file written before this field existed keeps its meaning: on = subtle).
    public enum LightingStrength: String, Codable, Sendable, CaseIterable {
        case subtle, vivid
    }
    /// How the picture is scaled into the window (`RenderSettings.Scaling`).
    public enum OutputScaling: String, Codable, Sendable, CaseIterable {
        /// Integer steps for sharp pixels without an HD pack, fill otherwise.
        case auto
        /// Largest whole multiple that fits (black borders).
        case integer
        /// Largest scale that fits, fractional allowed (aspect kept).
        case fill
    }
    /// Sample resampling of effects and music (`PinballAudio.AudioInterpolation`).
    public enum AudioInterpolation: String, Codable, Sendable, CaseIterable {
        /// Nearest neighbour, like the original's Sound Blaster driver.
        case original
        /// Linear for effects, libopenmpt's default filter for music.
        case smooth
    }
    /// Picture rotation for cabinets / portrait monitors, clockwise in degrees. Only the
    /// picture turns (renderer); input and simulation are untouched.
    public enum DisplayRotation: Int, Codable, Sendable, CaseIterable {
        case none = 0, clockwise90 = 90, upsideDown = 180, clockwise270 = 270
    }

    public var physicsMode: PhysicsMode = .classic
    public var upscaleFilter: UpscaleFilter = .nearest
    /// Use a high-resolution asset pack for the current table if one is installed.
    public var useHDPack: Bool = false
    /// Lamp glow / bloom / ball shading on top of the art.
    public var dynamicLighting: Bool = false
    /// Render at the display's refresh rate with interpolated ball/flipper motion.
    public var highRefresh: Bool = false
    /// Show the whole 320x400 table instead of the original scrolling window.
    public var fullTableView: Bool = false
    public var musicVolume: Double = 1.0
    public var sfxVolume: Double = 0.5
    /// Strength of the dynamic lighting while `dynamicLighting` is on.
    public var lightingStrength: LightingStrength = .subtle
    public var outputScaling: OutputScaling = .auto
    /// Tunables of the enhanced physics (`EnhancedPhysicsConfig.preset`); classic physics ignores it.
    public var enhancedPreset: EnhancedPhysicsConfig.Preset = .classicFeel
    public var audioInterpolation: AudioInterpolation = .original
    /// Rotation of the playfield window's picture (cabinet display); `.none` = as before.
    public var displayRotation: DisplayRotation = .none
    /// Score strip / DMD in its own window (e.g. a backglass screen); the main window then
    /// shows the playfield only. Off = the strip under the playfield, as before.
    public var scoreWindow: Bool = false
    /// CRT filter look (`RenderSettings.crt*`; only used with `upscaleFilter == .crt`): scanline
    /// depth 0...1, barrel curvature 0 (flat) ... 0.08, shadow-mask strength 0...1. The defaults
    /// are the renderer's built-in values, so files without these fields render as before.
    public var crtScanlines: Double = 0.75
    public var crtCurvature: Double = 0.025
    public var crtMask: Double = 0.18
    /// Round, anti-aliased message dots on the enhanced path (`RenderSettings.roundDots`; the
    /// nearest filter always keeps the original square dots).
    public var roundDots: Bool = true
    /// Full-table view on the enhanced path: show the score strip under the table
    /// (`RenderSettings.stripInFullTable`).
    public var stripInFullTable: Bool = true
    /// High refresh: rotate the flippers between the game's frames instead of cross-fading them
    /// (with an HD pack, or without one for the smooth / xBRZ / CRT filters; `RenderSettings.rotateFlippers`).
    public var rotateFlippers: Bool = true

    /// Ranges the renderer accepts for the CRT parameters (Settings > Display sliders).
    public static let crtScanlinesRange: ClosedRange<Double> = 0...1
    public static let crtCurvatureRange: ClosedRange<Double> = 0...0.08
    public static let crtMaskRange: ClosedRange<Double> = 0...1

    /// Rotation of the score window's picture (its screen may be mounted differently from the
    /// playfield's, e.g. a backglass monitor); `.none` = upright, as before.
    public var scoreWindowRotation: DisplayRotation = .none

    public init() {}
}
