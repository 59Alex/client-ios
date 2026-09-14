import ConnectSettings
import LiveKit

/// Обработка микрофона из «Голос и видео» этого устройства (`VoiceAndSoundSection.tsx`):
/// шумоподавление и эхоподавление применяются к каждой новой публикации микрофона.
@MainActor
enum AudioProcessing {
    private(set) static var settings: VoiceSettings?

    static func apply(_ settings: VoiceSettings?) {
        self.settings = settings
    }

    static var captureOptions: AudioCaptureOptions {
        guard let settings else { return AudioCaptureOptions() }
        let suppressNoise = settings.noiceReductionType != .none
        return AudioCaptureOptions(
            echoCancellation: settings.echoSuppression,
            autoGainControl: suppressNoise,
            noiseSuppression: suppressNoise,
            highpassFilter: settings.noiceReductionType == .ai || settings.noiceReductionType == .aiLight
        )
    }
}
