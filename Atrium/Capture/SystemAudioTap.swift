import CoreAudio
import AudioToolbox
import AVFoundation

enum TapCaptureError: Error {
    case tapCreateFailed(OSStatus)
    case aggregateCreateFailed(OSStatus)
    case ioProcCreateFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case noDefaultOutput
}

final class SystemAudioTap {
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private func defaultOutputDeviceUID() -> String? {
        var defaultOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )
        guard status == noErr, defaultOutputDeviceID != kAudioObjectUnknown else { return nil }

        var uidString: CFString?
        propertySize = UInt32(MemoryLayout<CFString?>.size)
        propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &uidString
        )
        guard uidStatus == noErr, let uid = uidString as String? else { return nil }
        return uid
    }

    func start(excludingPids: [pid_t] = [pid_t(getpid())],
              handler: @escaping (UnsafePointer<AudioBufferList>, UInt32, AudioTimeStamp) -> Void) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludingPids.map { AudioObjectID($0) })
        desc.uuid = UUID()
        desc.name = "Atrium System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw TapCaptureError.tapCreateFailed(tapStatus)
        }
        self.tapID = tap
        let tapUID = desc.uuid.uuidString

        guard let outputUID = defaultOutputDeviceUID() else {
            throw TapCaptureError.noDefaultOutput
        }

        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Atrium Tap Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard aggStatus == noErr else { throw TapCaptureError.aggregateCreateFailed(aggStatus) }
        self.aggregateID = agg

        let block: AudioDeviceIOBlock = { inNow, inInputData, _, _, _ in
            // Derive the real frame count from the first buffer rather than assuming one.
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let first = abl.first, first.mDataByteSize > 0 else { return }
            let bytesPerFrame = UInt32(MemoryLayout<Float>.size)
            let channelsInBuffer = max(first.mNumberChannels, 1)
            let frameCount = first.mDataByteSize / (bytesPerFrame * channelsInBuffer)
            handler(inInputData, frameCount, inNow.pointee)
        }
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, agg, DispatchQueue(label: "atrium.tap.io"), block)
        guard procStatus == noErr, let procID else {
            // Leave no aggregate/tap behind if we cannot actually receive audio.
            stop()
            throw TapCaptureError.ioProcCreateFailed(procStatus)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(agg, procID)
        guard startStatus == noErr else {
            stop()
            throw TapCaptureError.deviceStartFailed(startStatus)
        }
    }

    func stop() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
    
    deinit {
        stop()
    }
}
