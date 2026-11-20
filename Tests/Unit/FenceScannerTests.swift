import Foundation
import XCTest
@testable import Rnotebook

final class FenceScannerTests: XCTestCase {
    func testExecutableFencesRespectMarkerLengthAndLiteralExamples() {
        let text = "---\ntitle: Test\n---\n\n```r\nnot executable\n```\n\n````markdown\n```{r}\nexample only\n```\n````\n\n~~~~{r}\n#| label: real-one\nx <- '```'\n~~~\n~~~~\n"
        let index = FenceScanner().scan(text)
        XCTAssertTrue(index.canAppend)
        XCTAssertEqual(index.cells.count, 1)
        XCTAssertEqual(index.cells[0].label, "real-one")
        XCTAssertEqual(index.cells[0].source, "#| label: real-one\nx <- '```'\n~~~\n")
        XCTAssertTrue(index.cells[0].canRun)
    }

    func testUTF16RangesPreserveUnicodeBOMAndCRLF() {
        let text = "\u{feff}---\r\ntitle: 中文🧪\r\n---\r\n\r\n```{r}\r\n#| label: unicode\r\nx <- '🧪'\r\n```"
        let index = FenceScanner().scan(text)
        XCTAssertEqual(index.cells.count, 1)
        let cell = index.cells[0]
        XCTAssertEqual((text as NSString).substring(with: cell.sourceRange), cell.source)
        XCTAssertEqual(cell.source, "#| label: unicode\r\nx <- '🧪'\r\n")
        XCTAssertEqual((text as NSString).substring(with: cell.range), "```{r}\r\n#| label: unicode\r\nx <- '🧪'\r\n```")
        XCTAssertEqual(index.cell(atUTF16Location: cell.sourceRange.location)?.id, "label:unicode")
        XCTAssertNil(index.cell(atUTF16Location: 2))
    }

    func testUnclosedAndAmbiguousStructuresAreNeverRunnable() {
        let samples = [
            "---\ntitle: missing end\n```{r}\n1\n```",
            "```{r}\n1", "```\nexample", "<!--\n```{r}\n1\n```",
            "> ```{r}\n> 1\n> ```", "- item\n  ```{r}\n  1\n  ```",
            "term\n: definition\n  ```{r}\n  1\n  ```"
        ]
        for text in samples {
            let index = FenceScanner().scan(text)
            XCTAssertFalse(index.canAppend, text)
            XCTAssertTrue(index.cells.allSatisfy { !$0.canRun }, text)
        }
    }

    func testDuplicateAndUnsupportedLabelsAreSafeRefusals() {
        let duplicate = "```{r}\n#| label: same\n1\n```\n```{r}\n#| label: same\n2\n```"
        let index = FenceScanner().scan(duplicate)
        XCTAssertFalse(index.canAppend)
        XCTAssertTrue(index.cells.allSatisfy { !$0.canRun })
        for metadata in ["#| label: invalid name", "#| label: [nested]", "1\n#| label: late", "#| label: a\n#| label: b"] {
            let result = FenceScanner().scan("```{r}\n" + metadata + "\n1\n```")
            XCTAssertFalse(result.canAppend, metadata)
            XCTAssertFalse(result.cells[0].canRun, metadata)
        }
        for label in ["plain-name", "'quoted-name'", "\"quoted-name\""] {
            XCTAssertTrue(FenceScanner().scan("```{r}\n#| label: " + label + "\n1\n```").cells[0].canRun)
        }
    }

    func testCommentsAndOrdinaryIndentedCodeDoNotBecomeRCells() {
        let text = "<!--\n```{r}\n1\n```\n-->\n\n    ```{r}\n    example\n    ```\n\n~~~python\nexample\n~~~\n"
        let result = FenceScanner().scan(text)
        XCTAssertTrue(result.cells.isEmpty)
        XCTAssertTrue(result.canAppend)
        let python = FenceScanner().scan("```{python}\nprint(1)\n```")
        XCTAssertEqual(python.cells.count, 1)
        XCTAssertFalse(python.cells[0].canRun)
    }

    func testFixtureCorpusMatchesItsAcceptanceManifest() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/QMD")
        let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil).filter { $0.pathExtension == "qmd" }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let index = FenceScanner().scan(text)
            if file.lastPathComponent.hasPrefix("valid-") { XCTAssertTrue(index.canAppend, file.lastPathComponent) }
            else { XCTAssertFalse(index.canAppend, file.lastPathComponent); XCTAssertTrue(index.cells.allSatisfy { !$0.canRun }) }
        }
    }
}
