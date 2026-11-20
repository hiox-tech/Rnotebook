import XCTest
@testable import Rnotebook

final class PackageCatalogTests: XCTestCase {
    func testBundledOfficialMirrorsAreCompleteUniqueAndUsableOffline() {
        let mirrors = InspectorMirrorCatalog.bundled
        XCTAssertGreaterThan(mirrors.count, 70)
        XCTAssertEqual(Set(mirrors.map(\.url)).count, mirrors.count)
        XCTAssertTrue(mirrors.contains { $0.url == "https://cloud.r-project.org" })
        XCTAssertTrue(mirrors.contains { $0.url == "https://mirrors.tuna.tsinghua.edu.cn/CRAN" })
        XCTAssertTrue(mirrors.allSatisfy { !$0.name.isEmpty && URL(string: $0.url)?.host != nil })
    }

    func testOfficialCSVParsingHandlesQuotesCRLFAndFiltersInvalidOrInactiveRows() {
        let csv = "Name,URL,OK\r\n\"中国,镜像 \"\"A\"\"\",https://example.org/CRAN/,1\r\nDuplicate,https://example.org/CRAN,1\r\nInactive,https://inactive.example/,0\r\nUnsafe,https://user:password@example.org/,1\r\nOther,http://example.net/cran/,1\r\nMissing,https://missing.example/\r\n"
        let mirrors = InspectorMirrorCatalog.parse(Data(csv.utf8))
        XCTAssertEqual(mirrors.map(\.name), ["中国,镜像 \"A\"", "Other"])
        XCTAssertEqual(mirrors.map(\.url), ["https://example.org/CRAN", "http://example.net/cran"])
        XCTAssertTrue(InspectorMirrorCatalog.parse(Data("<html>Error</html>".utf8)).isEmpty)
        XCTAssertTrue(InspectorMirrorCatalog.parse(Data("Name,URL,OK\n\"unclosed,https://example.org,1".utf8)).isEmpty)
    }
}
