import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class BundledRuntimeTests: XCTestCase {
    private func executable(_ path: Path) throws {
        try FileManager.default.createDirectory(at: path.parent, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.url.path)
    }
    private struct Path {
        let url: URL
        var path: String { url.path }
        var parent: URL { url.deletingLastPathComponent() }
        init(_ root: URL, _ relative: String) { url = root.appendingPathComponent(relative) }
    }

    func testInstallerRuntimeIsLocatedAndSuppliesExplicitToolPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RnotebookRuntime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try executable(Path(root, "R.framework/Resources/bin/Rscript"))
        try executable(Path(root, "quarto/bin/quarto"))
        try executable(Path(root, "TinyTeX/bin/universal-darwin/tlmgr"))
        try executable(Path(root, "chrome-headless-shell/chrome-headless-shell"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("R/library"), withIntermediateDirectories: true)
        let previous = NotebookBundledRuntime.overrideRoot
        NotebookBundledRuntime.overrideRoot = root
        defer { NotebookBundledRuntime.overrideRoot = previous }

        XCTAssertEqual(NotebookBundledRuntime.rscript?.path, root.appendingPathComponent("R.framework/Resources/bin/Rscript").path)
        XCTAssertEqual(NotebookRExecutable.locate(selected: nil)?.path, NotebookBundledRuntime.rscript?.path)
        XCTAssertEqual(QuartoExecutable.locate()?.path, root.appendingPathComponent("quarto/bin/quarto").path)
        let user = root.appendingPathComponent("user-library")
        let environment = try NotebookLibrary.environment(["PATH": "/usr/bin:/bin"], library: user, rscript: NotebookBundledRuntime.rscript)
        let path = try XCTUnwrap(environment["PATH"])
        XCTAssertTrue(path.hasPrefix(root.appendingPathComponent("R.framework/Resources/bin").path + ":"))
        XCTAssertTrue(path.hasSuffix(":/usr/bin:/bin"))
        XCTAssertEqual(environment["QUARTO_CHROMIUM"], root.appendingPathComponent("chrome-headless-shell/chrome-headless-shell").path)
        XCTAssertEqual(environment["TEXMFHOME"], NotebookBundledRuntime.userTeXMF.path)
        let libs = try XCTUnwrap(environment["R_LIBS"]).split(separator: ":").map(String.init)
        XCTAssertEqual(libs.first, user.path)
        XCTAssertTrue(libs.contains(root.appendingPathComponent("R/library").path))
        let system = root.appendingPathComponent("custom-Rscript")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: system)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system.path)
        let systemEnvironment = try NotebookLibrary.environment(["PATH": "/usr/bin"], library: user, rscript: system)
        XCTAssertFalse(try XCTUnwrap(systemEnvironment["R_LIBS"]).contains(root.appendingPathComponent("R/library").path))
    }

    func testExplicitUserSelectionWinsOverInstallerRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RnotebookRuntime-" + UUID().uuidString)
        let selected = root.appendingPathComponent("custom-Rscript")
        defer { try? FileManager.default.removeItem(at: root) }
        try executable(Path(root, "R.framework/Resources/bin/Rscript"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: selected)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: selected.path)
        let previous = NotebookBundledRuntime.overrideRoot
        NotebookBundledRuntime.overrideRoot = root
        defer { NotebookBundledRuntime.overrideRoot = previous }
        XCTAssertEqual(NotebookRExecutable.locate(selected: selected.path)?.path, selected.path)
    }
}
