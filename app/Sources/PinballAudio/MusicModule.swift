import COpenMPT
import Foundation

/// A PSM module opened with libopenmpt (C API). Created and destroyed on a
/// control thread; the mixer only renders from it.
public final class MusicModule: @unchecked Sendable {
    public enum ModuleError: Error, CustomStringConvertible {
        case missing(URL)
        case openFailed(String)
        public var description: String {
            switch self {
            case let .missing(url): return "missing music module \(url.path) (read from your own copy of the game)"
            case let .openFailed(why): return "libopenmpt could not open the module: \(why)"
            }
        }
    }

    let handle: OpaquePointer

    public init(data: Data) throws {
        var error: Int32 = 0
        var errorMessage: UnsafePointer<CChar>? = nil
        let mod: OpaquePointer? = data.withUnsafeBytes { raw in
            openmpt_module_create_from_memory2(raw.baseAddress, raw.count,
                                               openmpt_log_func_silent, nil,
                                               nil, nil,
                                               &error, &errorMessage, nil)
        }
        guard let mod else {
            var why = "error \(error)"
            if let m = errorMessage {
                why = String(cString: m)
                openmpt_free_string(m)
            }
            throw ModuleError.openFailed(why)
        }
        if let m = errorMessage { openmpt_free_string(m) }
        handle = mod
        // The original player loops the song forever; the table never stops it
        // except to pause (driver function 9) or at exit (0x1C).
        openmpt_module_set_repeat_count(handle, -1)
    }

    public convenience init(contentsOf url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ModuleError.missing(url) }
        try self.init(data: try Data(contentsOf: url))
    }

    public static func load(originalDir: URL, song: Int) throws -> MusicModule {
        try MusicModule(contentsOf: ClassicSoundMap.songURL(originalDir: originalDir, song: song))
    }

    deinit { openmpt_module_destroy(handle) }

    public var channelCount: Int { Int(openmpt_module_get_num_channels(handle)) }
    public var orderCount: Int { Int(openmpt_module_get_num_orders(handle)) }
    public var subsongCount: Int { Int(openmpt_module_get_num_subsongs(handle)) }
    public var durationSeconds: Double { openmpt_module_get_duration_seconds(handle) }
    public var currentOrder: Int { Int(openmpt_module_get_current_order(handle)) }
    public var currentRow: Int { Int(openmpt_module_get_current_row(handle)) }

    public func subsongName(_ index: Int) -> String {
        guard let p = openmpt_module_get_subsong_name(handle, Int32(index)) else { return "" }
        defer { openmpt_free_string(p) }
        return String(cString: p)
    }

    public func metadata(_ key: String) -> String {
        guard let p = openmpt_module_get_metadata(handle, key) else { return "" }
        defer { openmpt_free_string(p) }
        return String(cString: p)
    }

    /// 1 = nearest neighbour (what the MASI software mixers do), 0 = libopenmpt default.
    func setInterpolation(filterLength: Int32) {
        openmpt_module_set_render_param(handle, Int32(OPENMPT_MODULE_RENDER_INTERPOLATIONFILTER_LENGTH), filterLength)
    }

    // Render-thread entry points (no allocation in libopenmpt's normal render path).
    @inline(__always)
    func setPosition(order: Int32) {
        _ = openmpt_module_set_position_order_row(handle, order, 0)
    }

    @inline(__always)
    func read(sampleRate: Int32, frames: Int, left: UnsafeMutablePointer<Float>,
              right: UnsafeMutablePointer<Float>) -> Int {
        openmpt_module_read_float_stereo(handle, sampleRate, frames, left, right)
    }
}
