import ScreenCaptureKit
import AVFoundation

enum SCKCaptureError: Error {
    case noDisplay
}

final class SCKFallbackCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?

    var onSystemAudio: ((CMSampleBuffer) -> Void)?

    func start() async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SCKCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // MicCapture owns the microphone path. Capturing it here as well
        // creates duplicate/competing mic tracks when CoreAudio falls back.
        config.captureMicrophone = false
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 8
        config.height = 8
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        
        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        
        let queue = DispatchQueue(label: "app.atrium.sck")
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        try await newStream.startCapture()
        self.stream = newStream
    }
    
    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            onSystemAudio?(sampleBuffer)
        case .microphone:
            // Disabled in configuration; keep the handler defensive if the
            // framework emits a microphone buffer during reconfiguration.
            break
        case .screen:
            // Discard
            break
        @unknown default:
            break
        }
    }
}
