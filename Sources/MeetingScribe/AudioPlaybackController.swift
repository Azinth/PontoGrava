import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackController: ObservableObject {
    static let playbackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4]

    @Published private(set) var loadedRecordID: UUID?
    @Published private(set) var isAvailable = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1 {
        didSet {
            guard Self.playbackRates.contains(playbackRate) else {
                playbackRate = oldValue
                return
            }
            if isPlaying {
                player.rate = playbackRate
            }
        }
    }
    @Published var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    private let player = AVPlayer()
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedURL: URL?

    init() {
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
                self?.isPlaying = self?.player.rate != 0
            }
        }
    }

    deinit {
        if let periodicObserver { player.removeTimeObserver(periodicObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ record: MeetingRecord?) {
        guard let record,
              FileManager.default.fileExists(atPath: record.audioPath) else {
            reset()
            loadedRecordID = record?.id
            return
        }
        if loadedRecordID == record.id, loadedURL == record.audioURL { return }

        reset()
        loadedRecordID = record.id
        loadedURL = record.audioURL
        duration = max(0, record.duration)
        isAvailable = true

        let item = AVPlayerItem(url: record.audioURL)
        player.replaceCurrentItem(with: item)
        player.volume = volume
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player.seek(to: .zero)
                self?.currentTime = 0
                self?.isPlaying = false
            }
        }
    }

    func togglePlayback() {
        guard isAvailable else { return }
        if !isPlaying {
            if duration > 0, currentTime >= duration - 0.1 {
                player.seek(to: .zero)
            }
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        } else {
            pause()
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        guard isAvailable else { return }
        let target = min(max(0, seconds), max(0, duration))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
    }

    func reset() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        loadedRecordID = nil
        loadedURL = nil
        isAvailable = false
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
