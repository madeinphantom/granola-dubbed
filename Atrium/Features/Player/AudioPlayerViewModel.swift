import SwiftUI
import AVFoundation

final class AudioPlayerViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    
    func load(url: URL) {
        // Clean up previous player
        cleanup()
        
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        
        Task {
            if let d = try? await AVAsset(url: url).load(.duration) {
                await MainActor.run {
                    self.duration = d.seconds.isFinite ? d.seconds : 0
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
    }
    
    func togglePlayback() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
        } else {
            p.play()
        }
        isPlaying.toggle()
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
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
    
    deinit {
        if let to = timeObserver { player?.removeTimeObserver(to) }
        if let eo = endObserver { NotificationCenter.default.removeObserver(eo) }
    }
}
