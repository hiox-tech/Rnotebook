import Foundation

enum NotebookDocumentType {
    static let quarto = "org.quarto.qmarkdown"
    static let rMarkdown = "com.rstudio.rmarkdown"
    static let legacyQuarto = "org.quarto.qmd"
    static let legacyRMarkdown = "org.hiox.Rnotebook.rmd"

    static func canonicalIdentifier(for identifier: String) -> String? {
        switch identifier.lowercased() {
        case quarto, legacyQuarto: quarto
        case rMarkdown, legacyRMarkdown: rMarkdown
        default: nil
        }
    }

    static func supports(_ url: URL) -> Bool {
        url.isFileURL && ["qmd", "rmd"].contains(url.pathExtension.lowercased())
    }

    static func displayName(for identifier: String, extension suffix: String? = nil) -> String? {
        if canonicalIdentifier(for: identifier) == quarto || suffix?.lowercased() == "qmd" { return "Quarto(.qmd)" }
        if canonicalIdentifier(for: identifier) == rMarkdown || suffix?.lowercased() == "rmd" { return "R Markdown(.Rmd)" }
        return nil
    }

    static func identifier(for url: URL) -> String {
        url.pathExtension.lowercased() == "rmd" ? rMarkdown : quarto
    }
}
