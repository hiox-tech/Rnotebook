import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class HelpIllustrationTests: XCTestCase {
    private let bundle = Bundle(for: RecordNativeEditorHost.self)
    func testDetailedImagesLoadLocallyWithCaptionsAndRejectUntrustedPaths() throws {
        var images = Set<String>()
        for language in AppLanguage.supported {
            for topic in NotebookHelpTopic.allCases {
                let blocks = NotebookHelpGuideBlock.parse(try NotebookHelpContent.load(topic, language: language, bundle: bundle).markdown)
                for block in blocks {
                    if case .image(let path) = block.kind {
                        images.insert(path)
                        XCTAssertFalse(block.text.isEmpty)
                        let image = try XCTUnwrap(NSImage(contentsOf: XCTUnwrap(NotebookHelpAsset.url(path, bundle: bundle))))
                        XCTAssertGreaterThan(image.size.width, 500)
                        XCTAssertGreaterThan(image.size.height, 300)
                    }
                }
            }
        }
        XCTAssertEqual(images.count, 8)
        for bad in ["images/../secret.png", "https://example.com/a.png", "file:///tmp/a.png", "images/a.svg", "images/a/b.png", "images/missing.png"] {
            XCTAssertNil(NotebookHelpAsset.url(bad, bundle: bundle))
        }
        let parsed = NotebookHelpGuideBlock.parse("![A real screenshot](images/workspace-code-en.png)\n\n3. First\n4. Second\n")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].text, "A real screenshot")
        XCTAssertEqual(parsed[1].text, "3. First\n4. Second")
    }
    func testShortGuidesAreIndependentReferencesWithCopyableExampleAndSections() throws {
        for language in AppLanguage.supported {
            for topic in [NotebookHelpTopic.quickStart, .syntax] {
                let short = try NotebookHelpGuideModel.load(topic, language: language, bundle: bundle)
                let detailed = try NotebookHelpContent.load(topic, language: language, bundle: bundle).markdown
                XCTAssertLessThan(short.count, detailed.count)
                XCTAssertFalse(detailed.contains(short))
                XCTAssertLessThan(short.split(separator: "\n").count, 90)
                let model = try NotebookHelpGuideModel(topic: topic, language: language, bundle: bundle)
                XCTAssertEqual(model.blocks.filter { if case .code = $0.kind { return true }; return false }.count, 1)
                XCTAssertFalse(model.blocks.contains { if case .image = $0.kind { return true }; return false })
                XCTAssertGreaterThanOrEqual(model.blocks.filter { if case .heading(2) = $0.kind { return true }; return false }.count, 4)
                XCTAssertTrue(short.contains(topic == .syntax ? "@fig-trend" : "⇧⌘E"))
                for block in model.blocks {
                    if case .table = block.kind {
                        XCTAssertTrue(block.rows.allSatisfy { $0.count == 2 }, "Option syntax must not split the meaning into a third column")
                    }
                }
            }
        }
    }
    func testAllPackagedNoticesHaveOriginalLicenseTextAndAboutWindowsAreReusable() throws {
        let notices = try NotebookThirdPartyNotice.load(bundle: bundle)
        XCTAssertEqual(notices.count, 17)
        XCTAssertEqual(Set(notices.map(\.id)).count, notices.count)
        for notice in notices { XCTAssertGreaterThan(try notice.text(bundle: bundle).count, 250) }
        let raven = try XCTUnwrap(notices.first { $0.id == "raven" })
        XCTAssertEqual(raven.license, "GPL-3.0")
        XCTAssertTrue(try raven.text(bundle: bundle).contains("GNU GENERAL PUBLIC LICENSE"))
        let before = NSDocumentController.shared.documents.count
        let controller = NotebookAboutController()
        defer { controller.window?.close(); controller.noticesWindow?.close() }
        controller.show(); let about = try XCTUnwrap(controller.window)
        controller.showNotices(); let licenses = try XCTUnwrap(controller.noticesWindow)
        XCTAssertFalse(about === licenses)
        XCTAssertNil(about.windowController?.document)
        XCTAssertEqual(licenses.tabbingMode, .disallowed)
        about.close(); controller.show(); XCTAssertTrue(controller.window === about)
        licenses.close(); controller.showNotices(); XCTAssertTrue(controller.noticesWindow === licenses)
        XCTAssertEqual(NSDocumentController.shared.documents.count, before)
        let delegate = RnotebookDelegate(), menu = RnotebookApp.makeMenu(commandTarget: delegate)
        let item = try XCTUnwrap(menu.items.first?.submenu?.items.first)
        XCTAssertEqual(item.action, #selector(RnotebookDelegate.showAbout(_:)))
        XCTAssertTrue(delegate.validateMenuItem(item))
    }
}
