import XCTest

final class ReplyStreamSplitterTests: XCTestCase {
    private func settledText(_ text: String, after known: Int = 0) -> String {
        let offset = ReplyStreamSplitter.settledOffset(in: text, after: known)
        return String(decoding: Array(text.utf8.prefix(offset)), as: UTF8.self)
    }

    func testSettlesBeforeTheLastParagraph() {
        let text = "Birinci paragraf.\n\nİkinci paragraf.\n\nÜçüncü yazılıyor"
        XCTAssertEqual(settledText(text), "Birinci paragraf.\n\nİkinci paragraf.\n\n")
    }

    func testNeverCutsInsideAnOpenCodeFence() {
        // The blank line before the fence is a safe cut; the one inside it is not.
        let text = "Giriş.\n\n```python\nprint(1)\n\nprint(2)"
        XCTAssertEqual(settledText(text), "Giriş.\n\n")
    }

    func testCutsAfterAFenceHasClosed() {
        let text = "Giriş.\n\n```python\nprint(1)\n\nprint(2)\n```\n\nSonuç yazılıyor"
        XCTAssertEqual(settledText(text), "Giriş.\n\n```python\nprint(1)\n\nprint(2)\n```\n\n")
    }

    func testDoesNotSplitAListOrAQuote() {
        XCTAssertEqual(settledText("- bir\n\n- iki\n\ndevam"), "")
        XCTAssertEqual(settledText("1. bir\n\n2. iki\n\ndevam"), "")
        XCTAssertEqual(settledText("> alıntı\n\ndevam"), "")
    }

    func testDoesNotCutInsideDisplayMath() {
        XCTAssertEqual(settledText("Şu formül:\n\n$$\na = b\n\nc = d"), "Şu formül:\n\n")
    }

    func testNeverCutsWhenNothingFollowsYet() {
        XCTAssertEqual(settledText("Bitti.\n\n"), "")
    }

    func testResumesFromWhatIsAlreadySettled() {
        let first = "Bir.\n\nİki.\n\nÜç yazılıyor"
        let known = ReplyStreamSplitter.settledOffset(in: first, after: 0)
        let extended = first + " ve bitti.\n\nDört başladı"
        let next = ReplyStreamSplitter.settledOffset(in: extended, after: known)
        XCTAssertGreaterThan(next, known)
        XCTAssertEqual(String(decoding: Array(extended.utf8.prefix(next)), as: UTF8.self), "Bir.\n\nİki.\n\nÜç yazılıyor ve bitti.\n\n")
    }

    func testHandlesMultiByteText() {
        let text = "Çok güzel bir gün ☀️.\n\nİkinci şarkı yazılıyor"
        XCTAssertEqual(settledText(text), "Çok güzel bir gün ☀️.\n\n")
    }
}
