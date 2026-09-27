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

    public init() {}
}
