import ArrumatorCore
import Foundation

/// The prompts the model reads documents and search requests with, bundled with this module (`Prompts/*.md`).
public enum PromptLibrary {
    static let names = ["labels-system", "archive-labels", "document-user", "repair-user", "search-system", "search-archive", "search-user"]

    public static func bundled() throws -> PromptTemplates {
        try PromptTemplates.bundled(names, in: .module)
    }
}
