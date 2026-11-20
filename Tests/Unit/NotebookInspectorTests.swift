import AppKit
import Darwin
import XCTest
@testable import Rnotebook

@MainActor final class NotebookInspectorTests: XCTestCase {
    private func configuration() throws -> RuntimeConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InspectorTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return RuntimeConfiguration(executable: try XCTUnwrap(NotebookRExecutable.locate(selected: nil)),
            workerScript: try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap")),
            projectDirectory: root, startupTimeout: 10, taskTimeout: 20)
    }
    private func session() async throws -> (RRuntime, RuntimeConfiguration) {
        let config = try configuration(), runtime = RRuntime()
        _ = try await runtime.start(config)
        addTeardownBlock { try await runtime.stop() }
        return (runtime, config)
    }
    private func model(_ source: String) throws -> RecordLayoutModel {
        let config = try configuration(), suite = "InspectorTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = RecordLayoutModel(visualDefaults: defaults, notebookConfiguration: { config }); model.source = source
        addTeardownBlock { @MainActor in await model.notebook.shutdown(); defaults.removePersistentDomain(forName: suite) }
        return model
    }
    @discardableResult private func evaluate(_ runtime: RRuntime, _ source: String) async throws -> RuntimeTranscript {
        let result = try await runtime.evaluate(.init(cellID: "inspector-test", source: source))
        XCTAssertEqual(result.events.last?.payload.status, "completed", result.events.compactMap(\.payload.text).joined())
        return result
    }
    private func snapshot(_ result: RuntimeTranscript) throws -> NotebookInspectorSnapshot {
        XCTAssertEqual(result.events.last?.payload.status, "completed", result.events.compactMap(\.payload.text).joined())
        return try XCTUnwrap(result.events.first(where: { $0.kind == "inspector_result" })?.payload.inspector)
    }
    func testSnapshotNeverForcesBindingsOrCallsUserPrintLengthMethods() async throws {
        let (runtime, _) = try await session()
        try await evaluate(runtime, "touches <- 0L\nlength.tripwire <- function(x) { touches <<- touches + 1L; stop('length called') }\nprint.tripwire <- function(x, ...) { touches <<- touches + 1L; stop('print called') }\nx <- structure(1:3, class='tripwire')\ndat <- head(iris, 2)\nhelper <- function() 1\nmakeActiveBinding('watch', function(value) { touches <<- touches + 1L; 9 }, globalenv())\ndelayedAssign('later', { touches <<- touches + 1L; 9 }, assign.env=globalenv())\nassign('x;touches<-99', 7L, globalenv())\n")
        let first = try snapshot(await runtime.inspect(.init(operation: .snapshot)))
        XCTAssertTrue(first.isValid)
        XCTAssertEqual(first.variables.first(where: { $0.name == "dat" })?.detail, "2 行 × 5 列")
        XCTAssertEqual(first.variables.first(where: { $0.name == "x" })?.detail, "3 个元素")
        XCTAssertEqual(first.variables.first(where: { $0.name == "watch" })?.type, "active binding")
        XCTAssertEqual(first.variables.first(where: { $0.name == "later" })?.type, "promise")
        XCTAssertFalse(first.variables.contains { ["helper", "length.tripwire", "print.tripwire"].contains($0.name) })
        let removed = try snapshot(await runtime.inspect(.init(operation: .removeObject, name: "x;touches<-99")))
        XCTAssertFalse(removed.variables.contains { $0.name == "x;touches<-99" })
        let counter = try await evaluate(runtime, "cat('TOUCHES', touches, '\\n')\n")
        XCTAssertTrue(counter.events.compactMap(\.payload.text).joined().contains("TOUCHES 0"))
    }
    func testVariablePagesSearchTheWholeSnapshotWithoutForcingLateBindings() async throws {
        let (runtime, _) = try await session()
        try await evaluate(runtime, """
        touches <- 0L
        local({ for (i in seq_len(1205)) assign(sprintf('obj_%04d', i), 1:3, envir=.GlobalEnv) })
        assign('zz_[中文]', structure(1:4, class='LateType'), envir=.GlobalEnv)
        hidden_helper <- function() stop('never called')
        makeActiveBinding('zz_watch', function(value) { touches <<- touches + 1L; 9 }, globalenv())
        delayedAssign('zz_later', { touches <<- touches + 1L; 9 }, assign.env=globalenv())
        """)
        let first = try snapshot(await runtime.inspect(.init(operation: .snapshot)))
        let page = try XCTUnwrap(first.variablePage)
        XCTAssertEqual(first.variableTotal, 1209); XCTAssertEqual(page.total, 1209)
        XCTAssertEqual(first.variables.count, 500); XCTAssertTrue(first.isValid)
        var names = first.variables.map(\.name)
        for offset in [500, 1000] {
            let next = try snapshot(await runtime.inspect(.init(operation: .snapshot, refreshPackages: false,
                variablePage: .init(offset: offset, snapshotID: page.snapshotID))))
            XCTAssertEqual(next.variablePage?.offset, offset)
            XCTAssertEqual(next.variablePage?.snapshotID, page.snapshotID)
            XCTAssertTrue(next.isValid); names += next.variables.map(\.name)
        }
        XCTAssertEqual(Set(names).count, 1209)
        XCTAssertTrue(names.contains("obj_1205")); XCTAssertTrue(names.contains("zz_watch")); XCTAssertTrue(names.contains("zz_later"))
        XCTAssertFalse(names.contains("hidden_helper"))
        for query in ["OBJ_1205", "latetype", "4 个元素", "["] {
            let filtered = try snapshot(await runtime.inspect(.init(operation: .snapshot, refreshPackages: false,
                variablePage: .init(query: query, snapshotID: page.snapshotID))))
            XCTAssertEqual(filtered.variables.count, 1, query)
            XCTAssertEqual(filtered.variables.first?.name, query == "OBJ_1205" ? "obj_1205" : "zz_[中文]")
            XCTAssertEqual(filtered.variablePage?.total, 1); XCTAssertTrue(filtered.isValid)
        }
        let none = try snapshot(await runtime.inspect(.init(operation: .snapshot, refreshPackages: false,
            variablePage: .init(query: "absent_1209", snapshotID: page.snapshotID))))
        XCTAssertTrue(none.variables.isEmpty); XCTAssertEqual(none.variablePage?.total, 0); XCTAssertTrue(none.isValid)
        let count = try await evaluate(runtime, "cat('TOUCHES', touches, '\\n')")
        XCTAssertTrue(count.events.compactMap(\.payload.text).joined().contains("TOUCHES 0"))
        try await evaluate(runtime, "rm(obj_0001)")
        let refreshed = try snapshot(await runtime.inspect(.init(operation: .snapshot)))
        XCTAssertNotEqual(refreshed.variablePage?.snapshotID, page.snapshotID)
        let stale = try snapshot(await runtime.inspect(.init(operation: .snapshot, refreshPackages: false,
            variablePage: .init(offset: 500, snapshotID: page.snapshotID))))
        XCTAssertEqual(stale.variablePage?.offset, 0, "An obsolete page must restart from a consistent snapshot")
        XCTAssertNotEqual(stale.variablePage?.snapshotID, page.snapshotID)
        XCTAssertFalse(stale.variables.contains { $0.name == "obj_0001" })
    }
    func testModelLoadsEveryVariableAndFiltersWithoutRunningTheNotebookAgain() async throws {
        let source = "```{r}\n#| label: many-variables\nexecution_count <- 1L\nlocal({ for (i in seq_len(1205)) assign(sprintf('v_%04d', i), i, envir=.GlobalEnv) })\n```\n"
        let model = try model(source), session = model.notebook
        model.runAllNotebookCells(); await session.waitUntilIdle()
        let task = model.outputStates["many-variables"]?.taskID
        let revision = model.outputRevision
        XCTAssertEqual(session.inspectorVariables.count, 500); XCTAssertTrue(session.canLoadMoreVariables)
        session.loadMoreVariables(); await session.waitUntilIdle()
        XCTAssertEqual(session.inspectorVariables.count, 1000)
        session.loadMoreVariables(); await session.waitUntilIdle()
        XCTAssertEqual(session.inspectorVariables.count, 1206); XCTAssertFalse(session.canLoadMoreVariables)
        XCTAssertEqual(Set(session.inspectorVariables.map(\.id)).count, 1206)
        session.filterVariables("V_1205"); await session.waitUntilIdle()
        XCTAssertEqual(session.inspectorVariables.map(\.name), ["v_1205"])
        XCTAssertEqual(session.inspectorVariablePage?.total, 1)
        session.filterVariables("v_0001"); session.filterVariables("v_0801"); await session.waitUntilIdle()
        XCTAssertEqual(session.inspectorVariables.map(\.name), ["v_0801"], "Only the latest filter may populate the list")
        session.manage(.init(operation: .removeObject, name: "v_0801"), expectedSession: session.sessionID)
        await session.waitUntilIdle()
        XCTAssertEqual(session.variableQuery, "v_0801"); XCTAssertTrue(session.inspectorVariables.isEmpty)
        session.filterVariables(""); await session.waitUntilIdle()
        XCTAssertEqual(session.inspectorVariables.count, 500); XCTAssertEqual(session.inspectorVariablePage?.total, 1205)
        let count = try await evaluate(session.runtime, "cat(execution_count)")
        XCTAssertEqual(count.events.filter { $0.kind == "stdout" }.compactMap(\.payload.text).joined(), "1")
        XCTAssertEqual(model.outputStates["many-variables"]?.taskID, task)
        XCTAssertEqual(model.outputRevision, revision + 1, "Only explicit object deletion refreshes result controls")
        XCTAssertEqual(model.source, source)
        session.manage(.init(operation: .clearObjects), expectedSession: session.sessionID); await session.waitUntilIdle()
        XCTAssertTrue(session.inspectorVariables.isEmpty); XCTAssertEqual(session.inspectorVariablePage?.total, 0)
        XCTAssertFalse(session.canLoadMoreVariables)
        let oldSession = session.sessionID
        session.restart(); await session.waitUntilIdle()
        XCTAssertNotEqual(session.sessionID, oldSession); XCTAssertTrue(session.inspectorVariables.isEmpty)
        XCTAssertFalse(session.canLoadMoreVariables)
        session.manage(.init(operation: .snapshot, variablePage: .init(offset: 500, snapshotID: 1)), expectedSession: oldSession)
        XCTAssertFalse(session.isBusy); XCTAssertTrue(session.inspectorVariables.isEmpty)
    }
    func testFilterTypedWhileRIsBusyUsesTheCompletedEnvironmentAndLatestQuery() async throws {
        let source = "```{r}\n#| label: filter-while-busy\nlocal({ for (i in seq_len(705)) assign(sprintf('v_%04d', i), i, envir=.GlobalEnv) })\nSys.sleep(0.4)\n```\n"
        let model = try model(source), session = model.notebook
        model.runAllNotebookCells()
        let deadline = Date(timeIntervalSinceNow: 5)
        while session.activeBlockID == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isBusy)
        session.filterVariables("v_0705"); session.filterVariables("v_0699")
        await session.waitUntilIdle()
        XCTAssertEqual(session.inspectorVariables.map(\.name), ["v_0699"])
        XCTAssertEqual(session.inspectorVariablePage?.query, "v_0699")
        XCTAssertEqual(session.completedCount, 1); XCTAssertEqual(session.state, .ready)
        let token = session.inspectorVariablePage?.snapshotID
        session.filterVariables("v_0705")
        session.manage(.init(operation: .snapshot))
        session.filterVariables("v_0699")
        await session.waitUntilIdle()
        XCTAssertEqual(session.inspectorVariables.map(\.name), ["v_0699"])
        XCTAssertTrue(session.variablesMatchQuery)
        XCTAssertNotEqual(session.inspectorVariablePage?.snapshotID, token)
        XCTAssertEqual(session.inspectorVariablePage?.snapshotID, session.inspectorSnapshot?.variablePage?.snapshotID,
                       "Returning to an earlier query must not keep rows from an obsolete snapshot")
    }
    func testVariableFilterDoesNotStartRAndRejectsInvalidOrUnrelatedPages() async throws {
        let model = try model("No R execution for typing a filter.\n")
        model.notebook.filterVariables("later"); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.state, .notStarted); XCTAssertNil(model.notebook.sessionID)
        XCTAssertFalse(NotebookVariablePageRequest(offset: 500).isValid)
        XCTAssertFalse(NotebookVariablePageRequest(offset: -1, snapshotID: 1).isValid)
        XCTAssertFalse(NotebookVariablePageRequest(query: "x\0").isValid)
        XCTAssertFalse(NotebookInspectorRequest(operation: .previewObject, name: "x", variablePage: .init()).isValid)
        let command = RuntimeCommand(sessionID: UUID(), requestID: UUID(), taskID: UUID(), kind: "inspector",
            inspector: .init(operation: .snapshot, variablePage: .init(query: "new")))
        var payload = NotebookInspectorSnapshot(variables: [.init(name: "x", type: "integer", detail: "1", kind: "numeric")],
            packages: [], variableTotal: 1, packageTotal: 0, installLibrary: "/tmp", repositories: [])
        payload.variablePage = .init(query: "old", offset: 0, total: 1, snapshotID: 1)
        func event(_ sequence: Int, _ kind: String, _ payload: RuntimePayload = .init()) -> RuntimeEnvelope {
            .init(protocolVersion: "1.4", sessionID: command.sessionID, requestID: command.requestID, taskID: command.taskID,
                  sequence: sequence, cellID: nil, sourceHash: nil, kind: kind, payload: payload)
        }
        var validator = ResponseValidator(command: command); try validator.accept(event(1, "started"))
        XCTAssertThrowsError(try validator.accept(event(2, "inspector_result", .init(inspector: payload))))
    }
    func testPackageAttachDetachAndFailuresReflectRealSearchPath() async throws {
        let (runtime, _) = try await session()
        let initial = try snapshot(await runtime.inspect(.init(operation: .snapshot)))
        XCTAssertFalse(try XCTUnwrap(initial.packages.first(where: { $0.name == "MASS" })).loaded)
        XCTAssertTrue(try XCTUnwrap(initial.packages.first(where: { $0.name == "stats" })).protected)
        let attached = try snapshot(await runtime.inspect(.init(operation: .loadPackage, name: "MASS")))
        XCTAssertTrue(try XCTUnwrap(attached.packages.first(where: { $0.name == "MASS" })).loaded)
        let detached = try snapshot(await runtime.inspect(.init(operation: .unloadPackage, name: "MASS")))
        let package = try XCTUnwrap(detached.packages.first(where: { $0.name == "MASS" }))
        XCTAssertFalse(package.loaded); XCTAssertTrue(package.namespaceLoaded)
        for request in [NotebookInspectorRequest(operation: .unloadPackage, name: "stats"), .init(operation: .loadPackage, name: "KailMissingPackage000")] {
            let failed = try await runtime.inspect(request)
            XCTAssertEqual(failed.events.last?.payload.status, "failed")
            let state = await runtime.state; XCTAssertEqual(state, .ready)
            XCTAssertTrue(failed.events.contains { $0.kind == "error" })
        }
        do { _ = try await runtime.inspect(.init(operation: .loadPackage, name: "splines);quit()")); XCTFail("Invalid package name accepted") } catch {}
        let final = try snapshot(await runtime.inspect(.init(operation: .snapshot)))
        XCTAssertFalse(try XCTUnwrap(final.packages.first(where: { $0.name == "MASS" })).loaded)
    }
    func testModelRefreshAfterRunAndDeletionNeverRerunsOrChangesNotebookOutput() async throws {
        let source = "```{r}\n#| label: inspector-live\nexecution_count <- 1L\nx <- 1:4\ncat('once\\n')\n```\n"
        let model = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertTrue(try XCTUnwrap(model.notebook.inspectorSnapshot).variables.contains { $0.name == "x" })
        let task = model.outputStates["inspector-live"]?.taskID, content = model.outputStates["inspector-live"]?.contentID
        model.notebook.manage(.init(operation: .loadPackage, name: "MASS")); await model.notebook.waitUntilIdle()
        XCTAssertTrue(model.notebook.inspectorSnapshot?.packages.first(where: { $0.name == "MASS" })?.loaded == true)
        model.notebook.manage(.init(operation: .removeObject, name: "x"), expectedSession: UUID())
        XCTAssertFalse(model.notebook.isBusy); XCTAssertNotNil(model.notice)
        XCTAssertTrue(model.notebook.inspectorSnapshot?.variables.contains { $0.name == "x" } == true)
        model.notice = nil
        model.notebook.manage(.init(operation: .removeObject, name: "x"), expectedSession: model.notebook.sessionID); await model.notebook.waitUntilIdle()
        XCTAssertFalse(model.notebook.inspectorSnapshot?.variables.contains { $0.name == "x" } == true)
        model.notebook.manage(.init(operation: .loadPackage, name: "KailMissingPackage000")); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.state, .ready); XCTAssertNotNil(model.notebook.inspectorMessage)
        XCTAssertFalse(model.notebook.inspectorSnapshot?.packages.contains { $0.name == "KailMissingPackage000" } == true)
        let count = try await evaluate(model.notebook.runtime, "cat(execution_count)\n")
        XCTAssertEqual(count.events.filter { $0.kind == "stdout" }.compactMap(\.payload.text).joined(), "1")
        XCTAssertEqual(model.outputStates["inspector-live"]?.taskID, task)
        XCTAssertEqual(model.outputStates["inspector-live"]?.contentID, content)
        XCTAssertEqual(model.source, source)
        model.notebook.restart(); await model.notebook.waitUntilIdle()
        XCTAssertTrue(model.notebook.inspectorSnapshot?.variables.isEmpty == true)
        XCTAssertEqual(model.outputStates["inspector-live"]?.taskID, task)
    }
    func testChangedRSelectionBlocksActionsUntilExplicitRestartUsesNewExecutable() async throws {
        let config = try configuration(), suite = "InspectorSelection." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let escapedR = "'" + config.executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var wrappers: [URL] = []
        for marker in ["first", "second"] {
            let path = config.projectDirectory.appendingPathComponent("Rscript-" + marker)
            try Data(("#!/bin/sh\nexport KAIL_INSPECTOR_TARGET=" + marker + "\nexec " + escapedR + " \"$@\"\n").utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path); wrappers.append(path)
        }
        defaults.set(wrappers[0].path, forKey: "notebook.rscript")
        let model = RecordLayoutModel(visualDefaults: defaults, notebookConfiguration: {
            RuntimeConfiguration(executable: URL(fileURLWithPath: defaults.string(forKey: "notebook.rscript")!), workerScript: config.workerScript, projectDirectory: config.projectDirectory, taskTimeout: 20)
        })
        addTeardownBlock { @MainActor in await model.notebook.shutdown(); defaults.removePersistentDomain(forName: suite) }
        model.notebook.manage(.init(operation: .snapshot)); await model.notebook.waitUntilIdle()
        let first = model.notebook.sessionID
        let initial = try await evaluate(model.notebook.runtime, "cat(Sys.getenv('KAIL_INSPECTOR_TARGET'))\n")
        XCTAssertTrue(initial.events.compactMap(\.payload.text).joined().contains("first"))
        defaults.set(wrappers[1].path, forKey: "notebook.rscript")
        XCTAssertTrue(model.notebook.hasPendingRSelection)
        model.notebook.manage(.init(operation: .loadPackage, name: "MASS")); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.sessionID, first); XCTAssertNotNil(model.notice)
        model.notebook.restart(); await model.notebook.waitUntilIdle()
        XCTAssertFalse(model.notebook.hasPendingRSelection); XCTAssertNotEqual(model.notebook.sessionID, first)
        let changed = try await evaluate(model.notebook.runtime, "cat(Sys.getenv('KAIL_INSPECTOR_TARGET'))\n")
        XCTAssertTrue(changed.events.compactMap(\.payload.text).joined().contains("second"))
    }
    func testInstallUsesSelectedSessionLibraryAndOfflineRepositoryThenReportsFailureHonestly() async throws {
        let (runtime, config) = try await session()
        let package = config.projectDirectory.appendingPathComponent("inspectorfixture")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("R"), withIntermediateDirectories: true)
        try Data("Package: inspectorfixture\nVersion: 0.0.1\nTitle: Inspector Fixture\nDescription: Local package for inspector integration validation.\nAuthor: Test User\nMaintainer: Test User <test@example.invalid>\nLicense: GPL-3\n".utf8).write(to: package.appendingPathComponent("DESCRIPTION"))
        try Data("export(inspector_value)\n".utf8).write(to: package.appendingPathComponent("NAMESPACE"))
        try Data("inspector_value <- function() 7L\n".utf8).write(to: package.appendingPathComponent("R/value.R"))
        try await evaluate(runtime, "dir.create('repo/src/contrib', recursive=TRUE)\ndir.create('library')\nold <- setwd('repo/src/contrib')\nbuild_status <- system2(file.path(R.home('bin'), 'R'), c('CMD','build','--no-manual',shQuote('../../../inspectorfixture')))\nsetwd(old)\nstopifnot(build_status == 0L)\ntools::write_PACKAGES('repo/src/contrib', type='source')\n.libPaths(c(normalizePath('library'), .libPaths()))\noptions(repos=c(CRAN=paste0('file://',normalizePath('repo'))), pkgType='source')\n")
        let installed = try snapshot(await runtime.inspect(.init(operation: .installPackage, name: "inspectorfixture")))
        let row = try XCTUnwrap(installed.packages.first(where: { $0.name == "inspectorfixture" }))
        XCTAssertEqual(URL(fileURLWithPath: row.library).resolvingSymlinksInPath(), config.projectDirectory.appendingPathComponent("library").resolvingSymlinksInPath())
        XCTAssertEqual(row.version, "0.0.1"); XCTAssertFalse(row.loaded)
        XCTAssertEqual(row.description, "Inspector Fixture")
        _ = try snapshot(await runtime.inspect(.init(operation: .loadPackage, name: "inspectorfixture")))
        let value = try await evaluate(runtime, "cat(inspector_value())\n")
        XCTAssertTrue(value.events.compactMap(\.payload.text).joined().contains("7"))
        let blocked = try await runtime.inspect(.init(operation: .installPackage, name: "inspectorfixture"))
        XCTAssertEqual(blocked.events.last?.payload.status, "failed")
        XCTAssertTrue(blocked.events.compactMap(\.payload.text).joined().contains("重启"))
        try await evaluate(runtime, "options(repos=c(CRAN=paste0('file://',getwd(),'/missing-repo')))\n")
        let failed = try await runtime.inspect(.init(operation: .installPackage, name: "KailMissingPackage000"))
        XCTAssertEqual(failed.events.last?.payload.status, "failed")
        XCTAssertTrue(failed.events.contains { $0.kind == "warning" })
        let state = await runtime.state; XCTAssertEqual(state, .ready)
    }
    func testHelpDirectlyOpensOfficialResultsWithoutStartingRAndEncodesQueries() async throws {
        let model = try model("No R code is executed by help.\n")
        var opened: URL?
        model.notebook.openHelpURL = { opened = $0; return true }
        for query in ["stats::lm", "中文 回归 + & ? #", "  mean  "] {
            model.notebook.manage(.init(operation: .help, name: query))
            let url = try XCTUnwrap(opened)
            XCTAssertEqual(url.host, "search.r-project.org"); XCTAssertEqual(url.scheme, "https")
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.queryItems?.first { $0.name == "P" }?.value, query.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertTrue(url.absoluteString.contains("FMT=query"))
            if query.contains("+") { XCTAssertTrue(url.absoluteString.contains("%2B")) }
            XCTAssertEqual(model.notebook.state, .notStarted); XCTAssertNil(model.notebook.sessionID)
        }
        opened = nil
        model.notebook.manage(.init(operation: .help, name: "   "))
        XCTAssertNil(opened)
        model.notebook.openHelpURL = { _ in false }
        model.notebook.manage(.init(operation: .help, name: "mean"))
        XCTAssertEqual(model.notebook.inspectorMessage, "未能打开浏览器帮助。")
        XCTAssertEqual(model.notebook.completedCount, 0); XCTAssertTrue(model.outputStates.isEmpty)
        XCTAssertEqual(model.source, "No R code is executed by help.\n")
    }
    func testStoppingSourcePackageInstallCleansItsChildProcessAndRequiresRestart() async throws {
        let (runtime, config) = try await session()
        let package = config.projectDirectory.appendingPathComponent("inspectorfixture")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("R"), withIntermediateDirectories: true)
        try Data("Package: inspectorfixture\nVersion: 0.0.1\nTitle: Installer Cancellation Fixture\nDescription: Local package for installer cancellation validation.\nAuthor: Test User\nMaintainer: Test User <test@example.invalid>\nLicense: GPL-3\n".utf8).write(to: package.appendingPathComponent("DESCRIPTION"))
        try Data("\n".utf8).write(to: package.appendingPathComponent("NAMESPACE"))
        let pidFile = config.projectDirectory.appendingPathComponent("install-child.pid")
        let escapedPIDFile = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let configure = package.appendingPathComponent("configure")
        try Data(("#!/bin/sh\nprintf '%s\\n' \"$$\" > " + escapedPIDFile + "\nsleep 30\nexit 0\n").utf8).write(to: configure)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configure.path)
        try await evaluate(runtime, "dir.create('repo/src/contrib', recursive=TRUE)\ndir.create('library')\nold <- setwd('repo/src/contrib')\nbuild_status <- system2(file.path(R.home('bin'), 'R'), c('CMD','build','--no-manual',shQuote('../../../inspectorfixture')))\nsetwd(old)\nstopifnot(build_status == 0L)\ntools::write_PACKAGES('repo/src/contrib', type='source')\n.libPaths(c(normalizePath('library'), .libPaths()))\noptions(repos=c(CRAN=paste0('file://',normalizePath('repo'))), pkgType='source')\n")
        let installing = Task { try await runtime.inspect(.init(operation: .installPackage, name: "inspectorfixture")) }
        let deadline = Date(timeIntervalSinceNow: 8)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let child = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let worker = await runtime.processID
        XCTAssertEqual(getpgid(child), worker)
        await runtime.interrupt(); _ = try? await installing.value
        let state = await runtime.state; XCTAssertEqual(state, .uncertain)
        try await runtime.stop()
        let exitDeadline = Date(timeIntervalSinceNow: 3)
        while kill(child, 0) == 0 && Date() < exitDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(kill(child, 0), -1, "Installing subprocess must not outlive its R session")
    }
    func testInspectorProtocolRejectsSpoofedBrowserURLsAndCrossTaskEvents() throws {
        XCTAssertNil(NotebookInspectorSnapshot.helpURL("https://example.com/"))
        XCTAssertNil(NotebookInspectorSnapshot.helpURL("file:///etc/passwd"))
        let command = RuntimeCommand(sessionID: UUID(), requestID: UUID(), taskID: UUID(), kind: "inspector", inspector: .init(operation: .snapshot))
        func event(_ sequence: Int, _ kind: String, _ payload: RuntimePayload = .init()) -> RuntimeEnvelope {
            .init(protocolVersion: "1.4", sessionID: command.sessionID, requestID: command.requestID, taskID: command.taskID, sequence: sequence, cellID: nil, sourceHash: nil, kind: kind, payload: payload)
        }
        for bad in [event(2, "display_text", .init(text: "not a panel event")), event(2, "gui_result"), event(2, "finished", .init(status: "completed", uncertain: false))] {
            var validator = ResponseValidator(command: command); try validator.accept(event(1, "started"))
            XCTAssertThrowsError(try validator.accept(bad))
        }
        XCTAssertFalse(NotebookInspectorRequest(operation: .installPackage, name: "x;quit()").isValid)
        XCTAssertTrue(NotebookInspectorRequest(operation: .removeObject, name: "x;quit()").isValid, "Object names are data, not source")
    }
}
