import AVFoundation

enum CameraPermission {
    /// Системный запрос камеры показывается один раз; при отказе панель ошибок ведёт в настройки.
    @MainActor
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
