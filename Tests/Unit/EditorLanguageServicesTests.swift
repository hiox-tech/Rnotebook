import AppKit
import Darwin
import XCTest
@testable import Rnotebook

@MainActor final class EditorLanguageServicesTests: XCTestCase {
    func testRScannerAllocationFailuresReleaseAllOwnedBuffers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Rnotebook-scanner-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("scanner-allocation-test")
        let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-std=c11", "-I", root.appendingPathComponent("ThirdParty/LanguageTools/TreeSitter/r/src").path,
                             root.appendingPathComponent("Tests/Native/RScannerAllocationTests.c").path, "-o", executable.path]
        try compile.run(); compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        guard compile.terminationStatus == 0 else { return }
        let probe = Process(); probe.executableURL = executable
        try probe.run(); probe.waitUntilExit()
        XCTAssertEqual(probe.terminationStatus, 0, "Both failed allocations and normal create/destroy must release all buffers")
    }
    private func settings(enabled: Bool = false) throws -> SourceEditorSettings {
        let name = "LanguageServices."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        addTeardownBlock { defaults.removePersistentDomain(forName:name) }
        let settings = SourceEditorSettings(defaults:defaults); settings.completionEnabled = enabled
        return settings
    }
    private func offset(_ text: String, _ marker: String) throws -> Int {
        let range = (text as NSString).range(of:marker)
        return try XCTUnwrap(range.location == NSNotFound ? nil : range.location)
    }
    func testQMDMaskPreservesUTF16AndCrossBlockRWithoutProseOrOtherLanguages() throws {
        let source = "---\ntitle: 中文🙂\n---\n# Markdown\n```{r one}\ncross_chunk <- 1\n```\n\n```python\nnot_r = 2\n```\n\n~~~{r}\ncross_chu\n~~~\n"
        let map = RCodeDocument(source)
        XCTAssertEqual(map.blocks.count,2)
        XCTAssertEqual(map.virtualSource.utf16.count,source.utf16.count)
        XCTAssertEqual(map.virtualSource.components(separatedBy:"\n").count,source.components(separatedBy:"\n").count)
        XCTAssertTrue(map.virtualSource.contains("cross_chunk <- 1"))
        XCTAssertFalse(map.virtualSource.contains("Markdown")); XCTAssertFalse(map.virtualSource.contains("not_r"))
        XCTAssertNil(map.block(at:try offset(source,"Markdown")))
        XCTAssertNotNil(map.block(at:try offset(source,"cross_chu")))
        XCTAssertEqual((map.virtualSource as NSString).range(of:"cross_chunk").location,(source as NSString).range(of:"cross_chunk").location)
    }
    func testPositionRoundTripIncludesEmojiChineseCRLFAndRejectsSurrogateHalf() throws {
        let source = "标题🙂\r\n```{r}\r\n中文 <- \"🙂\"; 中文\r\n```\r\n"
        let map = RCodeDocument(source)
        let location = try offset(source,"; 中文")+2
        let pos = map.position(at:location)
        XCTAssertEqual(map.offset(line:pos["line"]!,character:pos["character"]!),location)
        XCTAssertEqual(map.prefix(at:location+2).0,"中文")
        let emoji = try offset(source,"🙂")
        XCTAssertNil(map.offset(line:0,character:emoji+1))
    }
    func testUnclosedFenceAvailableForCompletionButMarkdownAndOtherFenceRemainMasked() {
        let source = "```python\n```{r}\n```\n\n```{r}\nunfinished <- 1\nunf"
        let map = RCodeDocument(source)
        XCTAssertEqual(map.blocks.count,1); XCTAssertFalse(map.blocks[0].closed)
        XCTAssertNotNil(map.block(at:source.utf16.count))
        XCTAssertFalse(map.virtualSource.contains("python"))
    }
    func testTreeSitterRTokensDistinguishFunctionsReturnStringsRawStringsAndUnicode() throws {
        let lexer = try RecordRTokenSource()
        XCTAssertTrue(lexer.version.hasPrefix("tree-sitter"))
        let source = "# 中文🙂\nf <- function(参数 = 2) { mean(参数); return(r\"(a#b)\") }\n"
        let tokens = try XCTUnwrap(lexer.tokens(source))
        func scope(_ string:String) throws -> String? {
            let at = try offset(source,string)
            return tokens.first { NSLocationInRange(at,$0.range) }?.scope
        }
        XCTAssertEqual(try scope("# 中文"),"comment")
        XCTAssertEqual(try scope("function"),"keyword")
        XCTAssertEqual(try scope("mean"),"function")
        XCTAssertEqual(try scope("return"),"keyword")
        XCTAssertEqual(try scope("a#b"),"string")
        XCTAssertTrue(tokens.allSatisfy { Range($0.range,in:source) != nil })
        XCTAssertEqual(lexer.tokens(source)?.count,tokens.count)
        let edited = source.replacingOccurrences(of:"mean",with:"sum")
        XCTAssertTrue(try XCTUnwrap(lexer.tokens(edited)).contains { $0.scope == "function" && (edited as NSString).substring(with:$0.range) == "sum" })
    }
    func testTreeSitterMarkdownHighlightsHeadingStrongLinksAndInlineCode() throws {
        let lexer = try RecordRTokenSource()
        let source = "# 标题🙂\n\n**strong** and *emphasis* [link](https://example.org) `x <- 1`\n"
        let tokens = try XCTUnwrap(lexer.tokens(source,language:"markdown"))
        for scope in ["heading","strong","emphasis","link","code"] {
            XCTAssertTrue(tokens.contains { $0.scope == scope },scope)
        }
    }
    func testNativeCodeAndVisualUseRTreeSitterWithoutChangingSourceOrUndo() throws {
        let source = "# 标题\n\n```{r}\n# 中文🙂\nf <- function(x = 2) { mean(x); return(\"string\") }\nresult <- stats::median(c(1, NA, TRUE))\n```\n"
        let preferences = try settings()
        preferences.fontSize = 16
        let model = RecordLayoutModel(visualDefaults:preferences.defaults,initialSource:source,usesProcessArguments:false)
        model.visualCodeFontSize = 12
        let host = RecordNativeEditorHost(model:model,sourceSettings:preferences)
        defer { host.detach() }
        let probes = [("f <-", "function"), ("mean", "function"), ("median", "function"),
                      ("function", "keyword"), ("return", "keyword"),
                      ("string", "string"), ("2", "number"),
                      ("NA", "literal"), ("TRUE", "literal"),
                      ("# 中文", "comment"), ("result", "plain")]
        var functionColors: [NSColor] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named:appearance)
            for caret in [0, try offset(source,"mean")] {
                var snapshots: [[NSColor]] = []
                for code in [false,true,false,true] {
                    host.editor.setSelectedRange(NSRange(location:caret,length:0))
                    model.sourceOnly = code; host.update()
                    XCTAssertEqual(host.editor.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]),appearance)
                    let storage = try XCTUnwrap(host.editor.textStorage)
                    snapshots.append(try probes.map { marker, scope in
                        let location = try offset(source,marker)
                        XCTAssertEqual(storage.attribute(RecordRSyntaxAdapter.scopeKey,at:location,effectiveRange:nil) as? String,scope)
                        XCTAssertEqual((storage.attribute(.font,at:location,effectiveRange:nil) as? NSFont)?.pointSize,code ? 16 : 12)
                        return try XCTUnwrap(storage.attribute(.foregroundColor,at:location,effectiveRange:nil) as? NSColor)
                    })
                    XCTAssertEqual(model.source,source); XCTAssertEqual(host.editor.rawSource,source)
                    XCTAssertFalse(host.editor.canUndoSource)
                }
                for snapshot in snapshots {
                    XCTAssertEqual(snapshot,snapshots[1],"R token colors must match Code in \(appearance.rawValue), caret \(caret)")
                    XCTAssertNotEqual(snapshot[0],snapshot.last,"Function names must remain distinct from plain identifiers")
                }
                if caret == 0 { functionColors.append(snapshots[1][0]) }
            }
        }
        XCTAssertNotEqual(functionColors[0],functionColors[1],"The shared palette must still adapt to light/dark appearance")
        XCTAssertEqual(preferences.fontSize,16); XCTAssertEqual(model.visualCodeFontSize,12)
        XCTAssertEqual(model.notebook.state,.notStarted)
    }
    func testCompletionSettingPersistsBothStatesAndDefaultsOn() throws {
        let value = try settings(enabled:true)
        XCTAssertTrue(SourceEditorSettings(defaults:value.defaults).completionEnabled)
        value.completionEnabled = false
        XCTAssertFalse(SourceEditorSettings(defaults:value.defaults).completionEnabled)
        value.defaults.removeObject(forKey:"sourceEditor.completionEnabled")
        XCTAssertTrue(SourceEditorSettings(defaults:value.defaults).completionEnabled)
    }
    func testCompletionDisabledOrMarkdownNeverStartsRaven() async throws {
        let preferences = try settings(enabled:false)
        let model = RecordLayoutModel(initialSource:"```{r}\nmea\n```\n",usesProcessArguments:false)
        let host = RecordNativeEditorHost(model:model,sourceSettings:preferences)
        defer { host.detach() }
        host.editor.setSelectedRange(NSRange(location:try offset(model.source,"mea")+3,length:0))
        host.completion?.schedule(manual:true)
        try await Task.sleep(for:.milliseconds(300))
        let disabled = await host.completion?.session.processID
        XCTAssertNil(disabled)
        preferences.completionEnabled = true
        host.loadSynchronizedSource("# prose\n")
        host.editor.setSelectedRange(NSRange(location:3,length:0))
        host.completion?.schedule(manual:true)
        try await Task.sleep(for:.milliseconds(250))
        let prose = await host.completion?.session.processID
        XCTAssertNil(prose)
    }
    func testAirFormatsOnlyCurrentRBodyAndPreservesOptionsYamlProseOtherBlocks() async throws {
        let source = "---\ntitle: 中文🙂\n---\n# **正文**\n\n```{r}\n#| label: keep\n#| echo: false\nx<-c(1,2,3)\n```\n\n```{r}\ny<-2\n```\n"
        let selection = NSRange(location:try offset(source,"x<-"),length:0)
        let edit = try await RAirFormatter.format(source:source,selection:selection,documentURL:nil)
        let formatted = (source as NSString).replacingCharacters(in:edit.range,with:edit.replacement)
        XCTAssertTrue(formatted.contains("x <- c(1, 2, 3)"))
        XCTAssertTrue(formatted.contains("#| label: keep\n#| echo: false\n"))
        XCTAssertTrue(formatted.hasPrefix("---\ntitle: 中文🙂\n---\n# **正文**\n"))
        XCTAssertTrue(formatted.hasSuffix("```{r}\ny<-2\n```\n"))
    }
    func testAirPreservesCRLFIndentAndIsIdempotent() async throws {
        let source = "  ~~~{r}\r\n  #| echo: true\r\n  x<-c(1,2)\r\n  ~~~\r\n"
        let selection = NSRange(location:try offset(source,"x<-"),length:0)
        let edit = try await RAirFormatter.format(source:source,selection:selection,documentURL:nil)
        XCTAssertTrue(edit.replacement.contains("  x <- c(1, 2)\r\n"))
        XCTAssertFalse(edit.replacement.replacingOccurrences(of:"\r\n",with:"").contains("\n"))
        let next = (source as NSString).replacingCharacters(in:edit.range,with:edit.replacement)
        let again = try await RAirFormatter.format(source:next,selection:selection,documentURL:nil)
        XCTAssertEqual(again.replacement,edit.replacement)
    }
    func testAirRejectsProsePythonUnclosedAndInvalidRWithoutChangingDocument() async throws {
        for source in ["text\n", "```python\nx=1\n```\n", "```{r}\nx<-\n", "```{r}\nf(]x\n```\n"] {
            let selection = NSRange(location:source.contains("x") ? (source as NSString).range(of:"x").location : 0,length:0)
            do { _ = try await RAirFormatter.format(source:source,selection:selection,documentURL:nil); XCTFail("Unexpected format success: \(source)") }
            catch {}
        }
    }
    func testAirNativeFormattingIsOneUndoAndStaleResultCannotReplaceNewInput() async throws {
        let source = "```{r}\nx<-c(1,2)\n```\n"
        let model = RecordLayoutModel(initialSource:source,usesProcessArguments:false)
        let host = RecordNativeEditorHost(model:model,sourceSettings:try settings())
        defer { host.detach() }
        host.editor.setSelectedRange(NSRange(location:try offset(source,"x<-"),length:0))
        model.formatCurrentRBlock()
        for _ in 0..<100 { if model.source != source { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(model.source.contains("x <- c(1, 2)"))
        host.undoSource(nil); XCTAssertEqual(model.source,source)
        model.formatCurrentRBlock()
        host.editor.insertText("# newer\n",replacementRange:NSRange(location:0,length:0)); host.publishCommittedText()
        let newer = model.source
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(model.source,newer)
    }
    private func complete(_ session:RavenSession, _ code:String) async throws -> ([RCompletionCandidate],String?) {
        let cursor = try offset(code,"|")
        let source = code.replacingOccurrences(of:"|",with:"")
        let rscript = try XCTUnwrap(NotebookRExecutable.locate(selected:nil))
        return try await session.complete(source,offset:cursor,rExecutable:rscript.deletingLastPathComponent().appendingPathComponent("R").path,
            libraries:[],environmentKey:"test")
    }
    func testPatchedRavenLocalParametersAndSignatureBeforeExecutionIncludingIncompleteCalls() async throws {
        let session = RavenSession(); defer { Task { await session.stop() } }
        for call in ["myfun(al|)","myfun(al|","myfun(|"] {
            let result = try await complete(session,"```{r}\nmyfun <- function(alpha,beta=2) alpha\n```\n```{r}\n"+call+"\n```\n")
            XCTAssertTrue(result.0.contains { $0.label == "alpha" && $0.isParameter })
            XCTAssertTrue(result.1?.contains("beta = 2") == true, result.1 ?? "missing signature")
        }
    }
    func testPatchedRavenPackageArgumentsAndExactReadRDSSignature() async throws {
        let session = RavenSession(); defer { Task { await session.stop() } }
        let result = try await complete(session,"```{r}\nbase::readRDS(fi|)\n```\n")
        let diagnostic = await session.diagnostic
        XCTAssertTrue(result.0.contains { $0.label == "file" && $0.isParameter },diagnostic)
        let signature = try XCTUnwrap(result.1)
        XCTAssertTrue(signature.contains("refhook")); XCTAssertFalse(signature.contains("object"))
        XCTAssertFalse(signature.contains("compress")); XCTAssertFalse(signature.contains("ascii"))
        let lm = try await complete(session,"```{r}\nstats::lm(wei|\n```\n")
        XCTAssertTrue(lm.0.contains { $0.label == "weights" && $0.isParameter })
        XCTAssertTrue(lm.1?.contains("formula") == true)
    }
    func testPatchedRavenStaticNestedAndReassignedMembersAndStopsItsProcess() async throws {
        let session = RavenSession()
        let nested = try await complete(session,"```{r}\ncfg <- list(db=list(host=1,port=2))\ncfg$db$|\n```\n")
        XCTAssertEqual(Set(nested.0.map(\.label)),["host","port"])
        let reassigned = try await complete(session,"```{r}\nx <- list(before=1)\nx <- list(after=2)\nx$|\n```\n")
        XCTAssertEqual(Set(reassigned.0.map(\.label)),["after"])
        let process = await session.processID
        let pid = try XCTUnwrap(process)
        await session.stop()
        for _ in 0..<100 { if kill(pid,0) != 0 { break }; try await Task.sleep(for:.milliseconds(50)) }
        XCTAssertNotEqual(kill(pid,0),0,"Raven must exit after disable/close")
    }
    func testConcurrentRavenRequestsKeepLatestSourceAndStopCancelsQueuedStarts() async throws {
        let session = RavenSession()
        let first = Task { try await complete(session,"```{r}\na <- list(first=1)\na$|\n```\n") }
        let second = Task { try await complete(session,"```{r}\nb <- list(second=1)\nb$|\n```\n") }
        let responses = try await (first.value,second.value)
        XCTAssertEqual(responses.0.0.map(\.label),["first"])
        XCTAssertEqual(responses.1.0.map(\.label),["second"])
        let queued = Task { try await self.complete(session,"```{r}\nstats::glm(wei|\n```\n") }
        await session.stop()
        _ = try? await queued.value
        // A request explicitly made after stop may start a new service; close
        // that service too, then ensure no queued response resurrects it.
        await session.stop()
        try await Task.sleep(for:.milliseconds(150))
        let pid = await session.processID
        XCTAssertNil(pid)
    }
    func testExistingWorkerRuntimeCompletionDoesNotForceBindingsAndIncludesRealColumns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeCompletion-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let runtime = RRuntime()
        let config = RuntimeConfiguration(executable:try XCTUnwrap(NotebookRExecutable.locate(selected:nil)),
            workerScript:try XCTUnwrap(Bundle(for:RecordNativeEditorHost.self).url(forResource:"worker",withExtension:"R",subdirectory:"NotebookRuntime/Bootstrap")),projectDirectory:root)
        _ = try await runtime.start(config); defer { Task { try? await runtime.stop() } }
        _ = try await runtime.evaluate(.init(cellID:"setup",source:"touches <- 0L; df <- data.frame(real_column=1); cfg <- list(db=list(port=1)); helper <- function(a) a; makeActiveBinding('danger',function(x){touches <<- touches+1L;1},globalenv()); delayedAssign('later',{touches <<- touches+1L;1})"))
        let direct = try await runtime.inspect(.init(operation:.completion,name:"hel"))
        XCTAssertEqual(direct.events.last?.payload.status,"completed",String(describing:direct.events))
        let globals = await runtime.completionItems("hel")
        XCTAssertTrue(globals.contains { $0.label == "helper" })
        let cols = await runtime.completionItems("df$real")
        XCTAssertEqual(cols.map(\.label),["real_column"])
        let nested = await runtime.completionItems("cfg$db$")
        XCTAssertEqual(nested.map(\.label),["port"])
        let active = await runtime.completionItems("danger$"); XCTAssertTrue(active.isEmpty)
        let lazy = await runtime.completionItems("later$"); XCTAssertTrue(lazy.isEmpty)
        let result = try await runtime.evaluate(.init(cellID:"verify",source:"stopifnot(touches == 0L); cat('UNCHANGED')"))
        XCTAssertTrue(result.events.compactMap(\.payload.text).joined().contains("UNCHANGED"))
        async let metadata = runtime.completionItems("hel")
        let execution = try await runtime.evaluate(.init(cellID:"concurrent",source:"cat('EXECUTION_OK')"))
        _ = await metadata
        XCTAssertTrue(execution.events.compactMap(\.payload.text).joined().contains("EXECUTION_OK"))
        try await runtime.stop()
    }
    func testNativeCompletionAcceptUndoVisualAndDisableStopsLiveService() async throws {
        let preferences = try settings(enabled:true)
        let source = "# prose\n\n```{r}\nz_unique_name <- 1\nz_unique_n\n```\n"
        let model = RecordLayoutModel(initialSource:source,usesProcessArguments:false)
        let host = RecordNativeEditorHost(model:model,sourceSettings:preferences)
        let window = NSWindow(contentRect:NSRect(x:100,y:100,width:800,height:500),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { host.detach(); window.orderOut(nil); window.close() }
        let controller = try XCTUnwrap(host.completion)
        for code in [true,false] {
            host.loadSynchronizedSource(source); model.sourceOnly = code; host.update()
            host.editor.setSelectedRange(NSRange(location:try offset(source,"z_unique_n\n")+10,length:0))
            window.makeFirstResponder(host.editor)
            controller.schedule(manual:true)
            for _ in 0..<150 { if !controller.candidates.isEmpty { break }; try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertEqual(controller.candidates.first?.label,"z_unique_name")
            XCTAssertTrue(controller.isPresented)
            try await Task.sleep(for:.milliseconds(120))
            saveWindowImages(prefix:code ? "completion-code" : "completion-visual")
            let popup = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0 !== window })
            let click = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,
                windowNumber:popup.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
            controller.pointerEvent(click)
            XCTAssertTrue(controller.isPresented,"Candidate pointer events must reach the native table")
            controller.acceptSelection(); host.publishCommittedText()
            XCTAssertTrue(model.source.contains("\nz_unique_name\n"),model.source)
            host.undoSource(nil); XCTAssertEqual(model.source,source)
        }
        host.editor.setSelectedRange(NSRange(location:try offset(source,"z_unique_n\n")+10,length:0))
        controller.schedule(manual:true)
        for _ in 0..<100 { if controller.isPresented { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(controller.isPresented)
        let run = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,
            windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
        XCTAssertFalse(controller.handle(run),"Command-Return must reach the notebook execution shortcut")
        XCTAssertEqual(model.source,source)
        let process = await controller.session.processID
        let pid = try XCTUnwrap(process)
        preferences.completionEnabled = false
        for _ in 0..<150 { if kill(pid,0) != 0 { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertNotEqual(kill(pid,0),0)
        XCTAssertTrue(controller.candidates.isEmpty)
        XCTAssertEqual(model.notebook.state,.notStarted)
    }
    private func saveWindowImages(prefix:String) {
        // Screenshots are opt-in, with a caller-selected run directory; never
        // overwrite an earlier session's accepted evidence on a regression run.
        guard let path = ProcessInfo.processInfo.environment["RNOTEBOOK_LANGUAGE_UI_EVIDENCE"] else { return }
        let root = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for (index,window) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let capture = Process(); capture.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
            capture.arguments = ["-x","-l",String(window.windowNumber),root.appendingPathComponent("\(prefix)-\(index).png").path]
            do { try capture.run(); capture.waitUntilExit(); print("LANGUAGE_UI_CAPTURE",prefix,index,capture.terminationStatus) }
            catch { print("LANGUAGE_UI_CAPTURE_UNAVAILABLE",error) }
        }
    }
    func testNativeSettingsEditorShowsCompletionPreferenceInBothAppearances() async throws {
        let controller = NotebookSettingsController(source:try settings(enabled:true))
        controller.selectedTabViewItemIndex = NotebookSettingsPane.allCases.firstIndex(of: .completion)!
        let window = NSWindow(contentViewController:controller)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            window.appearance = NSAppearance(named:appearance)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for:.milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.selectedTabViewItemIndex, NotebookSettingsPane.allCases.firstIndex(of: .completion))
            XCTAssertGreaterThanOrEqual(window.contentView?.bounds.height ?? 0, NotebookSettingsPane.completion.contentHeight)
            saveWindowImages(prefix:"settings-"+name)
        }
    }
    func testNativeCompletionRejectsChangedSourceAndSeparatesDocumentScopes() async throws {
        let preferences = try settings(enabled:true)
        let source = "```{r}\nz_unique_name <- 1\nz_unique_n\n```\n"
        let model = RecordLayoutModel(initialSource:source,usesProcessArguments:false)
        let host = RecordNativeEditorHost(model:model,sourceSettings:preferences)
        defer { host.detach() }
        let controller = try XCTUnwrap(host.completion)
        host.editor.setSelectedRange(NSRange(location:try offset(source,"z_unique_n\n")+10,length:0))
        controller.schedule(manual:true)
        model.source = "# changed\n"
        host.loadSynchronizedSource(model.source)
        try await Task.sleep(for:.milliseconds(500))
        controller.acceptSelection()
        XCTAssertEqual(host.editor.string,"# changed\n"); XCTAssertTrue(controller.candidates.isEmpty)
        let separate = RavenSession()
        let result = try await complete(separate,"```{r}\nz_unique_n|\n```\n")
        XCTAssertFalse(result.0.contains { $0.label == "z_unique_name" })
        await separate.stop(); await controller.session.stop()
    }
}
