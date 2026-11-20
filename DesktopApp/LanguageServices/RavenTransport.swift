import Darwin
import Foundation

/// Owns only its new process group. Never signals the interactive R Worker.
final class RavenTransport: @unchecked Sendable {
    enum Failure: Error { case stopped, protocolError, timeout }
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var sequence = 0
    private var alive = true
    private var reaped = false
    private let input: FileHandle
    private let output: FileHandle
    private let directory: URL
    private let cacheLease: NotebookCacheLease?
    private let settings: Data
    let pid: pid_t
    var isRunning: Bool { lock.withLock { alive } }
    var diagnostic: String { (try? String(contentsOf: directory.appendingPathComponent("server.log"), encoding: .utf8)) ?? "" }

    init(executable: URL, directory: URL, environment: [String: String], settings: Data, cacheLease: NotebookCacheLease? = nil) throws {
        self.directory = directory; self.settings = settings; self.cacheLease = cacheLease
        var toServer: [Int32] = [0,0], fromServer: [Int32] = [0,0]
        guard pipe(&toServer) == 0 else { throw Failure.stopped }
        guard pipe(&fromServer) == 0 else { close(toServer[0]); close(toServer[1]); throw Failure.stopped }
        for fd in toServer+fromServer { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?; var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let inheritedLock = try cacheLease?.inheritLock(in: &actions)
        defer { if let inheritedLock { close(inheritedLock) } }
        posix_spawn_file_actions_adddup2(&actions, toServer[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromServer[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, directory.appendingPathComponent("server.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        for fd in toServer+fromServer { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var mask = sigset_t(); sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGCHLD); sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let argv = [strdup(executable.path), strdup("--stdio"), nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key+"="+$0.value) } + [nil]
        defer { for pointer in argv+envp { free(pointer) } }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&child, executable.path, &actions, &attributes,
                UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
        } }
        close(toServer[0]); close(fromServer[1])
        guard code == 0 else { close(toServer[1]); close(fromServer[0]); throw Failure.stopped }
        pid = child
        input = FileHandle(fileDescriptor: toServer[1], closeOnDealloc: true)
        output = FileHandle(fileDescriptor: fromServer[0], closeOnDealloc: true)
        DispatchQueue.global(qos: .utility).async { [self] in readLoop() }
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            lock.withLock { reaped = true }
            failPending(); kill(-pid, SIGTERM)
            if let cacheLease { try? cacheLease.finish() }
            else { try? FileManager.default.removeItem(at: directory) }
        }
    }
    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var frame = Data("Content-Length: \(data.count)\r\n\r\n".utf8); frame.append(data)
        try lock.withLock {
            guard alive else { throw Failure.stopped }
            try input.write(contentsOf: frame)
        }
    }
    func notify(_ method: String, _ params: Data) throws {
        let value = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed])
        var message: [String:Any] = ["jsonrpc":"2.0", "method":method]
        if !(value is NSNull) { message["params"] = value }
        try send(message)
    }
    func request(_ method: String, _ params: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let id = lock.withLock { sequence += 1; pending[sequence] = continuation; return sequence }
            do {
                let value = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed])
                var message: [String:Any] = ["jsonrpc":"2.0", "id":id, "method":method]
                if !(value is NSNull) { message["params"] = value }
                try send(message)
                DispatchQueue.global().asyncAfter(deadline: .now()+12) { [self] in
                    let waiting = lock.withLock { pending.removeValue(forKey: id) }
                    waiting?.resume(throwing: Failure.timeout)
                }
            } catch {
                lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: error)
            }
        }
    }
    private func readLoop() {
        var buffer = Data(); let boundary = Data("\r\n\r\n".utf8)
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let chunk = Data(bytes.prefix(count))
            buffer.append(chunk)
            while let header = buffer.range(of: boundary) {
                guard let text = String(data: buffer[..<header.lowerBound], encoding: .utf8),
                      let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let count = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)), count >= 0, count <= 8_388_608 else { failPending(); return }
                let start = header.upperBound
                guard buffer.count >= start+count else { break }
                let data = buffer.subdata(in: start..<start+count); buffer.removeSubrange(0..<start+count)
                guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { failPending(); return }
                if let method = message["method"] as? String, let id = message["id"] {
                    var result: Any = NSNull()
                    if method == "workspace/configuration", let params = message["params"] as? [String: Any], let items = params["items"] as? [[String: Any]],
                       let config = try? JSONSerialization.jsonObject(with: settings) {
                        result = items.map { item -> Any in
                            var value: Any = config
                            for part in (item["section"] as? String ?? "").split(separator: ".") { value = (value as? [String: Any])?[String(part)] ?? NSNull() }
                            return value
                        }
                    }
                    try? send(["jsonrpc":"2.0", "id":id, "result":result])
                } else if let id = message["id"] as? Int {
                    let waiting = lock.withLock { pending.removeValue(forKey: id) }
                    if message["error"] != nil { waiting?.resume(throwing: Failure.protocolError) }
                    else { waiting?.resume(returning: data) }
                }
            }
            if buffer.count > 8_388_608 { break }
        }
        failPending()
    }
    private func failPending() {
        let waiters = lock.withLock { alive = false; let values = Array(pending.values); pending.removeAll(); return values }
        for waiter in waiters { waiter.resume(throwing: Failure.stopped) }
    }
    func stop() async {
        let process = pid
        DispatchQueue.global().asyncAfter(deadline: .now()+2) { [self] in
            if lock.withLock({ !reaped }) { kill(-process, SIGTERM) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now()+3) { [self] in
            if lock.withLock({ !reaped }) { kill(-process, SIGKILL) }
        }
        _ = try? await request("shutdown", Data("null".utf8))
        try? notify("exit", Data("null".utf8))
        try? input.close()
    }
}

struct RCompletionCandidate: Codable, Sendable, Equatable {
    let label: String
    let insertion: String
    let detail: String
    var range: NSRange?
    var isParameter: Bool { detail == "parameter" }
}

actor RavenSession {
    private var flight: Task<([RCompletionCandidate], String?), Error>?
    private var flightID: UUID?
    private var epoch = 0
    private var transport: RavenTransport?
    private var key = ""
    private var uri = ""
    private var previous = ""
    private var version = 0
    private var startupTime: TimeInterval = 0
    var processID: pid_t? { transport?.pid }
    var diagnostic: String { key+"\n"+(transport?.diagnostic ?? "") }
    private func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) }
    func complete(_ source: String, offset: Int, rExecutable: String, libraries: [String], environmentKey: String) async throws -> ([RCompletionCandidate], String?) {
        let predecessor = flight
        let id = UUID()
        let expectedEpoch = epoch
        let task = Task {
            _ = try? await predecessor?.value
            try Task.checkCancellation()
            guard epoch == expectedEpoch else { throw CancellationError() }
            return try await performComplete(source, offset: offset, rExecutable: rExecutable, libraries: libraries, environmentKey: environmentKey, expectedEpoch: expectedEpoch)
        }
        flight = task; flightID = id
        defer { if flightID == id { flight = nil; flightID = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func performComplete(_ source: String, offset: Int, rExecutable: String, libraries: [String], environmentKey: String, expectedEpoch: Int) async throws -> ([RCompletionCandidate], String?) {
        try Task.checkCancellation()
        let configuration = rExecutable+"|"+libraries.joined(separator: "\n")+environmentKey
        if key != configuration { await resetTransport(); key = configuration }
        if transport?.isRunning == false { await resetTransport() }
        try Task.checkCancellation()
        guard epoch == expectedEpoch else { throw CancellationError() }
        if transport == nil {
            guard let executable = LanguageToolResources.executable("raven") else { throw RavenTransport.Failure.stopped }
            let lease = try NotebookCacheStore().create(.completion)
            let work = lease.directory
            var handedOff = false
            defer { if !handedOff { try? lease.finish() } }
            let packages: [String: Any] = ["rPath":rExecutable, "additionalLibraryPaths":libraries, "watchLibraryPaths":false, "packageMode":"disabled", "rprofilePrelude":false]
            let settings: [String: Any] = ["raven":["packages":packages, "diagnostics":["enabled":false], "linting":["enabled":false], "crossFile":["indexWorkspace":false, "maxBackwardDepth":0, "maxForwardDepth":0, "onDemandIndexing":["enabled":false]]]]
            // An app-owned project layer pins settings before background discovery.
            let rPath = String(data: try encode(rExecutable), encoding: .utf8)!
            let paths = String(data: try encode(libraries), encoding: .utf8)!
            let config = "[packages]\nrPath = " + rPath + "\nadditionalLibraryPaths = " + paths + "\nwatchLibraryPaths = false\npackageMode = \"disabled\"\nrprofilePrelude = false\n[diagnostics]\nenabled = false\n[linting]\nenabled = false\n[crossFile]\nindexWorkspace = false\nmaxBackwardDepth = 0\nmaxForwardDepth = 0\n[crossFile.onDemandIndexing]\nenabled = false\n"
            try config.write(to: work.appendingPathComponent("raven.toml"), atomically: true, encoding: .utf8)
            let inherited = ProcessInfo.processInfo.environment
            var env: [String:String] = ["PATH":inherited["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG":inherited["LANG"] ?? "en_US.UTF-8"]
            for name in ["HOME", "TMPDIR", "R_LIBS", "R_LIBS_SITE", "R_LIBS_USER"] { env[name] = inherited[name] }
            env["RUST_LOG"] = "warn"
            env["R_USER"] = inherited["R_USER"] ?? FileManager.default.homeDirectoryForCurrentUser.path; env["R_PROFILE_USER"] = "/dev/null"; env["R_ENVIRON_USER"] = "/dev/null"
            let temporary = work.appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            env["TMPDIR"] = temporary.path
            env["XDG_CACHE_HOME"] = work.appendingPathComponent("cache").path
            env["XDG_DATA_HOME"] = work.appendingPathComponent("data").path
            env["RAVEN_NAMES_DB"] = work.appendingPathComponent("no-names.db").path
            if !libraries.isEmpty { env["R_LIBS_USER"] = libraries.joined(separator: ":") }
            uri = work.appendingPathComponent("document.R").absoluteString
            let connection = try RavenTransport(executable: executable, directory: work, environment: env, settings: encode(settings), cacheLease: lease)
            handedOff = true
            transport = connection
            do {
                _ = try await connection.request("initialize", encode(["processId":ProcessInfo.processInfo.processIdentifier,
                    "rootUri":work.absoluteString, "workspaceFolders":[["uri":work.absoluteString,"name":"Rnotebook"]],
                    "initializationOptions":settings["raven"]!, "capabilities":["general":["positionEncodings":["utf-16"]],
                        "workspace":["configuration":true], "textDocument":["completion":["completionItem":["snippetSupport":false]]]]]))
                try Task.checkCancellation()
                guard epoch == expectedEpoch else { throw CancellationError() }
                try connection.notify("initialized", encode([String:String]()))
            } catch { await connection.stop(); if transport === connection { transport = nil }; throw error }
            previous = ""; version = 0; startupTime = ProcessInfo.processInfo.systemUptime
        }
        guard let connection = transport else { throw RavenTransport.Failure.stopped }
        let map = RCodeDocument(source), virtual = map.virtualSource
        if version == 0 {
            version = 1
            try connection.notify("textDocument/didOpen", encode(["textDocument":["uri":uri,"languageId":"r","version":version,"text":virtual]]))
        } else if previous != virtual {
            version += 1
            try connection.notify("textDocument/didChange", encode(["textDocument":["uri":uri,"version":version],"contentChanges":[["text":virtual]]]))
        }
        previous = virtual
        let params: [String:Any] = ["textDocument":["uri":uri],"position":map.position(at: offset)]
        var response = try await connection.request("textDocument/completion", encode(params))
        try Task.checkCancellation()
        guard epoch == expectedEpoch else { throw CancellationError() }
        let lineBefore = (source as NSString).substring(to: offset).components(separatedBy: "\n").last ?? ""
        // initialize precedes asynchronous package discovery. Retry only the
        // first call context while that background metadata becomes available.
        if lineBefore.contains("("), ProcessInfo.processInfo.systemUptime-startupTime < 3 {
            for _ in 0..<12 {
                if String(decoding: response, as: UTF8.self).contains("\"parameter\"") { break }
                try await Task.sleep(for: .milliseconds(100))
                response = try await connection.request("textDocument/completion", encode(params))
            }
        }
        let object = try JSONSerialization.jsonObject(with: response) as? [String:Any]
        let items = object?["result"] as? [[String:Any]] ?? (object?["result"] as? [String:Any])?["items"] as? [[String:Any]] ?? []
        var candidates: [RCompletionCandidate] = []
        for item in items {
            guard let label = item["label"] as? String, item["additionalTextEdits"] == nil else { continue }
            let edit = item["textEdit"] as? [String:Any]
            var range: NSRange?
            if let r = edit?["range"] as? [String:[String:Int]], let start = r["start"], let end = r["end"],
               let a = map.offset(line:start["line"] ?? -1, character:start["character"] ?? -1),
               let b = map.offset(line:end["line"] ?? -1, character:end["character"] ?? -1), b >= a { range = NSRange(location:a,length:b-a) }
            let insertion = edit?["newText"] as? String ?? item["insertText"] as? String ?? label
            guard (item["insertTextFormat"] as? Int ?? 1) == 1 else { continue }
            candidates.append(.init(label:label, insertion:insertion, detail:item["detail"] as? String ?? "", range:range))
        }
        let signatureData = try? await connection.request("textDocument/signatureHelp", encode(params))
        var signature: String?
        if let signatureData, let value = try? JSONSerialization.jsonObject(with: signatureData) as? [String:Any],
           let result = value["result"] as? [String:Any], let rows = result["signatures"] as? [[String:Any]], let label = rows.first?["label"] as? String,
           !label.hasSuffix("(...)") { signature = label }
        return (candidates, signature)
    }
    func stop() async {
        epoch += 1
        flight?.cancel(); flight = nil; flightID = nil
        await resetTransport()
    }
    private func resetTransport() async {
        let old = transport; transport = nil; previous = ""; version = 0
        if let old { await old.stop() }
    }
}
