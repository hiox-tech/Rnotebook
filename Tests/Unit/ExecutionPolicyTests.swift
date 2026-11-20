import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class ExecutionPolicyTests: XCTestCase {
    private func model(_ source: String) throws -> RecordLayoutModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExecutionPolicy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try XCTUnwrap(NotebookRExecutable.locate(selected: nil))
        let worker = try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap"))
        let config = RuntimeConfiguration(executable: executable, workerScript: worker, projectDirectory: root, startupTimeout: 10, taskTimeout: 12)
        let suite = "ExecutionPolicy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = RecordLayoutModel(visualDefaults: defaults, notebookConfiguration: { config }, initialSource: source, usesProcessArguments: false)
        addTeardownBlock { @MainActor in
            await model.notebook.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return model
    }
    private func cell(_ code: String, header: String = "r") -> String { "```{" + header + "}\n" + code + "\n```\n" }
    private func check(_ model: RecordLayoutModel, _ code: String) async throws {
        let result = try await model.notebook.runtime.evaluate(.init(cellID: "acceptance", source: code))
        XCTAssertEqual(result.events.last?.payload.status, "completed", result.events.compactMap(\.payload.text).joined())
    }
    private func output(_ model: RecordLayoutModel, _ id: String) -> String {
        model.notebook.outputState(id)?.events.map { switch $0 { case .text(let t), .message(let t), .warning(let t), .error(let t): t; default: "" } }.joined() ?? ""
    }
    func testCommonMathHTMLDivAndRMDHeadersLeaveRealChunksRunnable() async throws {
        let source = "---\ntitle: Test\n---\n# Report\n\n$$\nx^2\n$$\n\n<div>ordinary HTML</div>\n\n:::: {.outer}\n::: {.callout-note}\n" + cell("counter <- 1", header: "r setup, include=FALSE, fig.cap='a,b', fig.width=c(4, 6)") + ":::\n::::\n\n\\[a=b\\]\n" + cell("counter + 1")
        let index = FenceScanner().scan(source)
        XCTAssertTrue(index.issues.isEmpty, index.issues.joined())
        XCTAssertEqual(index.cells.count, 2); XCTAssertTrue(index.cells.allSatisfy(\.canRun))
        XCTAssertEqual(index.cells.first?.label, "setup")
        let model = try model(source)
        XCTAssertEqual(model.notebookJobs(all: true).count, 2)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 2)
        try await check(model, "stopifnot(counter == 1)")
        XCTAssertEqual(model.source, source)
    }
    func testLiteralFencesMathCommentAndHTMLNeverBecomeExecutableOrVirtualR() {
        let fake = cell("do_not_execute <- TRUE")
        let source = "````markdown\n" + fake + "````\n\n$$\n" + fake + "$$\n\n<!--\n" + fake + "-->\n\n<pre>\n" + fake + "</pre>\n\n\\begin{equation}\n" + fake + "\\end{equation}\n\n" + cell("real <- 1") + "\n```r\nshown <- 2\n```\n"
        let index = FenceScanner().scan(source)
        XCTAssertTrue(index.issues.isEmpty)
        XCTAssertEqual(index.cells.count, 1)
        XCTAssertEqual(index.cells.first?.source, "real <- 1\n")
        let map = RCodeDocument(source)
        XCTAssertFalse(map.virtualSource.contains("do_not_execute"))
        XCTAssertTrue(map.virtualSource.contains("real <- 1")); XCTAssertTrue(map.virtualSource.contains("shown <- 2"))
        XCTAssertEqual(map.virtualSource.utf16.count, source.utf16.count)
    }
    func testLocalAmbiguityDoesNotDisableAnEarlierManualChunkButPreflightsBatch() throws {
        for suffix in ["$$\nunclosed", "<!--\nunclosed", "```{r}\nunfinished", "::: {.callout}\n" + cell("inside <- 2"), "> ```{r}\n> 2\n> ```\n"] {
            let source = cell("#| label: good\nx <- 1") + suffix
            let index = FenceScanner().scan(source)
            XCTAssertFalse(index.issues.isEmpty, suffix)
            XCTAssertTrue(try XCTUnwrap(index.cells.first).canRun, suffix)
            let model = try model(source)
            XCTAssertEqual(model.notebookJobs(blockID: "good").count, 1)
            XCTAssertTrue(model.notebookJobs(all: true).isEmpty)
            XCTAssertEqual(model.notebook.state, .notStarted)
        }
    }
    func testDuplicateLabelsRefuseOnlyRelatedChunksAndKeepDistinctDisplayIdentities() throws {
        let source = cell("#| label: same\n1") + cell("#| label: same\n2") + cell("#| label: good\n3")
        let model = try model(source), blocks = model.visualBlocks.blocks(in: source)
        XCTAssertEqual(Set(blocks.map(\.id)).count, 3)
        XCTAssertFalse(blocks[0].canRun); XCTAssertFalse(blocks[1].canRun); XCTAssertTrue(blocks[2].canRun)
        XCTAssertEqual(model.notebookJobs(blockID: "good").count, 1)
        XCTAssertTrue(model.notebookJobs(all: true).isEmpty)
    }
    func testSourceRangesAgreeForUTF16BOMCRLFAndUnclosedLanguageServiceBlock() throws {
        let source = "\u{feff}---\r\ntitle: 中文🙂\r\n---\r\n\r\n~~~~{r setup, echo=FALSE}\r\n中文 <- '🙂'\r\n~~~~\r\n\r\n```{r}\r\nunfinished("
        let index = FenceScanner().scan(source), map = RCodeDocument(source), model = try model(source)
        let displays = model.visualBlocks.blocks(in: source)
        XCTAssertEqual(displays.count, 2); XCTAssertEqual(map.blocks.count, 2)
        for i in displays.indices {
            XCTAssertEqual(displays[i].range, map.blocks[i].fullRange)
            XCTAssertEqual(displays[i].contentRange, map.blocks[i].bodyRange)
            XCTAssertEqual(index.cells[i].sourceRange, displays[i].contentRange)
            XCTAssertNotNil(Range(displays[i].contentRange, in: source))
        }
        XCTAssertTrue(displays[0].canRun); XCTAssertFalse(displays[1].canRun)
        XCTAssertNotNil(map.block(at: source.utf16.count))
        XCTAssertEqual(map.virtualSource.utf16.count, source.utf16.count)
    }
    func testStaticOptionPrecedenceFlowMappingQuotesCommentsAndOrigins() throws {
        let source = "---\ntitle: 'a: # title'\nformat:\n  html:\n    toc: true\nknitr:\n  opts_chunk: {eval: false, error: true}\nexecute: {eval: true, error: false}\n---\n" + cell("#| eval: false # disabled\n#| error: true\nx <- 1", header: "r setup, eval=TRUE, error=FALSE, fig.cap='x,y'")
        let model = try model(source), job = try XCTUnwrap(model.notebookJobs(all: true).first)
        XCTAssertTrue(job.skipped); XCTAssertTrue(job.request.continueOnError)
        let options = try XCTUnwrap(model.visualBlocks.blocks(in: source).first?.options)
        XCTAssertTrue(options.issues.isEmpty, options.issues.joined()); XCTAssertEqual(options.origins["eval"], "#|")
        XCTAssertEqual(options.label, "setup")
        XCTAssertEqual(model.notebookJobs(blockID: "setup").first?.skipped, false)
    }
    func testDocumentDisableCannotBeOverriddenByChunkAndAllSkippedStartsNoR() async throws {
        let source = "---\nexecute: {enabled: false}\n---\n" + cell("#| label: disabled\n#| eval: true\nstop('must not run')")
        let model = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.state, .notStarted); XCTAssertNil(model.notebook.sessionID)
        XCTAssertEqual(model.notebook.completedCount, 0); XCTAssertEqual(model.notebook.skippedCount, 1)
        XCTAssertTrue(try XCTUnwrap(model.outputStates["disabled"]).skipped)
        XCTAssertNotNil(model.notebook.lastRunSummary)
        XCTAssertTrue(model.outputStates.values.allSatisfy { $0.runSummary == nil }, "Batch summary belongs to session status, not the final block")
        XCTAssertEqual(model.source, source)
    }
    func testUnsupportedDynamicAliasesDuplicateControlsAndCodeSubstitutionNeverRunBatch() throws {
        for option in ["eval: [1, 3]", "eval: !expr file.create('unwanted')", "eval: *alias", "<<: *defaults", "error: 'true'", "eval: false\n#| eval: true", "child: child.qmd", "code: stop('replaced')"] {
            let source = cell("#| label: manual\n#| " + option + "\nx <- 1")
            let model = try model(source)
            XCTAssertTrue(model.notebookJobs(all: true).isEmpty, option)
            XCTAssertEqual(model.notebook.state, .notStarted)
            XCTAssertEqual(model.notebookJobs(blockID: "manual").count, 1, option)
            XCTAssertNotNil(model.notebookJobs(blockID: "manual").first?.manualNote)
        }
        for yaml in ["execute: {eval: *alias}", "execute: {eval: true, eval: false}", "execute: &settings {eval: false}", "metadata-files: other.yml", "<<: *defaults", "knitr:\n  opts_chunk: !expr list(eval=FALSE)"] {
            let model = try model("---\n" + yaml + "\n---\n" + cell("1", header: "r named"))
            XCTAssertTrue(model.notebookJobs(all: true).isEmpty, yaml)
            XCTAssertEqual(model.notebookJobs(blockID: "named").count, 1, yaml)
        }
    }
    func testYAMLBlockStringsAndUnrelatedSequencesDoNotMasqueradeAsExecutionOptions() throws {
        let yaml = "title: |\n  Report\n  eval: false\nauthor:\n- name: First\n  affiliation: Here\n- name: Second\nformat:\n  html:\n    css: [a.css, b.css]\nexecute:\n  eval: true\n"
        let model = try model("---\n" + yaml + "---\n" + cell("1"))
        XCTAssertEqual(model.notebookJobs(all: true).count, 1)
        XCTAssertEqual(model.notebookJobs(all: true).first?.skipped, false)
    }
    func testBatchSkipsButExplicitChunkAndSelectionExecuteExactlyTheirSource() async throws {
        let source = cell("#| label: first\ncounter <- 1L") + cell("#| label: off\n#| eval: false\nnot_selected <- TRUE\ncounter <- counter + 10L") + cell("#| label: last\nstopifnot(counter == 1L)")
        let model = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 2); XCTAssertEqual(model.notebook.skippedCount, 1)
        try await check(model, "stopifnot(counter == 1L, !exists('not_selected'))")
        model.runNotebookBlock("off"); await model.notebook.waitUntilIdle()
        try await check(model, "stopifnot(counter == 11L, not_selected)")
        XCTAssertTrue(model.outputStates["off"]?.phase.contains(L10n.string("手动运行，忽略 eval 禁用")) == true)
        let editor = NSTextView(); editor.string = source; model.activeEditor = editor
        editor.setSelectedRange((source as NSString).range(of: "counter <- counter + 10L"))
        model.runNotebookSelection(); await model.notebook.waitUntilIdle()
        try await check(model, "stopifnot(counter == 21L)")
        XCTAssertEqual(model.source, source)
    }
    func testSkippedBatchPreservesExistingResultsAndDoesNotCountThemAsSuccess() async throws {
        let source = cell("#| label: retained\n#| eval: false\n42")
        let model = try model(source)
        model.runNotebookBlock("retained"); await model.notebook.waitUntilIdle()
        let task = model.outputStates["retained"]?.taskID, before = output(model, "retained")
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.outputStates["retained"]?.taskID, task); XCTAssertEqual(output(model, "retained"), before)
        XCTAssertTrue(model.outputStates["retained"]?.skipped == true)
        XCTAssertEqual(model.notebook.completedCount, 0); XCTAssertEqual(model.notebook.skippedCount, 1)
    }
    func testRuntimeErrorTrueContinuesWithinAndAcrossChunksWithoutDoubleEvaluation() async throws {
        let source = cell("count <- 0L\ncount <- count + 1L\nstop('expected failure')\ncount <- count + 10L", header: "r failed, error=TRUE") + cell("#| label: next\ncount <- count + 100L\nstopifnot(count == 111L)")
        let model = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 1); XCTAssertEqual(model.notebook.failedCount, 1)
        XCTAssertEqual(model.notebook.pendingCount, 0); XCTAssertEqual(model.notebook.state, .ready)
        XCTAssertTrue(model.outputStates["failed"]?.failed == true); XCTAssertTrue(output(model, "failed").contains("expected failure"))
        XCTAssertFalse(model.outputStates["next"]?.failed ?? true)
        try await check(model, "stopifnot(count == 111L)")
    }
    func testRuntimeErrorFalseStopsWithinAndAcrossChunks() async throws {
        let source = cell("count <- 1L\nstop('stop here')\ncount <- 2L", header: "r failed, error=FALSE") + cell("#| label: next\ncount <- 3L")
        let model = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 0); XCTAssertEqual(model.notebook.failedCount, 1)
        XCTAssertEqual(model.notebook.pendingCount, 1); XCTAssertNil(model.outputStates["next"])
        try await check(model, "stopifnot(count == 1L)")
    }
    func testSelectionStopsAtFirstErrorEvenWhenChunkAllowsErrors() async throws {
        let code = "count <- 1L\nstop('selection failure')\ncount <- 2L"
        let source = cell("#| label: selected\n#| error: true\n" + code), model = try model(source)
        let editor = NSTextView(); editor.string = source; model.activeEditor = editor
        editor.setSelectedRange((source as NSString).range(of: code))
        model.runNotebookSelection(); await model.notebook.waitUntilIdle()
        try await check(model, "stopifnot(count == 1L)")
        XCTAssertTrue(model.outputStates["selected"]?.failed == true)
    }
    func testParseFailureWithErrorTrueMayContinueNextChunkWithoutGuessingExpressions() async throws {
        let model = try model(cell("broken <- (", header: "r broken, error=TRUE") + cell("#| label: next\nworked <- TRUE"))
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.failedCount, 1); XCTAssertEqual(model.notebook.completedCount, 1)
        try await check(model, "stopifnot(worked)")
    }
    func testErrorTrueCannotBypassOutputResourceLimits() async throws {
        let model = try model(cell("cat(strrep('x', 2100000))", header: "r limit, error=TRUE") + cell("#| label: next\nshould_not_run <- TRUE"))
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertNil(model.outputStates["next"])
        XCTAssertNotEqual(model.notebook.state, .ready)
        XCTAssertEqual(model.notebook.pendingCount, 1)
        XCTAssertEqual(model.notebook.failedCount, 1)
    }
    func testErrorTrueCannotBypassRichResourceLimits() async throws {
        let model = try model(cell("knitr::asis_output(strrep('x', 1100000))", header: "r limit, error=TRUE") + cell("#| label: next\nshould_not_run <- TRUE"))
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertNil(model.outputStates["next"])
        XCTAssertNotEqual(model.notebook.state, .ready)
        XCTAssertEqual(model.notebook.failedCount, 1); XCTAssertEqual(model.notebook.pendingCount, 1)
    }
    func testErrorTrueCannotBypassExplicitInterrupt() async throws {
        let model = try model(cell("cat('interrupt-ready\\n')\nSys.sleep(20)", header: "r interrupted, error=TRUE") + cell("#| label: next\nshould_not_run <- TRUE"))
        model.runAllNotebookCells()
        for _ in 0..<100 {
            if output(model, "interrupted").contains("interrupt-ready") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(output(model, "interrupted").contains("interrupt-ready"))
        model.notebook.interrupt(); await model.notebook.waitUntilIdle()
        XCTAssertNil(model.outputStates["next"])
        XCTAssertTrue(model.outputStates["interrupted"]?.stopped == true)
        XCTAssertEqual(model.notebook.stoppedCount, 1); XCTAssertEqual(model.notebook.pendingCount, 1)
    }
    func testAboveAndBelowUseRequestedScopeAndRespectEval() throws {
        let source = cell("#| label: first\n#| eval: false\n1") + cell("#| label: current\n2") + cell("#| label: last\n3") + "\n<!-- unclosed"
        let model = try model(source), editor = NSTextView(); editor.string = source; model.activeEditor = editor
        editor.setSelectedRange((source as NSString).range(of: "2"))
        let above = model.notebookJobs(relative: -1)
        XCTAssertEqual(above.map(\.blockID), ["first"]); XCTAssertTrue(above[0].skipped)
        XCTAssertTrue(model.notebookJobs(relative: 1).isEmpty)
        XCTAssertEqual(model.notebookJobs().first?.blockID, "current")
    }
    func testRestartAndRunAllReplacesSessionAndUsesFreshCurrentSource() async throws {
        let source = cell("#| label: first\ncount <- 1L")
        let model = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        let old = model.notebook.sessionID
        try await check(model, "old_only <- TRUE")
        model.source = cell("#| label: first\ncount <- 42L\nstopifnot(!exists('old_only'))")
        model.notebook.restart(runAllAfter: true); await model.notebook.waitUntilIdle()
        XCTAssertNotEqual(model.notebook.sessionID, old)
        XCTAssertEqual(model.notebook.completedCount, 1)
        try await check(model, "stopifnot(count == 42L, !exists('old_only'))")
    }
    func testOrdinaryDisplayRFenceIsNotABatchCandidate() throws {
        let source = "```r\nstop('display only')\n```\n" + cell("1")
        let model = try model(source)
        XCTAssertEqual(model.notebookJobs(all: true).count, 1)
        XCTAssertEqual(model.visualBlocks.blocks(in: source).count, 2)
    }
    func testInlineCodeCommentsMultilineHTMLAndNestedRawTextNeverLeakExampleR() {
        let fake = cell("must_not_execute <- TRUE")
        let source = "Inline `<!--` and `$$` examples.\n\n<div\nclass='outer'>\n<pre>\n</div>\n" + fake + "</pre>\n</div>\n\n<custom-element>\n" + fake + "</custom-element>\n\nInline math $$\n" + fake + "$$\n\n" + cell("real <- 1")
        let index = FenceScanner().scan(source)
        XCTAssertTrue(index.issues.isEmpty, index.issues.joined())
        XCTAssertEqual(index.cells.count, 1)
        XCTAssertEqual(index.cells.first?.source, "real <- 1\n")
        XCTAssertFalse(RCodeDocument(source).virtualSource.contains("must_not_execute"))
    }
    func testQuotedRHeaderBooleansStayStringsAndEscapedCaptionsRemainValid() throws {
        let source = cell("1", header: "r named, fig.cap='can\\'t, split', eval=FALSE")
        let model = try model(source)
        XCTAssertTrue(try XCTUnwrap(model.notebookJobs(all: true).first).skipped)
        for literal in ["'false'", "\"true\"", "T", "F", "c(1, 2)", "file.create('must-not-execute')"] {
            let model = try self.model(cell("1", header: "r named, eval=" + literal))
            XCTAssertTrue(model.notebookJobs(all: true).isEmpty, literal)
            XCTAssertEqual(model.notebookJobs(blockID: "named").count, 1)
        }
    }
    func testHeaderChangeInvalidatesOutputHashWithoutMovingAnonymousIdentity() throws {
        let source = cell("42", header: "r, error=FALSE"), index = RecordVisualBlockIndex()
        let old = try XCTUnwrap(index.blocks(in: source).first)
        let next = try XCTUnwrap(index.blocks(in: source.replacingOccurrences(of: "FALSE", with: "TRUE")).first)
        XCTAssertEqual(next.id, old.id)
        XCTAssertNotEqual(next.sourceHash, old.sourceHash)
    }
    func testLargeNotebookRangeMappingRemainsBoundedAndPreservesSource() throws {
        let source = "\u{feff}---  \r\ntitle: 中文🙂\r\nexecute: {error: false}\r\n---  \r\n" + (0..<500).map {
            "# Section \($0)\n\n$$ x^2 $$\n\n::: {.callout-note}\n" + cell("#| label: chunk-\($0)\nx <- c(1, 2, 3)\nmean(x)") + ":::\n\n"
        }.joined()
        let start = ProcessInfo.processInfo.systemUptime
        let index = FenceScanner().scan(source), virtual = RCodeDocument(source)
        let duration = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(index.cells.count, 500); XCTAssertTrue(index.cells.allSatisfy(\.canRun))
        XCTAssertEqual(virtual.virtualSource.utf16.count, source.utf16.count)
        XCTAssertTrue(index.defaults.issues.isEmpty)
        XCTAssertLessThan(duration, 3, "Source indexing and virtual mapping must stay bounded for a 500-chunk document")
        print("NOTEBOOK_INDEX_PERFORMANCE bytes=\(source.utf8.count) chunks=500 twoIndexesSeconds=\(duration)")
    }
    func testNativeSkippedManualAndBatchNotesAreVisibleWithoutCoveringOutputTabs() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(400), 840] {
                for kind in 0..<3 {
                    let shelf = RecordOutputShelf(frame: NSRect(x: 0, y: 0, width: width, height: 140))
                    shelf.appearance = NSAppearance(named: appearance)
                    var state = RecordOutputLayout.State(hash: "source")
                    state.isSample = false; state.events = [.text("old result")]
                    shelf.configure(id: "note", state: state, stale: false, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                    shelf.layoutSubtreeIfNeeded()
                    XCTAssertTrue(shelf.titleLabel.isHidden)
                    if kind == 0 { state.skipped = true }
                    if kind == 1 { state.manualNote = L10n.string("手动运行，忽略 eval 禁用"); state.phase = state.manualNote! }
                    if kind == 2 { state.runSummary = "Success 2 · Skipped 1 · Failed 1 · Not run 0" }
                    shelf.configure(id: "note", state: state, stale: false, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                    shelf.layoutSubtreeIfNeeded()
                    XCTAssertTrue(shelf.titleLabel.superview === shelf)
                    XCTAssertFalse(shelf.titleLabel.isHidden)
                    XCTAssertGreaterThan(shelf.titleLabel.frame.width, 100)
                    if kind == 2 { XCTAssertGreaterThan(shelf.titleLabel.frame.width, 200) }
                    XCTAssertTrue(shelf.bounds.contains(shelf.titleLabel.frame))
                    XCTAssertTrue(shelf.titleLabel.toolTip?.contains(state.skipped ? L10n.string("本次已跳过 · eval 禁用") : state.phase) == true)
                    let tabFrames = shelf.tabButtons.map { $0.convert($0.bounds, to: shelf) }
                    XCTAssertTrue(tabFrames.allSatisfy { !$0.intersects(shelf.titleLabel.frame) })
                }
            }
        }
    }
}
