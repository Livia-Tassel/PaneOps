import XCTest
@testable import SentinelMonitor

final class SentinelMonitorArgumentTests: XCTestCase {
    func testParseModeDefaultsToRun() throws {
        XCTAssertEqual(try SentinelMonitorMain.parseMode([]), .run)
        XCTAssertEqual(try SentinelMonitorMain.parseMode(["run"]), .run)
    }

    func testParseModeHelpAndVersion() throws {
        XCTAssertEqual(try SentinelMonitorMain.parseMode(["--help"]), .help)
        XCTAssertEqual(try SentinelMonitorMain.parseMode(["-h"]), .help)
        XCTAssertEqual(try SentinelMonitorMain.parseMode(["help"]), .help)

        XCTAssertEqual(try SentinelMonitorMain.parseMode(["--version"]), .version)
        XCTAssertEqual(try SentinelMonitorMain.parseMode(["-v"]), .version)
        XCTAssertEqual(try SentinelMonitorMain.parseMode(["version"]), .version)
    }

    func testParseModeRejectsUnknownArgs() {
        XCTAssertThrowsError(try SentinelMonitorMain.parseMode(["--unknown"]))
        XCTAssertThrowsError(try SentinelMonitorMain.parseMode(["run", "--debug"]))
    }
}
