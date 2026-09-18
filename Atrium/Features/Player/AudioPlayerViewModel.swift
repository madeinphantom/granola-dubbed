import SwiftUI
import AVFoundation

final class AudioPlayerViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    
    func load(url: URL) {
        // Clean up previous player
        cleanup()

        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Audio is still being prepared."
            return
        }
        
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        
        Task {
            if let d = try? await AVAsset(url: url).load(.duration), d.isValid, d.seconds > 0 {
                await MainActor.run {
                    self.duration = d.seconds
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "This recording has no playable audio."
                }
            }
        }
        
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            if time.seconds.isFinite {
                self.currentTime = time.seconds
            }
        }
        
        // Watch for playback end
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
            self?.currentTime = 0
            self?.player?.seek(to: .zero)
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            self?.isPlaying = false
            self?.errorMessage = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? "This recording could not be played."
        }
    }
    
    func togglePlayback() {
        guard let p = player, duration > 0, errorMessage == nil else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
        }
    }
    
    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }
    
    private func cleanup() {
        if let to = timeObserver {
            player?.removeTimeObserver(to)
            timeObserver = nil
        }
        if let eo = endObserver {
            NotificationCenter.default.removeObserver(eo)
            endObserver = nil
        }
        if let fo = failureObserver {
            NotificationCenter.default.removeObserver(fo)
            failureObserver = nil
        }
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        errorMessage = nil
    }
    
    deinit {
        if let to = timeObserver { player?.removeTimeObserver(to) }
        if let eo = endObserver { NotificationCenter.default.removeObserver(eo) }
        if let fo = failureObserver { NotificationCenter.default.removeObserver(fo) }
    }
}
