import AVFoundation

enum MicrophonePermission {
    /// Запрашивает доступ к микрофону; системный диалог показывается только в первый раз.
    @MainActor
    static func request() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }
}
