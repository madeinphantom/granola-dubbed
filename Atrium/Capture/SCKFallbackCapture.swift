import ScreenCaptureKit
import AVFoundation

enum SCKCaptureError: Error {
    case noDisplay
}

final class SCKFallbackCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    
    var onSystemAudio: ((CMSampleBuffer) -> Void)?
    var onMicAudio: ((CMSampleBuffer) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SCKCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 8
        config.height = 8
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        
        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.stream = newStream
        
        let queue = DispatchQueue(label: "app.atrium.sck")
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        try await newStream.startCapture()
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
            onMicAudio?(sampleBuffer)
        case .screen:
            // Discard
            break
        @unknown default:
            break
        }
    }
}
