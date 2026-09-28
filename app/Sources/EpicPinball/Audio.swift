import Foundation
import PinballAudio
import PinballCore

/// The app's side of PinballAudio: one `AudioEngine` per table (SFXn.PIN effects, SONGn.PSM
/// music from the user's `original/` directory), fed once per original frame with the rules'
/// `PresentationState`. Keys: M pauses/resumes the music (the tables' M key), S switches effects
/// off/on (the original's opt_sfx: new effects are dropped, playing ones finish), - / = master
/// volume, [ / ] music volume.
@MainActor
final class AudioController {
    let engine: AudioEngine
    private(set) var sfxOn: Bool
    private(set) var musicPaused = false
    private(set) var volumes: AudioVolumes

    /// nil when there is no original directory or no bank (the game runs silently).
    init?(table: Int, originalDir: String?, options o: Options) {
        guard let dir = OriginalDataLocator.resolve(explicit: originalDir) else {
            warn("no original/ directory with SFX\(table).PIN / SONG\(table).PSM found: no sound (pass --original DIR)")
            return nil
        }
        do { engine = try AudioEngine(dataDir: dir, table: table) } catch {
            warn("audio disabled: \(error)")
            return nil
        }
        sfxOn = !o.noSfx
        volumes = AudioVolumes()
        if let v = o.volume { volumes.master = Float(v) }
        do { try engine.start() } catch {
            warn("audio output could not start: \(error)")
            return nil
        }
        engine.setVolumes(volumes)
        if !o.noMusic {
            engine.startTableMusic()   // the launcher starts SONGn, the table resumes it after its fade-in
        } else {
            musicPaused = true
            engine.setMusicPaused(true)
        }
    }

    /// Effects handed to the audio engine so far (smoke-test statistics).
    private(set) var effectsSubmitted = 0

    /// One original frame's sounds (and music request, which the tables never make).
    func present(_ s: PresentationState) {
        var st = s
        if !sfxOn { st.soundEvents.removeAll() }
        effectsSubmitted += st.soundEvents.count
        engine.present(st)
    }

    func toggleMusic() {
        musicPaused.toggle()
        engine.setMusicPaused(musicPaused)
    }

    func toggleSfx() { sfxOn.toggle() }

    func setPaused(_ paused: Bool) {
        engine.setMusicPaused(paused || musicPaused)
        if paused { engine.stopAllSounds() }
    }

    /// Absolute levels from the settings (master, music, effects; 0...1).
    func apply(master: Double, music: Double, sfx: Double) {
        let v = AudioVolumes(master: Float(min(max(master, 0), 1)), sfx: Float(min(max(sfx, 0), 1)),
                             music: Float(min(max(music, 0), 1)))
        guard v != volumes else { return }
        volumes = v
        engine.setVolumes(volumes)
    }

    func adjust(master: Float = 0, music: Float = 0) {
        volumes.master = min(max(volumes.master + master, 0), 1)
        volumes.music = min(max(volumes.music + music, 0), 1)
        engine.setVolumes(volumes)
    }

    func stop() { engine.stop() }
}
