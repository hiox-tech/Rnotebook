import Foundation

enum NotebookDocumentType {
    static let quarto = "org.quarto.qmd"
    static let rMarkdown = "org.hiox.Rnotebook.rmd"

    static func displayName(for identifier: String, extension suffix: String? = nil) -> String? {
        if identifier.caseInsensitiveCompare(quarto) == .orderedSame || suffix?.lowercased() == "qmd" { return "Quarto(.qmd)" }
        if identifier.caseInsensitiveCompare(rMarkdown) == .orderedSame || suffix?.lowercased() == "rmd" { return "R Markdown(.Rmd)" }
        return nil
    }

    static func identifier(for url: URL) -> String {
        url.pathExtension.lowercased() == "rmd" ? rMarkdown : quarto
    }
}
