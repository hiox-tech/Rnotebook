import AppKit
import SwiftUI
import XCTest
@testable import Rnotebook

@MainActor final class InspectorContentTests: XCTestCase {
    private func configuration() throws -> RuntimeConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InspectorContent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(executable: try XCTUnwrap(NotebookRExecutable.locate(selected: nil)),
            workerScript: try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap")),
            projectDirectory: root, taskTimeout: 30)
    }
    private func session() async throws -> (RRuntime, RuntimeConfiguration) {
        let runtime = RRuntime(), config = try configuration()
        _ = try await runtime.start(config)
        addTeardownBlock { try await runtime.stop() }
        return (runtime, config)
    }
    @discardableResult private func evaluate(_ runtime: RRuntime, _ source: String) async throws -> RuntimeTranscript {
        let result = try await runtime.evaluate(.init(cellID: "inspector-content", source: source))
        XCTAssertEqual(result.events.last?.payload.status, "completed", result.events.compactMap(\.payload.text).joined())
        return result
    }
    private func preview(_ runtime: RRuntime, _ name: String, _ request: NotebookPreviewRequest = .init()) async throws -> NotebookObjectPreview {
        let result = try await runtime.inspect(.init(operation: .previewObject, name: name, preview: request))
        XCTAssertEqual(result.events.last?.payload.status, "completed", result.events.compactMap(\.payload.text).joined())
        let page = try XCTUnwrap(result.events.first { $0.kind == "inspector_result" }?.payload.objectPreview)
        XCTAssertTrue(page.isValid); XCTAssertEqual(page.request, request)
        return page
    }
    func testReadOnlyPreviewPaginatesRowsAndColumnsAndHandlesUnicodeNAAndZeroDimensions() async throws {
        let (runtime, _) = try await session()
        try await evaluate(runtime, "dat <- as.data.frame(replicate(35, seq_len(230), simplify=FALSE)); dat[[2]][1] <- NA_integer_; dat[[3]] <- rep(paste(rep('中文',1000),collapse=''),230); mat <- matrix(1:12,3); empty <- data.frame(a=integer()); zero <- data.frame(row.names=1:3); zmat <- matrix(integer(),0,3); vec <- c(NA,NaN,Inf,1.25)\n")
        let first = try await preview(runtime, "dat")
        XCTAssertEqual(first.totalRows, 230); XCTAssertEqual(first.totalColumns, 35)
        XCTAssertEqual(first.rows.count, 100); XCTAssertEqual(first.columns.count, 30)
        XCTAssertEqual(first.rows[0][1], "NA"); XCTAssertLessThanOrEqual(first.rows[0][2].utf8.count, 256)
        let page = try await preview(runtime, "dat", .init(rowOffset: 200, columnOffset: 30))
        XCTAssertEqual(page.rows.count, 30); XCTAssertEqual(page.columns.count, 5); XCTAssertEqual(page.rows[0][0], "201")
        let matrix = try await preview(runtime, "mat"); XCTAssertEqual(matrix.rows[0], ["1", "4", "7", "10"])
        let empty = try await preview(runtime, "empty"); XCTAssertTrue(empty.rows.isEmpty); XCTAssertEqual(empty.totalColumns, 1)
        let zero = try await preview(runtime, "zero"); XCTAssertEqual(zero.rows, [[], [], []])
        let zmat = try await preview(runtime, "zmat"); XCTAssertTrue(zmat.rows.isEmpty)
        let vector = try await preview(runtime, "vec"); XCTAssertEqual(vector.rows.map { $0[1] }, ["NA", "NaN", "Inf", "1.25"])
        let check = try await evaluate(runtime, "stopifnot(nrow(dat)==230L,ncol(dat)==35L,nchar(dat[[3]][1])==2000L);cat('UNCHANGED')\n")
        XCTAssertTrue(check.events.compactMap(\.payload.text).joined().contains("UNCHANGED"))
    }
    func testPreviewNeverForcesBindingsOrRunsCustomMethodsAndExpandsNestedLists() async throws {
        let (runtime, _) = try await session()
        try await evaluate(runtime, "touches <- 0L; print.tripwire <- format.tripwire <- length.tripwire <- `[.tripwire` <- `[[.tripwire` <- function(...) { touches <<- touches+1L;stop('USER_METHOD') }; x <- structure(1:3,class='tripwire'); nested <- list(first=list(text=c('你好','world')),date=as.Date('2026-11-07'),factor=factor(c('中文',NA))); makeActiveBinding('watch',function(value){ touches<<-touches+1L;1 },globalenv()); delayedAssign('later',{touches<<-touches+1L;1},assign.env=globalenv())\n")
        let x = try await preview(runtime, "x"); XCTAssertEqual(x.rows[0][1], "1")
        let root = try await preview(runtime, "nested"); XCTAssertEqual(root.kind, "list"); XCTAssertTrue(root.expandable[0])
        let child = try await preview(runtime, "nested", .init(path: [0, 0])); XCTAssertEqual(child.rows[0][1], "你好")
        let date = try await preview(runtime, "nested", .init(path: [1])); XCTAssertEqual(date.rows[0][1], "2026-11-07")
        let factor = try await preview(runtime, "nested", .init(path: [2])); XCTAssertEqual(factor.rows.map { $0[1] }, ["中文", "NA"])
        for name in ["watch", "later", "missing"] {
            let result = try await runtime.inspect(.init(operation: .previewObject, name: name))
            XCTAssertEqual(result.events.last?.payload.status, "failed")
        }
        let check = try await evaluate(runtime, "cat('TOUCHES',touches)\n")
        XCTAssertTrue(check.events.compactMap(\.payload.text).joined().contains("TOUCHES 0"))
    }
    func testStructuredListPagesShowValuesPreserveTypesAndExpandDataFrameColumns() async throws {
        let (runtime, _) = try await session()
        try await evaluate(runtime, "nested <- list(scalar=42L, nil=NULL, empty=list(), chars=c('你好','world'), data=data.frame(group=factor(c('中','英')),day=as.Date(c('2026-11-09','2026-11-10')),row.names=c('甲','乙')), matrix=matrix(1:4,2,dimnames=list(c('a','b'),c('x','y')))); named <- c(first=1L,second=2L); long <- paste(rep('文字',400),collapse=''); big <- as.list(1:230)\n")
        try await evaluate(runtime, "nested$long <- paste(rep('文字',400),collapse='')\n")
        let root = try await preview(runtime, "nested")
        XCTAssertTrue(root.expandable[6])
        let longChild = try await preview(runtime, "nested", .init(path: [6], structure: true)); XCTAssertEqual(longChild.scalarText?.count, 800)
        XCTAssertEqual(root.rows[0][2], "42"); XCTAssertFalse(root.expandable[0])
        XCTAssertEqual(root.rows[1][2], "NULL"); XCTAssertFalse(root.expandable[1]); XCTAssertFalse(root.expandable[2])
        XCTAssertTrue(root.rows[3][2].contains("你好")); XCTAssertTrue(root.expandable[3])
        let data = try await preview(runtime, "nested", .init(path: [4], structure: true))
        XCTAssertEqual(data.kind, "list"); XCTAssertEqual(data.rows.map { $0[0] }, ["group", "day"])
        XCTAssertTrue(data.rows[0][2].contains("中")); XCTAssertTrue(data.rows[1][2].contains("2026-11-09"))
        let factor = try await preview(runtime, "nested", .init(path: [4,0], structure: true))
        XCTAssertEqual(factor.rows.map { $0[1] }, ["中", "英"])
        let table = try await preview(runtime, "nested", .init(path: [4])); XCTAssertEqual(table.rowNames, ["甲", "乙"])
        let matrix = try await preview(runtime, "nested", .init(path: [5], structure: true))
        XCTAssertEqual(matrix.rowNames, ["a", "b"]); XCTAssertEqual(matrix.columns, ["x", "y"])
        let named = try await preview(runtime, "named"); XCTAssertEqual(named.rows.map { $0[0] }, ["first", "second"])
        let text = try await preview(runtime, "long"); XCTAssertEqual(text.scalarText?.count, 800)
        let big = try await preview(runtime, "big", .init(rowOffset: 200, structure: true))
        XCTAssertEqual(big.rows.count, 30); XCTAssertEqual(big.rows[0][2], "201")
    }
    func testBrowserQueuesSiblingExpansionAndAppendsMemberPagesWithoutReplacingParents() throws {
        func page(_ request: NotebookPreviewRequest, rows: [[String]], total: Int, expandable: [Bool]) -> NotebookObjectPreview {
            .init(name: "nested", type: "list", kind: "list", summary: "list", totalRows: total, totalColumns: 3, columns: ["成员", "类型", "值"], rows: rows, expandable: expandable, request: request)
        }
        let browser = InspectorPreviewBrowser(); browser.reset()
        let request = try XCTUnwrap(browser.next())
        browser.receive(page(request, rows: [["a", "list", "nested"], ["b", "list", "nested"]], total: 102, expandable: [true,true]), error: nil)
        let first = browser.roots[0], second = browser.roots[1], more = browser.roots[2]
        browser.expand(first); browser.expand(second)
        let child = try XCTUnwrap(browser.next()); XCTAssertEqual(child.path, [0]); XCTAssertTrue(child.structure)
        browser.receive(page(child, rows: [["leaf", "integer", "7"]], total: 1, expandable: [false]), error: nil)
        XCTAssertTrue(browser.roots[0] === first); XCTAssertTrue(first.loaded); XCTAssertEqual(first.children[0].cells.last, "7")
        let sibling = try XCTUnwrap(browser.next()); XCTAssertEqual(sibling.path, [1])
        browser.receive(page(sibling, rows: [], total: 0, expandable: []), error: nil)
        XCTAssertTrue(browser.roots[1] === second); XCTAssertEqual(first.children.count, 1)
        browser.more(more); let next = try XCTUnwrap(browser.next()); XCTAssertEqual(next.rowOffset, 2)
        browser.receive(page(next, rows: [["c", "integer", "3"]], total: 3, expandable: [false]), error: nil)
        XCTAssertEqual(browser.roots.count, 3); XCTAssertTrue(browser.roots[0] === first); XCTAssertEqual(browser.root?.rows.count, 2)
        browser.expand(first); XCTAssertNil(browser.next(), "Cached nodes do not issue another request")
        browser.reset(); _ = browser.next(); browser.receive(nil, error: "changed")
        XCTAssertNil(browser.root); XCTAssertEqual(browser.error, "changed"); XCTAssertNil(browser.next())
    }
    func testNativeOutlineRetainsSiblingExpansionsAndCollapsesWithoutRefetching() async throws {
        let browser = InspectorPreviewBrowser(); browser.reset()
        let root = try XCTUnwrap(browser.next())
        let page = NotebookObjectPreview(name: "tree", type: "list", kind: "list", summary: "list", totalRows: 2, totalColumns: 3, columns: ["成员","类型","值"], rows: [["a","list","nested"],["b","list","nested"]], expandable: [true,true], request: root)
        browser.receive(page, error: nil)
        let host = NSHostingView(rootView: InspectorObjectOutline(browser: browser, load: {}, rowsChanged: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 690, height: 250)
        func find(_ view: NSView) -> NSOutlineView? { (view as? NSOutlineView) ?? view.subviews.lazy.compactMap { find($0) }.first }
        host.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(find(host)); XCTAssertEqual(outline.numberOfRows, 2)
        let a = browser.roots[0], b = browser.roots[1]
        outline.expandItem(a); outline.expandItem(b)
        let first = try XCTUnwrap(browser.next()); XCTAssertEqual(first.path, [0])
        func child(_ request: NotebookPreviewRequest) -> NotebookObjectPreview {
            .init(name: "tree", type: "integer", kind: "vector", summary: "integer", totalRows: 2, totalColumns: 2, columns: ["索引","值"], rows: [["1","10"],["2","20"]], expandable: [false,false], request: request)
        }
        browser.receive(child(first), error: nil)
        try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        let second = try XCTUnwrap(browser.next()); XCTAssertEqual(second.path, [1])
        browser.receive(child(second), error: nil)
        try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(outline.isItemExpanded(a)); XCTAssertTrue(outline.isItemExpanded(b)); XCTAssertEqual(outline.numberOfRows, 6)
        outline.collapseItem(a)
        try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
        XCTAssertFalse(outline.isItemExpanded(a)); XCTAssertTrue(outline.isItemExpanded(b)); XCTAssertEqual(outline.numberOfRows, 4)
        outline.expandItem(a); XCTAssertNil(browser.next()); XCTAssertEqual(outline.numberOfRows, 6)
        XCTAssertTrue(outline.tableColumns.allSatisfy { !$0.isEditable })
        let value = try XCTUnwrap(outline.delegate?.outlineView?(outline, viewFor: outline.tableColumns[2], item: a.children[0]) as? NSTextField)
        XCTAssertTrue(value.isSelectable); XCTAssertFalse(value.isEditable); XCTAssertEqual(value.stringValue, "10")
    }
    func testClearIncludesHiddenFunctionsAndObjectsBeyondDisplayLimitButPreservesLockedAndOtherSession() async throws {
        let (runtime, _) = try await session(), (other, _) = try await session()
        try await evaluate(runtime, "for(i in 1:520) assign(paste0('x',i),i,globalenv()); .hidden<-1; helper<-function()1; locked<-9L; lockBinding('locked',globalenv())\n")
        try await evaluate(other, "keep<-77L\n")
        let result = try await runtime.inspect(.init(operation: .clearObjects))
        XCTAssertEqual(result.events.last?.payload.status, "completed")
        let snapshot = try XCTUnwrap(result.events.first { $0.kind == "inspector_result" }?.payload.inspector)
        XCTAssertEqual(snapshot.variables.map(\.name), ["locked"])
        XCTAssertTrue(result.events.filter { $0.kind == "warning" }.compactMap(\.payload.text).joined().contains("锁定"))
        let check = try await evaluate(other, "stopifnot(keep==77L);cat('INDEPENDENT')\n")
        XCTAssertTrue(check.events.compactMap(\.payload.text).joined().contains("INDEPENDENT"))
    }
    func testModelPreviewClearDirectoryAndHelpKeepQMDOutputsAndSessionIdentity() async throws {
        let config = try configuration(), suite = "InspectorContent." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let source = "```{r}\n#| label: once\nx <- data.frame(a=1:3)\ncat('once')\n```\n"
        let model = RecordLayoutModel(visualDefaults: defaults, notebookConfiguration: { config }, initialSource: source)
        model.documentURL = config.projectDirectory.appendingPathComponent("report.qmd")
        addTeardownBlock { @MainActor in await model.notebook.shutdown(); defaults.removePersistentDomain(forName: suite) }
        var directory: URL?; model.notebook.openDirectoryURL = { directory = $0; return true }
        model.notebook.revealWorkingDirectory(); XCTAssertEqual(directory?.path, config.projectDirectory.path)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        let identity = try XCTUnwrap(model.notebook.sessionID), task = model.outputStates["once"]?.taskID
        model.notebook.manage(.init(operation: .previewObject, name: "x"), expectedSession: identity); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.objectPreview?.rows.count, 3); XCTAssertNil(model.notebook.previewError)
        let content = model.outputStates["once"]?.contentID
        model.notebook.manage(.init(operation: .clearObjects), expectedSession: UUID())
        XCTAssertFalse(model.notebook.isBusy); XCTAssertFalse(model.notebook.inspectorSnapshot?.variables.isEmpty == true)
        try await evaluate(model.notebook.runtime, "dir.create('sub');setwd('sub')\n")
        model.notebook.manage(.init(operation: .snapshot)); await model.notebook.waitUntilIdle()
        model.notebook.revealWorkingDirectory(); XCTAssertEqual(directory?.lastPathComponent, "sub")
        var helpURL: URL?; model.notebook.openHelpURL = { helpURL = $0; return true }
        model.notebook.manage(.init(operation: .clearObjects), expectedSession: identity)
        model.notebook.manage(.init(operation: .help, name: "stats::lm"))
        XCTAssertEqual(helpURL?.host, "search.r-project.org")
        await model.notebook.waitUntilIdle()
        XCTAssertTrue(model.notebook.inspectorSnapshot?.variables.isEmpty == true)
        XCTAssertNil(model.notebook.objectPreview); XCTAssertEqual(model.notebook.sessionID, identity)
        XCTAssertEqual(model.source, source); XCTAssertEqual(model.outputStates["once"]?.taskID, task)
        XCTAssertEqual(model.outputStates["once"]?.contentID, content)
    }
    func testOfficialHelpOnUntitledDocumentDoesNotPresentSaveOrLaunchR() throws {
        let doc = QMDDocument(); doc.makeWindowControllers()
        defer { doc.close() }
        var opened: URL?; doc.model.notebook.openHelpURL = { opened = $0; return true }
        doc.model.notebook.manage(.init(operation: .help, name: "t test"))
        XCTAssertEqual(opened?.host, "search.r-project.org"); XCTAssertNil(doc.fileURL)
        XCTAssertNil(doc.windowControllers.first?.window?.attachedSheet); XCTAssertEqual(doc.model.notebook.state, .notStarted)
    }
    func testNativePreviewTableHasSelectableCellsAndNoEditingPath() throws {
        let result = NotebookObjectPreview(name: "x", type: "integer", kind: "vector", summary: "2", totalRows: 2, totalColumns: 2, columns: ["索引", "值"], rows: [["1", "你好"], ["2", "NA"]], expandable: [false, false], request: .init())
        let host = NSHostingView(rootView: InspectorReadOnlyTable(preview: result, expand: { _ in XCTFail("Atomic vector cannot expand") }))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 350); host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? { if let value = view as? NSTableView { return value }; return view.subviews.lazy.compactMap { table(in: $0) }.first }
        let table = try XCTUnwrap(table(in: host)); XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.tableColumns.count, 2, "A vector has just index and value, without a second row index")
        XCTAssertTrue(table.tableColumns.allSatisfy { !$0.isEditable })
        let cell = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: table.tableColumns[1], row: 0) as? NSTextField)
        XCTAssertFalse(cell.isEditable); XCTAssertTrue(cell.isSelectable); XCTAssertEqual(cell.stringValue, "你好")
    }
    func testLocalArchiveAndMultipleRepositoryPackagesUseChosenLibraryAndReportPartialFailure() async throws {
        let (runtime, config) = try await session()
        let package = config.projectDirectory.appendingPathComponent("inspectorcontentfixture")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("R"), withIntermediateDirectories: true)
        try Data("Package: inspectorcontentfixture\nVersion: 0.0.1\nTitle: Read Only Inspector Fixture\nDescription: Local fixture for native inspector installation.\nAuthor: Test User\nMaintainer: Test User <test@example.invalid>\nLicense: GPL-3\n".utf8).write(to: package.appendingPathComponent("DESCRIPTION"))
        try Data("export(fixture_value)\n".utf8).write(to: package.appendingPathComponent("NAMESPACE"))
        try Data("fixture_value <- function() 42L\n".utf8).write(to: package.appendingPathComponent("R/value.R"))
        try await evaluate(runtime, "dir.create('repo/src/contrib',recursive=TRUE);dir.create('library'); old<-setwd('repo/src/contrib'); status<-system2(file.path(R.home('bin'),'R'),c('CMD','build','--no-manual',shQuote('../../../inspectorcontentfixture'))); setwd(old);stopifnot(status==0L);tools::write_PACKAGES('repo/src/contrib',type='source');.libPaths(c(normalizePath('library'),.libPaths()));options(pkgType='source')\n")
        let library = config.projectDirectory.appendingPathComponent("library").path
        let archive = config.projectDirectory.appendingPathComponent("repo/src/contrib/inspectorcontentfixture_0.0.1.tar.gz").path
        let local = NotebookPackageInstallation(source: .local, files: [archive], library: library)
        XCTAssertTrue(local.isValid)
        let installed = try await runtime.inspect(.init(operation: .installPackage, installation: local))
        XCTAssertEqual(installed.events.last?.payload.status, "completed", installed.events.compactMap(\.payload.text).joined())
        let row = try XCTUnwrap(installed.events.first { $0.kind == "inspector_result" }?.payload.inspector?.packages.first { $0.name == "inspectorcontentfixture" })
        XCTAssertFalse(row.loaded); XCTAssertEqual(row.description, "Read Only Inspector Fixture")
        XCTAssertEqual(URL(fileURLWithPath: row.library).resolvingSymlinksInPath().path, URL(fileURLWithPath: library).resolvingSymlinksInPath().path)
        let repository = config.projectDirectory.appendingPathComponent("repo").absoluteString
        let multiple = NotebookPackageInstallation(packages: ["inspectorcontentfixture", "MissingRnotebookPackage000"], repository: repository, library: library)
        XCTAssertTrue(multiple.isValid)
        let partial = try await runtime.inspect(.init(operation: .installPackage, installation: multiple))
        XCTAssertEqual(partial.events.last?.payload.status, "failed")
        XCTAssertTrue(partial.events.compactMap(\.payload.text).joined().contains("已安装 1 个，失败 1 个"))
        let state = await runtime.state; XCTAssertEqual(state, .ready)
    }
    func testPreviewProtocolRejectsMismatchedPageAndMalformedCells() throws {
        let request = NotebookInspectorRequest(operation: .previewObject, name: "x", preview: .init(rowOffset: 100))
        let command = RuntimeCommand(sessionID: UUID(), requestID: UUID(), taskID: UUID(), kind: "inspector", inspector: request)
        func event(_ sequence: Int, _ kind: String, _ payload: RuntimePayload = .init()) -> RuntimeEnvelope {
            .init(protocolVersion: "1.4", sessionID: command.sessionID, requestID: command.requestID, taskID: command.taskID, sequence: sequence, cellID: nil, sourceHash: nil, kind: kind, payload: payload)
        }
        let page = NotebookObjectPreview(name: "x", type: "integer", kind: "vector", summary: "x", totalRows: 101, totalColumns: 2, columns: ["index", "value"], rows: [["1", "2"]], expandable: [false], request: .init())
        XCTAssertTrue(page.isValid)
        var validator = ResponseValidator(command: command); try validator.accept(event(1, "started"))
        XCTAssertThrowsError(try validator.accept(event(2, "inspector_result", .init(objectPreview: page))))
        XCTAssertFalse(NotebookInspectorRequest(operation: .previewObject, name: "x", preview: .init(path: [-1])).isValid)
        XCTAssertFalse(NotebookInspectorRequest(operation: .clearObjects, name: "x").isValid)
        XCTAssertFalse(NotebookPackageInstallation(packages: ["x;quit()"], library: "/tmp/library").isValid)
    }
}
