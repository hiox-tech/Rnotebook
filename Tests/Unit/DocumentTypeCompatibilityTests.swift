import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Rnotebook

@MainActor final class DocumentTypeCompatibilityTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentTypes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testCanonicalAndLegacyTypesResolveToTheSameDocumentAndPreserveBytes() throws {
        let controller = QMDDocumentController()
        let bytes = Data("---\r\ntitle: 中文🙂\r\n---\r\n".utf8)
        for (canonical, legacy) in [(NotebookDocumentType.quarto, NotebookDocumentType.legacyQuarto),
                                    (NotebookDocumentType.rMarkdown, NotebookDocumentType.legacyRMarkdown)] {
            for identifier in [canonical, legacy] {
                XCTAssertTrue(controller.documentClass(forType: identifier) == QMDDocument.self)
                let doc = QMDDocument()
                defer { doc.close() }
                try doc.read(from: bytes, ofType: identifier)
                XCTAssertEqual(doc.fileType, canonical)
                XCTAssertEqual(try doc.data(ofType: canonical), bytes)
                XCTAssertEqual(NotebookDocumentType.displayName(for: identifier), NotebookDocumentType.displayName(for: canonical))
            }
        }
    }

    func testOpenPanelAcceptsSupportedSuffixesWithoutAnyUTIFilterAndRejectsOtherFiles() throws {
        let root = try directory()
        let controller = QMDDocumentController()
        let panel = NSOpenPanel()
        let previous = RejectingPanelDelegate()
        panel.delegate = previous
        panel.allowedContentTypes = [.plainText]
        controller.configureOpenPanel(panel)
        XCTAssertTrue(panel.allowedContentTypes.isEmpty, "A public.data or dynamic UTI must not disable a supported filename")
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        let delegate = try XCTUnwrap(panel.delegate)
        XCTAssertEqual(delegate.panel?(panel, shouldEnable: root), true, "Directories must remain navigable")
        for ext in ["qmd", "QMD", "rmd", "Rmd", "RMD"] {
            let url = root.appendingPathComponent("报告." + ext)
            try Data("# Existing document\n".utf8).write(to: url)
            XCTAssertEqual(delegate.panel?(panel, shouldEnable: url), true)
            XCTAssertNoThrow(try delegate.panel?(panel, validate: url))
            XCTAssertEqual(try controller.typeForContents(of: url), NotebookDocumentType.identifier(for: url))
        }
        for name in ["report.txt", "report.md", "report.qmd.txt", "report", ".qmd"] {
            let url = root.appendingPathComponent(name)
            try Data().write(to: url)
            XCTAssertEqual(delegate.panel?(panel, shouldEnable: url), false)
            XCTAssertThrowsError(try delegate.panel?(panel, validate: url))
        }
        let directory = root.appendingPathComponent("folder.qmd", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try delegate.panel?(panel, validate: directory), "A supported suffix does not turn a directory into a document")
        XCTAssertEqual(delegate.panel?(panel, shouldEnable: root.appendingPathComponent("missing.qmd")), true,
                       "Picker enablement must not require complete resource metadata")
        XCTAssertThrowsError(try delegate.panel?(panel, validate: root.appendingPathComponent("missing.qmd")))
    }

    func testPackagedAppAndQuickLookAdvertiseCanonicalAndLegacyTypes() throws {
        let bundle = Bundle.main
        let documents = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let supported = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let expected: Set<String> = ["org.quarto.qmarkdown", "com.rstudio.rmarkdown", "org.quarto.qmd", "org.hiox.Rnotebook.rmd"]
        XCTAssertEqual(supported, expected)
        let declarations = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        XCTAssertEqual(Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String }), expected)
        let plugins = try XCTUnwrap(bundle.builtInPlugInsURL)
        let preview = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("RnotebookPreview.appex")))
        let extensionInfo = try XCTUnwrap(preview.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])), expected)
        XCTAssertEqual(preview.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                       bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(preview.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                       bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
}

@MainActor private final class RejectingPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { false }
    func panel(_ sender: Any, validate url: URL) throws { throw CocoaError(.fileReadUnknown) }
}
