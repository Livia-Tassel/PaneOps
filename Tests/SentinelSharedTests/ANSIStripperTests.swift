import XCTest
@testable import SentinelShared

final class ANSIStripperTests: XCTestCase {
    let stripper = ANSIStripper()

    func testStripCSISequences() {
        let input = "\u{1b}[32mHello\u{1b}[0m World"
        let result = stripper.strip(input)
        XCTAssertEqual(result, "Hello World")
    }

    func testStripBoldAndColor() {
        let input = "\u{1b}[1;34mBold Blue\u{1b}[0m Normal"
        let result = stripper.strip(input)
        XCTAssertEqual(result, "Bold Blue Normal")
    }

    func testStripCursorMovement() {
        let input = "\u{1b}[2AUp two\u{1b}[3BDown three"
        let result = stripper.strip(input)
        XCTAssertEqual(result, "Up twoDown three")
    }

    func testStripOSCBel() {
        let input = "\u{1b}]0;Window Title\u{07}Content"
        let result = stripper.strip(input)
        XCTAssertEqual(result, "Content")
    }

    func testPlainTextUnchanged() {
        let input = "Just plain text with no escapes"
        let result = stripper.strip(input)
        XCTAssertEqual(result, input)
    }

    func testEmptyString() {
        XCTAssertEqual(stripper.strip(""), "")
    }

    func testStripToLines() {
        let input = "\u{1b}[32mLine 1\u{1b}[0m\nLine 2\n\u{1b}[31mLine 3\u{1b}[0m"
        let lines = stripper.stripToLines(input)
        XCTAssertEqual(lines, ["Line 1", "Line 2", "Line 3"])
    }

    func testMixedSequences() {
        let input = "\u{1b}[1m\u{1b}[31mError:\u{1b}[0m something failed"
        let result = stripper.strip(input)
        XCTAssertEqual(result, "Error: something failed")
    }
}
