import AVFoundation
import Observation

/// Запись кружка: фронтальная камера и микрофон, H.264/AAC в mp4 (`useChatRecorder.ts`, режим видео).
@MainActor
@Observable
final class VideoCircleRecorder: NSObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
    }

    static let maxDuration: TimeInterval = 60

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    let session = AVCaptureSession()
    /// Запуск и остановка сессии блокируют поток, поэтому идут в своей очереди.
    private let sessionQueue = SessionQueue()

    private let output = AVCaptureMovieFileOutput()
    private var configured = false
    private var ticker: Task<Void, Never>?
    private var finished: CheckedContinuation<URL?, Never>?
    private var startedAt: Date?

    var isActive: Bool { state != .idle }

    func start() async -> Bool {
        guard state == .idle else { return false }
        state = .preparing
        guard await Self.requestAccess(), configure() else {
            state = .idle
            return false
        }
        await sessionQueue.run(SessionBox(session: session), start: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("circle-\(UUID().uuidString).mov")
        output.maxRecordedDuration = CMTime(seconds: Self.maxDuration, preferredTimescale: 600)
        output.startRecording(to: url, recordingDelegate: self)
        startedAt = Date()
        state = .recording
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return true
    }

    /// Останавливает запись и отдаёт mp4; записи короче секунды отбрасываются.
    func finish() async -> Data? {
        guard state == .recording else { return nil }
        let duration = elapsed
        let movie = await withCheckedContinuation { continuation in
            finished = continuation
            output.stopRecording()
        }
        stopSession()
        guard let movie, duration >= 1 else { return nil }
        defer { try? FileManager.default.removeItem(at: movie) }
        return await Self.exportMP4(movie)
    }

    func cancel() {
        guard state == .recording else { return }
        finished = nil
        output.stopRecording()
        stopSession()
    }

    private func stopSession() {
        ticker?.cancel()
        ticker = nil
        startedAt = nil
        elapsed = 0
        state = .idle
        let queue = sessionQueue
        let box = SessionBox(session: session)
        Task { await queue.run(box, start: false) }
    }

    private func configure() -> Bool {
        if configured { return true }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let cameraInput = try? AVCaptureDeviceInput(device: camera), session.canAddInput(cameraInput),
              let microphone = AVCaptureDevice.default(for: .audio),
              let microphoneInput = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(microphoneInput),
              session.canAddOutput(output)
        else { return false }
        session.addInput(cameraInput)
        session.addInput(microphoneInput)
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
            if output.availableVideoCodecTypes.contains(.h264) {
                output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
            }
        }
        configured = true
        return true
    }

    private static func requestAccess() async -> Bool {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return camera && microphone
    }

    /// Контейнер mov → mp4 без перекодирования: сервис пересобирает кружок сам.
    private static func exportMP4(_ movie: URL) async -> Data? {
        let asset = AVURLAsset(url: movie)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return nil }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("circle-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: target) }
        if #available(iOS 18, *) {
            do {
                try await export.export(to: target, as: .mp4)
            } catch {
                return nil
            }
        } else {
            export.outputURL = target
            export.outputFileType = .mp4
            nonisolated(unsafe) let session = export
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else { return nil }
        }
        return try? Data(contentsOf: target)
    }
}

extension VideoCircleRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        // Достижение максимальной длины тоже приходит ошибкой, но файл при этом годен.
        let success = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
        Task { @MainActor in
            if let continuation = self.finished {
                self.finished = nil
                continuation.resume(returning: success ? outputFileURL : nil)
            } else {
                try? FileManager.default.removeItem(at: outputFileURL)
                if self.state == .recording { self.stopSession() }
            }
        }
    }
}

/// Последовательная очередь сессии камеры: AVCaptureSession живёт на ней, а не на главном акторе.
private final class SessionQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ru.cnnect.circle-session")

    func run(_ box: SessionBox, start: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if start { box.session.startRunning() } else { box.session.stopRunning() }
                continuation.resume()
            }
        }
    }
}

private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}
