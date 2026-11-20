import AppKit
import Combine

@MainActor final class QMDFileSynchronization: ObservableObject {
    struct Conflict: Identifiable {
        let id = UUID()
        let base: String
        let editor: String
        let external: String?
    }
    enum Choice { case editor, external, later }
    private weak var document: QMDDocument?
    private var url: URL?
    private var base = ""
    private var expectedDisk: String?
    private var watcher: QMDFileWatcher?
    private var idle: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var externalTask: Task<Void, Never>?
    private var presentation: Task<Void, Never>?
    private var closed = false
    private var saving = false
    private var reconciling = false
    private let idleOverride: TimeInterval?
    private let maximumOverride: TimeInterval?
    private var preferencesChanged: AnyCancellable?
    var idleDelay: TimeInterval { idleOverride ?? document?.behavior.effectiveIdleDelay ?? 1 }
    var maximumDelay: TimeInterval { maximumOverride ?? document?.behavior.effectiveMaximumDelay ?? 5 }
    var documentName: String { document?.fileURL?.lastPathComponent ?? document?.displayName ?? "" }
    var documentPath: String { document?.fileURL?.path ?? "" }
    @Published private(set) var conflict: Conflict?
    @Published var showingConflict = false
    @Published private(set) var paused = false
    @Published private(set) var failure: String?

    init(document: QMDDocument, idleDelay: TimeInterval? = nil, maximumDelay: TimeInterval? = nil) {
        self.document = document; idleOverride = idleDelay; maximumOverride = maximumDelay
        preferencesChanged = document.behavior.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.cancelSaves()
                if self.document?.sourceIsModified == true { self.sourceChanged() }
                self.notify()
            }
        }
    }
    private func notify() { document?.model.objectWillChange.send() }
    private func cancelSaves() { idle?.cancel(); deadline?.cancel(); idle = nil; deadline = nil }
    func received(_ text: String, at location: URL) {
        base = text; expectedDisk = text; url = location.standardizedFileURL
        conflict = nil; showingConflict = false; paused = false; failure = nil
        cancelSaves(); watch(); notify()
    }
    private func watch() {
        watcher?.stop()
        guard let url, !closed else { return }
        watcher = QMDFileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.scheduleExternalCheck() }
        }
    }
    func relocated(to location: URL?) {
        guard url != nil, url != location?.standardizedFileURL else { return }
        // Native Rename/Move changes fileURL without a new writeSafely call.
        // Keep the baseline and unresolved edits while following the new file.
        url = location?.standardizedFileURL
        watch()
        if url == nil { cancelSaves() }
        else { scheduleExternalCheck() }
    }
    func sourceChanged() {
        guard !closed, !paused, document?.behavior.autosaveEnabled == true, document?.fileURL != nil else { return }
        idle?.cancel()
        idle = Task { [weak self, idleDelay] in
            do { try await Task.sleep(for: .seconds(idleDelay)) } catch { return }
            await self?.saveNow()
        }
        if deadline == nil {
            deadline = Task { [weak self, maximumDelay] in
                do { try await Task.sleep(for: .seconds(maximumDelay)) } catch { return }
                await self?.saveNow()
            }
        }
    }
    private func disk(_ location: URL) throws -> String? {
        do { return try String(contentsOf: location, encoding: .utf8) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    private func scheduleExternalCheck() {
        guard !closed else { return }
        externalTask?.cancel()
        externalTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            watcher?.rearm()
            checkExternalChanges()
        }
    }
    func checkExternalChanges() {
        guard !closed, !saving, let document, let url else { return }
        guard document.committedEditorIsReady else { scheduleExternalCheck(); return }
        document.commitEditor()
        do {
            let remote = try disk(url)
            if let conflict {
                if !DocumentRevision.sameSource(conflict.external, remote) || !DocumentRevision.sameSource(conflict.editor, document.model.source) {
                    self.conflict = Conflict(base: conflict.base, editor: document.model.source, external: remote); notify()
                }
                return
            }
            if paused { return }
            _ = reconcile(remote)
        } catch { stopForFailure(error) }
    }
    @discardableResult private func reconcile(_ remote: String?) -> Bool {
        guard let document, !reconciling else { return true }
        guard !DocumentRevision.sameSource(remote, expectedDisk) else { return true }
        let local = document.model.source
        if DocumentRevision.sameSource(remote, local), let remote {
            base = remote; expectedDisk = remote
            if let url { document.acceptedExternalRevision(at: url) }
            document.replaceSynchronizedSource(remote, clean: true)
            notify(); return true
        }
        guard document.behavior.automaticallyReload,
              let remote, let merged = QMDMerge.merge(base: base, editor: local, external: remote) else {
            conflict = Conflict(base: base, editor: local, external: remote)
            paused = true; cancelSaves(); requestComparison(); notify(); return false
        }
        reconciling = true
        base = remote; expectedDisk = remote
        if let url { document.acceptedExternalRevision(at: url) }
        document.replaceSynchronizedSource(merged, clean: DocumentRevision.sameSource(merged, remote))
        reconciling = false
        if !DocumentRevision.sameSource(merged, remote) { sourceChanged() }
        notify(); return true
    }
    func prepareWrite(to destination: URL) throws {
        guard url == destination.standardizedFileURL else { return }
        if conflict != nil { requestComparison(); throw Self.conflictError }
        guard !paused, reconcile(try disk(destination)) else { throw Self.conflictError }
        // Re-check after a merge; only the reviewed/reconciled disk is writable.
        guard DocumentRevision.sameSource(try disk(destination), expectedDisk) else {
            checkExternalChanges(); throw Self.conflictError
        }
    }
    func saveNow(manual: Bool = false) async {
        guard !closed, !saving, let document, let location = document.fileURL else { return }
        guard manual || document.behavior.autosaveEnabled else { cancelSaves(); return }
        if conflict != nil { if manual { requestComparison() }; return }
        if manual { paused = false; failure = nil }
        guard !paused else { return }
        guard document.committedEditorIsReady else { cancelSaves(); sourceChanged(); return }
        document.commitEditor()
        guard document.sourceIsModified else { cancelSaves(); return }
        saving = true; cancelSaves()
        do {
            try await document.save(to: location, ofType: NotebookDocumentType.identifier(for: location), for: .saveOperation)
            failure = nil
        } catch {
            if conflict == nil { stopForFailure(error) }
        }
        saving = false
        if !paused, document.sourceIsModified { sourceChanged() }
        notify()
    }
    private func stopForFailure(_ error: Error) {
        paused = true; cancelSaves(); failure = error.localizedDescription
        document?.model.notice = L10n.string("保存已暂停：") + error.localizedDescription
        notify()
    }
    func requestComparison() {
        guard conflict != nil, !closed else { return }
        checkExternalChanges()
        presentation?.cancel()
        presentation = Task { [weak self] in
            while let self, !closed, conflict != nil {
                guard let window = document?.windowControllers.first?.window else { return }
                if window.attachedSheet == nil || showingConflict {
                    showingConflict = true; notify(); return
                }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
        }
    }
    func resolve(_ choice: Choice) async {
        guard let document, let conflict, let url, !closed else { return }
        if choice == .later { showingConflict = false; paused = true; notify(); return }
        guard document.committedEditorIsReady else { return }
        document.commitEditor()
        do {
            let current = try disk(url)
            guard DocumentRevision.sameSource(current, conflict.external), DocumentRevision.sameSource(document.model.source, conflict.editor) else {
                self.conflict = Conflict(base: conflict.base, editor: document.model.source, external: current); notify(); return
            }
            if choice == .external {
                guard let current else { return }
                received(current, at: url)
                document.acceptedExternalRevision(at: url)
                document.replaceSynchronizedSource(current, clean: true)
            } else {
                expectedDisk = current; base = current ?? conflict.base
                document.acceptedExternalRevision(at: url)
                self.conflict = nil; showingConflict = false; paused = false
                document.replaceSynchronizedSource(conflict.editor, clean: false)
                await saveNow(manual: true)
            }
        } catch { stopForFailure(error) }
        notify()
    }
    func stop() {
        closed = true; preferencesChanged = nil; cancelSaves(); externalTask?.cancel(); presentation?.cancel(); watcher?.stop(); watcher = nil
    }
    static var conflictError: NSError {
        NSError(domain: "Rnotebook", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.string("检测到外部修改，请先比对并选择要使用的版本。")])
    }
}
