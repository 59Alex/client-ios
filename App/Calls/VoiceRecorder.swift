import AVFoundation
import Observation

/// Запись голосового в AAC `.m4a` (`useChatRecorder.ts` пишет webm/opus, но его не проигрывает iOS).
@MainActor
@Observable
final class VoiceRecorder {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Уровень сигнала 0…1 для индикатора.
    private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var meter: Task<Void, Never>?

    var isActive: Bool { state != .idle }

    /// Начинает запись; `false`, если нет доступа к микрофону или сессия не поднялась.
    func start() async -> Bool {
        guard state == .idle, await MicrophonePermission.request() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return false }
            self.recorder = recorder
            fileURL = url
            state = .recording
            startMeter()
            return true
        } catch {
            return false
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        recorder?.record()
        state = .recording
    }

    /// Останавливает запись и отдаёт файл; слишком короткие записи (< 0,5 с) отбрасываются.
    func finish() -> Data? {
        guard let recorder, let fileURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        reset()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard duration >= 0.5 else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        reset()
    }

    private func reset() {
        meter?.cancel()
        meter = nil
        recorder = nil
        fileURL = nil
        state = .idle
        elapsed = 0
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startMeter() {
        meter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                let power = Double(recorder.averagePower(forChannel: 0))
                self.level = max(0, min(1, (power + 50) / 50))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
