// PinballAudio: sound effects (SFXn.PIN banks, signed 8-bit PCM with a live
// pitch/rate) and PSM music (libopenmpt), mixed through AVAudioEngine.
// Consumes SoundEvent / MusicRequest values produced by PinballCore (see
// PinballCore/Presentation/PresentationState.swift).
//
// Public entry points:
//   AudioEngine(dataDir:table:options:)  real-time playback (AVAudioSourceNode)
//   OfflineAudioRenderer                  headless render of a scripted event list to WAV
//   SfxBank / MusicModule                 file loaders (user's own original/ files)
//   ClassicSoundMap / OriginalDataLocator table -> bank/song mapping, file lookup
// Format and behaviour notes: docs/formats/audio.md.
import COpenMPT
import PinballCore

/// libopenmpt version string (for diagnostics).
public var openMPTVersion: String {
    guard let p = openmpt_get_string("library_version") else { return "?" }
    defer { openmpt_free_string(p) }
    return String(cString: p)
}
