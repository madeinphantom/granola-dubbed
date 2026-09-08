import XCTest
@testable import Atrium

/// Guards the delete path math. Deletion previously derived the session
/// directory from `audioMixRelativePath`, which defaults to "" — resolving to
/// Application Support itself and wiping every app's data on the Mac.
final class AudioStoreDeletePathTests: XCTestCase {
    private let appSupport = URL(fileURLWithPath: "/Users/x/Library/Application Support")

    private func resolve(id: String) -> (dir: URL, isInsideSessions: Bool) {
        let root = appSupport.appendingPathComponent("Atrium/Sessions", isDirectory: true)
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let inside = dir.standardizedFileURL.path
            .hasPrefix(root.standardizedFileURL.path + "/")
        return (dir, inside)
    }

    func testResolvesToTheSessionDirectory() {
        let id = UUID().uuidString
        let (dir, inside) = resolve(id: id)
        XCTAssertEqual(dir.path, "\(appSupport.path)/Atrium/Sessions/\(id)")
        XCTAssertTrue(inside)
    }

    func testEmptyIdentifierCannotEscapeTheSessionsRoot() {
        XCTAssertFalse(resolve(id: "").isInsideSessions)
    }

    func testPathTraversalIsRejected() {
        let (dir, inside) = resolve(id: "../../..")
        XCTAssertFalse(inside, "Traversal resolved to \(dir.standardizedFileURL.path)")
    }
}
