import AVFoundation
import UIKit

enum MicrophonePermission {
    enum Status {
        case granted, denied, undetermined
    }

    @MainActor
    static var status: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    /// Запрашивает доступ к микрофону; системный диалог показывается только в первый раз.
    @MainActor
    static func request() async -> Bool {
        switch status {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Страница Connect в «Настройках»: там переключатели доступа приложения, в том числе «Микрофон».
    @MainActor
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
