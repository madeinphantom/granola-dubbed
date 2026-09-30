import CoreAudio
import AudioToolbox
import AVFoundation
import os

enum TapCaptureError: Error {
    case tapCreateFailed(OSStatus)
    case aggregateCreateFailed(OSStatus)
    case ioProcCreateFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case formatUnavailable(OSStatus)
}

final class SystemAudioTap {
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "atrium.tap.format")

    /// The tap's stream format. It follows the output device, so it can
    /// change mid-session (for example when AirPods switch to their headset
    /// profile); the IO block reads it on every callback.
    private let tapFormat = OSAllocatedUnfairLock(initialState: AudioStreamBasicDescription())

    /// Callbacks whose buffers did not match the tap's format and were
    /// dropped rather than written as garbage.
    private let mismatchCounter = OSAllocatedUnfairLock(initialState: 0)
    var mismatchedCallbacks: Int { mismatchCounter.withLock { $0 } }

    /// The tap's format when capture started, for diagnostics.
    private(set) var startFormatDescription: String?

    private static var formatAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func readFormat(of tap: AudioObjectID) -> (OSStatus, AudioStreamBasicDescription) {
        var address = formatAddress
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        return (status, asbd)
    }

    /// Translates a Unix pid into the AudioObjectID of its audio process.
    ///
    /// `CATapDescription` takes AudioObjectIDs, not pids. Passing a raw pid
    /// makes `AudioHardwareCreateProcessTap` fail with
    /// `kAudioHardwareBadObjectError` ('!obj') and no system audio is ever
    /// captured. A process that has never played audio has no audio object,
    /// which is not an error — there is simply nothing to exclude.
    private func audioObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &size,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    /// Starts capturing all system audio except Atrium's own.
    ///
    /// `handler` receives each IO cycle as a buffer in the tap's own format,
    /// which is valid only for the duration of the call. Callers must convert
    /// it (see `SystemAudioConverter`) rather than assume a rate or layout.
    func start(excludingPids: [pid_t] = [pid_t(getpid())],
               handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let excludedObjects = excludingPids.compactMap { audioObjectID(forPID: $0) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedObjects)
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

        let (formatStatus, initialFormat) = Self.readFormat(of: tap)
        guard formatStatus == noErr, initialFormat.mSampleRate > 0, initialFormat.mChannelsPerFrame > 0 else {
            stop()
            throw TapCaptureError.formatUnavailable(formatStatus)
        }
        tapFormat.withLock { $0 = initialFormat }
        if let format = SystemAudioConverter.format(for: initialFormat) {
            startFormatDescription = SystemAudioConverter.describe(format)
        }

        let formatBox = tapFormat
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            let (status, updated) = Self.readFormat(of: tap)
            if status == noErr, updated.mSampleRate > 0 { formatBox.withLock { $0 = updated } }
        }
        var listenerAddress = Self.formatAddress
        if AudioObjectAddPropertyListenerBlock(tap, &listenerAddress, listenerQueue, listener) == noErr {
            formatListener = listener
        }

        // The aggregate contains the tap and nothing else. It used to include
        // the default output device as its main subdevice, which made the
        // aggregate run at that device's rate and expose that device's input
        // streams as extra buffers: with AirPods in their headset profile the
        // IO block received two stereo buffers at 24 kHz, and another session
        // received 12 channels per frame. All of it was written into them.caf
        // as 48 kHz stereo — a 59 s recording became 350 s of static.
        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Atrium Tap Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard aggStatus == noErr else {
            stop()
            throw TapCaptureError.aggregateCreateFailed(aggStatus)
        }
        self.aggregateID = agg

        let mismatches = mismatchCounter
        // Called serially on one queue, so the cached format needs no lock.
        var cachedDescription = AudioStreamBasicDescription()
        var cachedFormat: AVAudioFormat?
        let block: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            let asbd = formatBox.withLock { $0 }
            if cachedFormat == nil || !Self.sameFormat(asbd, cachedDescription) {
                cachedFormat = SystemAudioConverter.format(for: asbd)
                cachedDescription = asbd
            }
            guard let format = cachedFormat else { return }

            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let frames = Self.frameCount(abl, matching: asbd) else {
                if abl.contains(where: { $0.mDataByteSize > 0 }) {
                    mismatches.withLock { $0 += 1 }
                }
                return
            }
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: inInputData,
                                                deallocator: nil) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            handler(buffer)
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

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    /// Frames in `abl` if its layout is exactly what `asbd` describes, else nil.
    ///
    /// The buffer list must be checked against the format, never assumed:
    /// writing a list with extra buffers or channels as if it were the tap's
    /// stereo stream is what turned system audio into static.
    static func frameCount(_ abl: UnsafeMutableAudioBufferListPointer,
                           matching asbd: AudioStreamBasicDescription) -> Int? {
        let channels = Int(asbd.mChannelsPerFrame)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard channels > 0, bytesPerFrame > 0 else { return nil }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBuffers = nonInterleaved ? channels : 1
        let channelsPerBuffer = nonInterleaved ? 1 : channels
        guard abl.count == expectedBuffers else { return nil }
        var frames: Int?
        for buffer in abl {
            guard Int(buffer.mNumberChannels) == channelsPerBuffer,
                  Int(buffer.mDataByteSize) % bytesPerFrame == 0 else { return nil }
            let count = Int(buffer.mDataByteSize) / bytesPerFrame
            if let frames, frames != count { return nil }
            frames = count
        }
        return frames
    }

    func stop() {
        if let listener = formatListener {
            var address = Self.formatAddress
            AudioObjectRemovePropertyListenerBlock(tapID, &address, listenerQueue, listener)
            formatListener = nil
        }
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
