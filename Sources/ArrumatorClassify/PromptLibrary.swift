import ArrumatorCore
import Foundation

/// The prompts the model reads documents and search requests with, and answers questions about a task's documents with,
/// bundled with this module (`Prompts/*.md`).
public enum PromptLibrary {
    static let names = ["labels-system", "archive-labels", "document-user", "repair-user", "search-system", "search-archive", "search-user",
                        "conversation-system", "conversation-user", "conversation-document", "conversation-listed", "conversation-unlisted",
                        "conversation-empty", "conversation-history", "conversation-exchange"]

    public static func bundled() throws -> PromptTemplates {
        try PromptTemplates.bundled(names, in: .module)
    }
}
