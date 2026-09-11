import XCTest
import CoreAudio
@testable import Atrium

final class SystemAudioTapTests: XCTestCase {
    /// Regression: the app passed raw Unix pids to `CATapDescription`, which
    /// takes AudioObjectIDs. `AudioHardwareCreateProcessTap` then failed with
    /// kAudioHardwareBadObjectError ('!obj') and system audio was never
    /// captured — every recording had an empty them.caf.
    func testPIDIsTranslatedToADifferentAudioObjectID() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID
        )

        try XCTSkipUnless(status == noErr && objectID != kAudioObjectUnknown,
                          "Test host has no audio process object")

        XCTAssertNotEqual(AudioObjectID(pid), objectID,
                          "AudioObjectID must not be assumed equal to the pid")
    }

    /// A global tap excluding no processes must be creatable; this is the
    /// baseline the app's tap builds on.
    func testGlobalTapCanBeCreated() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "AtriumTests probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)

        try XCTSkipUnless(status == noErr, "No audio hardware available on this host")
        defer { AudioHardwareDestroyProcessTap(tapID) }
        XCTAssertNotEqual(tapID, AudioObjectID(kAudioObjectUnknown))
    }
}
