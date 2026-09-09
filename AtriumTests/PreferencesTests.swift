import XCTest
@testable import Atrium

@MainActor
final class PreferencesTests: XCTestCase {
    func testWhisperModelFallsBackWhenRawValueIsUnknown() {
        // A stale or corrupted defaults value must not leave the app with no
        // model; it falls back to the pinned default.
        let prefs = Preferences.shared
        let original = prefs.whisperModelRaw
        defer { prefs.whisperModelRaw = original }

        prefs.whisperModelRaw = "not-a-real-model"
        XCTAssertEqual(prefs.whisperModel, .largeTurbo)
    }

    func testEveryModelVariantHasDisplayNameAndSize() {
        for model in WhisperModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertFalse(model.approximateDownloadSize.isEmpty)
        }
    }

    func testSessionsDirectoryIsUnderApplicationSupport() {
        let path = Preferences.shared.sessionsDirectory.path
        XCTAssertTrue(path.hasSuffix("Atrium/Sessions"), "Unexpected path: \(path)")
    }
}
