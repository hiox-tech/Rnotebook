import Combine
import Foundation

struct DependencyConfiguration: Equatable, Sendable {
    let rscript: URL?
    let quarto: URL?
    let library: URL
    var repository = "https://cloud.r-project.org"
}

struct DependencyReport: Equatable, Sendable {
    var rVersion: String?
    var quartoVersion: String?
    var missing: [String] = []
    var errors: [String] = []
    var packagesChecked = false
    var ready: Bool { rVersion != nil && quartoVersion != nil && packagesChecked && missing.isEmpty && errors.isEmpty }
}

/// Uses base R only, so missing jsonlite/evaluate cannot prevent repair.
enum DependencyService {
    static let requiredPackages = ["evaluate", "jsonlite", "rlang", "knitr", "rmarkdown"]
    static func environment(_ configuration: DependencyConfiguration) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        let others = (result["R_LIBS"] ?? "").split(separator: ":").map(String.init).filter { $0 != configuration.library.path }
        result["R_LIBS"] = ([configuration.library.path] + others).joined(separator: ":")
        return result
    }
    static func script(install: Bool, packages: [String] = requiredPackages) -> String {
        // Paths/repository are argv values, never interpolated into executable R code.
        """
        args <- commandArgs(TRUE)
        lib <- args[[1L]]
        if (\(install ? "TRUE" : "FALSE")) {
          if (!dir.exists(lib) && !dir.create(lib, recursive=TRUE)) stop("Cannot create package library")
          if (file.access(lib, 2L) != 0L) stop("Package library is not writable")
        }
        .libPaths(c(lib, .libPaths()))
        packages <- c(\(packages.map { "\"" + $0 + "\"" }.joined(separator: ",")))
        available <- function(p) isTRUE(tryCatch(suppressWarnings(requireNamespace(p, quietly=TRUE)), error=function(e) FALSE))
        if (\(install ? "TRUE" : "FALSE")) {
          missing <- packages[!vapply(packages, available, logical(1))]
          if (length(missing)) utils::install.packages(missing, lib=lib, repos=args[[2L]], dependencies=NA, Ncpus=1L)
        }
        cat("RNOTEBOOK_R_VERSION\\t", R.version.string, "\\n", sep="")
        for (p in packages) cat("RNOTEBOOK_PACKAGE\\t", p, "\\t", if (available(p)) "ok" else "missing", "\\n", sep="")
        """
    }
    static func parse(_ output: QuartoProcessOutput, packages: [String] = requiredPackages) -> DependencyReport {
        var report = DependencyReport()
        var found: [String: String] = [:]
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2, parts[0] == "RNOTEBOOK_R_VERSION" { report.rVersion = parts[1] }
            if parts.count == 3, parts[0] == "RNOTEBOOK_PACKAGE", packages.contains(parts[1]), ["ok", "missing"].contains(parts[2]) {
                found[parts[1]] = parts[2]
            }
        }
        report.packagesChecked = packages.allSatisfy { found[$0] != nil }
        report.missing = packages.filter { found[$0] != "ok" }
        if output.cancelled { report.errors.append(L10n.string("操作已取消")) }
        else if output.timedOut { report.errors.append(L10n.string("依赖操作超时")) }
        else if output.exitCode != 0 || !report.packagesChecked || report.rVersion == nil {
            report.errors.append(L10n.string("依赖检测失败，请查看日志"))
        }
        return report
    }
    static func runR(_ configuration: DependencyConfiguration, install: Bool, process: QuartoProcess,
                     packages: [String] = requiredPackages,
                     log: @escaping @Sendable (Int, Data) -> Void = { _, _ in }) async throws -> QuartoProcessOutput {
        guard let executable = configuration.rscript else { throw RuntimeError.unavailable }
        return try await process.run(executable: executable,
            arguments: ["--vanilla", "-e", script(install: install, packages: packages), configuration.library.path, configuration.repository],
            directory: FileManager.default.temporaryDirectory, environment: environment(configuration),
            timeout: install ? 900 : 30, log: log)
    }
}

@MainActor final class EnvironmentDependencies: ObservableObject {
    static let shared = EnvironmentDependencies()
    @Published private(set) var report: DependencyReport?
    @Published private(set) var isBusy = false
    @Published private(set) var isInstalling = false
    @Published private(set) var log = ""
    private var process: QuartoProcess?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private(set) var configuration: DependencyConfiguration?

    func check(_ configuration: DependencyConfiguration) {
        guard !isInstalling else { return }
        start(configuration, install: false)
    }
    func installMissing(_ configuration: DependencyConfiguration) {
        guard !isBusy, self.configuration == configuration,
              let report, report.packagesChecked, !report.missing.isEmpty, report.rVersion != nil else { return }
        start(configuration, install: true)
    }
    func cancel() { process?.cancel(); operation?.cancel() }
    func shutdown() async { cancel(); await operation?.value }

    private func append(_ data: Data, generation: UUID) {
        guard self.generation == generation, log.utf8.count < 1_048_576 else { return }
        log += String(decoding: data.prefix(16_384), as: UTF8.self)
    }
    private func start(_ configuration: DependencyConfiguration, install: Bool) {
        cancel()
        let token = UUID(); generation = token
        self.configuration = configuration
        isBusy = true; isInstalling = install; report = nil; log = ""
        operation = Task { [weak self] in
            guard let self else { return }
            var result = DependencyReport()
            if configuration.rscript == nil { result.errors.append(L10n.string("未找到 Rscript")) }
            else {
                let runner = QuartoProcess(); process = runner
                do {
                    let output = try await DependencyService.runR(configuration, install: install, process: runner) { [weak self] _, data in
                        Task { @MainActor in self?.append(data, generation: token) }
                    }
                    result = DependencyService.parse(output)
                    // A fresh process avoids requireNamespace's cached failures after installation,
                    // and verifies partial installation rather than trusting install.packages' exit code.
                    if install, !output.cancelled, !output.timedOut, !Task.isCancelled {
                        let verification = QuartoProcess(); process = verification
                        let checked = try await DependencyService.runR(configuration, install: false, process: verification)
                        let priorErrors = result.errors
                        result = DependencyService.parse(checked)
                        if !result.missing.isEmpty { result.errors += priorErrors.isEmpty ? [L10n.string("部分依赖未安装成功，请查看日志")] : priorErrors }
                    }
                } catch { result.errors.append(error.localizedDescription) }
            }
            guard generation == token else { return }
            if !Task.isCancelled, let quarto = configuration.quarto {
                let runner = QuartoProcess(); process = runner
                do {
                    let output = try await runner.run(executable: quarto, arguments: ["--version"],
                        directory: FileManager.default.temporaryDirectory, environment: DependencyService.environment(configuration), timeout: 15)
                    if output.exitCode == 0, !output.cancelled, !output.timedOut {
                        let version = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !version.isEmpty { result.quartoVersion = version }
                    }
                    if result.quartoVersion == nil { result.errors.append(L10n.string("Quarto 检测失败")) }
                } catch { result.errors.append(error.localizedDescription) }
            } else if configuration.quarto == nil { result.errors.append(L10n.string("未找到 Quarto")) }
            guard generation == token else { return }
            if Task.isCancelled, !result.errors.contains(L10n.string("操作已取消")) { result.errors.append(L10n.string("操作已取消")) }
            report = result; isBusy = false; isInstalling = false; process = nil
        }
    }
}
