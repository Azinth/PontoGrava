import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct RecordingResult {
    let audioURL: URL
    let duration: TimeInterval
}

final class RecordingEngine: NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    var onWarning: ((String) -> Void)?
    var onAudioLevels: ((Float, Float) -> Void)?

    private let systemQueue = DispatchQueue(label: "pontograva.audio.sistema")
    private let microphoneQueue = DispatchQueue(label: "pontograva.audio.microfone")

    private var stream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var systemWriter: AudioTrackWriter?
    private var microphoneWriter: AudioTrackWriter?
    private var capturedSegments: [CapturedSegment] = []
    private var segmentIndex = 0
    private var destinationURL: URL?
    private var temporaryFolder: URL?
    private var selectedMicrophoneID: String?
    private var selectedMicrophoneName: String?
    private var disconnectObserver: NSObjectProtocol?
    private var microphoneRuntimeErrorObserver: NSObjectProtocol?
    private var microphoneMonitor: DispatchSourceTimer?
    private var firstCaptureError: Error?
    private let captureErrorLock = NSLock()
    private let stateLock = NSLock()
    private var acceptingSamples = false
    private let microphoneStateLock = NSLock()
    private var microphoneSampleBuffersReceived = 0
    private var microphoneNoSamplesWarningSent = false
    private let levelLock = NSLock()
    private var systemLevel: Float = 0
    private var microphoneLevel: Float = 0
    private var lastLevelEmission: TimeInterval = 0

    func start(microphoneID: String, destinationFolder: URL) async throws {
        guard let microphoneDevice = AVCaptureDevice(uniqueID: microphoneID) else {
            throw AppError.microphoneUnavailable
        }

        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw ScreenCaptureDiagnostics.appError(from: error)
        }
        guard let display = shareableContent.displays.first else {
            throw AppError.noDisplayAvailable
        }

        try FileManager.default.createDirectory(
            at: destinationFolder,
            withIntermediateDirectories: true
        )
        let temporaryFolder = destinationFolder.appendingPathComponent(".captura", isDirectory: true)
        try? FileManager.default.removeItem(at: temporaryFolder)
        try FileManager.default.createDirectory(
            at: temporaryFolder,
            withIntermediateDirectories: true
        )

        destinationURL = destinationFolder.appendingPathComponent("audio.wav")
        self.temporaryFolder = temporaryFolder
        selectedMicrophoneID = microphoneID
        selectedMicrophoneName = microphoneDevice.localizedName
        setFirstCaptureError(nil)
        resetMicrophoneMonitoringState()
        capturedSegments = []
        segmentIndex = 0
        try startSegment()

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(StandardAudio.sampleRate)
        configuration.channelCount = Int(StandardAudio.channels)
        configuration.captureMicrophone = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        let microphoneCapture = try makeMicrophoneCapture(for: microphoneDevice)
        self.stream = stream
        microphoneSession = microphoneCapture.session
        microphoneOutput = microphoneCapture.output
        observeSelectedMicrophone()
        observeMicrophoneRuntimeErrors(for: microphoneCapture.session)
        startMicrophoneMonitor()

        var didStartScreenCapture = false
        do {
            try await stream.startCapture()
            didStartScreenCapture = true
            try startMicrophoneCapture()
            setAcceptingSamples(true)
        } catch {
            if didStartScreenCapture {
                try? await stream.stopCapture()
            }
            cleanupFailedStart()
            throw screenCaptureErrorIfNeeded(error)
        }
    }

    func pause() throws {
        guard stream != nil, isAcceptingSamples() else {
            throw AppError.recordingNotRunning
        }
        setAcceptingSamples(false)
        finishCurrentSegment()
        resetLevels()
    }

    func resume() throws {
        guard stream != nil, !isAcceptingSamples() else {
            throw AppError.recordingNotRunning
        }
        try startSegment()
        setAcceptingSamples(true)
    }

    func stop() async throws -> RecordingResult {
        guard let stream, let destinationURL else {
            throw AppError.recordingNotRunning
        }

        let wasAcceptingSamples = isAcceptingSamples()
        setAcceptingSamples(false)
        stopMicrophoneMonitor()
        stopMicrophoneCapture()
        do {
            try await stream.stopCapture()
        } catch {
            onWarning?("A captura foi interrompida pelo macOS: \(error.localizedDescription)")
        }
        self.stream = nil
        stopObservingMicrophone()
        if wasAcceptingSamples { finishCurrentSegment() }
        resetLevels()

        let segments = capturedSegments
        let duration = try AudioMixer.mix(segments: segments, to: destinationURL)
        AudioMixer.removeTemporaryTracks(segments.flatMap(\.tracks))
        if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }

        if let firstCaptureError = getFirstCaptureError() {
            onWarning?("Parte do áudio apresentou erro, mas o WAV foi preservado: \(firstCaptureError.localizedDescription)")
        }
        if markMicrophoneNoSamplesWarningIfNeeded() {
            onWarning?(noMicrophoneSamplesWarning(final: true))
        }

        self.destinationURL = nil
        self.temporaryFolder = nil
        selectedMicrophoneID = nil
        selectedMicrophoneName = nil
        capturedSegments = []
        segmentIndex = 0
        return RecordingResult(audioURL: destinationURL, duration: duration)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard isAcceptingSamples() else { return }
        do {
            switch type {
            case .audio:
                if let level = try systemWriter?.append(sampleBuffer) {
                    updateLevel(level, for: .system)
                }
            default:
                break
            }
        } catch {
            recordCaptureError(error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onWarning?("A gravação foi interrompida: \(error.localizedDescription)")
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isAcceptingSamples() else { return }
        do {
            if let level = try microphoneWriter?.append(sampleBuffer) {
                markMicrophoneSampleReceived()
                updateLevel(level, for: .microphone)
            }
        } catch {
            recordCaptureError(error)
        }
    }

    private struct MicrophoneCapture {
        let session: AVCaptureSession
        let output: AVCaptureAudioDataOutput
    }

    private func makeMicrophoneCapture(for device: AVCaptureDevice) throws -> MicrophoneCapture {
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AppError.microphoneCaptureFailed(error.localizedDescription)
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            throw AppError.microphoneCaptureFailed(
                "O dispositivo \"\(device.localizedName)\" não pôde ser usado como entrada de áudio."
            )
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            throw AppError.microphoneCaptureFailed(
                "O macOS recusou a saída de áudio para \"\(device.localizedName)\"."
            )
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: microphoneQueue)
        return MicrophoneCapture(session: session, output: output)
    }

    private func startMicrophoneCapture() throws {
        guard let microphoneSession else { throw AppError.microphoneUnavailable }
        microphoneQueue.sync {
            microphoneSession.startRunning()
        }
        guard microphoneSession.isRunning else {
            throw AppError.microphoneCaptureFailed(
                "Confirme que o fone ou microfone continua conectado e tente novamente."
            )
        }
    }

    private func stopMicrophoneCapture() {
        let session = microphoneSession
        let output = microphoneOutput
        microphoneQueue.sync {
            output?.setSampleBufferDelegate(nil, queue: nil)
            if session?.isRunning == true {
                session?.stopRunning()
            }
        }
        microphoneOutput = nil
        microphoneSession = nil
    }

    private func observeSelectedMicrophone() {
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let device = notification.object as? AVCaptureDevice,
                  device.uniqueID == self.selectedMicrophoneID else { return }
            self.onWarning?(
                "O microfone \"\(device.localizedName)\" foi desconectado. " +
                "O app continuará gravando o áudio do sistema sem trocar de entrada."
            )
        }
    }

    private func observeMicrophoneRuntimeErrors(for session: AVCaptureSession) {
        microphoneRuntimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            if let error {
                self?.recordCaptureError(error)
            }
            self?.onWarning?(
                "A captura do microfone foi interrompida pelo macOS. " +
                "Confirme que o fone continua conectado e tente iniciar uma nova gravação."
            )
        }
    }

    private func stopObservingMicrophone() {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
        disconnectObserver = nil
        if let microphoneRuntimeErrorObserver {
            NotificationCenter.default.removeObserver(microphoneRuntimeErrorObserver)
        }
        microphoneRuntimeErrorObserver = nil
    }

    private func cleanupFailedStart() {
        stopMicrophoneMonitor()
        stopObservingMicrophone()
        setAcceptingSamples(false)
        stopMicrophoneCapture()
        stream = nil
        systemQueue.sync { systemWriter = nil }
        microphoneQueue.sync { microphoneWriter = nil }
        capturedSegments = []
        segmentIndex = 0
        destinationURL = nil
        selectedMicrophoneID = nil
        selectedMicrophoneName = nil
        if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
        temporaryFolder = nil
        resetLevels()
        resetMicrophoneMonitoringState()
    }

    private func startSegment() throws {
        guard let temporaryFolder else { throw AppError.recordingNotRunning }
        let index = segmentIndex
        let systemURL = temporaryFolder.appendingPathComponent("segmento-\(index)-sistema.caf")
        let microphoneURL = temporaryFolder.appendingPathComponent("segmento-\(index)-microfone.caf")
        let newSystemWriter = try AudioTrackWriter(url: systemURL)
        let newMicrophoneWriter = try AudioTrackWriter(url: microphoneURL)
        systemQueue.sync { systemWriter = newSystemWriter }
        microphoneQueue.sync { microphoneWriter = newMicrophoneWriter }
        segmentIndex += 1
    }

    private func finishCurrentSegment() {
        let systemTrack = systemQueue.sync { () -> CapturedTrack? in
            defer { systemWriter = nil }
            return systemWriter?.finish(gain: 0.82)
        }
        let microphoneTrack = microphoneQueue.sync { () -> CapturedTrack? in
            defer { microphoneWriter = nil }
            return microphoneWriter?.finish(gain: 1.0)
        }
        let tracks = [systemTrack, microphoneTrack].compactMap { $0 }
        if !tracks.isEmpty {
            capturedSegments.append(CapturedSegment(tracks: tracks))
        }
    }

    private func startMicrophoneMonitor() {
        stopMicrophoneMonitor()
        let timer = DispatchSource.makeTimerSource(queue: microphoneQueue)
        timer.schedule(deadline: .now() + .seconds(6), repeating: .seconds(6))
        timer.setEventHandler { [weak self] in
            guard let self, self.isAcceptingSamples() else { return }
            if self.markMicrophoneNoSamplesWarningIfNeeded() {
                self.onWarning?(self.noMicrophoneSamplesWarning(final: false))
            }
        }
        microphoneMonitor = timer
        timer.resume()
    }

    private func stopMicrophoneMonitor() {
        microphoneMonitor?.cancel()
        microphoneMonitor = nil
    }

    private func setAcceptingSamples(_ value: Bool) {
        stateLock.lock()
        acceptingSamples = value
        stateLock.unlock()
    }

    private func isAcceptingSamples() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acceptingSamples
    }

    private func resetMicrophoneMonitoringState() {
        microphoneStateLock.lock()
        microphoneSampleBuffersReceived = 0
        microphoneNoSamplesWarningSent = false
        microphoneStateLock.unlock()
    }

    private func markMicrophoneSampleReceived() {
        microphoneStateLock.lock()
        microphoneSampleBuffersReceived += 1
        microphoneStateLock.unlock()
    }

    private func markMicrophoneNoSamplesWarningIfNeeded() -> Bool {
        microphoneStateLock.lock()
        defer { microphoneStateLock.unlock() }
        guard microphoneSampleBuffersReceived == 0, !microphoneNoSamplesWarningSent else {
            return false
        }
        microphoneNoSamplesWarningSent = true
        return true
    }

    private func noMicrophoneSamplesWarning(final: Bool) -> String {
        let name = selectedMicrophoneName ?? "selecionado"
        if final {
            return "O microfone \"\(name)\" não enviou áudio para o PontoGrava. O WAV foi preservado, mas pode conter apenas o áudio do sistema."
        }
        return "O microfone \"\(name)\" ainda não enviou áudio para o PontoGrava. Se você estiver falando, confira a entrada selecionada no app e no macOS."
    }

    private enum AudioSource {
        case system
        case microphone
    }

    private func updateLevel(_ level: Float, for source: AudioSource) {
        levelLock.lock()
        switch source {
        case .system:
            systemLevel = AudioMeter.smoothed(previous: systemLevel, next: level)
        case .microphone:
            microphoneLevel = AudioMeter.smoothed(previous: microphoneLevel, next: level)
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelEmission >= (1.0 / 15.0) else {
            levelLock.unlock()
            return
        }
        lastLevelEmission = now
        let levels = (systemLevel, microphoneLevel)
        let callback = onAudioLevels
        levelLock.unlock()
        callback?(levels.0, levels.1)
    }

    private func resetLevels() {
        levelLock.lock()
        systemLevel = 0
        microphoneLevel = 0
        lastLevelEmission = 0
        let callback = onAudioLevels
        levelLock.unlock()
        callback?(0, 0)
    }

    private func setFirstCaptureError(_ error: Error?) {
        captureErrorLock.lock()
        firstCaptureError = error
        captureErrorLock.unlock()
    }

    private func recordCaptureError(_ error: Error) {
        captureErrorLock.lock()
        if firstCaptureError == nil { firstCaptureError = error }
        captureErrorLock.unlock()
    }

    private func getFirstCaptureError() -> Error? {
        captureErrorLock.lock()
        defer { captureErrorLock.unlock() }
        return firstCaptureError
    }

    private func screenCaptureErrorIfNeeded(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return error }
        return ScreenCaptureDiagnostics.appError(from: error)
    }
}
