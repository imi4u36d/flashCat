import XCTest
@testable import FlashCat

/// The quit path now ends its grace period as soon as the engine tree is gone,
/// which means `ProcessTree.anyAlive` decides how long quitting takes. A false
/// negative there would return from "quit" while weights were still resident;
/// a false positive would always burn the full grace. Both directions matter.
final class ProcessTreeTests: XCTestCase {
    func testLiveProcessIsReportedAlive() {
        // The test runner itself is a process that certainly exists.
        let tree = ProcessTree(root: getpid(), descendants: [])
        XCTAssertTrue(tree.anyAlive)
    }

    func testDeadProcessIsReportedGone() {
        // Start something that exits immediately, then look at its pid after it
        // has been reaped: `kill(pid, 0)` must fail with ESRCH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        do { try process.run() } catch {
            return XCTFail("could not spawn probe process: \(error)")
        }
        let pid = process.processIdentifier
        process.waitUntilExit()

        let tree = ProcessTree(root: pid, descendants: [])
        XCTAssertFalse(tree.anyAlive, "a reaped pid must not read as alive")
    }

    func testEmptyOrInvalidRootIsNotAlive() {
        // Pid 1 is launchd; pids at or below 1 are never signalled by design
        // and must not keep the quit path waiting.
        XCTAssertFalse(ProcessTree(root: 0, descendants: []).anyAlive)
        XCTAssertFalse(ProcessTree(root: 1, descendants: []).anyAlive)
    }

    /// One surviving descendant is enough to hold the grace period open: the
    /// whole point of snapshotting the tree is that the root dying does not
    /// mean the model is unloaded.
    func testOneLiveDescendantKeepsTreeAlive() {
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        guard (try? dead.run()) != nil else { return XCTFail("probe process failed") }
        let deadPid = dead.processIdentifier
        dead.waitUntilExit()

        let tree = ProcessTree(root: deadPid, descendants: [getpid()])
        XCTAssertTrue(tree.anyAlive)
    }

    func testPidListIncludesRootFirst() {
        let tree = ProcessTree(root: 42, descendants: [43, 44])
        XCTAssertEqual(tree.pids, [42, 43, 44])
    }
}
